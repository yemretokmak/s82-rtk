import 'dart:math';

import 'package:flutter/foundation.dart';

/// Alıcıdan gelen son durum
class Gnss {
  static double lat = 0, lon = 0, alt = 0, geoidSep = 0, hdop = 0;
  static int fix = 0, sats = 0, satsInView = 0, nmeaCount = 0;
  static double diffAge = -1, sigLat = -1, sigLon = -1, sigAlt = -1;
  static String utc = '', lastGga = '', board = '';
  static int lastUpdateMs = 0;
  static int _gpsView = 0, _glView = 0;
  static final List<String> log = [];
  /// Her yeni GGA'da artar; ekranlar bununla anında yenilenir
  static final ValueNotifier<int> tick = ValueNotifier(0);

  static double get ellHeight => alt + geoidSep;

  static String fixText([int? q]) {
    switch (q ?? fix) {
      case 0: return 'YOK';
      case 1: return 'TEKİL';
      case 2: return 'DGPS';
      case 4: return 'RTK FIX';
      case 5: return 'RTK FLOAT';
      case 6: return 'TAHMİNİ';
      default: return '?';
    }
  }

  static bool checksumOk(String line) {
    final star = line.lastIndexOf('*');
    if (!line.startsWith(r'$') || star < 0 || star + 3 > line.length) return false;
    var c = 0;
    for (var i = 1; i < star; i++) { c ^= line.codeUnitAt(i); }
    return line.substring(star + 1, star + 3).toUpperCase() ==
        c.toRadixString(16).toUpperCase().padLeft(2, '0');
  }

  static double? _dm(String v, String h) {
    final x = double.tryParse(v);
    if (x == null) return null;
    final deg = (x / 100).floorToDouble();
    final r = deg + (x - deg * 100) / 60.0;
    return (h == 'S' || h == 'W') ? -r : r;
  }

  static void parse(String line) {
    nmeaCount++;
    log.add(line);
    if (log.length > 40) log.removeAt(0);
    if (!checksumOk(line)) return;
    final f = line.substring(1, line.lastIndexOf('*')).split(',');
    final t = f[0];
    double? d(int i) => i < f.length ? double.tryParse(f[i]) : null;
    if (t.endsWith('GGA') && f.length >= 14) {
      utc = f[1];
      fix = int.tryParse(f[6]) ?? 0;
      sats = int.tryParse(f[7]) ?? 0;
      hdop = d(8) ?? 0;
      if (fix > 0) {
        lat = _dm(f[2], f[3]) ?? lat;
        lon = _dm(f[4], f[5]) ?? lon;
        alt = d(9) ?? 0;
        geoidSep = d(11) ?? 0;
      }
      diffAge = d(13) ?? -1;
      lastGga = line;
      lastUpdateMs = DateTime.now().millisecondsSinceEpoch;
      tick.value++;
    } else if (t.endsWith('GST') && f.length >= 9) {
      sigLat = d(6) ?? -1; sigLon = d(7) ?? -1; sigAlt = d(8) ?? -1;
    } else if (t == 'GPGSV' && f.length >= 4) {
      _gpsView = int.tryParse(f[3]) ?? 0; satsInView = _gpsView + _glView;
    } else if (t == 'GLGSV' && f.length >= 4) {
      _glView = int.tryParse(f[3]) ?? 0; satsInView = _gpsView + _glView;
    } else if (t == 'PTNL') {
      board = 'Trimble';
    }
  }
}

/// GRS80 Transverse Mercator (TM 3°, k0=1, sağa +500000). ITRF96 -> Y (sağa), X (yukarı)
class Tm {
  static const a = 6378137.0;
  static const f = 1 / 298.257222101;
  static final e2 = f * (2 - f);
  static final ep2 = e2 / (1 - e2);

  static int autoCm(double lon) => (lon / 3).round() * 3;

  static List<double> forward(double latDeg, double lonDeg, int cm, {double k0 = 1, double fe = 500000}) {
    final phi = latDeg * pi / 180;
    final dl = (lonDeg - cm) * pi / 180;
    final s = sin(phi), c = cos(phi), t = tan(phi);
    final n = a / sqrt(1 - e2 * s * s);
    final tt = t * t, cc = ep2 * c * c, aa = dl * c;
    final e4 = e2 * e2, e6 = e4 * e2;
    final m = a * ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi -
        (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi) +
        (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi) -
        (35 * e6 / 3072) * sin(6 * phi));
    final y = k0 * n * (aa + (1 - tt + cc) * pow(aa, 3) / 6 +
        (5 - 18 * tt + tt * tt + 72 * cc - 58 * ep2) * pow(aa, 5) / 120) + fe;
    final x = k0 * (m + n * t * (aa * aa / 2 + (5 - tt + 9 * cc + 4 * cc * cc) * pow(aa, 4) / 24 +
        (61 - 58 * tt + tt * tt + 600 * cc - 330 * ep2) * pow(aa, 6) / 720));
    return [y, x];
  }

  /// Y (sağa), X (yukarı) -> [enlem, boylam] derece
  static List<double> inverse(double y, double x, int cm, {double k0 = 1, double fe = 500000}) {
    final e4 = e2 * e2, e6 = e4 * e2;
    final m = x / k0;
    final mu = m / (a * (1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256));
    final e1 = (1 - sqrt(1 - e2)) / (1 + sqrt(1 - e2));
    final phi1 = mu +
        (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu) +
        (21 * e1 * e1 / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu) +
        (151 * pow(e1, 3) / 96) * sin(6 * mu) +
        (1097 * pow(e1, 4) / 512) * sin(8 * mu);
    final s = sin(phi1), c = cos(phi1), t = tan(phi1);
    final c1 = ep2 * c * c, t1 = t * t;
    final n1 = a / sqrt(1 - e2 * s * s);
    final r1 = a * (1 - e2) / pow(1 - e2 * s * s, 1.5);
    final d = (y - fe) / (n1 * k0);
    final lat = phi1 -
        (n1 * t / r1) *
            (d * d / 2 -
                (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ep2) * pow(d, 4) / 24 +
                (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ep2 - 3 * c1 * c1) * pow(d, 6) / 720);
    final lon = (d -
            (1 + 2 * t1 + c1) * pow(d, 3) / 6 +
            (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ep2 + 24 * t1 * t1) * pow(d, 5) / 120) /
        c;
    return [lat * 180 / pi, cm + lon * 180 / pi];
  }
}

class Pt {
  final String name;
  final double y, x, z;
  final String note;
  Pt(this.name, this.y, this.x, this.z, [this.note = '']);

  String fmt() => '$name ${y.toStringAsFixed(3)} ${x.toStringAsFixed(3)} ${z.toStringAsFixed(3)}'
      '${note.isNotEmpty ? ' $note' : ''}';

  /// "ad Y X [Z]" — boşluk/virgül; noktalı virgül/sekme varsa virgül ondalıktır.
  static Pt? parse(String s) {
    final t = s.trim();
    List<String> p;
    if (t.contains(';') || t.contains('\t')) {
      p = t.split(RegExp(r'[;\t]+')).map((e) => e.trim().replaceAll(',', '.')).toList();
    } else {
      p = t.split(RegExp(r'[\s,]+'));
    }
    p = p.where((e) => e.isNotEmpty).toList();
    if (p.length < 3) return null;
    final y = double.tryParse(p[1]), x = double.tryParse(p[2]);
    if (y == null || x == null) return null;
    final z = p.length > 3 ? (double.tryParse(p[3]) ?? 0.0) : 0.0;
    return Pt(p[0], y, x, z, p.length > 4 ? p.sublist(4).join(' ') : '');
  }

  static List<Pt> parseText(String t) =>
      t.split(RegExp(r'\r?\n')).map(parse).whereType<Pt>().toList();
}
