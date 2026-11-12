import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s82_rtk/ncz.dart';

void main() {
  final f = File('test/data/test_verisi.ncz');
  test('NCZ test_verisi', skip: !f.existsSync() ? 'örnek dosya yok (gizli veri)' : null, () {
    final d = Ncz.parse(f.readAsBytesSync());
    for (final e in d.entities) {
      // ignore: avoid_print
      print('${e.kind} ${e.layerName} "${e.name}" ${e.pts.map((p) => p.map((v) => v.toStringAsFixed(3)).join(",")).join(" | ")}');
    }
    // ignore: avoid_print
    print('${d.projection} ver=${d.version} layers=${d.layerNames.length}');
    final p1 = d.points.firstWhere((e) => e.name == 'P.1');
    expect(p1.layerName, 'YERKONTROL');
    expect(p1.pts[0][0], closeTo(530854.77, 0.001));
    expect(p1.pts[0][1], closeTo(4101902.46, 0.001));
    expect(d.points.length, 8);
    expect(d.entities.where((e) => e.kind == 'Polygon').length, 1);
    expect(d.zone, 27);
  });
}
