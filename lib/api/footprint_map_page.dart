import 'package:flutter/material.dart';
import '../apple_map.dart';
import '../yaris_theme.dart';
import 'backend.dart';

/// Full-screen City Footprint ("Light Up the Map") overlay displaying all valid
/// historical routes on Apple Maps along with aggregate exploration statistics.
class FootprintMapPage extends StatefulWidget {
  const FootprintMapPage({super.key, required this.session});
  final BackendSession session;

  @override
  State<FootprintMapPage> createState() => _FootprintMapPageState();
}

class _FootprintMapPageState extends State<FootprintMapPage> {
  final AppleMapController _mapController = AppleMapController();
  bool _loading = true;
  String? _error;
  int _totalTrips = 0;
  double _totalKm = 0.0;
  double _totalMinutes = 0.0;
  double _maxSpanKm = 0.0;

  @override
  void initState() {
    super.initState();
    _loadFootprint();
  }

  Future<void> _loadFootprint() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.session.api.fetchTripFootprint();
      if (!mounted) return;
      final rawRoutes = data['routes'] is List ? data['routes'] as List : const [];
      final routes = <List<Map<String, double>>>[];
      for (final r in rawRoutes) {
        if (r is! List) continue;
        final pts = <Map<String, double>>[];
        for (final p in r) {
          if (p is Map && p['latitude'] is num && p['longitude'] is num) {
            pts.add({
              'latitude': (p['latitude'] as num).toDouble(),
              'longitude': (p['longitude'] as num).toDouble(),
            });
          }
        }
        if (pts.length >= 2) routes.add(pts);
      }
      setState(() {
        _totalTrips = (data['total_trips'] as num?)?.toInt() ?? 0;
        _totalKm = (data['total_distance_km'] as num?)?.toDouble() ?? 0.0;
        _totalMinutes = (data['total_duration_minutes'] as num?)?.toDouble() ?? 0.0;
        _maxSpanKm = (data['max_span_km'] as num?)?.toDouble() ?? 0.0;
        _loading = false;
      });
      await _mapController.setMultiRoutes(routes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiFailure ? e.message : '加载足迹地图失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hours = _totalMinutes / 60.0;
    return Scaffold(
      backgroundColor: YarisTheme.canvas,
      appBar: AppBar(
        title: const Text('点亮城市足迹'),
        actions: [
          IconButton(
            tooltip: '刷新足迹',
            onPressed: _loading ? null : _loadFootprint,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: AppleMap(
              controller: _mapController,
              active: true,
              onSelected: (_) {},
            ),
          ),
          if (_loading)
            const Positioned(
              top: 16,
              right: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: YarisTheme.paper,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: YarisTheme.paper.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: YarisTheme.line),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: YarisTheme.red, fontSize: 12.5),
                      ),
                    ),
                  Row(
                    children: [
                      _FootprintStat(
                        label: '累计点亮',
                        value: '${_totalKm.toStringAsFixed(1)} km',
                        accent: YarisTheme.red,
                      ),
                      _FootprintStat(
                        label: '有效行程',
                        value: '$_totalTrips 次',
                        accent: YarisTheme.blue,
                      ),
                      _FootprintStat(
                        label: '探索跨度',
                        value: '${_maxSpanKm.toStringAsFixed(1)} km',
                        accent: YarisTheme.ink,
                      ),
                      _FootprintStat(
                        label: '累计驾驶',
                        value: hours >= 1
                            ? '${hours.toStringAsFixed(1)} h'
                            : '${_totalMinutes.round()} 分',
                        accent: YarisTheme.muted,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FootprintStat extends StatelessWidget {
  const _FootprintStat({
    required this.label,
    required this.value,
    required this.accent,
  });
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: accent,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: YarisTheme.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
