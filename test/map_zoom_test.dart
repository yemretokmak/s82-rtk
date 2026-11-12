import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:s82_rtk/gnss.dart';
import 'package:s82_rtk/main.dart';
import 'package:s82_rtk/map_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('zoom 28 + izgara + parsel cizgisi hatasiz cizilir', (t) async {
    SharedPreferences.setMockInitialValues({'cm': '27'});
    prefs = await SharedPreferences.getInstance();
    final a = Tm.inverse(530859.813, 4101899.275, 27), b = Tm.inverse(530857.029, 4101905.373, 27);
    final ctrl = MapController();
    await t.pumpWidget(MaterialApp(
        home: SizedBox(
            width: 400,
            height: 700,
            child: FlutterMap(
                mapController: ctrl,
                options: MapOptions(initialCenter: LatLng(a[0], a[1]), initialZoom: 28, maxZoom: 28),
                children: [
                  const TmGrid(),
                  PolylineLayer(polylines: [Polyline(points: [LatLng(a[0], a[1]), LatLng(b[0], b[1])])]),
                ]))));
    await t.pump();
    expect(ctrl.camera.zoom, 28);
    // ignore: avoid_print
    print(find.textContaining('Izgara').evaluate().map((e) => (e.widget as Text).data).toList());
    expect(find.textContaining('Izgara: '), findsOneWidget);
    ctrl.move(LatLng(a[0], a[1]), 21);
    await t.pump();
    expect(find.textContaining('Izgara:'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
