import 'package:flutter_test/flutter_test.dart';
import 'package:s82_rtk/beeper.dart';

void main() {
  test('bip araligi yaklastikca kisalir', () {
    final a = [3.0, 2.0, 1.0, 0.5, 0.2, 0.05].map((d) => Beeper.intervalMs(d, 0.02, 3)).toList();
    // ignore: avoid_print
    print(a);
    for (var i = 1; i < a.length; i++) { expect(a[i] < a[i - 1], true); }
    expect(a.first, closeTo(1200, 5));
    expect(Beeper.intervalMs(0.01, 0.02, 3), 250);
  });
}
