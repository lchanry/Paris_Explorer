import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math';

void main() => runApp(const ParisExplorerApp());

// ── App ──────────────────────────────────────────────────────────────────────

class ParisExplorerApp extends StatelessWidget {
  const ParisExplorerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Paris Explorer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
        home: const MapPage(),
      );
}

// ── Modèle ───────────────────────────────────────────────────────────────────

class OsmWay {
  final String id;
  final String name;
  final List<int> nodeIds;
  const OsmWay({required this.id, required this.name, required this.nodeIds});
}

// ── Page principale ──────────────────────────────────────────────────────────

class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  // Position & orientation
  double _lat = 48.8566;
  double _lng = 2.3522;
  double _heading = 0; // degrés, 0 = nord

  // Données radar (rayon ~200m)
  Map<int, List<double>> _nodes = {};
  List<OsmWay> _ways = [];

  // Données accumulées (carte explorée)
  final Map<int, List<double>> _allNodes = {};
  final Map<String, OsmWay> _allWaysMap = {};

  // Progression
  String _currentWayId = '';
  String _currentStreetName = 'Localisation en cours…';
  final Set<String> _discovered = {};
  static const int _totalParisStreets = 5800;

  bool _loading = false;
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ── GPS ──────────────────────────────────────────────────────────────────

  Future<void> _initLocation() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      setState(() => _currentStreetName = 'Permission GPS refusée');
      return;
    }

    await _fetchStreets(_lat, _lng);

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
        // heading > 0 = valeur réelle (mobile), 0 sur Chrome = par défaut
        if (pos.heading >= 0) _heading = pos.heading;
      });
      _fetchStreets(pos.latitude, pos.longitude);
    });
  }

  // ── Overpass API ─────────────────────────────────────────────────────────

  Future<void> _fetchStreets(double lat, double lng) async {
    if (_loading) return;
    setState(() => _loading = true);

    final query = '''
[out:json][timeout:15];
(
  way(around:200,$lat,$lng)["highway"]["name"];
);
(._;>;);
out body;
''';

    try {
      final res = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        body: query,
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final elements = data['elements'] as List;

        final Map<int, List<double>> nodes = {};
        final List<OsmWay> ways = [];

        for (final el in elements) {
          if (el['type'] == 'node') {
            nodes[el['id'] as int] = [
              (el['lat'] as num).toDouble(),
              (el['lon'] as num).toDouble(),
            ];
          } else if (el['type'] == 'way') {
            ways.add(OsmWay(
              id: '${el['id']}',
              name: el['tags']?['name'] ?? 'Voie sans nom',
              nodeIds: (el['nodes'] as List).cast<int>(),
            ));
          }
        }

        // Rue la plus proche
        String closestId = '';
        String closestName = 'Hors rue';
        double closestDist = double.infinity;

        for (final way in ways) {
          for (final nid in way.nodeIds) {
            final n = nodes[nid];
            if (n == null) continue;
            final d = _distMeters(lat, lng, n[0], n[1]);
            if (d < closestDist) {
              closestDist = d;
              closestId = way.id;
              closestName = way.name;
            }
          }
        }

        if (closestDist < 20 && closestId.isNotEmpty) {
          _discovered.add(closestId);
        }

        // Accumulation pour la carte explorée
        _allNodes.addAll(nodes);
        for (final way in ways) {
          _allWaysMap[way.id] = way;
        }

        setState(() {
          _nodes = nodes;
          _ways = ways;
          _currentWayId = closestId;
          _currentStreetName = closestDist < 20 ? closestName : 'Hors rue';
        });
      }
    } catch (e) {
      setState(() => _currentStreetName = 'Erreur réseau');
    } finally {
      setState(() => _loading = false);
    }
  }

  double _distMeters(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final percent =
        (_discovered.length / _totalParisStreets * 100).clamp(0.0, 100.0);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(percent),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _buildRadarPage(context),
                  _buildExploredPage(context),
                ],
              ),
            ),
            _buildTabIndicator(),
            _buildBottomPanel(),
          ],
        ),
      ),
    );
  }

  // ── Barre du haut avec boussole ───────────────────────────────────────────

  Widget _buildTopBar(double percent) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            const Text(
              'PARIS\nEXPLORER',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
                height: 1.4,
              ),
            ),
            // Boussole centrée
            Expanded(
              child: Center(child: CompassWidget(heading: _heading)),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${percent.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    color: Color(0xFFF59E0B),
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  '${_discovered.length} rues',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ],
            ),
          ],
        ),
      );

  // ── Page radar ────────────────────────────────────────────────────────────

  Widget _buildRadarPage(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.78;
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: RadarPainter(
            lat: _lat,
            lng: _lng,
            heading: _heading,
            nodes: _nodes,
            ways: _ways,
            currentWayId: _currentWayId,
            displayRadiusMeters: 150,
          ),
        ),
      ),
    );
  }

  // ── Page carte explorée ───────────────────────────────────────────────────

  Widget _buildExploredPage(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.78;
    final allWays = _allWaysMap.values.toList();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'CARTE EXPLORÉE',
            style: TextStyle(
                color: Colors.white38, fontSize: 10, letterSpacing: 3),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: size,
            height: size,
            child: allWays.isEmpty
                ? const Center(
                    child: Text(
                      'Marche pour remplir la carte',
                      style:
                          TextStyle(color: Colors.white24, fontSize: 13),
                    ),
                  )
                : CustomPaint(
                    painter: ExploredMapPainter(
                      userLat: _lat,
                      userLng: _lng,
                      nodes: _allNodes,
                      ways: allWays,
                      discovered: _discovered,
                      displayRadiusMeters: 800,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legendDot(const Color(0xFFEF4444)),
              const SizedBox(width: 6),
              const Text('découverte',
                  style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(width: 20),
              _legendDot(Colors.white24),
              const SizedBox(width: 6),
              const Text('non explorée',
                  style: TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          )
        ],
      ),
    );
  }

  Widget _legendDot(Color color) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  // ── Indicateur d'onglet ───────────────────────────────────────────────────

  Widget _buildTabIndicator() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [0, 1].map((i) {
            final isActive = _currentPage == i;
            return GestureDetector(
              onTap: () => _pageController.animateToPage(
                i,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: isActive ? 24 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: isActive ? Colors.white : Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            );
          }).toList(),
        ),
      );

  // ── Bandeau bas ───────────────────────────────────────────────────────────

  Widget _buildBottomPanel() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _currentWayId.isNotEmpty
                      ? const Color(0xFFEF4444)
                      : Colors.white24,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentStreetName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600),
                    ),
                    if (_currentWayId.isNotEmpty)
                      const Text('rue débloquée ✓',
                          style: TextStyle(
                              color: Color(0xFFEF4444), fontSize: 11)),
                  ],
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: Colors.white38),
                ),
            ],
          ),
        ),
      );
}

// ── Boussole ─────────────────────────────────────────────────────────────────

class CompassWidget extends StatelessWidget {
  final double heading;
  const CompassWidget({super.key, required this.heading});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 54,
        height: 54,
        child: CustomPaint(painter: CompassPainter(heading: heading)),
      );
}

class CompassPainter extends CustomPainter {
  final double heading;
  const CompassPainter({required this.heading});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 1;

    // Fond
    canvas.drawCircle(
        c, r, Paint()..color = const Color(0xFF1A1A1A));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);

    // Marques cardinales (fixes)
    for (int i = 0; i < 4; i++) {
      final angle = i * pi / 2 - pi / 2;
      final outer = Offset(c.dx + cos(angle) * (r - 2), c.dy + sin(angle) * (r - 2));
      final inner = Offset(c.dx + cos(angle) * (r - 7), c.dy + sin(angle) * (r - 7));
      canvas.drawLine(
          inner,
          outer,
          Paint()
            ..color = Colors.white24
            ..strokeWidth = 1.5);
    }

    // Aiguille rotative (-heading pour pointer vers le nord géo)
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-heading * pi / 180);

    // Moitié nord — rouge
    final northPath = Path()
      ..moveTo(0, -(r * 0.68))
      ..lineTo(-4, 0)
      ..lineTo(4, 0)
      ..close();
    canvas.drawPath(northPath, Paint()..color = const Color(0xFFEF4444));

    // Moitié sud — blanc atténué
    final southPath = Path()
      ..moveTo(0, r * 0.58)
      ..lineTo(-4, 0)
      ..lineTo(4, 0)
      ..close();
    canvas.drawPath(southPath, Paint()..color = Colors.white30);

    canvas.restore();

    // Label N fixe
    final tp = TextPainter(
      text: const TextSpan(
          text: 'N',
          style: TextStyle(
              color: Color(0xFFEF4444),
              fontSize: 8,
              fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - r + 3));

    // Point central
    canvas.drawCircle(c, 3, Paint()..color = const Color(0xFF1A1A1A));
    canvas.drawCircle(
        c,
        3,
        Paint()
          ..color = Colors.white54
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(CompassPainter old) => old.heading != heading;
}

// ── Radar CustomPainter ───────────────────────────────────────────────────────

class RadarPainter extends CustomPainter {
  final double lat, lng, heading;
  final Map<int, List<double>> nodes;
  final List<OsmWay> ways;
  final String currentWayId;
  final double displayRadiusMeters;

  const RadarPainter({
    required this.lat,
    required this.lng,
    required this.heading,
    required this.nodes,
    required this.ways,
    required this.currentWayId,
    required this.displayRadiusMeters,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final scale = radius / displayRadiusMeters;
    final cosLat = cos(lat * pi / 180);

    // Fond + clip
    canvas.drawCircle(
        center, radius, Paint()..color = const Color(0xFF080808));
    canvas.clipPath(Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius - 1)));

    Offset project(double pLat, double pLng) {
      final dx = (pLng - lng) * 111320 * cosLat * scale;
      final dy = (lat - pLat) * 111320 * scale;
      return Offset(center.dx + dx, center.dy + dy);
    }

    // ── Cône de vision ──
    // heading 0 = nord = haut dans le repère canvas = angle -pi/2
    final coneHalfAngle = 25.0 * pi / 180;
    final directionRad = heading * pi / 180 - pi / 2;
    final coneLength = 28.0;

    final conePath = Path()..moveTo(center.dx, center.dy);
    conePath.arcTo(
      Rect.fromCircle(center: center, radius: coneLength),
      directionRad - coneHalfAngle,
      coneHalfAngle * 2,
      false,
    );
    conePath.close();

    canvas.drawPath(
        conePath,
        Paint()..color = Colors.white.withValues(alpha: 0.05));

    // Bords du cône (lignes)
    canvas.drawLine(
        center,
        Offset(
          center.dx + cos(directionRad - coneHalfAngle) * coneLength,
          center.dy + sin(directionRad - coneHalfAngle) * coneLength,
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.08)
          ..strokeWidth = 1);
    canvas.drawLine(
        center,
        Offset(
          center.dx + cos(directionRad + coneHalfAngle) * coneLength,
          center.dy + sin(directionRad + coneHalfAngle) * coneLength,
        ),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.08)
          ..strokeWidth = 1);

    // ── Rues ──
    for (final way in ways) {
      final isCurrent = way.id == currentWayId;

      final paint = Paint()
        ..color = isCurrent
            ? const Color(0xFFEF4444)
            : Colors.white.withValues(alpha: 0.78)
        ..strokeWidth = isCurrent ? 5.0 : 3.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final path = Path();
      bool first = true;
      for (final nid in way.nodeIds) {
        final n = nodes[nid];
        if (n == null) continue;
        final pt = project(n[0], n[1]);
        if (first) {
          path.moveTo(pt.dx, pt.dy);
          first = false;
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(path, paint);
    }

    // ── Cercle 50m ──
    canvas.drawCircle(
        center,
        radius * 50 / displayRadiusMeters,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.07)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8);

    // ── Bordure ──
    canvas.drawCircle(
        center,
        radius - 1,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.13)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    // ── Point utilisateur ──
    canvas.drawCircle(
        center, 14, Paint()..color = const Color(0x181D4ED8));
    canvas.drawCircle(center, 6, Paint()..color = Colors.white);
    canvas.drawCircle(
        center, 4, Paint()..color = const Color(0xFF3B82F6));
  }

  @override
  bool shouldRepaint(RadarPainter old) =>
      old.lat != lat ||
      old.lng != lng ||
      old.heading != heading ||
      old.ways != ways ||
      old.currentWayId != currentWayId;
}

// ── Explored Map CustomPainter ────────────────────────────────────────────────

class ExploredMapPainter extends CustomPainter {
  final double userLat, userLng;
  final Map<int, List<double>> nodes;
  final List<OsmWay> ways;
  final Set<String> discovered;
  final double displayRadiusMeters;

  const ExploredMapPainter({
    required this.userLat,
    required this.userLng,
    required this.nodes,
    required this.ways,
    required this.discovered,
    required this.displayRadiusMeters,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final scale = radius / displayRadiusMeters;
    final cosLat = cos(userLat * pi / 180);

    canvas.drawCircle(
        center, radius, Paint()..color = const Color(0xFF080808));
    canvas.clipPath(Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius - 1)));

    Offset project(double pLat, double pLng) {
      final dx = (pLng - userLng) * 111320 * cosLat * scale;
      final dy = (userLat - pLat) * 111320 * scale;
      return Offset(center.dx + dx, center.dy + dy);
    }

    // Rues non découvertes d'abord (en dessous)
    for (final way in ways) {
      if (discovered.contains(way.id)) continue;
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final path = Path();
      bool first = true;
      for (final nid in way.nodeIds) {
        final n = nodes[nid];
        if (n == null) continue;
        final pt = project(n[0], n[1]);
        if (first) { path.moveTo(pt.dx, pt.dy); first = false; }
        else path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(path, paint);
    }

    // Rues découvertes par dessus
    for (final way in ways) {
      if (!discovered.contains(way.id)) continue;
      final paint = Paint()
        ..color = const Color(0xFFEF4444)
        ..strokeWidth = 3.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final path = Path();
      bool first = true;
      for (final nid in way.nodeIds) {
        final n = nodes[nid];
        if (n == null) continue;
        final pt = project(n[0], n[1]);
        if (first) { path.moveTo(pt.dx, pt.dy); first = false; }
        else path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(path, paint);
    }

    // Bordure
    canvas.drawCircle(
        center,
        radius - 1,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    // Position utilisateur
    canvas.drawCircle(
        center, 8, Paint()..color = const Color(0x333B82F6));
    canvas.drawCircle(center, 5, Paint()..color = Colors.white);
    canvas.drawCircle(
        center, 3, Paint()..color = const Color(0xFF3B82F6));
  }

  @override
  bool shouldRepaint(ExploredMapPainter old) =>
      old.userLat != userLat ||
      old.userLng != userLng ||
      old.ways.length != ways.length ||
      old.discovered.length != discovered.length;
}