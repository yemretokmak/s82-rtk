import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'gnss.dart';

/// ESP32 köprüsü (Nordic UART Service) üzerinden S82 bağlantısı
class Ble {
  static const svc = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rxChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // telefon -> köprü
  static const txChar = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // köprü -> telefon

  static String? deviceId;
  static String deviceName = '';
  static bool connected = false;
  static String status = 'Bağlı değil';
  static int bytesIn = 0, rtcmOut = 0;
  static int payload = 20;
  static final StringBuffer _line = StringBuffer();
  static final List<Uint8List> _queue = [];
  static bool _writing = false;

  static void init() {
    UniversalBle.onConnectionChange = (c) {
      if (c.deviceId != deviceId) return;
      connected = c.isConnected;
      status = c.isConnected ? 'Bağlı: $deviceName' : 'Bağlantı koptu';
    };
    UniversalBle.onValueChange = (v) {
      if (v.characteristicId.toLowerCase() != txChar) return;
      bytesIn += v.value.length;
      for (final b in v.value) {
        final ch = String.fromCharCode(b);
        if (ch == '\n' || ch == '\r') {
          final s = _line.toString();
          if (s.startsWith(r'$')) Gnss.parse(s);
          _line.clear();
        } else if (ch == r'$') {
          _line.clear();
          _line.write(ch);
        } else if (b >= 32 && b <= 126 && _line.length < 300) {
          _line.write(ch);
        }
      }
    };
  }

  static Future<void> connect(String id, String name) async {
    await disconnect();
    deviceId = id;
    deviceName = name;
    status = 'Bağlanıyor: $name';
    try {
      await UniversalBle.connect(id, timeout: const Duration(seconds: 20));
      await UniversalBle.discoverServices(id);
      try {
        final mtu = await UniversalBle.requestMtu(id, 247);
        payload = (mtu - 3).clamp(20, 240);
      } catch (_) {}
      await UniversalBle.subscribeNotifications(id, svc, txChar);
      connected = true;
      status = 'Bağlı: $name';
    } catch (e) {
      connected = false;
      status = 'Hata: $e';
    }
  }

  static Future<void> disconnect() async {
    final id = deviceId;
    connected = false;
    status = 'Bağlı değil';
    if (id != null) {
      try { await UniversalBle.disconnect(id); } catch (_) {}
    }
  }

  /// RTCM verisini köprüye yazar (MTU boyunda parçalar, sırayla)
  static void send(Uint8List data) {
    if (!connected || deviceId == null) return;
    for (var i = 0; i < data.length; i += payload) {
      _queue.add(Uint8List.sublistView(data, i, (i + payload).clamp(0, data.length)));
    }
    if (_queue.length > 200) _queue.removeRange(0, _queue.length - 200); // eski düzeltme işe yaramaz
    _pump();
  }

  static Future<void> _pump() async {
    if (_writing) return;
    _writing = true;
    while (_queue.isNotEmpty && connected) {
      final p = _queue.removeAt(0);
      try {
        await UniversalBle.write(deviceId!, svc, rxChar, p, withoutResponse: true);
        rtcmOut += p.length;
      } catch (_) {}
    }
    _writing = false;
  }
}

/// NTRIP v1 istemcisi (TUSAGA-Aktif)
class Ntrip {
  static String status = 'Kapalı';
  static int bytes = 0;
  static bool running = false;
  static Socket? _sock;
  static Timer? _ggaTimer;

  static String _auth(String u, String p) => base64.encode(utf8.encode('$u:$p'));

  static Future<List<String>> sourceTable(String host, int port, String user, String pass) async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
    s.write('GET / HTTP/1.0\r\nUser-Agent: NTRIP S82RTK/0.1\r\n'
        '${user.isNotEmpty ? 'Authorization: Basic ${_auth(user, pass)}\r\n' : ''}\r\n');
    final bytes = <int>[];
    await for (final c in s.timeout(const Duration(seconds: 8), onTimeout: (sink) => sink.close())) {
      bytes.addAll(c);
    }
    s.destroy();
    final txt = latin1.decode(bytes);
    final list = txt.split('\n').where((l) => l.startsWith('STR;')).map((l) {
      final p = l.split(';');
      return '${p.length > 1 ? p[1] : '?'}  [${p.length > 3 ? p[3] : ''}]';
    }).toList();
    if (list.isEmpty) throw Exception(txt.split('\n').first);
    return list;
  }

  static Future<void> start(String host, int port, String user, String pass, String mount) async {
    await stop();
    running = true;
    while (running) {
      try {
        status = 'Bağlanıyor...';
        final s = await Socket.connect(host, port, timeout: const Duration(seconds: 10));
        _sock = s;
        s.write('GET /$mount HTTP/1.0\r\nUser-Agent: NTRIP S82RTK/0.1\r\n'
            'Authorization: Basic ${_auth(user, pass)}\r\n\r\n');
        var headerDone = false;
        final head = <int>[];
        final done = Completer<void>();
        var lastData = DateTime.now();
        s.listen((chunk) {
          lastData = DateTime.now();
          if (!headerDone) {
            head.addAll(chunk);
            final txt = latin1.decode(head, allowInvalid: true);
            final idx = txt.indexOf('\r\n');
            if (idx < 0) return;
            final first = txt.substring(0, idx);
            if (!first.contains('200')) {
              status = 'Red: $first';
              running = false;
              s.destroy();
              return;
            }
            headerDone = true;
            status = 'Bağlı ($mount)';
            _sendGga();
            // Başlıktan sonra gelen RTCM varsa ilet (HTTP/1.1 ise boş satırı atla)
            var rest = head.sublist(idx + 2);
            if (rest.length >= 2 && rest[0] == 13 && rest[1] == 10) rest = rest.sublist(2);
            if (rest.isNotEmpty) { bytes += rest.length; Ble.send(Uint8List.fromList(rest)); }
            return;
          }
          bytes += chunk.length;
          Ble.send(chunk);
        }, onDone: () { if (!done.isCompleted) done.complete(); },
           onError: (_) { if (!done.isCompleted) done.complete(); });
        _ggaTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          _sendGga();
          if (DateTime.now().difference(lastData).inSeconds > 20) s.destroy();
        });
        await done.future;
        _ggaTimer?.cancel();
        if (running) { status = 'Koptu, 5 sn sonra tekrar'; await Future.delayed(const Duration(seconds: 5)); }
      } catch (e) {
        _ggaTimer?.cancel();
        if (running) { status = 'Hata ($e), 5 sn sonra tekrar'; await Future.delayed(const Duration(seconds: 5)); }
      }
    }
  }

  static void _sendGga() {
    if (Gnss.lastGga.isNotEmpty) {
      try { _sock?.write('${Gnss.lastGga}\r\n'); } catch (_) {}
    }
  }

  static Future<void> stop() async {
    running = false;
    _ggaTimer?.cancel();
    _sock?.destroy();
    _sock = null;
    status = 'Kapalı';
  }
}
