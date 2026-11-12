import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import 'gnss.dart';
import 'beeper.dart';
import 'link.dart';
import 'map_page.dart';
import 'ncz.dart';

const acc = Color(0xFFFFB020);
const green = Color(0xFF3CC85A);
const red = Color(0xFFE6463C);
const blue = Color(0xFF4696F0);
const dim = Color(0xFF969CA8);

late SharedPreferences prefs;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  Ble.init();
  Spp.init();
  await loadDrawing();
  Beeper.enabled = prefs.getBool('beep') ?? true;
  Beeper.startDist = double.tryParse(prefs.getString('beepStart') ?? '') ?? 3.0;
  await Beeper.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'S82 RTK',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: acc, useMaterial3: true),
        home: const Home(),
      );
}

String f3(double v) => v.toStringAsFixed(3);

int cm() {
  final s = int.tryParse(prefs.getString('cm') ?? '0') ?? 0;
  return s == 0 ? Tm.autoCm(Gnss.lon != 0 ? Gnss.lon : 27) : s;
}

List<double> currentYX() => Tm.forward(Gnss.lat, Gnss.lon, cm());

NczDrawing? drawing;
String drawingName = '';

Future<File> _drawingFile() async => File('${(await getApplicationDocumentsDirectory()).path}/cizim.ncz');

Future<void> loadDrawing() async {
  try {
    final f = await _drawingFile();
    if (await f.exists()) {
      drawing = Ncz.parse(await f.readAsBytes());
      drawingName = prefs.getString('drawingName') ?? 'cizim.ncz';
    }
  } catch (_) {}
}

/// NCZ / NCN / TXT dosyası aç. NCZ: çizim haritaya, noktalar aplikasyon listesine.
Future<String> importFile() async {
  final f = await FilePicker.pickFile(type: FileType.any);
  if (f == null) return '';
  final bytes = await f.readAsBytes();
  final name = f.name;
  List<Pt> pts;
  if (name.toLowerCase().endsWith('.ncz')) {
    final d = Ncz.parse(bytes);
    if (d.entities.isEmpty) return 'NCZ okunamadı ya da boş';
    drawing = d;
    drawingName = name;
    prefs.setString('drawingName', name);
    await (await _drawingFile()).writeAsBytes(bytes);
    pts = d.points.where((e) => e.name.isNotEmpty).map((e) => Pt(e.name, e.pts[0][0], e.pts[0][1], e.pts[0][2], e.layerName)).toList();
    var warn = '';
    if (d.zone != 0 && d.zone != cm()) warn = '\nUYARI: çizim DOM ${d.zone}, uygulama DOM ${cm()}';
    if (!d.isItrf) warn += '\nUYARI: çizim ITRF değil (${d.projection})';
    final stake = loadPts('stake');
    for (final p in pts) { stake.removeWhere((s) => s.name == p.name); stake.add(p); }
    savePts('stake', stake);
    final nl = d.lines.length;
    return '$name: ${pts.length} nokta aplikasyon listesine, $nl çizgi/parsel haritaya eklendi.$warn';
  }
  pts = Pt.parseText(latin1.decode(bytes, allowInvalid: true));
  final stake = loadPts('stake');
  for (final p in pts) { stake.removeWhere((s) => s.name == p.name); stake.add(p); }
  savePts('stake', stake);
  return '$name: ${pts.length} nokta aplikasyon listesine eklendi';
}

List<Pt> loadPts(String key) => Pt.parseText(prefs.getString(key) ?? '');
void savePts(String key, List<Pt> l) => prefs.setString(key, l.map((p) => p.fmt()).join('\n'));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  Timer? t;

  @override
  void initState() {
    super.initState();
    // Yeni konum gelince anında, ayrıca saniyede bir (NTRIP vb. durumlar için) yenile
    Gnss.tick.addListener(_refresh);
    t = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _refresh() { if (mounted) setState(() {}); }

  @override
  void dispose() { t?.cancel(); Gnss.tick.removeListener(_refresh); super.dispose(); }

  Color fixColor(int q) => q == 4 ? green : q == 5 ? acc : (q == 1 || q == 2) ? blue : red;

  void _updateBeeper(bool stale) {
    final t = target;
    Beeper.active = tab == 3 || tab == 4;
    Beeper.tolerance = (double.tryParse(prefs.getString('tol') ?? '') ?? 2) / 100;
    if (t == null || stale || Gnss.fix == 0 || !Link.connected) {
      Beeper.distance = null;
      return;
    }
    final yx = currentYX();
    final dy = t.y - yx[0], dx = t.x - yx[1];
    Beeper.distance = sqrt(dy * dy + dx * dx);
  }

  @override
  Widget build(BuildContext context) {
    final stale = DateTime.now().millisecondsSinceEpoch - Gnss.lastUpdateMs > 3000;
    _updateBeeper(stale);
    final q = stale ? 0 : Gnss.fix;
    final sig = Gnss.sigLat >= 0 ? '±${f3(sqrt(Gnss.sigLat * Gnss.sigLat + Gnss.sigLon * Gnss.sigLon))} m' : '±?';
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Container(
            color: const Color(0xFF20242C),
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                color: Link.connected ? fixColor(q) : Colors.grey,
                child: Text(Link.connected ? Gnss.fixText(q) : 'BAĞLI DEĞİL',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 17)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                    'Uydu ${Gnss.sats}/${Gnss.satsInView}   $sig\nNTRIP: ${Ntrip.status}'
                    '${Gnss.diffAge >= 0 ? '  yaş ${Gnss.diffAge.toStringAsFixed(0)}s' : ''}',
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
          ),
          Expanded(child: [ConnectPage(), StatusPage(), MeasurePage(), StakePage(), MapPage()][tab]),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Bağlantı'),
          NavigationDestination(icon: Icon(Icons.satellite_alt), label: 'Durum'),
          NavigationDestination(icon: Icon(Icons.place), label: 'Ölçüm'),
          NavigationDestination(icon: Icon(Icons.navigation), label: 'Aplikasyon'),
          NavigationDestination(icon: Icon(Icons.map), label: 'Harita'),
        ],
      ),
    );
  }
}

Widget title(String t) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(t, style: const TextStyle(color: acc, fontWeight: FontWeight.bold, fontSize: 15)));

Widget btn(String t, VoidCallback onTap, [Color c = blue]) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: SizedBox(
        height: 46,
        width: double.infinity,
        child: FilledButton(style: FilledButton.styleFrom(backgroundColor: c), onPressed: onTap, child: Text(t))));

Widget row2(Widget a, Widget b) => Row(children: [Expanded(child: a), const SizedBox(width: 8), Expanded(child: b)]);

void toast(BuildContext c, String s) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(s)));

TextEditingController ctl(String key, [String def = '']) => TextEditingController(text: prefs.getString(key) ?? def);

// ---------------- Bağlantı ----------------
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final host = ctl('host'), port = ctl('port', '2101'), user = ctl('user'), pass = ctl('pass'),
      mount = ctl('mount'), cmC = ctl('cm', '0');

  void save() {
    prefs.setString('host', host.text.trim());
    prefs.setString('port', port.text.trim());
    prefs.setString('user', user.text.trim());
    prefs.setString('pass', pass.text);
    prefs.setString('mount', mount.text.trim());
  }

  Future<void> sppPick() async {
    try {
      final l = await Spp.bonded();
      if (!mounted) return;
      if (l.isEmpty) { toast(context, 'Önce Android ayarlarından S82 ile eşleştir'); return; }
      final d = await showDialog<Map>(
          context: context,
          builder: (c) => SimpleDialog(
              title: const Text('Eşleşmiş cihazlar'),
              children: l
                  .map((m) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(c, m), child: Text('${m['name']}\n${m['address']}')))
                  .toList()));
      if (d == null) return;
      prefs.setString('lastId', d['address'] as String);
      prefs.setString('lastName', d['name'] as String);
      prefs.setString('lastMode', 'spp');
      Spp.connect(d['address'] as String);
    } on PlatformException catch (e) {
      if (mounted) toast(context, e.message ?? 'Bluetooth hatası');
    }
  }

  Future<void> scan() async {
    final found = <String, String>{};
    try {
      await UniversalBle.requestPermissions();
    } catch (_) {}
    if (!mounted) return;
    await showDialog(
        context: context,
        builder: (dc) {
          UniversalBle.onScanResult = (d) {
            found[d.deviceId] = d.name ?? d.deviceId;
          };
          UniversalBle.startScan(scanFilter: ScanFilter(withServices: [Ble.svc])).catchError((_) {});
          return StatefulBuilder(builder: (c, set) {
            Future.delayed(const Duration(milliseconds: 500), () { if (c.mounted) set(() {}); });
            return AlertDialog(
              title: const Text('Köprü aranıyor...'),
              content: SizedBox(
                width: 300,
                child: found.isEmpty
                    ? const Text('S82-Kopru bekleniyor. ESP32 açık mı?')
                    : ListView(
                        shrinkWrap: true,
                        children: found.entries
                            .map((e) => ListTile(
                                title: Text(e.value),
                                subtitle: Text(e.key, style: const TextStyle(fontSize: 11)),
                                onTap: () {
                                  prefs.setString('lastId', e.key);
                                  prefs.setString('lastName', e.value);
                                  prefs.setString('lastMode', 'ble');
                                  Navigator.pop(dc);
                                  Ble.connect(e.key, e.value);
                                }))
                            .toList()),
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Kapat'))],
            );
          });
        });
    UniversalBle.stopScan().catchError((_) {});
    UniversalBle.onScanResult = null;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(14), children: [
      title('S82 bağlantısı'),
      Text('${Link.status}\nGelen: ${Link.bytesIn} bayt, NMEA satırı: ${Gnss.nmeaCount}'
          '${Gnss.board.isNotEmpty ? '\nKart: ${Gnss.board}' : ''}'),
      if (Link.sppAvailable) btn('S82 (Bluetooth) – eşleşmiş cihaz seç', sppPick),
      btn('ESP32 köprüyü ara (BLE)', scan),
      row2(
          btn('Son cihaza bağlan', () {
            final id = prefs.getString('lastId');
            final mode = prefs.getString('lastMode');
            if (id == null) { toast(context, 'Önce cihaz seç'); return; }
            if (mode == 'spp') { Spp.connect(id); } else { Ble.connect(id, prefs.getString('lastName') ?? id); }
          }, green),
          btn('Kes', () => Link.disconnect(), red)),
      title('TUSAGA-Aktif (NTRIP)'),
      TextField(controller: host, decoration: const InputDecoration(labelText: 'Sunucu adresi (IP)')),
      TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
      TextField(controller: user, decoration: const InputDecoration(labelText: 'Kullanıcı adı')),
      TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Şifre')),
      TextField(controller: mount, decoration: const InputDecoration(labelText: 'Mountpoint (RTCM 3.0/3.1 VRS)')),
      btn('Mountpoint listesini getir', () async {
        save();
        try {
          final l = await Ntrip.sourceTable(host.text.trim(), int.tryParse(port.text) ?? 2101, user.text.trim(), pass.text);
          if (!context.mounted) return;
          showDialog(
              context: context,
              builder: (dc) => SimpleDialog(
                  title: const Text('Mountpoint seç'),
                  children: l
                      .map((m) => SimpleDialogOption(
                          child: Text(m),
                          onPressed: () {
                            mount.text = m.split('  ').first;
                            save();
                            Navigator.pop(dc);
                          }))
                      .toList()));
        } catch (e) {
          if (context.mounted) toast(context, 'Hata: $e');
        }
      }),
      row2(
          btn('NTRIP Başlat', () {
            save();
            if (!Link.connected) toast(context, 'Uyarı: S82 bağlı değil');
            Ntrip.start(host.text.trim(), int.tryParse(port.text) ?? 2101, user.text.trim(), pass.text, mount.text.trim());
          }, green),
          btn('Durdur', () => Ntrip.stop(), red)),
      const SizedBox(height: 6),
      Text('Durum: ${Ntrip.status}\nAlınan: ${Ntrip.bytes} bayt, S82\'ye iletilen: ${Link.rtcmOut} bayt',
          style: const TextStyle(color: dim, fontSize: 13)),
      title('Koordinat sistemi'),
      const Text('ITRF96 → TM 3° (GRS80, k=1, sağa +500000). 0 = otomatik (Bodrum/Milas → 27)',
          style: TextStyle(color: dim, fontSize: 13)),
      TextField(controller: cmC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Orta meridyen')),
      btn('Kaydet', () { prefs.setString('cm', cmC.text.trim()); toast(context, 'DOM: ${cm()}'); }),
    ]);
  }
}

// ---------------- Durum ----------------
class StatusPage extends StatelessWidget {
  const StatusPage({super.key});
  @override
  Widget build(BuildContext context) {
    final yx = currentYX();
    const mono = TextStyle(fontFamily: 'Menlo', fontSize: 15);
    return ListView(padding: const EdgeInsets.all(14), children: [
      title('Konum'),
      Text(
          'Fix      : ${Gnss.fixText()}\n'
          'Uydu     : ${Gnss.sats} kullanılan / ${Gnss.satsInView} görünen\n'
          'HDOP     : ${Gnss.hdop.toStringAsFixed(1)}\n'
          'Enlem    : ${Gnss.lat.toStringAsFixed(9)}\n'
          'Boylam   : ${Gnss.lon.toStringAsFixed(9)}\n'
          'Elips. h : ${f3(Gnss.ellHeight)} m\n'
          'Kot(GGA) : ${f3(Gnss.alt)} m\n\n'
          'TM${cm()}  Y : ${f3(yx[0])}\n'
          'TM${cm()}  X : ${f3(yx[1])}\n\n'
          '${Gnss.sigLat >= 0 ? 'σ K/D/Y  : ${f3(Gnss.sigLat)} / ${f3(Gnss.sigLon)} / ${f3(Gnss.sigAlt)} m\n' : ''}'
          'UTC      : ${Gnss.utc}',
          style: mono),
      title('Ham NMEA'),
      Text(Gnss.log.join('\n'), style: const TextStyle(fontFamily: 'Menlo', fontSize: 9, color: dim)),
    ]);
  }
}

// ---------------- Ölçüm ----------------
class MeasurePage extends StatefulWidget {
  const MeasurePage({super.key});
  @override
  State<MeasurePage> createState() => _MeasurePageState();
}

class _MeasurePageState extends State<MeasurePage> {
  final name = ctl('nextName', '1'), epochs = ctl('epochs', '5');
  bool fixOnly = prefs.getBool('fixOnly') ?? true;
  bool measuring = false;
  String prog = '';
  List<Pt> pts = loadPts('measured');

  String nextName(String s) {
    final m = RegExp(r'^(.*?)(\d+)$').firstMatch(s);
    if (m == null) return '${s}1';
    final n = m.group(2)!;
    return m.group(1)! + (int.parse(n) + 1).toString().padLeft(n.length, '0');
  }

  Future<void> measure() async {
    if (measuring) return;
    prefs.setString('epochs', epochs.text);
    prefs.setBool('fixOnly', fixOnly);
    final n = (int.tryParse(epochs.text) ?? 5).clamp(1, 600);
    final nm = name.text.trim().isEmpty ? '1' : name.text.trim();
    measuring = true;
    double sy = 0, sx = 0, sz = 0;
    var k = 0, last = 0, allFix = true;
    final t0 = DateTime.now();
    while (k < n && measuring && DateTime.now().difference(t0).inSeconds < 120) {
      if (Gnss.lastUpdateMs != last) {
        last = Gnss.lastUpdateMs;
        final ok = fixOnly ? Gnss.fix == 4 : Gnss.fix > 0;
        if (ok) {
          final yx = currentYX();
          sy += yx[0]; sx += yx[1]; sz += Gnss.alt; k++;
          if (Gnss.fix != 4) allFix = false;
        }
        setState(() => prog = 'Ölçülüyor $k/$n  (${Gnss.fixText()})');
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    measuring = false;
    if (k < n) { setState(() => prog = 'İptal / zaman aşımı ($k/$n)'); return; }
    final p = Pt(nm, sy / k, sx / k, sz / k, allFix ? 'FIX' : 'FLOAT/TEKIL');
    pts.removeWhere((e) => e.name == nm);
    pts.add(p);
    savePts('measured', pts);
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.click);
    name.text = nextName(nm);
    prefs.setString('nextName', name.text);
    setState(() => prog = 'Kaydedildi: ${p.fmt()}');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(14), children: [
      title('Nokta ölç'),
      row2(TextField(controller: name, decoration: const InputDecoration(labelText: 'Nokta adı')),
          TextField(controller: epochs, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Epok'))),
      CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: fixOnly,
          onChanged: (v) => setState(() => fixOnly = v ?? true),
          title: const Text('Sadece RTK FIX iken ölç')),
      Text(prog, style: const TextStyle(color: acc, fontSize: 15)),
      btn('ÖLÇ', measure, green),
      btn('Durdur', () => measuring = false, red),
      title('Ölçülen noktalar (ad Y X Z)'),
      Text(pts.isEmpty ? '(henüz nokta yok)' : pts.reversed.map((p) => p.fmt()).join('\n'),
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
      row2(
          btn('Paylaş (.ncn)', () {
            SharePlus.instance.share(ShareParams(text: pts.map((p) => p.fmt()).join('\r\n'), subject: 'olcum.ncn'));
          }),
          btn('Hepsini sil', () async {
            final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(content: const Text('Tüm noktalar silinsin mi?'), actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
                      TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sil')),
                    ]));
            if (ok == true) setState(() { pts.clear(); savePts('measured', pts); });
          }, red)),
    ]);
  }
}

// ---------------- Aplikasyon ----------------
Pt? target;

class StakePage extends StatefulWidget {
  const StakePage({super.key});
  @override
  State<StakePage> createState() => _StakePageState();
}

class _StakePageState extends State<StakePage> {
  final tol = ctl('tol', '2');
  List<Pt> stake = loadPts('stake');
  final beepStart = ctl('beepStart', '3');

  void step(int d) {
    if (stake.isEmpty) { toast(context, 'Aplikasyon listesi boş'); return; }
    final i = stake.indexWhere((p) => p.name == target?.name);
    setState(() => target = stake[((i < 0 ? 0 : i + d) % stake.length + stake.length) % stake.length]);
  }

  Future<void> pick() async {
    final all = [...stake, ...loadPts('measured')];
    if (all.isEmpty) { toast(context, 'Önce nokta yükle'); return; }
    final p = await showDialog<Pt>(
        context: context,
        builder: (c) => SimpleDialog(
            title: const Text('Hedef nokta'),
            children: all
                .map((p) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, p), child: Text('${p.name}   Y ${f3(p.y)}  X ${f3(p.x)}')))
                .toList()));
    if (p != null) setState(() => target = p);
  }

  Future<void> manual() async {
    final n = TextEditingController(text: 'H1'), y = TextEditingController(), x = TextEditingController();
    const num = TextInputType.numberWithOptions(decimal: true);
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text('Hedef (TM${cm()})'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(controller: n, decoration: const InputDecoration(labelText: 'Ad')),
                  TextField(controller: y, keyboardType: num, decoration: const InputDecoration(labelText: 'Y (sağa)')),
                  TextField(controller: x, keyboardType: num, decoration: const InputDecoration(labelText: 'X (yukarı)')),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
                  TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Tamam')),
                ]));
    if (ok != true) return;
    final yy = double.tryParse(y.text.replaceAll(',', '.')), xx = double.tryParse(x.text.replaceAll(',', '.'));
    if (yy == null || xx == null) { if (mounted) toast(context, 'Koordinat hatalı'); return; }
    setState(() => target = Pt(n.text, yy, xx, 0));
  }

  Future<void> paste() async {
    final clip = await Clipboard.getData('text/plain');
    final e = TextEditingController(text: clip?.text ?? '');
    if (!mounted) return;
    final r = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
                title: const Text('Noktaları yapıştır (ad Y X Z)'),
                content: TextField(controller: e, maxLines: 10, style: const TextStyle(fontSize: 12)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, 'clear'), child: const Text('Listeyi temizle')),
                  TextButton(onPressed: () => Navigator.pop(c), child: const Text('Vazgeç')),
                  TextButton(onPressed: () => Navigator.pop(c, 'add'), child: const Text('Ekle')),
                ]));
    if (r == 'clear') { stake.clear(); target = null; }
    if (r == 'add') {
      final l = Pt.parseText(e.text);
      for (final p in l) { stake.removeWhere((s) => s.name == p.name); stake.add(p); }
      if (mounted) toast(context, '${l.length} nokta eklendi');
    }
    savePts('stake', stake);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = target;
    String dist = '', dir = '', small = '';
    double? az;
    var ok = false;
    if (t != null && Gnss.fix > 0) {
      final yx = currentYX();
      final dy = t.y - yx[0], dx = t.x - yx[1];
      final d = sqrt(dy * dy + dx * dx);
      ok = d <= (double.tryParse(tol.text) ?? 2) / 100;
      dist = d < 10 ? '${d.toStringAsFixed(3)} m' : '${d.toStringAsFixed(1)} m';
      dir = '${dx >= 0 ? 'KUZEY' : 'GÜNEY'} ${dx.abs().toStringAsFixed(3)}\n'
          '${dy >= 0 ? 'DOĞU ' : 'BATI '} ${dy.abs().toStringAsFixed(3)}';
      az = (atan2(dy, dx) * 180 / pi + 360) % 360;
      final dz = t.z - Gnss.alt;
      small = 'Semt ${az.toStringAsFixed(1)}° (${(az * 400 / 360).toStringAsFixed(4)} g)   '
          'ΔZ ${dz >= 0 ? 'dolgu' : 'kazı'} ${dz.abs().toStringAsFixed(3)}\nFix: ${Gnss.fixText()}';
    } else if (t != null) {
      dist = 'Konum yok';
    }
    return ListView(padding: const EdgeInsets.all(14), children: [
      Text(t == null ? 'Hedef: (seçilmedi)' : 'Hedef: ${t.name}   Y ${f3(t.y)}  X ${f3(t.x)}',
          style: const TextStyle(color: acc, fontSize: 16)),
      row2(btn('Listeden seç', pick), btn('Elle gir', manual)),
      row2(btn('◀ Önceki', () => step(-1)), btn('Sonraki ▶', () => step(1))),
      SizedBox(height: 210, child: CustomPaint(painter: ArrowPainter(az, ok))),
      Text(dist, textAlign: TextAlign.center,
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: ok ? green : null)),
      Text(dir, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontFamily: 'Menlo')),
      Text(small, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: dim, fontFamily: 'Menlo')),
      title('Ayarlar'),
      TextField(controller: tol, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Tolerans (cm)'), onChanged: (v) => prefs.setString('tol', v)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Sesli uyarı (yaklaştıkça bip sıklaşır)'),
        value: Beeper.enabled,
        onChanged: (v) => setState(() { Beeper.enabled = v; prefs.setBool('beep', v); }),
      ),
      TextField(controller: beepStart, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Biplerin başlayacağı mesafe (m)'),
          onChanged: (v) {
            final x = double.tryParse(v.replaceAll(',', '.'));
            if (x != null && x > 0) { Beeper.startDist = x; prefs.setString('beepStart', v); }
          }),
      btn('Dosya aç (NCZ / NCN / TXT)', () async {
        try {
          final m = await importFile();
          if (m.isNotEmpty && mounted) {
            setState(() => stake = loadPts('stake'));
            showDialog(context: this.context, builder: (c) => AlertDialog(content: Text(m)));
          }
        } catch (e) {
          if (mounted) toast(this.context, 'Hata: $e');
        }
      }, green),
      btn('Aplikasyon noktalarını yapıştır', paste),
      Text('Yüklü nokta: ${stake.length}${drawing != null ? '   Çizim: $drawingName' : ''}',
          style: const TextStyle(color: dim, fontSize: 12)),
    ]);
  }
}

/// Yukarı = kuzey; ok hedefin semtini gösterir
class ArrowPainter extends CustomPainter {
  final double? az;
  final bool ok;
  ArrowPainter(this.az, this.ok);

  @override
  void paint(Canvas c, Size s) {
    final cx = s.width / 2, cy = s.height / 2, r = min(cx, cy) * 0.9;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = ok ? green : const Color(0xFF464C5A);
    c.drawCircle(Offset(cx, cy), r, p);
    final tp = TextPainter(text: const TextSpan(text: 'K', style: TextStyle(color: dim, fontSize: 13)),
        textDirection: TextDirection.ltr)..layout();
    tp.paint(c, Offset(cx - tp.width / 2, cy - r + 4));
    if (ok) { c.drawCircle(Offset(cx, cy), r * 0.35, Paint()..color = green); return; }
    if (az == null) return;
    c.save();
    c.translate(cx, cy);
    c.rotate(az! * pi / 180);
    final path = Path()
      ..moveTo(0, -r * 0.85)
      ..lineTo(r * 0.3, -r * 0.2)
      ..lineTo(r * 0.1, -r * 0.2)
      ..lineTo(r * 0.1, r * 0.6)
      ..lineTo(-r * 0.1, r * 0.6)
      ..lineTo(-r * 0.1, -r * 0.2)
      ..lineTo(-r * 0.3, -r * 0.2)
      ..close();
    c.drawPath(path, Paint()..color = acc);
    c.restore();
  }

  @override
  bool shouldRepaint(covariant ArrowPainter o) => o.az != az || o.ok != ok;
}
