import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Aplikasyon sesli yönlendirme: hedefe yaklaştıkça bip aralığı kısalır ve ses incelir.
/// Tolerans içine girince yüksek, hızlı "tamam" sesi + titreşim.
class Beeper {
  static bool enabled = true;
  static double startDist = 3.0; // bu mesafeden itibaren bipler başlar (m)

  /// Ekranlar her konumda günceller; null = hedef/konum yok
  static double? distance;
  static double tolerance = 0.02;
  static bool active = false; // aplikasyon/harita ekranı açıkken true

  static final _players = <String, AudioPlayer>{};
  static final _files = <String, String>{};
  static Timer? _timer;
  static int _last = 0;
  static bool _ready = false;

  // ad -> (frekans Hz, süre ms)
  static const _tones = {'uzak': (880, 70), 'yakin': (1320, 60), 'tamam': (1960, 140)};

  static const _native = MethodChannel('s82/spp');

  static Future<void> init() async {
    _timer ??= Timer.periodic(const Duration(milliseconds: 40), (_) => _tick());
    if (Platform.isAndroid) return; // Android: yerel AudioTrack (MainActivity.kt)
    try {
      final dir = await getTemporaryDirectory();
      await AudioPlayer.global.setAudioContext(AudioContextConfig(
        focus: AudioContextConfigFocus.mixWithOthers,
        respectSilence: false, // iPhone sessiz modda da çalsın
      ).build());
      for (final e in _tones.entries) {
        final f = File('${dir.path}/bip_${e.key}.wav');
        await f.writeAsBytes(_wav(e.value.$1.toDouble(), e.value.$2));
        _files[e.key] = f.path;
        final p = AudioPlayer();
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSource(DeviceFileSource(f.path));
        _players[e.key] = p;
      }
      _ready = true;
    } catch (_) {
      _ready = false; // ses yoksa sadece titreşim
    }
  }

  static void _play(String tone) {
    if (Platform.isAndroid) {
      final t = _tones[tone]!;
      _native.invokeMethod('beep', {'hz': t.$1, 'ms': t.$2}).catchError((_) {});
      return;
    }
    if (!_ready) return;
    // iOS: önce durdur, sonra baştan çal (önceki bip bitmemiş olsa da yeni bip kaçmaz)
    final p = _players[tone]!;
    p.stop().then((_) => p.resume()).catchError((_) {});
  }

  /// Bip aralığı (ms): startDist'te ~1200 ms, toleransta ~90 ms
  static int intervalMs(double d, double tol, double start) {
    if (d <= tol) return 250;
    final r = ((d - tol) / max(start - tol, 0.01)).clamp(0.0, 1.0);
    return (90 + 1110 * pow(r, 0.8)).round();
  }

  static void _tick() {
    final d = distance;
    if (!enabled || !active || d == null || d > startDist) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _last < intervalMs(d, tolerance, startDist)) return;
    _last = now;
    final ok = d <= tolerance;
    final tone = ok ? 'tamam' : (d < startDist / 3 ? 'yakin' : 'uzak');
    _play(tone);
    if (ok) HapticFeedback.heavyImpact();
  }

  /// 16 bit mono 44.1 kHz sinüs WAV; tık sesi olmasın diye uçlar yumuşatılır
  static Uint8List _wav(double hz, int ms) {
    const rate = 44100;
    final n = rate * ms ~/ 1000;
    final fade = rate * 6 ~/ 1000;
    final b = ByteData(44 + n * 2);
    void str(int o, String s) { for (var i = 0; i < s.length; i++) { b.setUint8(o + i, s.codeUnitAt(i)); } }
    str(0, 'RIFF'); b.setUint32(4, 36 + n * 2, Endian.little); str(8, 'WAVE');
    str(12, 'fmt '); b.setUint32(16, 16, Endian.little); b.setUint16(20, 1, Endian.little);
    b.setUint16(22, 1, Endian.little); b.setUint32(24, rate, Endian.little);
    b.setUint32(28, rate * 2, Endian.little); b.setUint16(32, 2, Endian.little); b.setUint16(34, 16, Endian.little);
    str(36, 'data'); b.setUint32(40, n * 2, Endian.little);
    for (var i = 0; i < n; i++) {
      var a = 0.8;
      if (i < fade) a *= i / fade;
      if (i > n - fade) a *= (n - i) / fade;
      b.setInt16(44 + i * 2, (sin(2 * pi * hz * i / rate) * a * 32767).round(), Endian.little);
    }
    return b.buffer.asUint8List();
  }
}
