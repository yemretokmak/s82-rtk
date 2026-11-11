/*
  S82 → iPhone BLE köprüsü  (v0.1)
  -------------------------------------------------------------
  S82'nin NMEA çıkışını BLE "Nordic UART Service" (NUS) ile iPhone'a aktarır,
  iPhone'dan gelen TUSAGA RTCM düzeltmesini S82'ye geri yollar.

  İKİ MOD:
   KABLOSUZ = 1 : ESP32 klasik Bluetooth ile S82'ye bağlanır (kablo yok).
                  SADECE klasik ESP32 (ESP32-WROOM-32 / DevKit V1) ile çalışır.
                  S3 / C3 klasik Bluetooth desteklemez!
                  Arduino IDE: Tools > Partition Scheme > "Huge APP (3MB No OTA)"
   KABLOSUZ = 0 : S82'nin DB9 seri portuna MAX3232 modülü ile kablo bağlanır.
                  Her ESP32'de çalışır (S3, C3 dahil).

  Kart: Arduino-ESP32 çekirdeği 3.x
*/

#define KABLOSUZ 1

// ---- KABLOSUZ mod ayarları ----
// S82'nin Bluetooth MAC adresi (Android'de Ayarlar > Bluetooth > S82 > detay'da görünür)
uint8_t S82_MAC[6] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
const char *S82_PIN = "1234";          // eşleştirme PIN'i (0000 de olabilir)

// ---- KABLOLU mod ayarları ----
#define S82_BAUD 115200                // S82 DB9 port hızı (9600/38400/115200 deneyin)
#define S82_RX_PIN 16                  // ESP32 RX  <- MAX3232 TXD  (S3 için örn. 18)
#define S82_TX_PIN 17                  // ESP32 TX  -> MAX3232 RXD  (S3 için örn. 17)

#define BLE_NAME "S82-Kopru"
#define LED_PIN 2                      // Kartınızda farklıysa değiştirin

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#if KABLOSUZ && !defined(CONFIG_IDF_TARGET_ESP32)
  #error "KABLOSUZ mod sadece klasik ESP32 (WROOM-32) ile calisir. S3/C3 icin KABLOSUZ 0 yapin."
#endif
#if KABLOSUZ
  #include <BluetoothSerial.h>
  BluetoothSerial SerialBT;
  #define S82 SerialBT
#else
  #define S82 Serial1
#endif

// Nordic UART Service UUID'leri (iOS uygulamaları bunu tanır)
#define NUS_SERVICE "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"   // telefon -> ESP32 (RTCM)
#define NUS_TX      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"   // ESP32 -> telefon (NMEA)

BLECharacteristic *txChar;
BLEServer *srv;
volatile bool phoneConnected = false;
volatile uint16_t blePayload = 20;     // MTU-3; iPhone genelde 182'ye çıkarır
uint32_t rtcmBytes = 0, nmeaBytes = 0;

class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override { phoneConnected = true; blePayload = 20; }
  void onDisconnect(BLEServer *s) override {
    phoneConnected = false;
    BLEDevice::startAdvertising();     // tekrar görünür ol
  }
};

class RxCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    // Telefondan gelen RTCM düzeltmesi -> S82
    String v = c->getValue();
    if (v.length()) { S82.write((const uint8_t *)v.c_str(), v.length()); rtcmBytes += v.length(); }
  }
};

void setupBLE() {
  BLEDevice::init(BLE_NAME);
  BLEDevice::setMTU(247);
  srv = BLEDevice::createServer();
  srv->setCallbacks(new ServerCB());
  BLEService *svc = srv->createService(NUS_SERVICE);
  txChar = svc->createCharacteristic(NUS_TX, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());
  BLECharacteristic *rx = svc->createCharacteristic(NUS_RX,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCB());
  svc->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(NUS_SERVICE);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
}

#if KABLOSUZ
uint32_t lastTry = 0;
void keepS82Connected() {
  if (SerialBT.connected()) return;
  if (millis() - lastTry < 5000) return;
  lastTry = millis();
  Serial.println("S82'ye baglaniliyor...");
  if (SerialBT.connect(S82_MAC)) Serial.println("S82 BAGLANDI");
  else Serial.println("S82 baglanamadi, 5 sn sonra tekrar");
}
#endif

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
#if KABLOSUZ
  SerialBT.begin("S82-Kopru-M", true);   // true = master (S82'ye biz bağlanırız)
  SerialBT.setPin(S82_PIN, strlen(S82_PIN));
#else
  Serial1.begin(S82_BAUD, SERIAL_8N1, S82_RX_PIN, S82_TX_PIN);
#endif
  setupBLE();
  Serial.println("Kopru hazir. iPhone'da '" BLE_NAME "' cihazina baglanin.");
}

uint8_t buf[512];
uint32_t lastStat = 0;

void loop() {
#if KABLOSUZ
  keepS82Connected();
#endif
  // S82 -> telefon
  int n = 0;
  while (S82.available() && n < (int)sizeof(buf)) buf[n++] = S82.read();
  if (n > 0) {
    nmeaBytes += n;
    if (phoneConnected) {             // iPhone'un anlaştığı MTU'ya göre paket boyu
      uint16_t m = srv->getPeerMTU(srv->getConnId());
      blePayload = (m > 23) ? min(m - 3, 240) : 20;
    }
    if (phoneConnected) {
      for (int i = 0; i < n; i += blePayload) {
        int len = min((int)blePayload, n - i);
        txChar->setValue(buf + i, len);
        txChar->notify();
        delay(3);                      // BLE kuyruğu taşmasın
      }
    }
  }

  // Durum LED'i: S82 bağlı + telefon bağlı = sürekli yanık, sadece biri = yanıp söner
#if KABLOSUZ
  bool s82ok = SerialBT.connected();
#else
  bool s82ok = nmeaBytes > 0;
#endif
  digitalWrite(LED_PIN, (s82ok && phoneConnected) ? HIGH : ((millis() / 300) % 2 && (s82ok || phoneConnected)));

  if (millis() - lastStat > 5000) {
    lastStat = millis();
    Serial.printf("S82:%s  iPhone:%s  NMEA:%u bayt  RTCM:%u bayt  BLE paket:%u\n",
                  s82ok ? "OK" : "--", phoneConnected ? "OK" : "--", nmeaBytes, rtcmBytes, blePayload);
  }
  delay(5);
}
