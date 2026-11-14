/*
  S82 El Ünitesi (Kumanda)  v0.1
  ------------------------------------------------------------------
  ESP32-WROOM + 1.3" IPS (ST7789 240x240) + 3 buton + pasif buzzer

  - Telefonun hotspot'una Wi-Fi ile bağlanır, TUSAGA-Aktif'ten (NTRIP) düzeltme çeker
  - S82'ye klasik Bluetooth ile bağlanır: düzeltmeyi gönderir, konumu (NMEA) alır
  - Ekranda: DURUM / APLIKASYON / OLCUM sayfaları
  - Aplikasyon: mesafe, Kuzey/Dogu farki, ok (yukari = kuzey), yaklastikca siklasan bip
  - Ayarlar ve nokta listeleri: telefondan web sayfasi (ekranda IP yazar)

  Kart:     ESP32 Dev Module (WROOM-32)   — S3/C3 OLMAZ (klasik Bluetooth yok)
  Ayar:     Tools > Partition Scheme > "Huge APP (3MB No OTA/1MB SPIFFS)"
  Kütüph.:  Adafruit ST7735 and ST7789 Library, Adafruit GFX Library

  BAĞLANTI (ST7789 7 pinli modül: GND VCC SCL SDA RES DC BLK)
    VCC -> 3V3     GND -> GND
    SCL -> GPIO18  SDA -> GPIO23
    RES -> GPIO17  DC  -> GPIO16   BLK -> GPIO4 (ya da 3V3)
  BUTONLAR (diğer ucu GND'ye):
    MOD  -> GPIO32  (sayfa değiştir)
    SOL  -> GPIO33  (aplikasyon: önceki nokta | ölçüm: ÖLÇ | durum: NTRIP aç/kapa)
    SAĞ  -> GPIO25  (aplikasyon: sonraki nokta | durum: S82'ye yeniden bağlan)
  BUZZER (pasif, 3 V uyumlu): + -> GPIO26, - -> GND

  SPDX-License-Identifier: GPL-2.0-or-later
*/

#include <WiFi.h>
#include <WebServer.h>
#include <Preferences.h>
#include <LittleFS.h>
#include <BluetoothSerial.h>
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include "base64.h"
#include <math.h>
#include "types.h"

#if !defined(CONFIG_IDF_TARGET_ESP32)
#error "Bu kod klasik ESP32 (WROOM-32) icindir. S3/C3'te klasik Bluetooth yok."
#endif

// ---------------- Pinler ----------------
#define TFT_DC   16
#define TFT_RST  17
#define TFT_BLK  4
#define BTN_MOD  32
#define BTN_SOL  33
#define BTN_SAG  25
#define BUZZER   26

Adafruit_ST7789 tft(-1, TFT_DC, TFT_RST);   // CS pini yok (7 pinli modül)
BluetoothSerial SerialBT;
WebServer web(80);
Preferences pref;

// ---------------- Renkler ----------------
#define C_BG     0x0000
#define C_FG     0xFFFF
#define C_DIM    0x8410
#define C_ACC    0xFD20
#define C_GREEN  0x07E0
#define C_RED    0xF800
#define C_BLUE   0x3D7F
#define C_CARD   0x2124

// ---------------- Ayarlar ----------------
struct Cfg {
  String ssid, wpass, host, user, npass, mount, mac, pin;
  int port = 2101, cm = 27;
  float tolCm = 2.0, beepStart = 3.0;
  float antH = 2.0, pco = 0.0884;   // alet yüksekliği, faz merkezi ofseti (m)
  bool fixOnly = true;
} cfg;

void loadCfg() {
  pref.begin("kum", true);
  cfg.ssid = pref.getString("ssid", "");
  cfg.wpass = pref.getString("wpass", "");
  cfg.host = pref.getString("host", "");
  cfg.port = pref.getInt("port", 2101);
  cfg.user = pref.getString("user", "");
  cfg.npass = pref.getString("npass", "");
  cfg.mount = pref.getString("mount", "");
  cfg.mac = pref.getString("mac", "");
  cfg.pin = pref.getString("pin", "1234");
  cfg.cm = pref.getInt("cm", 27);
  cfg.tolCm = pref.getFloat("tol", 2.0);
  cfg.beepStart = pref.getFloat("bstart", 3.0);
  cfg.fixOnly = pref.getBool("fixonly", true);
  cfg.antH = pref.getFloat("anth", 2.0);
  cfg.pco = pref.getFloat("pco", 0.0884);
  pref.end();
}

void saveCfg() {
  pref.begin("kum", false);
  pref.putString("ssid", cfg.ssid); pref.putString("wpass", cfg.wpass);
  pref.putString("host", cfg.host); pref.putInt("port", cfg.port);
  pref.putString("user", cfg.user); pref.putString("npass", cfg.npass);
  pref.putString("mount", cfg.mount); pref.putString("mac", cfg.mac);
  pref.putString("pin", cfg.pin); pref.putInt("cm", cfg.cm);
  pref.putFloat("tol", cfg.tolCm); pref.putFloat("bstart", cfg.beepStart);
  pref.putBool("fixonly", cfg.fixOnly);
  pref.putFloat("anth", cfg.antH); pref.putFloat("pco", cfg.pco);
  pref.end();
}

// ---------------- GNSS durumu ----------------
struct {
  double lat = 0, lon = 0, alt = 0;
  int fix = 0, sats = 0;
  float hdop = 0, age = -1, sLat = -1, sLon = -1;
  uint32_t lastMs = 0, ggaCount = 0;
  char lastGga[120] = "";
} g;

const char *fixText(int q) {
  switch (q) {
    case 1: return "TEKIL";
    case 2: return "DGPS";
    case 4: return "FIX";
    case 5: return "FLOAT";
    case 6: return "TAHMIN";
    default: return "YOK";
  }
}
uint16_t fixColor(int q) { return q == 4 ? C_GREEN : q == 5 ? C_ACC : (q == 1 || q == 2) ? C_BLUE : C_RED; }

bool nmeaChecksumOk(const char *s) {
  const char *star = strrchr(s, '*');
  if (!star || s[0] != '$') return false;
  uint8_t c = 0;
  for (const char *p = s + 1; p < star; p++) c ^= *p;
  return strtol(star + 1, nullptr, 16) == c;
}

double dm2deg(const char *v, char h) {
  double x = atof(v);
  double d = floor(x / 100);
  double r = d + (x - d * 100) / 60.0;
  return (h == 'S' || h == 'W') ? -r : r;
}

void parseNmea(char *line) {
  if (!nmeaChecksumOk(line)) return;
  char buf[120];
  strncpy(buf, line, sizeof(buf) - 1); buf[sizeof(buf) - 1] = 0;
  char *f[20]; int n = 0;
  char *p = buf + 1;
  f[n++] = p;
  while (*p && *p != '*' && n < 20) { if (*p == ',') { *p = 0; f[n++] = p + 1; } p++; }
  if (*p == '*') *p = 0;
  const char *t = f[0];
  if (strlen(t) == 5 && strcmp(t + 2, "GGA") == 0 && n >= 14) {
    g.fix = atoi(f[6]); g.sats = atoi(f[7]); g.hdop = atof(f[8]);
    if (g.fix > 0 && *f[2] && *f[4]) {
      g.lat = dm2deg(f[2], *f[3]); g.lon = dm2deg(f[4], *f[5]); g.alt = atof(f[9]);
    }
    g.age = *f[13] ? atof(f[13]) : -1;
    strncpy(g.lastGga, line, sizeof(g.lastGga) - 1);
    g.lastMs = millis(); g.ggaCount++;
  } else if (strlen(t) == 5 && strcmp(t + 2, "GST") == 0 && n >= 9) {
    g.sLat = atof(f[6]); g.sLon = atof(f[7]);
  }
}

// Zemin kotu = GGA kotu (faz merkezi) - alet yüksekliği - faz merkezi ofseti
double zGround() { return g.alt - cfg.antH - cfg.pco; }

// ---------------- TM 3° (GRS80, k0=1, +500000) ----------------
void tmForward(double latDeg, double lonDeg, int cm, double &Y, double &X) {
  const double a = 6378137.0, f = 1 / 298.257222101;
  const double e2 = f * (2 - f), ep2 = e2 / (1 - e2);
  double phi = latDeg * M_PI / 180, dl = (lonDeg - cm) * M_PI / 180;
  double s = sin(phi), c = cos(phi), t = tan(phi);
  double N = a / sqrt(1 - e2 * s * s), T = t * t, C = ep2 * c * c, A = dl * c;
  double e4 = e2 * e2, e6 = e4 * e2;
  double M = a * ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
             - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi)
             + (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi)
             - (35 * e6 / 3072) * sin(6 * phi));
  Y = N * (A + (1 - T + C) * pow(A, 3) / 6 + (5 - 18 * T + T * T + 72 * C - 58 * ep2) * pow(A, 5) / 120) + 500000.0;
  X = M + N * t * (A * A / 2 + (5 - T + 9 * C + 4 * C * C) * pow(A, 4) / 24
                   + (61 - 58 * T + T * T + 600 * C - 330 * ep2) * pow(A, 6) / 720);
}

// ---------------- Noktalar ----------------
#define MAX_PTS 400
Pt stake[MAX_PTS];
int stakeN = 0, tgt = -1;

bool parsePtLine(String s, Pt &p) {
  s.trim();
  if (s.length() < 5) return false;
  bool semi = s.indexOf(';') >= 0 || s.indexOf('\t') >= 0;
  if (semi) { s.replace(',', '.'); s.replace(';', ' '); s.replace('\t', ' '); }
  else s.replace(',', ' ');
  char b[100]; s.toCharArray(b, sizeof(b));
  char *tok[5]; int n = 0;
  char *save; char *t = strtok_r(b, " ", &save);
  while (t && n < 5) { tok[n++] = t; t = strtok_r(nullptr, " ", &save); }
  if (n < 3) return false;
  char *e1, *e2;
  p.y = strtod(tok[1], &e1); p.x = strtod(tok[2], &e2);
  if (*e1 || *e2 || p.y < 100000 || p.x < 1000000) return false;  // TM aralığı kaba kontrol
  p.z = n > 3 ? atof(tok[3]) : 0;
  strncpy(p.name, tok[0], sizeof(p.name) - 1); p.name[sizeof(p.name) - 1] = 0;
  return true;
}

void loadStake() {
  stakeN = 0;
  File f = LittleFS.open("/apl.ncn", "r");
  if (!f) return;
  while (f.available() && stakeN < MAX_PTS) {
    Pt p;
    if (parsePtLine(f.readStringUntil('\n'), p)) stake[stakeN++] = p;
  }
  f.close();
  if (tgt >= stakeN) tgt = stakeN ? 0 : -1;
  if (tgt < 0 && stakeN) tgt = 0;
}

int measuredCount() {
  File f = LittleFS.open("/olcum.ncn", "r");
  if (!f) return 0;
  int n = 0;
  while (f.available()) if (f.read() == '\n') n++;
  f.close();
  return n;
}

// ---------------- NTRIP ----------------
WiFiClient ntrip;
bool ntripOn = true, ntripOk = false;
String ntripMsg = "Kapali";
uint32_t ntripBytes = 0, lastNtripTry = 0, lastGgaSent = 0, lastNtripData = 0, ntripWait = 5000;

void ntripStop(const char *msg) { ntrip.stop(); ntripOk = false; ntripMsg = msg; }

void ntripLoop() {
  if (!ntripOn) { if (ntripOk || ntrip.connected()) ntripStop("Kapali"); return; }
  if (WiFi.status() != WL_CONNECTED || cfg.host.isEmpty() || cfg.mount.isEmpty()) {
    if (ntripOk) ntripStop("Wi-Fi yok");
    if (cfg.host.isEmpty()) ntripMsg = "Ayar yok";
    return;
  }
  if (!ntripOk) {
    if (millis() - lastNtripTry < ntripWait) return;
    lastNtripTry = millis(); ntripWait = 5000;
    ntripMsg = "Baglaniyor";
    if (!ntrip.connect(cfg.host.c_str(), cfg.port, 5000)) { ntripMsg = "Sunucu yok"; return; }
    String auth = base64::encode(cfg.user + ":" + cfg.npass);
    ntrip.print("GET /" + cfg.mount + " HTTP/1.0\r\nUser-Agent: NTRIP S82Kumanda/0.1\r\n"
                "Authorization: Basic " + auth + "\r\n\r\n");
    uint32_t t0 = millis();
    String head;
    while (millis() - t0 < 5000) {
      while (ntrip.available()) {
        char c = ntrip.read();
        if (c == '\n') goto gotHead;
        if (c != '\r' && head.length() < 80) head += c;
      }
      delay(5);
    }
  gotHead:
    if (head.indexOf("200") < 0) {
      ntripStop(head.length() ? "Red/sifre?" : "Cevap yok");
      ntripWait = 30000;  // hatalı şifrede sunucuyu darlamamak için 30 sn bekle
      return;
    }
    ntripOk = true; ntripMsg = "Bagli"; lastNtripData = millis(); lastGgaSent = 0;
  }
  if (!ntrip.connected() || millis() - lastNtripData > 20000) { ntripStop("Koptu"); return; }
  uint8_t buf[512];
  while (ntrip.available()) {
    int n = ntrip.read(buf, sizeof(buf));
    if (n <= 0) break;
    lastNtripData = millis(); ntripBytes += n;
    if (SerialBT.connected()) SerialBT.write(buf, n);
  }
  if (g.lastGga[0] && millis() - lastGgaSent > 5000) {
    ntrip.print(g.lastGga); ntrip.print("\r\n");
    lastGgaSent = millis();
  }
}

// ---------------- Bluetooth (S82) ----------------
uint32_t lastBtTry = 0;
bool btBusy = false;
char nmeaLine[128]; int nmeaLen = 0;

bool parseMac(const String &s, uint8_t m[6]) {
  int v[6];
  if (sscanf(s.c_str(), "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6) return false;
  for (int i = 0; i < 6; i++) m[i] = v[i];
  return true;
}

void drawAll(bool full);
void btLoop(bool force = false) {
  if (!SerialBT.connected()) {
    if (cfg.mac.isEmpty()) return;
    if (!force && millis() - lastBtTry < 15000) return;
    lastBtTry = millis();
    uint8_t m[6];
    if (!parseMac(cfg.mac, m)) return;
    btBusy = true; drawAll(false);
    SerialBT.connect(m);   // birkaç saniye bloklar
    btBusy = false;
    return;
  }
  while (SerialBT.available()) {
    char c = SerialBT.read();
    if (c == '$') { nmeaLen = 0; }
    if (c == '\n' || c == '\r') {
      if (nmeaLen > 6 && nmeaLine[0] == '$') { nmeaLine[nmeaLen] = 0; parseNmea(nmeaLine); }
      nmeaLen = 0;
    } else if (nmeaLen < (int)sizeof(nmeaLine) - 1 && c >= 32 && c <= 126) {
      nmeaLine[nmeaLen++] = c;
    }
  }
}

// ---------------- Buzzer (sıklaşan bip) ----------------
uint32_t lastBeep = 0, beepOffAt = 0;
void beep(int hz, int ms) { ledcWriteTone(BUZZER, hz); beepOffAt = millis() + ms; }
int beepInterval(double d, double tol, double start) {
  if (d <= tol) return 250;
  double r = (d - tol) / fmax(start - tol, 0.01);
  if (r > 1) r = 1;
  if (r < 0) r = 0;
  return 90 + (int)(1110 * pow(r, 0.8));
}

// ---------------- Ölçüm durumu ----------------
String lastMeasured = "-";
int measEpochs = 5, measGot = 0;
bool measuring = false;
double mY, mX, mZ;
uint32_t measLastGga = 0, measStart = 0;
String nextName();

// ---------------- Ekran ----------------
enum Page { P_DURUM, P_APL, P_OLCUM, P_COUNT };
int page = P_APL;
bool fixFresh() { return g.fix > 0 && millis() - g.lastMs < 3000 && SerialBT.connected(); }

void txt(int x, int y, uint8_t size, uint16_t fg, const String &s, int padTo = 0) {
  String t = s;
  while ((int)t.length() < padTo) t += ' ';
  tft.setTextSize(size); tft.setTextColor(fg, C_BG); tft.setCursor(x, y); tft.print(t);
}

void drawTopBar() {
  int q = fixFresh() ? g.fix : 0;
  const char *lbl = !SerialBT.connected() ? (btBusy ? "BT..." : "BT YOK") : fixText(q);
  uint16_t col = !SerialBT.connected() ? C_DIM : fixColor(q);
  tft.fillRect(0, 0, 96, 26, col);
  tft.setTextSize(2); tft.setTextColor(C_BG, col); tft.setCursor(6, 6); tft.print(lbl);
  char b[24];
  float sig = (g.sLat >= 0) ? sqrt(g.sLat * g.sLat + g.sLon * g.sLon) : -1;
  snprintf(b, sizeof(b), "U%-2d %s", g.sats, sig >= 0 ? (String("+-") + String(sig, 3)).c_str() : "+-?");
  txt(102, 2, 1, C_FG, b, 22);
  snprintf(b, sizeof(b), "N:%s%s", ntripOn ? "" : "-", ntripMsg.c_str());
  txt(102, 14, 1, ntripOk ? C_GREEN : C_DIM, b, 22);
}

int arrowLastA = -999, arrowLastOk = -1;   // tam yeniden çizimde sıfırlanır
void drawArrow(double azDeg, bool ok) {
  int &lastA = arrowLastA; int &lastOk = arrowLastOk;
  int a = isnan(azDeg) ? -500 : (int)round(azDeg / 3) * 3;
  if (a == lastA && (int)ok == lastOk) return;
  lastA = a; lastOk = ok;
  const int cx = 120, cy = 100, r = 52;
  tft.fillCircle(cx, cy, r + 2, C_BG);
  tft.drawCircle(cx, cy, r, ok ? C_GREEN : C_CARD);
  tft.setTextSize(1); tft.setTextColor(C_DIM, C_BG); tft.setCursor(cx - 2, cy - r + 3); tft.print("K");
  if (ok) { tft.fillCircle(cx, cy, 24, C_GREEN); return; }
  if (a == -500) return;
  double th = a * M_PI / 180;
  auto P = [&](double fx, double fy, int &X, int &Y) {   // fx: sağ, fy: yukarı (r oranı)
    X = cx + (int)round(r * (fx * cos(th) + fy * sin(th)));
    Y = cy - (int)round(r * (-fx * sin(th) + fy * cos(th)));
  };
  int x0, y0, x1, y1, x2, y2, x3, y3;
  P(0, 0.85, x0, y0); P(0.32, 0.15, x1, y1); P(-0.32, 0.15, x2, y2);
  tft.fillTriangle(x0, y0, x1, y1, x2, y2, C_ACC);
  P(0.1, 0.15, x1, y1); P(-0.1, 0.15, x2, y2); P(0.1, -0.6, x3, y3);
  tft.fillTriangle(x1, y1, x2, y2, x3, y3, C_ACC);
  P(-0.1, -0.6, x0, y0);
  tft.fillTriangle(x2, y2, x3, y3, x0, y0, C_ACC);
}

String mFmt(double v) { return fabs(v) < 10 ? String(v, 3) : String(v, 1); }

void drawPage(bool full) {
  if (full) { tft.fillRect(0, 28, 240, 212, C_BG); arrowLastA = -999; arrowLastOk = -1; }
  double Y = 0, X = 0;
  bool pos = fixFresh();
  if (pos) tmForward(g.lat, g.lon, cfg.cm, Y, X);

  if (page == P_DURUM) {
    if (full) txt(4, 32, 2, C_ACC, "DURUM");
    txt(4, 56, 2, C_FG, pos ? "Y " + String(Y, 3) : "Y -", 18);
    txt(4, 76, 2, C_FG, pos ? "X " + String(X, 3) : "X -", 18);
    txt(4, 96, 2, C_FG, pos ? "Z " + String(zGround(), 3) : "Z -", 18);
    txt(4, 120, 1, C_DIM, "HDOP " + String(g.hdop, 1) + "  Yas " + (g.age >= 0 ? String(g.age, 0) + "s" : "-") + "  TM" + String(cfg.cm), 38);
    txt(4, 136, 1, C_FG, "S82: " + String(SerialBT.connected() ? "bagli" : (cfg.mac.isEmpty() ? "MAC ayarla" : "bagli degil")), 38);
    txt(4, 150, 1, C_FG, "WiFi: " + (WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : String("hotspot bekleniyor")), 38);
    txt(4, 164, 1, C_FG, "Ayar: " + (WiFi.status() == WL_CONNECTED ? "http://" + WiFi.localIP().toString() : String("AP S82-Kumanda 192.168.4.1")), 38);
    txt(4, 178, 1, C_FG, "Duzeltme: " + String(ntripBytes / 1024) + " kB", 38);
    txt(4, 192, 1, C_DIM, "Apl. nokta: " + String(stakeN) + "  Olculen: " + String(measuredCount()), 38);
    if (full) txt(4, 222, 1, C_DIM, "SOL: NTRIP ac/kapa  SAG: S82 yeniden");
  } else if (page == P_APL) {
    if (tgt < 0) {
      if (full) { txt(4, 60, 2, C_FG, "Nokta yok"); txt(4, 90, 1, C_DIM, "Telefondan web sayfasina"); txt(4, 104, 1, C_DIM, "nokta listesi yukleyin."); }
      return;
    }
    Pt &t = stake[tgt];
    txt(4, 32, 2, C_ACC, String(t.name), 10);
    txt(170, 36, 1, C_DIM, String(tgt + 1) + "/" + String(stakeN), 11);
    if (!pos) { drawArrow(NAN, false); txt(4, 160, 3, C_RED, "KONUM YOK", 13); txt(4, 192, 2, C_FG, "", 19); txt(4, 214, 2, C_FG, "", 19); return; }
    double dy = t.y - Y, dx = t.x - X, d = sqrt(dy * dy + dx * dx);
    bool ok = d <= cfg.tolCm / 100.0;
    double az = fmod(atan2(dy, dx) * 180 / M_PI + 360, 360);
    drawArrow(az, ok);
    txt(4, 160, 3, ok ? C_GREEN : C_FG, mFmt(d) + " m", 13);
    txt(4, 192, 2, C_FG, String(dx >= 0 ? "KUZEY " : "GUNEY ") + String(fabs(dx), 3), 19);
    txt(4, 214, 2, C_FG, String(dy >= 0 ? "DOGU  " : "BATI  ") + String(fabs(dy), 3), 19);
  } else if (page == P_OLCUM) {
    if (full) txt(4, 32, 2, C_ACC, "OLCUM");
    txt(4, 58, 2, C_FG, "Ad: " + nextName(), 18);
    txt(4, 82, 2, measuring ? C_ACC : C_DIM, measuring ? "Olculuyor " + String(measGot) + "/" + String(measEpochs) : "SOL: OLC", 18);
    txt(4, 110, 1, C_DIM, String(cfg.fixOnly ? "Sadece FIX" : "FLOAT de kabul") + "   h=" + String(cfg.antH, 3) + " m", 38);
    txt(4, 130, 1, C_FG, "Son:", 38);
    txt(4, 144, 1, C_FG, lastMeasured, 38);
    txt(4, 166, 2, C_FG, pos ? "Y " + String(Y, 3) : "Y -", 18);
    txt(4, 186, 2, C_FG, pos ? "X " + String(X, 3) : "X -", 18);
    txt(4, 206, 2, C_FG, pos ? "Z " + String(zGround(), 3) : "Z -", 18);
  }
}

void drawAll(bool full) {
  if (full) tft.fillScreen(C_BG);
  drawTopBar();
  drawPage(full);
}

// ---------------- Ölçüm ----------------

String nextName() {
  pref.begin("kum", true); int n = pref.getInt("pno", 1); pref.end();
  return "N" + String(n);
}

void measureLoop() {
  if (!measuring) return;
  if (millis() - measStart > 120000) { measuring = false; lastMeasured = "Zaman asimi"; beep(400, 400); return; }
  if (g.ggaCount == measLastGga) return;
  measLastGga = g.ggaCount;
  bool ok = cfg.fixOnly ? g.fix == 4 : g.fix > 0;
  if (!ok || !fixFresh()) return;
  double Y, X; tmForward(g.lat, g.lon, cfg.cm, Y, X);
  mY += Y; mX += X; mZ += zGround(); measGot++;
  if (measGot < measEpochs) return;
  measuring = false;
  String name = nextName();
  String line = name + " " + String(mY / measGot, 3) + " " + String(mX / measGot, 3) + " " + String(mZ / measGot, 3) + " " + fixText(g.fix) + " h=" + String(cfg.antH, 3);
  File f = LittleFS.open("/olcum.ncn", "a");
  if (f) { f.println(line); f.close(); }
  pref.begin("kum", false); pref.putInt("pno", pref.getInt("pno", 1) + 1); pref.end();
  lastMeasured = line;
  beep(1960, 200);
}

// ---------------- Web ayar sayfası ----------------
String esc(const String &s) { String r = s; r.replace("&", "&amp;"); r.replace("\"", "&quot;"); r.replace("<", "&lt;"); return r; }

void webRoot() {
  String h = F("<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width'>"
               "<title>S82 Kumanda</title><style>body{font-family:sans-serif;background:#111;color:#eee;padding:10px}"
               "input,textarea{width:100%;box-sizing:border-box;margin:3px 0 9px;padding:7px;background:#222;color:#eee;border:1px solid #444}"
               "button{padding:10px 16px;background:#e90;border:0;font-weight:bold}h3{color:#fb3}a{color:#6bf}</style></head><body>");
  h += "<h2>S82 Kumanda</h2><p>Fix: <b>" + String(fixText(fixFresh() ? g.fix : 0)) + "</b> | Uydu " + String(g.sats) +
       " | NTRIP: " + ntripMsg + " | S82: " + (SerialBT.connected() ? "bağlı" : "yok") + "</p>";
  h += "<form method='POST' action='/ayar'><h3>Wi-Fi (telefon hotspot)</h3>";
  h += "Ağ adı<input name='ssid' value=\"" + esc(cfg.ssid) + "\">Şifre<input name='wpass' type='password' value=\"" + esc(cfg.wpass) + "\">";
  h += "<h3>TUSAGA-Aktif (NTRIP)</h3>Sunucu<input name='host' value=\"" + esc(cfg.host) + "\">Port<input name='port' value='" + String(cfg.port) + "'>";
  h += "Kullanıcı<input name='user' value=\"" + esc(cfg.user) + "\">Şifre<input name='npass' type='password' value=\"" + esc(cfg.npass) + "\">";
  h += "Mountpoint (RTCM 3.0/3.1 VRS)<input name='mount' value=\"" + esc(cfg.mount) + "\">";
  h += "<h3>S82 Bluetooth</h3>MAC (ör. 00:12:6F:AA:BB:CC)<input name='mac' value=\"" + esc(cfg.mac) + "\">PIN<input name='pin' value=\"" + esc(cfg.pin) + "\">";
  h += "<h3>Ölçüm / Aplikasyon</h3>Orta meridyen<input name='cm' value='" + String(cfg.cm) + "'>";
  h += "Tolerans (cm)<input name='tol' value='" + String(cfg.tolCm, 1) + "'>Bip başlama mesafesi (m)<input name='bstart' value='" + String(cfg.beepStart, 1) + "'>";
  h += "Sadece FIX iken ölç (1/0)<input name='fixonly' value='" + String(cfg.fixOnly ? 1 : 0) + "'>";
  h += "Alet (jalon) yüksekliği (m)<input name='anth' value='" + String(cfg.antH, 3) + "'>";
  h += "Faz merkezi ofseti (m, S82 L1 = 0.0884)<input name='pco' value='" + String(cfg.pco, 4) + "'>";
  h += "<button>Kaydet</button> (Wi-Fi/MAC değişirse cihaz yeniden başlar)</form>";
  h += "<h3>Aplikasyon noktaları (" + String(stakeN) + ")</h3><form method='POST' action='/apl'>"
       "<textarea name='t' rows='8' placeholder='P1 530854.770 4101902.460 58.27'></textarea>"
       "<label><input type='checkbox' name='ekle' style='width:auto'> mevcut listeye ekle</label><br><button>Yükle</button></form>";
  h += "<h3>Ölçülen noktalar (" + String(measuredCount()) + ")</h3><a href='/olcum.ncn'>olcum.ncn indir</a> | "
       "<a href='/sil' onclick=\"return confirm('Ölçülen noktalar silinsin mi?')\">sil</a></body></html>";
  web.send(200, "text/html; charset=utf-8", h);
}

void webSave() {
  String oldSsid = cfg.ssid, oldW = cfg.wpass, oldMac = cfg.mac, oldPin = cfg.pin;
  cfg.ssid = web.arg("ssid"); cfg.wpass = web.arg("wpass");
  cfg.host = web.arg("host"); cfg.port = web.arg("port").toInt(); if (cfg.port <= 0) cfg.port = 2101;
  cfg.user = web.arg("user"); cfg.npass = web.arg("npass"); cfg.mount = web.arg("mount");
  cfg.mac = web.arg("mac"); cfg.mac.trim(); cfg.mac.toUpperCase(); cfg.pin = web.arg("pin");
  cfg.cm = web.arg("cm").toInt(); if (cfg.cm < 24 || cfg.cm > 45) cfg.cm = 27;
  cfg.tolCm = web.arg("tol").toFloat(); if (cfg.tolCm <= 0) cfg.tolCm = 2;
  cfg.beepStart = web.arg("bstart").toFloat(); if (cfg.beepStart <= 0) cfg.beepStart = 3;
  cfg.fixOnly = web.arg("fixonly") != "0";
  if (web.hasArg("anth")) { float v = web.arg("anth").toFloat(); if (v >= 0 && v < 10) cfg.antH = v; }
  if (web.hasArg("pco")) { float v = web.arg("pco").toFloat(); if (v >= 0 && v < 0.5) cfg.pco = v; }
  saveCfg();
  bool restart = oldSsid != cfg.ssid || oldW != cfg.wpass || oldMac != cfg.mac || oldPin != cfg.pin;
  web.send(200, "text/html; charset=utf-8", String("<meta charset='utf-8'><body style='font-family:sans-serif'>Kaydedildi. ") +
           (restart ? "Cihaz yeniden başlıyor..." : "<a href='/'>Geri</a>") + "</body>");
  ntripStop("Ayar degisti"); lastNtripTry = 0;
  if (restart) { delay(800); ESP.restart(); }
}

void webApl() {
  String t = web.arg("t");
  bool add = web.hasArg("ekle");
  File f = LittleFS.open("/apl.ncn", add ? "a" : "w");
  int n = 0, start = 0;
  while (start < (int)t.length()) {
    int e = t.indexOf('\n', start); if (e < 0) e = t.length();
    Pt p;
    if (parsePtLine(t.substring(start, e), p)) {
      f.printf("%s %.3f %.3f %.3f\n", p.name, p.y, p.x, p.z); n++;
    }
    start = e + 1;
  }
  f.close();
  loadStake(); tgt = stakeN ? 0 : -1;
  web.send(200, "text/html; charset=utf-8", "<meta charset='utf-8'><body style='font-family:sans-serif'>" + String(n) +
           " nokta yüklendi. Toplam " + String(stakeN) + ". <a href='/'>Geri</a></body>");
  drawAll(true);
}

void webOlcum() {
  File f = LittleFS.open("/olcum.ncn", "r");
  if (!f) { web.send(200, "text/plain", ""); return; }
  web.sendHeader("Content-Disposition", "attachment; filename=olcum.ncn");
  web.streamFile(f, "text/plain"); f.close();
}

void webSil() { LittleFS.remove("/olcum.ncn"); web.sendHeader("Location", "/"); web.send(303); }

// ---------------- Butonlar ----------------
struct Btn { int pin; bool last; uint32_t t; } btns[3] = {{BTN_MOD, true, 0}, {BTN_SOL, true, 0}, {BTN_SAG, true, 0}};
int pressed() {  // 0: yok, 1..3: hangi buton
  for (int i = 0; i < 3; i++) {
    bool v = digitalRead(btns[i].pin);
    if (v != btns[i].last && millis() - btns[i].t > 40) {
      btns[i].t = millis(); btns[i].last = v;
      if (!v) return i + 1;
    }
  }
  return 0;
}

void onButton(int b) {
  beep(1500, 25);
  if (b == 1) { page = (page + 1) % P_COUNT; drawAll(true); return; }
  if (page == P_APL && stakeN) {
    tgt = (tgt + (b == 2 ? -1 : 1) + stakeN) % stakeN;
    drawPage(true);
  } else if (page == P_OLCUM && b == 2) {
    if (!measuring) { measuring = true; measGot = 0; mY = mX = mZ = 0; measStart = millis(); measLastGga = g.ggaCount; }
  } else if (page == P_DURUM) {
    if (b == 2) { ntripOn = !ntripOn; if (!ntripOn) ntripStop("Kapali"); else ntripMsg = "Aciliyor"; }
    else { SerialBT.disconnect(); btLoop(true); }
  }
}

// ---------------- Kurulum / döngü ----------------
void setup() {
  Serial.begin(115200);
  pinMode(BTN_MOD, INPUT_PULLUP); pinMode(BTN_SOL, INPUT_PULLUP); pinMode(BTN_SAG, INPUT_PULLUP);
  pinMode(TFT_BLK, OUTPUT); digitalWrite(TFT_BLK, HIGH);
  ledcAttach(BUZZER, 2000, 8); ledcWriteTone(BUZZER, 0);

  tft.init(240, 240, SPI_MODE3);   // CS'siz modüller MODE3 ister
  tft.setRotation(2);
  tft.fillScreen(C_BG);
  txt(10, 100, 2, C_ACC, "S82 Kumanda"); txt(10, 125, 1, C_DIM, "v0.1 basliyor...");

  LittleFS.begin(true);
  loadCfg();
  loadStake();

  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP("S82-Kumanda", "12345678");   // ayar için her zaman açık
  if (!cfg.ssid.isEmpty()) WiFi.begin(cfg.ssid.c_str(), cfg.wpass.c_str());
  WiFi.setSleep(true);   // Bluetooth ile birlikte çalışması için gerekli (coexistence)

  web.on("/", webRoot);
  web.on("/ayar", HTTP_POST, webSave);
  web.on("/apl", HTTP_POST, webApl);
  web.on("/olcum.ncn", webOlcum);
  web.on("/sil", webSil);
  web.begin();

  SerialBT.begin("S82-Kumanda", true);   // master: S82'ye biz bağlanırız
  if (!cfg.pin.isEmpty()) SerialBT.setPin(cfg.pin.c_str(), cfg.pin.length());

  drawAll(true);
  lastBtTry = millis() - 14000;   // açılışta hemen dene
}

uint32_t lastDraw = 0, lastGgaDrawn = 0;

void loop() {
  web.handleClient();
  btLoop();
  ntripLoop();
  measureLoop();

  int b = pressed();
  if (b) onButton(b);

  // Yeni konumda hemen, değilse 2 sn'de bir ekranı tazele
  if (g.ggaCount != lastGgaDrawn || millis() - lastDraw > 2000) {
    lastGgaDrawn = g.ggaCount; lastDraw = millis();
    drawTopBar(); drawPage(false);
  }

  // Aplikasyon bipleri
  if (beepOffAt && millis() > beepOffAt) { ledcWriteTone(BUZZER, 0); beepOffAt = 0; }
  if (page == P_APL && tgt >= 0 && fixFresh()) {
    double Y, X; tmForward(g.lat, g.lon, cfg.cm, Y, X);
    double dy = stake[tgt].y - Y, dx = stake[tgt].x - X, d = sqrt(dy * dy + dx * dx);
    double tol = cfg.tolCm / 100.0;
    if (d <= cfg.beepStart && millis() - lastBeep > (uint32_t)beepInterval(d, tol, cfg.beepStart)) {
      lastBeep = millis();
      if (d <= tol) beep(1960, 140); else beep(d < cfg.beepStart / 3 ? 1320 : 880, 60);
    }
  }
  delay(2);
}
