import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../apple_map.dart';
import '../yaris_theme.dart';
import 'backend.dart';
import 'footprint_map_page.dart';
import 'trip_share_poster.dart';

class TripChartSample {
  const TripChartSample({
    required this.seconds,
    required this.value,
    this.timestamp,
    this.latitude,
    this.longitude,
  });
  final double seconds;
  final double value;
  final DateTime? timestamp;
  final double? latitude;
  final double? longitude;
}

class TripTelemetrySeries {
  const TripTelemetrySeries({
    required this.speedsKmh,
    required this.accelsMs2,
    required this.maxSpeedKmh,
    required this.avgSpeedKmh,
    required this.maxAccelMs2,
    required this.minAccelMs2,
    this.hardAccelCount = 0,
    this.hardBrakeCount = 0,
    this.smoothCruisePercent = 0.0,
    this.drivingScore = 0,
    this.drivingGrade = '—',
    this.estFuelLPer100Km,
  });

  final List<TripChartSample> speedsKmh;
  final List<TripChartSample> accelsMs2;
  final double? maxSpeedKmh;
  final double? avgSpeedKmh;
  final double? maxAccelMs2;
  final double? minAccelMs2;
  final int hardAccelCount;
  final int hardBrakeCount;
  final double smoothCruisePercent;
  final int drivingScore;
  final String drivingGrade;
  final double? estFuelLPer100Km;

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
    final parsed = <({double lat, double lon, double? speed, double? acc, DateTime time})>[];
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
      final rawAcc = item['accuracy_m'];
      final acc = rawAcc is num && rawAcc.isFinite && rawAcc >= 0
          ? rawAcc.toDouble()
          : null;
      parsed.add((
        lat: lat.toDouble(),
        lon: lon.toDouble(),
        speed: spd,
        acc: acc,
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
    final isFallback = <bool>[];
    for (var i = 0; i < parsed.length; i++) {
      final p = parsed[i];
      final sec = p.time.difference(t0).inMilliseconds / 1000.0;
      double? v = p.speed;
      var derived = false;
      if (v == null && i > 0) {
        final prev = parsed[i - 1];
        final dt = p.time.difference(prev.time).inMilliseconds / 1000.0;
        final coarseFix = (p.acc != null && p.acc! > 30.0) ||
            (prev.acc != null && prev.acc! > 30.0);
        if (!coarseFix && dt >= 1.0 && dt <= 60.0) {
          final meters = _haversineMeters(prev.lat, prev.lon, p.lat, p.lon);
          final kmh = (meters / dt) * 3.6;
          if (kmh >= 0 && kmh <= 180.0) {
            v = kmh;
            derived = true;
          }
        }
      }
      if (v != null) {
        speeds.add(
          TripChartSample(
            seconds: sec < 0 ? 0 : sec,
            value: v,
            timestamp: p.time,
            latitude: p.lat,
            longitude: p.lon,
          ),
        );
        isFallback.add(derived);
      }
    }

    // Filter isolated Haversine cold-start / GPS-jump spikes (>= 35 km/h above neighbors)
    if (speeds.length >= 2) {
      final cleaned = <TripChartSample>[];
      for (var i = 0; i < speeds.length; i++) {
        if (isFallback[i]) {
          final v = speeds[i].value;
          final prevV = i > 0 ? speeds[i - 1].value : null;
          final nextV = i + 1 < speeds.length ? speeds[i + 1].value : null;
          final spikeVsBoth = prevV != null &&
              nextV != null &&
              (v - prevV) >= 35.0 &&
              (v - nextV) >= 35.0;
          final spikeAtStart =
              i <= 3 && nextV != null && (v - nextV) >= 35.0;
          if (spikeVsBoth || spikeAtStart) continue;
        }
        cleaned.add(speeds[i]);
      }
      speeds
        ..clear()
        ..addAll(cleaned);
    }

    final accels = <TripChartSample>[];
    for (var i = 1; i < speeds.length; i++) {
      final prev = speeds[i - 1];
      final cur = speeds[i];
      final dt = cur.seconds - prev.seconds;
      if (dt >= 1.0 && dt <= 60.0) {
        final dvMs = (cur.value - prev.value) / 3.6;
        final a = (dvMs / dt).clamp(-10.0, 10.0);
        accels.add(
          TripChartSample(
            seconds: cur.seconds,
            value: a,
            timestamp: cur.timestamp,
            latitude: cur.latitude,
            longitude: cur.longitude,
          ),
        );
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

    // Compute driving score & hybrid smoothness metrics
    var hardAccel = 0;
    var hardBrake = 0;
    var smoothCount = 0;
    var prevWasHardAccel = false;
    var prevWasHardBrake = false;
    for (final a in accels) {
      if (a.value >= 2.2) {
        if (!prevWasHardAccel) hardAccel++;
        prevWasHardAccel = true;
        prevWasHardBrake = false;
      } else if (a.value <= -2.5) {
        if (!prevWasHardBrake) hardBrake++;
        prevWasHardBrake = true;
        prevWasHardAccel = false;
      } else {
        prevWasHardAccel = false;
        prevWasHardBrake = false;
        if (a.value.abs() <= 0.85) smoothCount++;
      }
    }
    final smoothPct = accels.isNotEmpty ? (smoothCount / accels.length) * 100.0 : 0.0;
    final rawScore = accels.isEmpty
        ? 0
        : (100 - hardAccel * 4 - hardBrake * 5 - ((100 - smoothPct) * 0.18).round())
            .clamp(50, 100);
    final grade = accels.isEmpty
        ? '—'
        : rawScore >= 92
            ? 'S 丝滑老司机'
            : rawScore >= 82
                ? 'A 稳健混动'
                : rawScore >= 70
                    ? 'B 轻快节奏'
                    : 'C 激进驾驶';

    // Yaris Hybrid WLTC heuristic (3.8 L/100km baseline + speed/harshness delta)
    double? estFuel;
    if (avgSpd != null && avgSpd >= 1.0) {
      final highSpeedPenalty = avgSpd > 75 ? (avgSpd - 75) * 0.045 : 0.0;
      final congestionPenalty = avgSpd < 18 ? (18 - avgSpd) * 0.06 : 0.0;
      final harshPenalty = (hardAccel + hardBrake) * 0.08;
      estFuel = (3.7 + highSpeedPenalty + congestionPenalty + harshPenalty).clamp(3.2, 8.5);
    }

    return TripTelemetrySeries(
      speedsKmh: speeds,
      accelsMs2: accels,
      maxSpeedKmh: maxSpd,
      avgSpeedKmh: avgSpd,
      maxAccelMs2: maxAcc,
      minAccelMs2: minAcc,
      hardAccelCount: hardAccel,
      hardBrakeCount: hardBrake,
      smoothCruisePercent: smoothPct,
      drivingScore: rawScore,
      drivingGrade: grade,
      estFuelLPer100Km: estFuel,
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
  int? _scrubSampleIndex;
  int _mileageDays = 7; // 7 = 一周, 30 = 一个月
  List<Map<String, dynamic>> _dailyStats = const [];
  double _periodTotalKm = 0.0;
  int _periodTotalTrips = 0;
  int? _selectedBarIndex;
  bool _loadingDailyStats = false;
  bool _loadingList = true;
  bool _loadingDetail = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTrips();
    _loadDailyStats(_mileageDays);
  }

  Future<void> _loadDailyStats(int days) async {
    setState(() {
      _mileageDays = days;
      _loadingDailyStats = true;
      _selectedBarIndex = null;
    });
    try {
      final raw = await widget.session.api.fetchDailyTripStats(days: days);
      if (!mounted || _mileageDays != days) return;
      final items = raw['items'] is List
          ? [
              for (final item in raw['items'] as List)
                if (item is Map) Map<String, dynamic>.from(item),
            ]
          : <Map<String, dynamic>>[];
      setState(() {
        _dailyStats = items;
        _periodTotalKm = (raw['total_distance_km'] as num?)?.toDouble() ?? 0.0;
        _periodTotalTrips = (raw['total_trips'] as num?)?.toInt() ?? 0;
        _loadingDailyStats = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingDailyStats = false);
    }
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
        _scrubSampleIndex = null;
        _loadingDetail = false;
      });
      final route = <Map<String, double>>[];
      for (final p in rawPoints) {
        if (p is Map && p['latitude'] is num && p['longitude'] is num) {
          final spd = p['speed_kmh'];
          route.add({
            'latitude': (p['latitude'] as num).toDouble(),
            'longitude': (p['longitude'] as num).toDouble(),
            if (spd is num && spd.isFinite && spd >= 0) 'speed_kmh': spd.toDouble(),
          });
        }
      }
      await _mapController.setScrubMarker();
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
          TextButton.icon(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => FootprintMapPage(session: widget.session),
              ),
            ),
            icon: const Icon(Icons.map_rounded, size: 17, color: YarisTheme.red),
            label: const Text(
              '足迹',
              style: TextStyle(color: YarisTheme.red, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            tooltip: '刷新行程',
            onPressed: _loadingList
                ? null
                : () {
                    _loadTrips();
                    _loadDailyStats(_mileageDays);
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([_loadTrips(), _loadDailyStats(_mileageDays)]);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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

            const SizedBox(height: 8),

            // Speed heatmap legend
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendDot(color: YarisTheme.blue, label: '<25'),
                SizedBox(width: 10),
                _LegendDot(color: Color(0xFF1E8E5A), label: '25-55'),
                SizedBox(width: 10),
                _LegendDot(color: Color(0xFFEB9414), label: '55-85'),
                SizedBox(width: 10),
                _LegendDot(color: Color(0xFFD22A36), label: '>85 km/h'),
              ],
            ),

            const SizedBox(height: 10),

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

            if (_series.drivingScore > 0) ...[
              const SizedBox(height: 12),
              _buildDrivingScoreCard(),
            ],

            const SizedBox(height: 12),

            // Weekly / Monthly daily mileage bar chart card
            _buildDailyMileageCard(),

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
      ),
    );
  }

  Widget _buildDailyMileageCard() {
    final isWeek = _mileageDays == 7;
    final items = _dailyStats;
    var maxKm = 0.0;
    for (final item in items) {
      final km = (item['distance_km'] as num?)?.toDouble() ?? 0.0;
      if (km > maxKm) maxKm = km;
    }
    final scaleMax = maxKm > 0 ? maxKm : 1.0;

    final selectedItem = (_selectedBarIndex != null &&
            _selectedBarIndex! >= 0 &&
            _selectedBarIndex! < items.length)
        ? items[_selectedBarIndex!]
        : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
                '每日里程',
                style: TextStyle(
                  color: YarisTheme.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _ChartSwitchPill(
                label: '一周',
                selected: isWeek,
                onTap: () {
                  if (!isWeek) _loadDailyStats(7);
                },
              ),
              const SizedBox(width: 6),
              _ChartSwitchPill(
                label: '一个月',
                selected: !isWeek,
                onTap: () {
                  if (isWeek) _loadDailyStats(30);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                selectedItem != null
                    ? '${selectedItem['date']}  ${((selectedItem['distance_km'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(2)} km'
                    : '合计 ${_periodTotalKm.toStringAsFixed(1)} km',
                style: TextStyle(
                  color: selectedItem != null ? YarisTheme.red : YarisTheme.blue,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                selectedItem != null
                    ? '${(selectedItem['trip_count'] as num?)?.toInt() ?? 0} 次行程'
                    : '$_periodTotalTrips 次有效行程',
                style: const TextStyle(color: YarisTheme.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 138,
            child: _loadingDailyStats && items.isEmpty
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : items.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无每日里程数据',
                          style: TextStyle(color: YarisTheme.muted, fontSize: 12.5),
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var i = 0; i < items.length; i++)
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(() {
                                  _selectedBarIndex = _selectedBarIndex == i ? null : i;
                                }),
                                child: _DailyMileageBar(
                                  label: '${items[i]['label'] ?? ''}',
                                  km: (items[i]['distance_km'] as num?)?.toDouble() ?? 0.0,
                                  ratio: (((items[i]['distance_km'] as num?)?.toDouble() ?? 0.0) /
                                          scaleMax)
                                      .clamp(0.0, 1.0),
                                  isWeek: isWeek,
                                  isToday: i == items.length - 1,
                                  isSelected: _selectedBarIndex == i,
                                  showMonthTick:
                                      i == 0 || i == items.length - 1 || i % 7 == 0,
                                ),
                              ),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  String _formatClockHms(DateTime? dt, double fallbackSeconds) {
    if (dt != null) {
      final l = dt.toLocal();
      final hh = l.hour.toString().padLeft(2, '0');
      final mm = l.minute.toString().padLeft(2, '0');
      final ss = l.second.toString().padLeft(2, '0');
      return '$hh:$mm:$ss';
    }
    final s = fallbackSeconds.round();
    final m = s ~/ 60;
    final rem = s % 60;
    return '${m.toString().padLeft(2, '0')}:${rem.toString().padLeft(2, '0')}';
  }

  int _findNearestSampleIndex(
    List<TripChartSample> samples,
    double dx,
    double width,
  ) {
    const leftPad = 36.0;
    const rightPad = 8.0;
    final w = math.max(1.0, width - leftPad - rightPad);
    final frac = ((dx - leftPad) / w).clamp(0.0, 1.0);
    final minT = samples.first.seconds;
    final spanT = math.max(1.0, samples.last.seconds - minT);
    final targetT = minT + frac * spanT;
    var bestIdx = 0;
    var bestDiff = (samples.first.seconds - targetT).abs();
    for (var i = 1; i < samples.length; i++) {
      final diff = (samples[i].seconds - targetT).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  Widget _buildTelemetryChartCard() {
    final isSpeed = _chartTab == 0;
    final samples = isSpeed ? _series.speedsKmh : _series.accelsMs2;
    final hasData = samples.length >= 2;
    final scrubbed = (hasData &&
            _scrubSampleIndex != null &&
            _scrubSampleIndex! >= 0 &&
            _scrubSampleIndex! < samples.length)
        ? samples[_scrubSampleIndex!]
        : null;

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
                onTap: () => setState(() {
                  _chartTab = 0;
                  _scrubSampleIndex = null;
                }),
              ),
              const SizedBox(width: 6),
              _ChartSwitchPill(
                label: '加速度',
                selected: !isSpeed,
                onTap: () => setState(() {
                  _chartTab = 1;
                  _scrubSampleIndex = null;
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (scrubbed != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: YarisTheme.periwinkle,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Text(
                    _formatClockHms(scrubbed.timestamp, scrubbed.seconds),
                    style: const TextStyle(
                      color: YarisTheme.ink,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isSpeed
                        ? '${scrubbed.value.toStringAsFixed(1)} km/h'
                        : '${scrubbed.value >= 0 ? "+" : ""}${scrubbed.value.toStringAsFixed(2)} m/s²',
                    style: TextStyle(
                      color: isSpeed
                          ? YarisTheme.blue
                          : (scrubbed.value >= 0 ? YarisTheme.blue : YarisTheme.red),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      setState(() => _scrubSampleIndex = null);
                      unawaited(_mapController.setScrubMarker());
                    },
                    child: const Icon(Icons.close_rounded, size: 15, color: YarisTheme.muted),
                  ),
                ],
              ),
            )
          else if (isSpeed)
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
            height: 144,
            child: !hasData
                ? _EmptyChartHint(isSpeed ? '暂无速度数据' : '暂无加速度数据')
                : LayoutBuilder(
                    builder: (context, constraints) {
                      void updateScrub(double dx) {
                        final idx = _findNearestSampleIndex(
                          samples,
                          dx,
                          constraints.maxWidth,
                        );
                        if (_scrubSampleIndex != idx) {
                          setState(() => _scrubSampleIndex = idx);
                          final pt = samples[idx];
                          if (pt.latitude != null && pt.longitude != null) {
                            unawaited(
                              _mapController.setScrubMarker(
                                latitude: pt.latitude,
                                longitude: pt.longitude,
                              ),
                            );
                          }
                        }
                      }

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => updateScrub(d.localPosition.dx),
                        onHorizontalDragStart: (d) => updateScrub(d.localPosition.dx),
                        onHorizontalDragUpdate: (d) => updateScrub(d.localPosition.dx),
                        child: CustomPaint(
                          key: ValueKey(
                            isSpeed ? 'trip-speed-chart' : 'trip-accel-chart',
                          ),
                          size: Size(constraints.maxWidth, 144),
                          painter: isSpeed
                              ? _SpeedChartPainter(
                                  samples,
                                  selectedIndex: _scrubSampleIndex,
                                )
                              : _AccelerationChartPainter(
                                  samples,
                                  selectedIndex: _scrubSampleIndex,
                                ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareDrivingReportCard() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    await showTripSharePosterDialog(
      context: context,
      detail: detail,
      series: _series,
      formattedDate: _formatLocalTime(detail['started_at']),
      formattedDuration: _formatDuration(detail['started_at'], detail['ended_at']),
    );
  }

  Widget _buildDrivingScoreCard() {
    final score = _series.drivingScore;
    final accent = score >= 85
        ? const Color(0xFF1E8E5A)
        : (score >= 70 ? YarisTheme.blue : YarisTheme.red);
    final detail = _selectedDetail;
    final distText = detail?['distance_km'] is num
        ? '${(detail!['distance_km'] as num).toStringAsFixed(2)} km'
        : '—';
    final durText = detail != null
        ? _formatDuration(detail['started_at'], detail['ended_at'])
        : '—';
    final dateText = detail != null ? _formatLocalTime(detail['started_at']) : '';

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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: YarisTheme.red,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'YARIS',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '老司机驾驶报告',
                style: TextStyle(
                  color: YarisTheme.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _shareDrivingReportCard,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: YarisTheme.periwinkle,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.ios_share_rounded,
                        size: 14,
                        color: YarisTheme.blue,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '分享海报',
                        style: TextStyle(
                          color: YarisTheme.blue,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$score 分 · ${_series.drivingGrade}',
                  style: TextStyle(
                    color: accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$distText · $durText${dateText.isNotEmpty ? " · $dateText" : ""}',
                  style: const TextStyle(color: YarisTheme.muted, fontSize: 11.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _SummaryMetric(
                label: '平顺滑行',
                value: '${_series.smoothCruisePercent.round()}%',
              ),
              _SummaryMetric(
                label: '急加速',
                value: '${_series.hardAccelCount} 次',
              ),
              _SummaryMetric(
                label: '急刹车',
                value: '${_series.hardBrakeCount} 次',
              ),
              _SummaryMetric(
                label: '估算油耗',
                value: _series.estFuelLPer100Km != null &&
                        _series.estFuelLPer100Km! > 0
                    ? '${(100.0 / _series.estFuelLPer100Km!).toStringAsFixed(1)} km/L'
                    : '—',
              ),
            ],
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

class _DailyMileageBar extends StatelessWidget {
  const _DailyMileageBar({
    required this.label,
    required this.km,
    required this.ratio,
    required this.isWeek,
    required this.isToday,
    required this.isSelected,
    required this.showMonthTick,
  });

  final String label;
  final double km;
  final double ratio;
  final bool isWeek;
  final bool isToday;
  final bool isSelected;
  final bool showMonthTick;

  @override
  Widget build(BuildContext context) {
    final barColor = isSelected
        ? YarisTheme.red
        : (km > 0
            ? (isToday ? YarisTheme.red.withValues(alpha: 0.85) : YarisTheme.blue)
            : YarisTheme.line);
    final barHeight = km > 0 ? math.max(8.0, ratio * 88.0) : 4.0;
    final showLabel = isWeek || showMonthTick;

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (isWeek)
          SizedBox(
            height: 16,
            child: km > 0
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      km >= 10 ? km.toStringAsFixed(0) : km.toStringAsFixed(1),
                      style: TextStyle(
                        color: isSelected ? YarisTheme.red : YarisTheme.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          )
        else
          const SizedBox(height: 16),
        const SizedBox(height: 3),
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: isWeek ? 18 : 6,
              height: barHeight,
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(isWeek ? 6 : 3),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 14,
          child: showLabel
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(
                      color: (isSelected || isToday) ? YarisTheme.ink : YarisTheme.muted,
                      fontSize: 10,
                      fontWeight: (isSelected || isToday) ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
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
  _SpeedChartPainter(this.samples, {this.selectedIndex});
  final List<TripChartSample> samples;
  final int? selectedIndex;

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

    if (selectedIndex != null && selectedIndex! >= 0 && selectedIndex! < samples.length) {
      final sel = samples[selectedIndex!];
      final sx = leftPad + ((sel.seconds - minT) / spanT) * w;
      final sy = topPad + h * (1 - (sel.value / maxVal).clamp(0.0, 1.0));
      canvas.drawLine(
        Offset(sx, topPad),
        Offset(sx, topPad + h),
        Paint()
          ..color = YarisTheme.red.withValues(alpha: 0.65)
          ..strokeWidth = 1.2,
      );
      canvas.drawCircle(Offset(sx, sy), 5.5, Paint()..color = YarisTheme.paper);
      canvas.drawCircle(Offset(sx, sy), 3.8, Paint()..color = YarisTheme.red);
    }

    _drawAxisTimeLabels(canvas, samples, leftPad, topPad + h + 4, w, spanT);
  }

  @override
  bool shouldRepaint(covariant _SpeedChartPainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.selectedIndex != selectedIndex;
}

class _AccelerationChartPainter extends CustomPainter {
  _AccelerationChartPainter(this.samples, {this.selectedIndex});
  final List<TripChartSample> samples;
  final int? selectedIndex;

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

    if (selectedIndex != null && selectedIndex! >= 0 && selectedIndex! < samples.length) {
      final sel = samples[selectedIndex!];
      final sx = leftPad + ((sel.seconds - minT) / spanT) * w;
      final sy = zeroY - (sel.value / peak).clamp(-1.0, 1.0) * (h / 2.0);
      final dotColor = sel.value >= 0 ? YarisTheme.blue : YarisTheme.red;
      canvas.drawLine(
        Offset(sx, topPad),
        Offset(sx, topPad + h),
        Paint()
          ..color = dotColor.withValues(alpha: 0.65)
          ..strokeWidth = 1.2,
      );
      canvas.drawCircle(Offset(sx, sy), 5.5, Paint()..color = YarisTheme.paper);
      canvas.drawCircle(Offset(sx, sy), 3.8, Paint()..color = dotColor);
    }

    _drawAxisTimeLabels(canvas, samples, leftPad, topPad + h + 4, w, spanT);
  }

  @override
  bool shouldRepaint(covariant _AccelerationChartPainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.selectedIndex != selectedIndex;
}

void _drawAxisTimeLabels(
  Canvas canvas,
  List<TripChartSample> samples,
  double leftPad,
  double y,
  double w,
  double spanT,
) {
  String fmtClock(DateTime dt) {
    final l = dt.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  final firstTs = samples.first.timestamp;
  final lastTs = samples.last.timestamp;
  if (firstTs != null && lastTs != null) {
    final midTs = firstTs.add(lastTs.difference(firstTs) ~/ 2);
    _drawText(canvas, fmtClock(firstTs), Offset(leftPad, y), 46, TextAlign.left);
    _drawText(canvas, fmtClock(midTs), Offset(leftPad + w / 2 - 23, y), 46, TextAlign.center);
    _drawText(canvas, fmtClock(lastTs), Offset(leftPad + w - 46, y), 46, TextAlign.right);
  } else {
    _drawText(canvas, '0s', Offset(leftPad, y), 48, TextAlign.left);
    _drawText(
      canvas,
      spanT >= 60 ? '${(spanT / 60).toStringAsFixed(1)}分' : '${spanT.round()}s',
      Offset(leftPad + w - 54, y),
      54,
      TextAlign.right,
    );
  }
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

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(color: YarisTheme.muted, fontSize: 11),
        ),
      ],
    );
  }
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
