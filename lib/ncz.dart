// NetCAD .ncz okuyucu (nokta, çizgi, polyline/parsel, yazı).
// cad2geo (Yusuf Eminoğlu, GPL-2.0-or-later) Python motorunun Dart'a uyarlanmış bir alt kümesidir.
// SPDX-License-Identifier: GPL-2.0-or-later
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

class NczEntity {
  final String kind; // Point, Line, Polyline, Polygon, Text
  final int layer;
  String layerName = '';
  final String name; // nokta adı veya etiket
  /// [Y (sağa), X (yukarı), Z] üçlüleri
  final List<List<double>> pts;
  NczEntity(this.kind, this.layer, this.name, this.pts);
}

class NczDrawing {
  final List<NczEntity> entities = [];
  final List<String> layerNames = [];
  String version = '';
  String projection = '';
  int zone = 0;
  bool isItrf = false;

  String layerName(int code) {
    for (final c in [code, code - 1]) {
      if (c >= 0 && c < layerNames.length) return layerNames[c];
    }
    return '';
  }

  Iterable<NczEntity> get points => entities.where((e) => e.kind == 'Point');
  Iterable<NczEntity> get lines => entities.where((e) => e.kind != 'Point' && e.kind != 'Text');
}

class _Cur {
  final Uint8List d;
  final ByteData bd;
  _Cur(this.d) : bd = ByteData.sublistView(d);
  int get size => d.length;
  int u8(int o) => (o >= 0 && o < size) ? d[o] : 0;
  int u16(int o) => (o >= 0 && o + 2 <= size) ? bd.getUint16(o, Endian.little) : 0;
  int u32(int o) => (o >= 0 && o + 4 <= size) ? bd.getUint32(o, Endian.little) : 0;
  double f32(int o) => (o >= 0 && o + 4 <= size) ? bd.getFloat32(o, Endian.little) : 0.0;
  double f64(int o) => (o >= 0 && o + 8 <= size) ? bd.getFloat64(o, Endian.little) : 0.0;
  String text(int o, int len) {
    if (len <= 0 || o < 0 || o >= size) return '';
    final end = min(o + len, size);
    final sb = StringBuffer();
    for (var i = o; i < end; i++) {
      sb.write(_cp1254(d[i]));
    }
    return sb.toString().replaceAll(RegExp(r'\x00+$'), '');
  }

  // Türkçe ANSI (cp1254): Latin-1'den farklı 6 harf
  static String _cp1254(int b) {
    switch (b) {
      case 0xD0: return 'Ğ';
      case 0xDD: return 'İ';
      case 0xDE: return 'Ş';
      case 0xF0: return 'ğ';
      case 0xFD: return 'ı';
      case 0xFE: return 'ş';
      default: return latin1.decode([b]);
    }
  }
}

const _limit = 100000000.0;
bool _ok(double a, double b) => a.isFinite && b.isFinite && a.abs() <= _limit && b.abs() <= _limit;
double _fin(double v) => v.isFinite ? v : 0.0;

class Ncz {
  static const _geomKinds = {21, 22};
  static const _containers = {0, 5, 14, 48, 108, 111, 132, 150, 180};
  static const _gisShift = 28;

  static NczDrawing parse(Uint8List data) {
    final c = _Cur(data);
    final dr = NczDrawing();
    var pos = 0;
    while (pos + 5 < c.size) {
      final size = c.u32(pos + 1) + 4;
      if (size < 4 || pos + size + 1 > c.size) {
        pos++;
        continue;
      }
      final kind = c.u8(pos);
      if (_geomKinds.contains(kind) && size >= 7) {
        _decode(c, pos, size, kind == 22 ? _gisShift : 0, dr);
      } else if (_containers.contains(kind)) {
        // İç içe geometri kayıtları
        var p = pos + 5;
        final end = pos + size + 1;
        while (p + 6 < end) {
          if (!_geomKinds.contains(c.u8(p)) || c.u8(p + 5) != c.u8(p + 6)) { p++; continue; }
          final inner = c.u32(p + 1) + 4;
          if (inner < 7 || p + inner + 1 > end) { p++; continue; }
          _decode(c, p, inner, c.u8(p) == 22 ? _gisShift : 0, dr);
          p += inner + 1;
        }
      } else {
        _meta(c, pos, kind, dr);
      }
      pos += size + 1;
    }
    for (final e in dr.entities) {
      e.layerName = dr.layerName(e.layer);
    }
    return dr;
  }

  static void _meta(_Cur c, int base, int kind, NczDrawing dr) {
    if (kind == 25) {
      if (dr.version.isEmpty) dr.version = c.text(base + 6, c.u8(base + 5));
    } else if (kind == 6) {
      if (base + 17 >= c.size) return;
      final n = c.u16(base + 16);
      for (var i = 0; i < n; i++) {
        final it = base + 18 + i * 29;
        if (it + 29 > c.size) break;
        final name = c.text(it + 5, c.u8(it + 4));
        if (name.trim().isNotEmpty) dr.layerNames.add(name);
      }
    } else if (kind == 28) {
      final name = c.text(base + 6, c.u8(base + 5));
      if (name == 'MPROJ' && base + 21 < c.size) {
        const proj = {1: 'Coğrafi', 2: '6°', 3: '3°'};
        const datum = {0: 'WGS-84', 1: 'ITRF', 4: 'ED50', 254: 'ED50-HGK'};
        final dt = c.u8(base + 17);
        dr.isItrf = dt == 1 || dt == 0;
        dr.zone = c.u8(base + 21);
        dr.projection = '${datum[dt] ?? '?'} / ${proj[c.u8(base + 16)] ?? '?'} / DOM ${dr.zone}';
      }
    }
  }

  // Kayıtta kuzey önce, doğu sonra saklanır -> [Y=doğu, X=kuzey, Z]
  static List<double> _p(double north, double east, [double z = 0]) => [east, north, z];

  static void _decode(_Cur c, int base, int size, int shift, NczDrawing dr) {
    if (base + 7 >= c.size) return;
    final type = c.u8(base + 6);
    final layer = c.u8(base + 7);
    final n1 = c.f64(base + 8), e1 = c.f64(base + 16);
    double z() {
      var v = c.f32(base + 24);
      if (v == 0) v = c.f32(base + 28);
      return _fin(v);
    }

    switch (type) {
      case 1: // Nokta
        if (!_ok(n1, e1)) return;
        final no = base + shift + 86;
        dr.entities.add(NczEntity('Point', layer, c.text(no + 1, c.u8(no)), [_p(n1, e1, z())]));
        break;
      case 2: // Çizgi
        final tail = base + size;
        final n2 = c.f64(tail - 19), e2 = c.f64(tail - 11);
        if (!_ok(n1, e1) || !_ok(n2, e2)) return;
        dr.entities.add(NczEntity('Line', layer, '', [_p(n1, e1, _fin(c.f32(base + 24))), _p(n2, e2, _fin(c.f32(tail - 3)))]));
        break;
      case 5: // Yazı
        if (!_ok(n1, e1)) return;
        final s = base + shift;
        var t = '';
        for (final lo in [s + 97, s + 86, base + 97, base + 86]) {
          final len = c.u8(lo);
          if (len > 0 && len <= 240 && lo + 1 + len <= c.size) {
            t = c.text(lo + 1, len).trim();
            if (t.isNotEmpty) break;
          }
        }
        if (t.isEmpty) return;
        dr.entities.add(NczEntity('Text', layer, t, [_p(n1, e1)]));
        break;
      case 7: // Polyline / parsel
        final s = base + shift;
        final label = c.text(s + 87, c.u8(s + 86));
        final count = (size + 1 - 113 - shift) ~/ 24;
        if (count < 2) return;
        final pts = <List<double>>[];
        for (var i = 0; i < count; i++) {
          final v = s + 113 + i * 24;
          if (v + 24 > c.size) break;
          final a = c.f64(v), b = c.f64(v + 8);
          if (!a.isFinite || !b.isFinite) continue;
          pts.add(_p(a, b, _fin(c.f64(v + 16))));
        }
        if (pts.length < 2) return;
        final closed = _closed(pts);
        if (closed && !_eq(pts.first, pts.last)) pts.add(List.of(pts.first));
        dr.entities.add(NczEntity(closed ? 'Polygon' : 'Polyline', layer, label, pts));
        break;
      case 9: // Sıkıştırılmış eğri: başlangıç + float32 farklar
        if (!_ok(n1, e1)) return;
        final start = base + shift + 122;
        final end = base + size + 1;
        if (start + 8 > end) return;
        final pts = <List<double>>[];
        var bad = 0;
        for (var p = start; p < end - 7; p += 18) {
          final dn = c.f32(p), de = c.f32(p + 4);
          final n = n1 + dn, e = e1 + de;
          if (!dn.isFinite || !de.isFinite || !_ok(n, e)) {
            bad++;
            if (pts.isNotEmpty && bad >= 4) break;
            continue;
          }
          bad = 0;
          final pt = _p(n, e);
          if (pts.isNotEmpty && (pts.last[0] - pt[0]).abs() < 1e-4 && (pts.last[1] - pt[1]).abs() < 1e-4) continue;
          pts.add(pt);
        }
        if (pts.length >= 2) dr.entities.add(NczEntity('Polyline', layer, '', pts));
        break;
    }
  }

  static bool _eq(List<double> a, List<double> b) =>
      (a[0] - b[0]).abs() < 0.001 && (a[1] - b[1]).abs() < 0.001 && (a[2] - b[2]).abs() < 0.001;

  static double _d(List<double> a, List<double> b) {
    final dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
    return sqrt(dx * dx + dy * dy + dz * dz);
  }

  static bool _closed(List<List<double>> p) {
    if (p.length < 4) return false;
    if (_eq(p.first, p.last)) return true;
    if (p.length < 5) return false;
    final ref = min(_d(p[0], p[1]), _d(p[p.length - 2], p.last));
    if (ref <= 0.001) return false;
    return _d(p.first, p.last) <= max(ref * 0.2, 0.05);
  }
}
