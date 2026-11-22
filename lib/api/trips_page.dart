import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../apple_map.dart';
import '../yaris_theme.dart';
import 'backend.dart';

class TripChartSample {
  const TripChartSample({required this.seconds, required this.value});
  final double seconds;
  final double value;
}

class TripTelemetrySeries {
  const TripTelemetrySeries({
    required this.speedsKmh,
    required this.accelsMs2,
    required this.maxSpeedKmh,
    required this.avgSpeedKmh,
    required this.maxAccelMs2,
    required this.minAccelMs2,
  });

  final List<TripChartSample> speedsKmh;
  final List<TripChartSample> accelsMs2;
  final double? maxSpeedKmh;
  final double? avgSpeedKmh;
  final double? maxAccelMs2;
  final double? minAccelMs2;

  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371008.8;
    final p1 = lat1 * math.pi / 180.0;
    final p2 = lat2 * math.pi / 180.0;
    final dp = (lat2 - lat1) * math.pi / 180.0;
    final dl = (lon2 - lon1) * math.pi / 180.0;
    final a = math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
  }

  /// Derives speed (km/h) and longitudinal acceleration (m/s^2) series from
  /// ordered trip points. Prefers reported GPS speed_kmh and falls back to
  /// Haversine delta / dt when speed_kmh is absent.
  static TripTelemetrySeries fromPoints(List<dynamic> rawPoints) {
    final parsed = <({double lat, double lon, double? speed, DateTime time})>[];
    for (final item in rawPoints) {
      if (item is! Map) continue;
      final lat = item['latitude'];
      final lon = item['longitude'];
      final ts = DateTime.tryParse('${item['recorded_at'] ?? ''}');
      if (lat is! num || lon is! num || ts == null) continue;
      final rawSpeed = item['speed_kmh'];
      final spd = rawSpeed is num && rawSpeed.isFinite && rawSpeed >= 0 && rawSpeed <= 300
          ? rawSpeed.toDouble()
          : null;
      parsed.add((
        lat: lat.toDouble(),
        lon: lon.toDouble(),
        speed: spd,
        time: ts,
      ));
    }

    if (parsed.isEmpty) {
      return const TripTelemetrySeries(
        speedsKmh: [],
        accelsMs2: [],
        maxSpeedKmh: null,
        avgSpeedKmh: null,
        maxAccelMs2: null,
        minAccelMs2: null,
      );
    }

    final t0 = parsed.first.time;
    final speeds = <TripChartSample>[];
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      final sec = p.time.difference(t0).inMilliseconds / 1000.0;
      double? v = p.speed;
      if (v == null && i > 0) {
        final prev = parsed[i - 1];
        final dt = p.time.difference(prev.time).inMilliseconds / 1000.0;
        if (dt >= 1.0 && dt <= 60.0) {
          final meters = _haversineMeters(prev.lat, prev.lon, p.lat, p.lon);
          final kmh = (meters / dt) * 3.6;
          if (kmh >= 0 && kmh <= 220.0) v = kmh;
        }
      }
      if (v != null) {
        speeds.add(TripChartSample(seconds: sec < 0 ? 0 : sec, value: v));
      }
    }

    final accels = <TripChartSample>[];
    for (var i = 1; i < speeds.length; i++) {
      final prev = speeds[i - 1];
      final cur = speeds[i];
      final dt = cur.seconds - prev.seconds;
      if (dt >= 1.0 && dt <= 60.0) {
        final dvMs = (cur.value - prev.value) / 3.6;
        final a = (dvMs / dt).clamp(-10.0, 10.0);
        accels.add(TripChartSample(seconds: cur.seconds, value: a));
      }
    }

    double? maxSpd;
    double? avgSpd;
    if (speeds.isNotEmpty) {
      var sum = 0.0;
      var hi = speeds.first.value;
      for (final s in speeds) {
        sum += s.value;
        if (s.value > hi) hi = s.value;
      }
      maxSpd = hi;
      avgSpd = sum / speeds.length;
    }

    double? maxAcc;
    double? minAcc;
    if (accels.isNotEmpty) {
      var hi = accels.first.value;
      var lo = accels.first.value;
      for (final a in accels) {
        if (a.value > hi) hi = a.value;
        if (a.value < lo) lo = a.value;
      }
      maxAcc = hi;
      minAcc = lo;
    }

    return TripTelemetrySeries(
      speedsKmh: speeds,
      accelsMs2: accels,
      maxSpeedKmh: maxSpd,
      avgSpeedKmh: avgSpd,
      maxAccelMs2: maxAcc,
      minAccelMs2: minAcc,
    );
  }
}

/// Displays recorded driving trips with Apple Maps route polyline and speed/acceleration charts.
class TripsPage extends StatefulWidget {
  const TripsPage({super.key, required this.session});
  final BackendSession session;

  @override
  State<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends State<TripsPage> {
  final AppleMapController _mapController = AppleMapController();
  List<Map<String, dynamic>> _trips = const [];
  Map<String, dynamic>? _selectedDetail;
  TripTelemetrySeries _series = const TripTelemetrySeries(
    speedsKmh: [],
    accelsMs2: [],
    maxSpeedKmh: null,
    avgSpeedKmh: null,
    maxAccelMs2: null,
    minAccelMs2: null,
  );
  String? _selectedTripId;
  int _chartTab = 0; // 0 = 速度, 1 = 加速度
  bool _loadingList = true;
  bool _loadingDetail = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  Future<void> _loadTrips() async {
    setState(() {
      _loadingList = true;
      _error = null;
    });
    try {
      final list = await widget.session.api.fetchTrips(limit: 40);
      if (!mounted) return;
      setState(() {
        _trips = list;
        _loadingList = false;
      });
      if (list.isNotEmpty) {
        final targetId = _selectedTripId != null &&
                list.any((t) => t['trip_id'] == _selectedTripId)
            ? _selectedTripId!
            : '${list.first['trip_id']}';
        await _selectTrip(targetId);
      } else {
        setState(() {
          _selectedTripId = null;
          _selectedDetail = null;
          _series = TripTelemetrySeries.fromPoints(const []);
        });
        await _mapController.setRoute(const []);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingList = false;
        _error = e is ApiFailure ? e.message : '加载行程记录失败';
      });
    }
  }

  Future<void> _selectTrip(String tripId) async {
    setState(() {
      _selectedTripId = tripId;
      _loadingDetail = true;
      _error = null;
    });
    try {
      final detail = await widget.session.api.fetchTripDetail(tripId);
      if (!mounted || _selectedTripId != tripId) return;
      final rawPoints = detail['points'] is List ? detail['points'] as List : const [];
      final computed = TripTelemetrySeries.fromPoints(rawPoints);
      setState(() {
        _selectedDetail = detail;
        _series = computed;
        _loadingDetail = false;
      });
      final route = <Map<String, double>>[];
      for (final p in rawPoints) {
        if (p is Map && p['latitude'] is num && p['longitude'] is num) {
          route.add({
            'latitude': (p['latitude'] as num).toDouble(),
            'longitude': (p['longitude'] as num).toDouble(),
          });
        }
      }
      await _mapController.setRoute(route);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDetail = false;
        _error = e is ApiFailure ? e.message : '加载行程轨迹失败';
      });
    }
  }

  Future<void> _deleteTrip(String tripId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除行程记录'),
        content: const Text('确定删除这条行程轨迹吗？删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: YarisTheme.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.session.api.deleteTrip(tripId);
      if (!mounted) return;
      if (_selectedTripId == tripId) _selectedTripId = null;
      await _loadTrips();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiFailure ? e.message : '删除行程失败')),
      );
    }
  }

  String _formatLocalTime(Object? raw) {
    final dt = DateTime.tryParse('${raw ?? ''}')?.toLocal();
    if (dt == null) return '—';
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$m-$d $hh:$mm';
  }

  String _formatDuration(Object? startRaw, Object? endRaw) {
    final s = DateTime.tryParse('${startRaw ?? ''}');
    final e = DateTime.tryParse('${endRaw ?? ''}');
    if (s == null || e == null) return '—';
    final sec = e.difference(s).inSeconds;
    if (sec < 60) return '${sec < 0 ? 0 : sec} 秒';
    final mins = sec ~/ 60;
    if (mins < 60) return '$mins 分钟';
    return '${mins ~/ 60} 小时 ${mins % 60} 分';
  }

  @override
  Widget build(BuildContext context) {
    final detail = _selectedDetail;
    final dist = detail?['distance_km'] is num
        ? '${(detail!['distance_km'] as num).toStringAsFixed(2)} km'
        : '—';
    final dur = detail != null
        ? _formatDuration(detail['started_at'], detail['ended_at'])
        : '—';
    final count = detail?['point_count'] is num ? '${detail!['point_count']} 点' : '—';

    return Scaffold(
      backgroundColor: YarisTheme.canvas,
      appBar: AppBar(
        title: const Text('行程轨迹'),
        actions: [
          IconButton(
            tooltip: '刷新行程',
            onPressed: _loadingList ? null : _loadTrips,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadTrips,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            // Apple Map route card
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                height: 235,
                child: Stack(
                  children: [
                    AppleMap(
                      controller: _mapController,
                      active: true,
                      onSelected: (_) {},
                    ),
                    if (_loadingDetail)
                      const Positioned(
                        right: 12,
                        top: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: YarisTheme.paper,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Trip summary metrics
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: YarisTheme.paper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: YarisTheme.line),
              ),
              child: Row(
                children: [
                  _SummaryMetric(label: '里程', value: dist),
                  _SummaryMetric(label: '时长', value: dur),
                  _SummaryMetric(label: '轨迹点', value: count),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Speed & Acceleration chart card
            _buildTelemetryChartCard(),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: YarisTheme.red, fontSize: 12.5),
                ),
              ),

            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                '历史行程',
                style: TextStyle(
                  color: YarisTheme.muted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),

            if (_loadingList)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_trips.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: YarisTheme.paper,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: YarisTheme.line),
                ),
                child: const Text(
                  '暂无行程记录',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: YarisTheme.muted, fontSize: 14),
                ),
              )
            else
              for (final trip in _trips) ...[
                _buildTripItem(trip),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryChartCard() {
    final isSpeed = _chartTab == 0;
    final hasSpeed = _series.speedsKmh.length >= 2;
    final hasAccel = _series.accelsMs2.length >= 2;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: YarisTheme.paper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: YarisTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '行驶曲线',
                style: TextStyle(
                  color: YarisTheme.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _ChartSwitchPill(
                label: '速度',
                selected: isSpeed,
                onTap: () => setState(() => _chartTab = 0),
              ),
              const SizedBox(width: 6),
              _ChartSwitchPill(
                label: '加速度',
                selected: !isSpeed,
                onTap: () => setState(() => _chartTab = 1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isSpeed)
            Row(
              children: [
                Text(
                  '最高 ${_series.maxSpeedKmh != null ? "${_series.maxSpeedKmh!.toStringAsFixed(1)} km/h" : "—"}',
                  style: const TextStyle(
                    color: YarisTheme.blue,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  '平均 ${_series.avgSpeedKmh != null ? "${_series.avgSpeedKmh!.toStringAsFixed(1)} km/h" : "—"}',
                  style: const TextStyle(color: YarisTheme.muted, fontSize: 12),
                ),
              ],
            )
          else
            Row(
              children: [
                Text(
                  '最大加速 ${_series.maxAccelMs2 != null ? "${_series.maxAccelMs2! >= 0 ? "+" : ""}${_series.maxAccelMs2!.toStringAsFixed(2)} m/s²" : "—"}',
                  style: const TextStyle(
                    color: YarisTheme.blue,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '最大减速 ${_series.minAccelMs2 != null ? "${_series.minAccelMs2!.toStringAsFixed(2)} m/s²" : "—"}',
                  style: const TextStyle(
                    color: YarisTheme.red,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 10),
          SizedBox(
            height: 136,
            child: isSpeed
                ? (hasSpeed
                    ? CustomPaint(
                        key: const ValueKey('trip-speed-chart'),
                        painter: _SpeedChartPainter(_series.speedsKmh),
                      )
                    : const _EmptyChartHint('暂无速度数据'))
                : (hasAccel
                    ? CustomPaint(
                        key: const ValueKey('trip-accel-chart'),
                        painter: _AccelerationChartPainter(_series.accelsMs2),
                      )
                    : const _EmptyChartHint('暂无加速度数据')),
          ),
        ],
      ),
    );
  }

  Widget _buildTripItem(Map<String, dynamic> trip) {
    final id = '${trip['trip_id']}';
    final selected = id == _selectedTripId;
    final km = trip['distance_km'] is num
        ? (trip['distance_km'] as num).toStringAsFixed(2)
        : '0.00';
    final pts = trip['point_count'] ?? 0;

    return Material(
      color: selected ? YarisTheme.periwinkle : YarisTheme.paper,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _selectTrip(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? YarisTheme.blue : YarisTheme.line,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: selected ? YarisTheme.blue : YarisTheme.periwinkle,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.route_rounded,
                  size: 20,
                  color: selected ? Colors.white : YarisTheme.blue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatLocalTime(trip['started_at']),
                      style: const TextStyle(
                        color: YarisTheme.ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$km km · ${_formatDuration(trip['started_at'], trip['ended_at'])} · $pts 个定位点',
                      style: const TextStyle(
                        color: YarisTheme.muted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除行程',
                onPressed: () => _deleteTrip(id),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: YarisTheme.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartSwitchPill extends StatelessWidget {
  const _ChartSwitchPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? YarisTheme.periwinkle : YarisTheme.neutral,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? YarisTheme.blue : YarisTheme.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyChartHint extends StatelessWidget {
  const _EmptyChartHint(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: YarisTheme.canvas,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: YarisTheme.muted, fontSize: 12.5),
      ),
    );
  }
}

class _SpeedChartPainter extends CustomPainter {
  _SpeedChartPainter(this.samples);
  final List<TripChartSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 36.0;
    const rightPad = 8.0;
    const topPad = 10.0;
    const bottomPad = 18.0;
    final w = math.max(1.0, size.width - leftPad - rightPad);
    final h = math.max(1.0, size.height - topPad - bottomPad);

    final maxVal = math.max(
      20.0,
      (samples.map((e) => e.value).reduce(math.max) / 10.0).ceil() * 10.0,
    );
    final minT = samples.first.seconds;
    final spanT = math.max(1.0, samples.last.seconds - minT);

    final gridPaint = Paint()
      ..color = YarisTheme.line
      ..strokeWidth = 1;

    // Horizontal grid & Y labels (0, mid, max)
    for (final frac in [0.0, 0.5, 1.0]) {
      final y = topPad + h * (1 - frac);
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + w, y), gridPaint);
      final label = (maxVal * frac).round().toString();
      _drawText(canvas, label, Offset(0, y - 6), 32, TextAlign.right);
    }

    final path = Path();
    final fillPath = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = leftPad + ((samples[i].seconds - minT) / spanT) * w;
      final y = topPad + h * (1 - (samples[i].value / maxVal).clamp(0.0, 1.0));
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, topPad + h);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
      if (i == samples.length - 1) {
        fillPath.lineTo(x, topPad + h);
        fillPath.close();
      }
    }

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          YarisTheme.blue.withValues(alpha: 0.24),
          YarisTheme.blue.withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(leftPad, topPad, w, h));
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = YarisTheme.blue
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    _drawText(canvas, '0s', Offset(leftPad, topPad + h + 4), 48, TextAlign.left);
    _drawText(
      canvas,
      spanT >= 60 ? '${(spanT / 60).toStringAsFixed(1)}分' : '${spanT.round()}s',
      Offset(leftPad + w - 54, topPad + h + 4),
      54,
      TextAlign.right,
    );
  }

  @override
  bool shouldRepaint(covariant _SpeedChartPainter oldDelegate) =>
      oldDelegate.samples != samples;
}

class _AccelerationChartPainter extends CustomPainter {
  _AccelerationChartPainter(this.samples);
  final List<TripChartSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 36.0;
    const rightPad = 8.0;
    const topPad = 10.0;
    const bottomPad = 18.0;
    final w = math.max(1.0, size.width - leftPad - rightPad);
    final h = math.max(1.0, size.height - topPad - bottomPad);

    var peak = 1.5;
    for (final s in samples) {
      if (s.value.abs() > peak) peak = s.value.abs();
    }
    peak = (peak * 2).ceil() / 2.0; // round up to 0.5 step

    final minT = samples.first.seconds;
    final spanT = math.max(1.0, samples.last.seconds - minT);
    final zeroY = topPad + h / 2.0;

    final gridPaint = Paint()
      ..color = YarisTheme.line
      ..strokeWidth = 1;
    canvas.drawLine(Offset(leftPad, topPad), Offset(leftPad + w, topPad), gridPaint);
    canvas.drawLine(Offset(leftPad, topPad + h), Offset(leftPad + w, topPad + h), gridPaint);

    // Zero baseline
    final zeroPaint = Paint()
      ..color = YarisTheme.muted.withValues(alpha: 0.45)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(leftPad, zeroY), Offset(leftPad + w, zeroY), zeroPaint);

    _drawText(canvas, '+${peak.toStringAsFixed(1)}', Offset(0, topPad - 6), 32, TextAlign.right);
    _drawText(canvas, '0', Offset(0, zeroY - 6), 32, TextAlign.right);
    _drawText(canvas, '-${peak.toStringAsFixed(1)}', Offset(0, topPad + h - 6), 32, TextAlign.right);

    // Draw segments colored by positive (blue accel) vs negative (red decel)
    for (var i = 1; i < samples.length; i++) {
      final a0 = samples[i - 1];
      final a1 = samples[i];
      final x0 = leftPad + ((a0.seconds - minT) / spanT) * w;
      final y0 = zeroY - (a0.value / peak).clamp(-1.0, 1.0) * (h / 2.0);
      final x1 = leftPad + ((a1.seconds - minT) / spanT) * w;
      final y1 = zeroY - (a1.value / peak).clamp(-1.0, 1.0) * (h / 2.0);
      final avg = (a0.value + a1.value) / 2.0;
      final color = avg >= 0 ? YarisTheme.blue : YarisTheme.red;

      final area = Path()
        ..moveTo(x0, zeroY)
        ..lineTo(x0, y0)
        ..lineTo(x1, y1)
        ..lineTo(x1, zeroY)
        ..close();
      canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.16));

      canvas.drawLine(
        Offset(x0, y0),
        Offset(x1, y1),
        Paint()
          ..color = color
          ..strokeWidth = 2.3
          ..strokeCap = StrokeCap.round,
      );
    }

    _drawText(canvas, '0s', Offset(leftPad, topPad + h + 4), 48, TextAlign.left);
    _drawText(
      canvas,
      spanT >= 60 ? '${(spanT / 60).toStringAsFixed(1)}分' : '${spanT.round()}s',
      Offset(leftPad + w - 54, topPad + h + 4),
      54,
      TextAlign.right,
    );
  }

  @override
  bool shouldRepaint(covariant _AccelerationChartPainter oldDelegate) =>
      oldDelegate.samples != samples;
}

void _drawText(
  Canvas canvas,
  String text,
  Offset offset,
  double maxWidth,
  TextAlign align,
) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: YarisTheme.muted, fontSize: 10),
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(minWidth: maxWidth, maxWidth: maxWidth);
  tp.paint(canvas, offset);
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: YarisTheme.ink,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: YarisTheme.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}
