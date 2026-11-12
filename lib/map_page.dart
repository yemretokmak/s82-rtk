import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'beeper.dart';
import 'gnss.dart';
import 'link.dart';
import 'main.dart';
import 'ncz.dart';

/// Harita: OSM / uydu altlık; NCZ çizimi, aplikasyon ve ölçülen noktalar, konum, hedef çizgisi.
class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final ctrl = MapController();
  String base = prefs.getString('mapBase') ?? 'sat';
  bool follow = false;
  double zoom = 17;
  bool ready = false;

  // Çizim çizgileri bir kez hesaplanır (çizim değişince yenilenir)
  NczDrawing? _cachedFor;
  List<Polyline> _drawLines = [];

  LatLng ll(double y, double x, [int? zone]) {
    final r = Tm.inverse(y, x, zone ?? cm());
    return LatLng(r[0], r[1]);
  }

  int get drawZone => (drawing != null && drawing!.zone > 0) ? drawing!.zone : cm();

  List<Polyline> drawLines() {
    if (identical(_cachedFor, drawing)) return _drawLines;
    _cachedFor = drawing;
    final z = drawZone;
    _drawLines = [
      for (final e in drawing?.lines ?? const <NczEntity>[])
        Polyline(
          points: e.pts.map((p) => ll(p[0], p[1], z)).toList(),
          color: e.kind == 'Polygon' ? Colors.yellowAccent : Colors.cyanAccent,
          strokeWidth: e.kind == 'Polygon' ? 2.5 : 1.5,
        )
    ];
    return _drawLines;
  }

  LatLng initialCenter() {
    if (Gnss.fix > 0) return LatLng(Gnss.lat, Gnss.lon);
    final s = loadPts('stake');
    if (s.isNotEmpty) return ll(s.first.y, s.first.x);
    final p = drawing?.points.firstOrNull;
    if (p != null) return ll(p.pts[0][0], p.pts[0][1], drawZone);
    return const LatLng(37.035, 27.43); // Bodrum
  }

  void fitAll() {
    final pts = <LatLng>[
      for (final l in drawLines()) ...l.points,
      for (final p in loadPts('stake')) ll(p.y, p.x),
      for (final p in loadPts('measured')) ll(p.y, p.x),
      if (Gnss.fix > 0) LatLng(Gnss.lat, Gnss.lon),
    ];
    if (pts.isEmpty) return;
    if (pts.length == 1) { ctrl.move(pts.first, 19); return; }
    ctrl.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(40), maxZoom: 21));
  }

  Marker dot(LatLng p, Color c, String label, {double size = 12, VoidCallback? onTap, bool ring = false}) {
    final showLabel = zoom >= 17 && label.isNotEmpty;
    return Marker(
      point: p,
      width: 120,
      height: 36,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: ring ? Colors.transparent : c,
              shape: BoxShape.circle,
              border: Border.all(color: ring ? c : Colors.black, width: ring ? 3 : 1),
            ),
          ),
          if (showLabel)
            Positioned(
              left: 60 + size / 2 + 2,
              top: 2,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white, shadows: [Shadow(blurRadius: 3, color: Colors.black)])),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stake = loadPts('stake');
    final measured = loadPts('measured');
    final hasPos = Gnss.fix > 0 && Link.connected;
    final me = LatLng(Gnss.lat, Gnss.lon);
    final t = target;

    if (follow && hasPos && ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.move(me, ctrl.camera.zoom));
    }

    // Hedef bilgisi
    String banner = '';
    if (t != null && hasPos) {
      final yx = currentYX();
      final dy = t.y - yx[0], dx = t.x - yx[1];
      final d = sqrt(dy * dy + dx * dx);
      banner = '${t.name}: ${d < 10 ? d.toStringAsFixed(3) : d.toStringAsFixed(1)} m   '
          '${dx >= 0 ? 'K' : 'G'} ${dx.abs().toStringAsFixed(2)}  ${dy >= 0 ? 'D' : 'B'} ${dy.abs().toStringAsFixed(2)}';
    } else if (t != null) {
      banner = 'Hedef: ${t.name} (konum yok)';
    }

    final fixC = Gnss.fix == 4 ? green : Gnss.fix == 5 ? acc : blue;

    return Stack(children: [
      FlutterMap(
        mapController: ctrl,
        options: MapOptions(
          initialCenter: initialCenter(),
          initialZoom: 17,
          maxZoom: 23,
          onMapReady: () => ready = true,
          onPositionChanged: (cam, gesture) {
            zoom = cam.zoom;
            if (gesture && follow) setState(() => follow = false);
          },
        ),
        children: [
          if (base == 'sat')
            TileLayer(
              urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
              userAgentPackageName: 'com.s82rtk.s82_rtk',
              // Türkiye'de uydu görüntüsü genelde 18'e kadar var; ötesinde 18'i büyüterek göster
              maxNativeZoom: 18,
              maxZoom: 23,
            )
          else
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.s82rtk.s82_rtk',
              maxNativeZoom: 19,
              maxZoom: 23,
            ),
          PolylineLayer(polylines: [
            ...drawLines(),
            if (t != null && hasPos)
              Polyline(
                points: [me, ll(t.y, t.x)],
                color: Colors.redAccent,
                strokeWidth: 2,
                pattern: StrokePattern.dashed(segments: const [8, 6]),
              ),
          ]),
          MarkerLayer(markers: [
            for (final p in stake)
              dot(ll(p.y, p.x), acc, p.name, onTap: () => setState(() => target = p)),
            for (final p in measured) dot(ll(p.y, p.x), blue, p.name, size: 10),
            if (t != null) dot(ll(t.y, t.x), Colors.redAccent, '', size: 22, ring: true),
            if (hasPos) dot(me, fixC, '', size: 18),
          ]),
          const Scalebar(
            alignment: Alignment.bottomLeft,
            textStyle: TextStyle(color: Colors.white, fontSize: 12, shadows: [Shadow(blurRadius: 3)]),
            lineColor: Colors.white,
            padding: EdgeInsets.only(left: 12, bottom: 30),
          ),
          RichAttributionWidget(attributions: [
            TextSourceAttribution(base == 'sat' ? 'Esri, Maxar, Earthstar Geographics' : 'OpenStreetMap katkıcıları'),
          ]),
        ],
      ),
      if (banner.isNotEmpty)
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.all(8),
            color: Colors.black.withValues(alpha: 0.7),
            child: Text(banner, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ),
      Positioned(
        right: 10,
        bottom: 40,
        child: Column(children: [
          FloatingActionButton.small(
            heroTag: 'beep',
            tooltip: 'Sesli uyarı',
            onPressed: () => setState(() {
              Beeper.enabled = !Beeper.enabled;
              prefs.setBool('beep', Beeper.enabled);
            }),
            child: Icon(Beeper.enabled ? Icons.volume_up : Icons.volume_off),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'base',
            tooltip: 'Altlık',
            onPressed: () => setState(() {
              base = base == 'sat' ? 'osm' : 'sat';
              prefs.setString('mapBase', base);
            }),
            child: Icon(base == 'sat' ? Icons.map : Icons.satellite_alt),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'fit',
            tooltip: 'Tümünü göster',
            onPressed: fitAll,
            child: const Icon(Icons.zoom_out_map),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'me',
            tooltip: 'Konumumu takip et',
            backgroundColor: follow ? green : null,
            onPressed: () {
              if (!hasPos) return;
              setState(() => follow = !follow);
              ctrl.move(me, max(ctrl.camera.zoom, 20));
            },
            child: const Icon(Icons.my_location),
          ),
        ]),
      ),
    ]);
  }
}
