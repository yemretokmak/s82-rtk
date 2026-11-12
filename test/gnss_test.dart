import 'package:flutter_test/flutter_test.dart';
import 'package:s82_rtk/gnss.dart';

void main() {
  test('TM27 pyproj ile ayni', () {
    final r = Tm.forward(37.0345, 27.4305, 27);
    expect(r[0], closeTo(538302.3048, 0.001));
    expect(r[1], closeTo(4100426.3828, 0.001));
  });
  test('GGA ve nokta okuma', () {
    const g = 'GPGGA,123519.00,3702.07000000,N,02725.83000000,E,4,12,0.8,45.123,M,36.500,M,1.0,0000';
    var c = 0; for (final u in g.codeUnits) { c ^= u; }
    Gnss.parse('\$$g*${c.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    expect(Gnss.fix, 4);
    expect(Gnss.lat, closeTo(37.0345, 1e-9));
    expect(Pt.parse('P12;512345,123;4101234,567')!.x, closeTo(4101234.567, 1e-6));
  });
  test('ters TM gidis-donus', () {
    for (final ll in [[37.0345, 27.4305], [37.312, 27.781], [36.98, 26.2], [38.5, 28.4]]) {
      final yx = Tm.forward(ll[0], ll[1], 27);
      final back = Tm.inverse(yx[0], yx[1], 27);
      expect(back[0], closeTo(ll[0], 1e-8)); // ~1 mm
      expect(back[1], closeTo(ll[1], 1e-8));
    }
  });
}
