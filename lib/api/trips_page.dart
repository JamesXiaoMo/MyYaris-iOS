import 'package:flutter/material.dart';
import '../apple_map.dart';
import '../yaris_theme.dart';
import 'backend.dart';

/// Displays recorded driving trips and renders the selected route polyline on Apple Maps.
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
  String? _selectedTripId;
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
      setState(() {
        _selectedDetail = detail;
        _loadingDetail = false;
      });
      final rawPoints = detail['points'];
      final route = <Map<String, double>>[];
      if (rawPoints is List) {
        for (final p in rawPoints) {
          if (p is Map && p['latitude'] is num && p['longitude'] is num) {
            route.add({
              'latitude': (p['latitude'] as num).toDouble(),
              'longitude': (p['longitude'] as num).toDouble(),
            });
          }
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
      body: Column(
        children: [
          // Top half: Apple Map route canvas
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                height: 270,
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
          ),

          // Selected trip summary card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
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
          ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _error!,
                style: const TextStyle(color: YarisTheme.red, fontSize: 12.5),
              ),
            ),

          const SizedBox(height: 10),

          // Trip list
          Expanded(
            child: _loadingList
                ? const Center(child: CircularProgressIndicator())
                : _trips.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            '暂无行程记录\n车机启动后每 10 秒自动上传位置。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: YarisTheme.muted, fontSize: 14),
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadTrips,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: _trips.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final trip = _trips[index];
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
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
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
                                          color: selected
                                              ? YarisTheme.blue
                                              : YarisTheme.periwinkle,
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
                          },
                        ),
                      ),
          ),
        ],
      ),
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
