import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../yaris_theme.dart';
import 'trips_page.dart';

/// Displays a magazine-grade Yaris Hybrid Driving Report share poster preview
/// and exports it as a 3x crisp PNG to the native iOS Share Sheet.
Future<void> showTripSharePosterDialog({
  required BuildContext context,
  required Map<String, dynamic> detail,
  required TripTelemetrySeries series,
  required String formattedDate,
  required String formattedDuration,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (ctx) => _TripSharePosterDialog(
      detail: detail,
      series: series,
      formattedDate: formattedDate,
      formattedDuration: formattedDuration,
    ),
  );
}

class _TripSharePosterDialog extends StatefulWidget {
  const _TripSharePosterDialog({
    required this.detail,
    required this.series,
    required this.formattedDate,
    required this.formattedDuration,
  });

  final Map<String, dynamic> detail;
  final TripTelemetrySeries series;
  final String formattedDate;
  final String formattedDuration;

  @override
  State<_TripSharePosterDialog> createState() => _TripSharePosterDialogState();
}

class _TripSharePosterDialogState extends State<_TripSharePosterDialog> {
  static const MethodChannel _shareChannel = MethodChannel('io.myyaris/share');
  final GlobalKey _posterKey = GlobalKey();
  bool _exporting = false;
  bool _loadingMap = true;
  Uint8List? _satelliteSnapshot;

  @override
  void initState() {
    super.initState();
    _loadSatelliteSnapshot();
  }

  Future<void> _loadSatelliteSnapshot() async {
    final rawPts = widget.detail['points'] is List
        ? widget.detail['points'] as List
        : const [];
    final compact = <Map<String, double>>[];
    final step = rawPts.length > 360 ? (rawPts.length / 360).ceil() : 1;
    for (var i = 0; i < rawPts.length; i += step) {
      final item = rawPts[i];
      if (item is! Map) continue;
      final lat = item['latitude'] ?? item['lat'];
      final lng = item['longitude'] ?? item['lng'];
      if (lat is! num || lng is! num) continue;
      final spd = item['speed_kmh'] is num
          ? (item['speed_kmh'] as num).toDouble()
          : 20.0;
      compact.add({
        'lat': lat.toDouble(),
        'lng': lng.toDouble(),
        'speed_kmh': spd,
      });
    }
    if (compact.length < 2) {
      if (mounted) setState(() => _loadingMap = false);
      return;
    }
    try {
      final bytes = await _shareChannel
          .invokeMethod<Uint8List>('renderSatelliteRouteSnapshot', {
            'points': compact,
            'width': 300.0,
            'height': 168.0,
          })
          .timeout(const Duration(seconds: 7));
      if (!mounted) return;
      setState(() {
        _satelliteSnapshot = bytes;
        _loadingMap = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMap = false);
    }
  }

  Future<void> _exportAndShare() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _posterKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('海报尚未渲染完成');
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw StateError('图片编码失败');
      final bytes = byteData.buffer.asUint8List();
      final km = widget.detail['distance_km'] is num
          ? (widget.detail['distance_km'] as num).toStringAsFixed(2)
          : '0.00';
      await _shareChannel.invokeMethod<bool>('shareImage', {
        'bytes': bytes,
        'text':
            'MyYaris 行程报告 · $km km · ${widget.series.drivingScore}分 (${widget.series.drivingGrade})',
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出海报失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kmVal = widget.detail['distance_km'] is num
        ? (widget.detail['distance_km'] as num).toDouble()
        : 0.0;
    final rawPts = widget.detail['points'] is List
        ? widget.detail['points'] as List
        : const [];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The actual exported poster (zero UI buttons inside)
          Flexible(
            child: SingleChildScrollView(
              child: RepaintBoundary(
                key: _posterKey,
                child: _YarisDrivingPoster(
                  distanceKm: kmVal,
                  durationText: widget.formattedDuration,
                  dateText: widget.formattedDate,
                  series: widget.series,
                  rawPoints: rawPts,
                  satelliteSnapshot: _satelliteSnapshot,
                  loadingMap: _loadingMap,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: YarisTheme.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                onPressed: _exporting ? null : _exportAndShare,
                icon: Icon(
                  _exporting ? Icons.hourglass_top_rounded : Icons.ios_share_rounded,
                  size: 18,
                ),
                label: Text(
                  _exporting ? '生成中…' : '分享 / 保存高清海报',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _YarisDrivingPoster extends StatelessWidget {
  const _YarisDrivingPoster({
    required this.distanceKm,
    required this.durationText,
    required this.dateText,
    required this.series,
    required this.rawPoints,
    this.satelliteSnapshot,
    this.loadingMap = false,
  });

  final double distanceKm;
  final String durationText;
  final String dateText;
  final TripTelemetrySeries series;
  final List<dynamic> rawPoints;
  final Uint8List? satelliteSnapshot;
  final bool loadingMap;

  @override
  Widget build(BuildContext context) {
    final score = series.drivingScore;
    final scoreColor = score >= 85
        ? const Color(0xFF19B36B)
        : (score >= 70 ? const Color(0xFF4C7EFF) : const Color(0xFFFF4D67));

    return Container(
      width: 340,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101522), Color(0xFF171E31), Color(0xFF0E1320)],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF28334F), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top editorial brand header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFD6323F), Color(0xFFA82F36)],
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'YARIS HYBRID',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  dateText,
                  style: const TextStyle(
                    color: Color(0xFF8A97B3),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Hero Distance + Score Ring
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'DRIVING REPORT',
                        style: TextStyle(
                          color: Color(0xFF6B7B99),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            distanceKm.toStringAsFixed(2),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                              letterSpacing: -1,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'km',
                            style: TextStyle(
                              color: Color(0xFF93A3C2),
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$durationText · 均速 ${series.avgSpeedKmh != null ? "${series.avgSpeedKmh!.toStringAsFixed(1)} km/h" : "—"}',
                        style: const TextStyle(
                          color: Color(0xFF9BAAC6),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Glowing Score Ring
                SizedBox(
                  width: 82,
                  height: 82,
                  child: CustomPaint(
                    painter: _ScoreRingPainter(score: score, color: scoreColor),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$score',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                            ),
                          ),
                          const Text(
                            'SCORE',
                            style: TextStyle(
                              color: Color(0xFF7D8DAA),
                              fontSize: 8.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Real Apple Satellite Map + Glowing Speed-Heatmap Route Box
            Container(
              height: 168,
              decoration: BoxDecoration(
                color: const Color(0xFF0A0F1B),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF283655)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: satelliteSnapshot != null
                        ? Image.memory(
                            satelliteSnapshot!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        : Padding(
                            padding: const EdgeInsets.all(12),
                            child: CustomPaint(
                              painter: _RouteSilhouettePainter(rawPoints),
                            ),
                          ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0F1B).withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: scoreColor.withValues(alpha: 0.72)),
                      ),
                      child: Text(
                        series.drivingGrade,
                        style: TextStyle(
                          color: scoreColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  if (loadingMap && satelliteSnapshot == null)
                    Positioned(
                      right: 10,
                      top: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0F1B).withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          '加载卫星图…',
                          style: TextStyle(
                            color: Color(0xFFB4C2DC),
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  if (series.maxSpeedKmh != null)
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0F1B).withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '极速 ${series.maxSpeedKmh!.toStringAsFixed(1)} km/h',
                          style: const TextStyle(
                            color: Color(0xFFD6E0F2),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 4-tile dark glass Bento Grid
            Row(
              children: [
                _PosterTile(
                  value: '${series.smoothCruisePercent.round()}%',
                  label: '平顺滑行',
                  accent: const Color(0xFF19B36B),
                ),
                const SizedBox(width: 8),
                _PosterTile(
                  value: '${series.hardAccelCount}',
                  label: '急加速',
                  accent: const Color(0xFF4C7EFF),
                ),
                const SizedBox(width: 8),
                _PosterTile(
                  value: '${series.hardBrakeCount}',
                  label: '急刹车',
                  accent: const Color(0xFFFF4D67),
                ),
                const SizedBox(width: 8),
                _PosterTile(
                  value: series.estFuelLPer100Km != null &&
                          series.estFuelLPer100Km! > 0
                      ? (100.0 / series.estFuelLPer100Km!).toStringAsFixed(1)
                      : '—',
                  label: '估算 km/L',
                  accent: const Color(0xFFFFB732),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Editorial Footer
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/images/yaris.png',
                    width: 40,
                    height: 24,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'MyYaris · 行程驾驶记录',
                  style: TextStyle(
                    color: Color(0xFF6B7B99),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MiniDot(Color(0xFF3548E8)),
                    SizedBox(width: 3),
                    _MiniDot(Color(0xFF19B36B)),
                    SizedBox(width: 3),
                    _MiniDot(Color(0xFFEB9414)),
                    SizedBox(width: 3),
                    _MiniDot(Color(0xFFD22A36)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniDot extends StatelessWidget {
  const _MiniDot(this.color);
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _PosterTile extends StatelessWidget {
  const _PosterTile({
    required this.value,
    required this.label,
    required this.accent,
  });
  final String value;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF161E31),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF232F4B)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                color: accent,
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF7D8DAA),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreRingPainter extends CustomPainter {
  _ScoreRingPainter({required this.score, required this.color});
  final int score;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 5;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = const Color(0xFF232F4B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    final sweep = (score.clamp(0, 100) / 100.0) * math.pi * 2;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ScoreRingPainter oldDelegate) =>
      oldDelegate.score != score || oldDelegate.color != color;
}

class _RouteSilhouettePainter extends CustomPainter {
  _RouteSilhouettePainter(this.rawPoints);
  final List<dynamic> rawPoints;

  Color _speedColor(double spd) {
    if (spd < 25) return const Color(0xFF4C7EFF);
    if (spd < 55) return const Color(0xFF19B36B);
    if (spd < 85) return const Color(0xFFEB9414);
    return const Color(0xFFFF3B4E);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pts = <({double lat, double lon, double spd})>[];
    for (final item in rawPoints) {
      if (item is! Map) continue;
      final lat = item['latitude'];
      final lon = item['longitude'];
      if (lat is! num || lon is! num) continue;
      final spd = item['speed_kmh'] is num ? (item['speed_kmh'] as num).toDouble() : 20.0;
      pts.add((lat: lat.toDouble(), lon: lon.toDouble(), spd: spd));
    }
    if (pts.length < 2) return;

    var minLat = pts.first.lat, maxLat = pts.first.lat;
    var minLon = pts.first.lon, maxLon = pts.first.lon;
    for (final p in pts) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    final midLatRad = ((minLat + maxLat) / 2) * math.pi / 180.0;
    final lonScale = math.cos(midLatRad).abs().clamp(0.2, 1.0);
    final spanX = math.max(1e-5, (maxLon - minLon) * lonScale);
    final spanY = math.max(1e-5, maxLat - minLat);

    const pad = 16.0;
    final availW = math.max(1.0, size.width - pad * 2);
    final availH = math.max(1.0, size.height - pad * 2);
    final scale = math.min(availW / spanX, availH / spanY);
    final offsetX = (size.width - spanX * scale) / 2;
    final offsetY = (size.height - spanY * scale) / 2;

    Offset toPt(({double lat, double lon, double spd}) p) {
      final x = offsetX + (p.lon - minLon) * lonScale * scale;
      final y = offsetY + (maxLat - p.lat) * scale;
      return Offset(x, y);
    }

    for (var i = 1; i < pts.length; i++) {
      final p0 = toPt(pts[i - 1]);
      final p1 = toPt(pts[i]);
      final col = _speedColor((pts[i - 1].spd + pts[i].spd) / 2);
      canvas.drawLine(
        p0,
        p1,
        Paint()
          ..color = col.withValues(alpha: 0.25)
          ..strokeWidth = 7.0
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        p0,
        p1,
        Paint()
          ..color = col
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round,
      );
    }

    final start = toPt(pts.first);
    final end = toPt(pts.last);
    canvas.drawCircle(start, 5.5, Paint()..color = Colors.white);
    canvas.drawCircle(start, 3.8, Paint()..color = const Color(0xFF19B36B));
    canvas.drawCircle(end, 5.5, Paint()..color = Colors.white);
    canvas.drawCircle(end, 3.8, Paint()..color = const Color(0xFFFF3B4E));
  }

  @override
  bool shouldRepaint(covariant _RouteSilhouettePainter oldDelegate) =>
      oldDelegate.rawPoints != rawPoints;
}
