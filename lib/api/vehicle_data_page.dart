import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../yaris_theme.dart';
import 'backend.dart';

const _statusGreen = Color(0xFF1E8E5A);

/// Dedicated OBD-II & Vehicle Telemetry inspection page displaying all persisted
/// vehicle metrics, interactive historical trend charts, and last parking location.
class VehicleDataPage extends StatefulWidget {
  const VehicleDataPage({super.key, required this.session});
  final BackendSession session;

  @override
  State<VehicleDataPage> createState() => _VehicleDataPageState();
}

class _VehicleDataPageState extends State<VehicleDataPage> {
  Map<String, dynamic>? _state;
  List<Map<String, dynamic>> _history = const [];
  bool _loading = true;
  String? _error;
  int _trendTab = 0; // 0: 12V电压, 1: 剩余油量, 2: 混动SOC, 3: 冷却水温
  int? _scrubIdx;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.session.api.fetchVehicleState(),
        widget.session.api.fetchVehicleHistory(limit: 120),
      ]);
      if (!mounted) return;
      final state = results[0];
      final rawHist = results[1]['items'];
      final hist = rawHist is List
          ? [
              for (final item in rawHist.reversed)
                if (item is Map) Map<String, dynamic>.from(item),
            ]
          : <Map<String, dynamic>>[];
      setState(() {
        _state = state;
        _history = hist;
        _scrubIdx = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiFailure ? e.message : '加载车况数据失败';
      });
    }
  }

  String _fmtNum(Object? raw, {int digits = 1, String unit = ''}) {
    if (raw is! num || !raw.isFinite) return '—';
    final s = digits == 0 ? raw.round().toString() : raw.toStringAsFixed(digits);
    return unit.isEmpty ? s : '$s $unit';
  }

  String _fmtTime(Object? raw) {
    final dt = DateTime.tryParse('${raw ?? ''}');
    if (dt == null) return '暂无记录';
    final l = dt.toLocal();
    return '${l.month.toString().padLeft(2, '0')}/${l.day.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }

  List<({DateTime time, double value})> _currentTrendPoints() {
    final field = switch (_trendTab) {
      0 => 'aux_12v_voltage',
      1 => 'fuel_level_liters',
      2 => 'battery_soc',
      _ => 'coolant_temp',
    };
    final pts = <({DateTime time, double value})>[];
    for (final row in _history) {
      final v = row[field];
      final ts = DateTime.tryParse('${row['recorded_at'] ?? ''}');
      if (v is num && v.isFinite && ts != null) {
        pts.add((time: ts, value: v.toDouble()));
      }
    }
    return pts;
  }

  String _trendUnit() => switch (_trendTab) {
        0 => 'V',
        1 => 'L',
        2 => '%',
        _ => '°C',
      };

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final online = s?['online'] == true;
    final parking = s?['parking'] is Map ? s!['parking'] as Map : null;

    return Scaffold(
      backgroundColor: YarisTheme.canvas,
      appBar: AppBar(
        title: const Text('车况与 OBD 数据'),
        actions: [
          IconButton(
            tooltip: '刷新车况',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  style: const TextStyle(color: YarisTheme.red, fontSize: 13),
                ),
              ),

            // Top summary card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: YarisTheme.paper,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: YarisTheme.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: online ? _statusGreen : YarisTheme.muted,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        online ? '车机在线' : '驻车离线',
                        style: TextStyle(
                          color: online ? _statusGreen : YarisTheme.muted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'OBD 更新：${_fmtTime(s?['obd_updated_at'])}',
                        style: const TextStyle(color: YarisTheme.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _HeroStat(
                        label: '预估续航',
                        value: _fmtNum(s?['estimated_range_km'], digits: 0, unit: 'km'),
                        accent: YarisTheme.red,
                      ),
                      _HeroStat(
                        label: '剩余油量',
                        value: _fmtNum(s?['fuel_level_liters'], digits: 1, unit: 'L'),
                        accent: YarisTheme.blue,
                      ),
                      _HeroStat(
                        label: '12V 蓄电池',
                        value: _fmtNum(s?['aux_12v_voltage'], digits: 1, unit: 'V'),
                        accent: _statusGreen,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            _buildHistoryTrendCard(),

            const SizedBox(height: 14),
            _buildSection('燃油与里程', [
              ('剩余油量', _fmtNum(s?['fuel_level_liters'], digits: 1, unit: 'L')),
              ('油量百分比', _fmtNum(s?['fuel_level_percent'], digits: 1, unit: '%')),
              ('预估续航', _fmtNum(s?['estimated_range_km'], digits: 0, unit: 'km')),
              ('整车总里程', _fmtNum(s?['total_odometer_km'], digits: 1, unit: 'km')),
              ('本次行程里程', _fmtNum(s?['trip_distance_km'], digits: 2, unit: 'km')),
              ('瞬时油耗率', _fmtNum(s?['fuel_rate_l_h'], digits: 2, unit: 'L/h')),
            ]),

            const SizedBox(height: 12),
            _buildSection('混动电池与电气', [
              ('12V 蓄电池电压', _fmtNum(s?['aux_12v_voltage'], digits: 2, unit: 'V')),
              ('12V 蓄电池电流', _fmtNum(s?['aux_12v_current'], digits: 1, unit: 'A')),
              ('12V 蓄电池温度', _fmtNum(s?['aux_12v_temp'], digits: 1, unit: '°C')),
              ('混动电池 SOC', _fmtNum(s?['battery_soc'], digits: 1, unit: '%')),
              ('混动电池总压', _fmtNum(s?['battery_voltage'], digits: 1, unit: 'V')),
              ('混动充放功率', _fmtNum(s?['battery_power_kw'], digits: 2, unit: 'kW')),
              ('电池健康度 SOH', _fmtNum(s?['battery_remaining_life'], digits: 1, unit: '%')),
              ('单体最大压差', _fmtNum(s?['cell_delta_voltage'], digits: 3, unit: 'V')),
              ('MG2 逆变器温度', _fmtNum(s?['mg2_inverter_temp'], digits: 1, unit: '°C')),
              ('变速箱油温', _fmtNum(s?['transaxle_oil_temp'], digits: 1, unit: '°C')),
            ]),

            const SizedBox(height: 12),
            _buildSection('发动机与环境', [
              ('车速', _fmtNum(s?['speed_kmh'], digits: 1, unit: 'km/h')),
              ('发动机转速', _fmtNum(s?['engine_rpm'], digits: 0, unit: 'RPM')),
              ('冷却液水温', _fmtNum(s?['coolant_temp'], digits: 1, unit: '°C')),
              ('机油温度', _fmtNum(s?['engine_oil_temp'], digits: 1, unit: '°C')),
              ('节气门开度', _fmtNum(s?['throttle_position'], digits: 1, unit: '%')),
              ('发动机负荷', _fmtNum(s?['engine_load'], digits: 1, unit: '%')),
              ('环境温度', _fmtNum(s?['ambient_air_temp'], digits: 1, unit: '°C')),
              ('进气温度', _fmtNum(s?['intake_air_temp'], digits: 1, unit: '°C')),
              ('大气压强', _fmtNum(s?['baro_kpa'], digits: 0, unit: 'kPa')),
              ('本次运行时间', _fmtNum(s?['run_time_seconds'], digits: 0, unit: '秒')),
            ]),

            const SizedBox(height: 12),
            _buildSection('最后停车点', [
              (
                '经纬度',
                (parking?['latitude'] is num && parking?['longitude'] is num)
                    ? '${(parking!['latitude'] as num).toStringAsFixed(5)}, ${(parking['longitude'] as num).toStringAsFixed(5)}'
                    : '—'
              ),
              ('记录时间', _fmtTime(parking?['parked_at'])),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryTrendCard() {
    final pts = _currentTrendPoints();
    final unit = _trendUnit();
    final sel = (_scrubIdx != null && _scrubIdx! >= 0 && _scrubIdx! < pts.length)
        ? pts[_scrubIdx!]
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
          const Text(
            '历史趋势',
            style: TextStyle(
              color: YarisTheme.ink,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final entry in const [
                  (0, '12V 电压'),
                  (1, '剩余油量'),
                  (2, '混动 SOC'),
                  (3, '冷却水温'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(entry.$2),
                      selected: _trendTab == entry.$1,
                      onSelected: (_) => setState(() {
                        _trendTab = entry.$1;
                        _scrubIdx = null;
                      }),
                      selectedColor: YarisTheme.periwinkle,
                      labelStyle: TextStyle(
                        color: _trendTab == entry.$1 ? YarisTheme.blue : YarisTheme.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (sel != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: YarisTheme.periwinkle,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Text(
                    _fmtTime(sel.time.toIso8601String()),
                    style: const TextStyle(
                      color: YarisTheme.ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${sel.value.toStringAsFixed(1)} $unit',
                    style: const TextStyle(
                      color: YarisTheme.blue,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _scrubIdx = null),
                    child: const Icon(Icons.close_rounded, size: 15, color: YarisTheme.muted),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            height: 128,
            child: pts.length < 2
                ? const Center(
                    child: Text(
                      '暂无足够的历史采样点（需至少 2 条）',
                      style: TextStyle(color: YarisTheme.muted, fontSize: 12.5),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      void update(double dx) {
                        const leftPad = 38.0;
                        const rightPad = 8.0;
                        final w = math.max(1.0, constraints.maxWidth - leftPad - rightPad);
                        final frac = ((dx - leftPad) / w).clamp(0.0, 1.0);
                        final idx = (frac * (pts.length - 1)).round().clamp(0, pts.length - 1);
                        if (_scrubIdx != idx) setState(() => _scrubIdx = idx);
                      }

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => update(d.localPosition.dx),
                        onHorizontalDragStart: (d) => update(d.localPosition.dx),
                        onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
                        child: CustomPaint(
                          size: Size(constraints.maxWidth, 128),
                          painter: _ObdTrendPainter(pts, selectedIndex: _scrubIdx),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<(String, String)> rows) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: YarisTheme.paper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: YarisTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: YarisTheme.ink,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: YarisTheme.line),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  Text(
                    rows[i].$1,
                    style: const TextStyle(color: YarisTheme.muted, fontSize: 13),
                  ),
                  const Spacer(),
                  Text(
                    rows[i].$2,
                    style: const TextStyle(
                      color: YarisTheme.ink,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
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
              fontSize: 18,
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

class _ObdTrendPainter extends CustomPainter {
  _ObdTrendPainter(this.points, {this.selectedIndex});
  final List<({DateTime time, double value})> points;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 38.0;
    const rightPad = 8.0;
    const topPad = 10.0;
    const bottomPad = 18.0;
    final w = math.max(1.0, size.width - leftPad - rightPad);
    final h = math.max(1.0, size.height - topPad - bottomPad);

    var minV = points.first.value;
    var maxV = points.first.value;
    for (final p in points) {
      if (p.value < minV) minV = p.value;
      if (p.value > maxV) maxV = p.value;
    }
    if ((maxV - minV).abs() < 0.2) {
      minV -= 1.0;
      maxV += 1.0;
    }
    final spanV = maxV - minV;

    final gridPaint = Paint()
      ..color = YarisTheme.line
      ..strokeWidth = 1;
    for (final frac in [0.0, 0.5, 1.0]) {
      final y = topPad + h * (1 - frac);
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + w, y), gridPaint);
      final label = (minV + spanV * frac).toStringAsFixed(1);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: YarisTheme.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
      )..layout(minWidth: 34, maxWidth: 34);
      tp.paint(canvas, Offset(0, y - 6));
    }

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = leftPad + (i / (points.length - 1)) * w;
      final y = topPad + h * (1 - ((points[i].value - minV) / spanV).clamp(0.0, 1.0));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = YarisTheme.blue
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    if (selectedIndex != null && selectedIndex! >= 0 && selectedIndex! < points.length) {
      final sx = leftPad + (selectedIndex! / (points.length - 1)) * w;
      final sy = topPad +
          h * (1 - ((points[selectedIndex!].value - minV) / spanV).clamp(0.0, 1.0));
      canvas.drawLine(
        Offset(sx, topPad),
        Offset(sx, topPad + h),
        Paint()
          ..color = YarisTheme.red.withValues(alpha: 0.65)
          ..strokeWidth = 1.2,
      );
      canvas.drawCircle(Offset(sx, sy), 5, Paint()..color = YarisTheme.paper);
      canvas.drawCircle(Offset(sx, sy), 3.4, Paint()..color = YarisTheme.red);
    }

    String fmtHm(DateTime dt) {
      final l = dt.toLocal();
      return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    }

    for (final item in [
      (fmtHm(points.first.time), leftPad, TextAlign.left),
      (fmtHm(points.last.time), leftPad + w - 42, TextAlign.right),
    ]) {
      final tp = TextPainter(
        text: TextSpan(
          text: item.$1,
          style: const TextStyle(color: YarisTheme.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
        textAlign: item.$3,
      )..layout(minWidth: 42, maxWidth: 42);
      tp.paint(canvas, Offset(item.$2, topPad + h + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _ObdTrendPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.selectedIndex != selectedIndex;
}
