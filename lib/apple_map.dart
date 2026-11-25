import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MapSelection {
  const MapSelection(
    this.latitude,
    this.longitude, {
    this.title = '地图选点',
    this.address,
  });
  final double latitude, longitude;
  final String title;
  final String? address;

  factory MapSelection.fromSearch(Map value) {
    final lat = value['latitude'], lon = value['longitude'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        value['title'] is! String ||
        value['address'] is! String) {
      throw const FormatException('地点搜索返回无效坐标');
    }
    return MapSelection(
      lat.toDouble(),
      lon.toDouble(),
      title: value['title'] as String,
      address: value['address'] as String,
    );
  }
}

class AppleMapController {
  MethodChannel? channel;
  Future<List<MapSelection>> search(String query) async {
    if (channel == null) {
      throw PlatformException(code: 'MAP_NOT_READY', message: '地图尚未就绪，请稍后重试');
    }
    final text = query.trim();
    if (text.isEmpty || text.length > 100) {
      throw const FormatException('请输入1～100字的地点或地址');
    }
    final response = await channel!.invokeMapMethod<String, dynamic>(
      'search',
      text,
    );
    final results = response?['results'];
    if (results is! List || results.any((e) => e is! Map)) {
      throw const FormatException('地点搜索响应无效');
    }
    final seen = <String>{};
    return results
        .take(20)
        .map((e) => MapSelection.fromSearch(e as Map))
        .where((p) => seen.add('${p.title}|${p.latitude}|${p.longitude}'))
        .toList();
  }

  Future<void> cancelSearch() async {
    try {
      await channel?.invokeMethod<void>('cancelSearch');
    } on PlatformException {
      /* The map may already be disposed. */
    }
  }

  List<Map<String, double>>? _pendingRoute;
  List<List<Map<String, double>>>? _pendingMultiRoutes;
  Map<String, double>? _pendingScrubMarker;

  Future<void> setRoute(List<Map<String, double>> points) async {
    _pendingRoute = points;
    _pendingMultiRoutes = null;
    try {
      await channel?.invokeMethod<void>('setRoute', points);
    } on PlatformException {
      /* The map may not be ready yet. */
    }
  }

  Future<void> setMultiRoutes(List<List<Map<String, double>>> routes) async {
    _pendingMultiRoutes = routes;
    _pendingRoute = null;
    try {
      await channel?.invokeMethod<void>('setMultiRoutes', routes);
    } on PlatformException {
      /* The map may not be ready yet. */
    }
  }

  List<Map<String, dynamic>>? _pendingFavoritePins;

  Future<void> setFavoritePins(List<Map<String, dynamic>> pins) async {
    _pendingFavoritePins = pins;
    try {
      await channel?.invokeMethod<void>('setFavoritePins', pins);
    } on PlatformException {
      /* The map may not be ready yet. */
    }
  }

  Future<void> setScrubMarker({double? latitude, double? longitude}) async {
    if (latitude == null || longitude == null) {
      _pendingScrubMarker = null;
    } else {
      _pendingScrubMarker = {'latitude': latitude, 'longitude': longitude};
    }
    try {
      await channel?.invokeMethod<void>('setScrubMarker', _pendingScrubMarker);
    } on PlatformException {
      /* The map may not be ready yet. */
    }
  }
}

class AppleMap extends StatefulWidget {
  const AppleMap({
    super.key,
    required this.onSelected,
    this.selection,
    this.controller,
    this.active = true,
    this.onInteractionChanged,
  });
  final ValueChanged<MapSelection> onSelected;
  final MapSelection? selection;
  final AppleMapController? controller;
  final bool active;
  final ValueChanged<bool>? onInteractionChanged;
  @override
  State<AppleMap> createState() => _AppleMapState();
}

class _AppleMapState extends State<AppleMap> with WidgetsBindingObserver {
  MethodChannel? channel;
  final pointers = <int>{};
  static final recognizers = <Factory<OneSequenceGestureRecognizer>>{
    Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
  };
  void pointerDown(PointerDownEvent event) {
    if (pointers.isEmpty) {
      channel?.invokeMethod<void>('interaction', true);
      widget.onInteractionChanged?.call(true);
    }
    pointers.add(event.pointer);
  }

  void pointerEnd(PointerEvent event) {
    if (!pointers.remove(event.pointer) || pointers.isNotEmpty) return;
    channel?.invokeMethod<void>('interaction', false);
    widget.onInteractionChanged?.call(false);
  }

  String? error;
  Timer? timer;
  bool ready = false;
  bool locating = false;
  bool satellite = false;
  bool changingStyle = false;
  bool foreground = true;
  String? locationMessage;
  String locationStatus = 'not_requested';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> toggleMapStyle() async {
    if (channel == null || changingStyle || pointers.isNotEmpty) return;
    final style = satellite ? 'standard' : 'satellite';
    setState(() => changingStyle = true);
    try {
      final result = await channel!.invokeMapMethod<String, dynamic>(
        'setMapStyle',
        {'style': style},
      );
      if (!mounted) return;
      if (result?['style'] != style) {
        throw PlatformException(code: 'MAP_STYLE', message: '地图样式切换未确认');
      }
      setState(() => satellite = style == 'satellite');
    } catch (_) {
      if (mounted) setState(() => locationMessage = '地图样式切换失败，请稍后重试');
    } finally {
      if (mounted) setState(() => changingStyle = false);
    }
  }

  Future<void> locate({bool automatic = false}) async {
    if (locating || channel == null) return;
    setState(() {
      locating = true;
      locationMessage = null;
      locationStatus = 'locating';
    });
    try {
      final value = await channel!.invokeMapMethod<String, dynamic>('locate');
      if (!mounted) return;
      setState(() {
        locationStatus = value?['status'] == 'located'
            ? 'located'
            : 'unavailable';
        locationMessage = value?['approximate'] == true
            ? '当前为大致位置，可在系统设置开启精确位置'
            : null;
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          locationStatus = e.code;
          locationMessage = e.code == 'CANCELLED'
              ? null
              : e.message ?? '暂时无法定位';
        });
      }
    } on MissingPluginException {
      if (mounted) setState(() => locationStatus = 'unsupported');
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  void updateActive() {
    channel?.invokeMethod<void>('setActive', widget.active && foreground);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground && pointers.isNotEmpty) {
      pointers.clear();
      channel?.invokeMethod<void>('interaction', false);
      widget.onInteractionChanged?.call(false);
    }
    updateActive();
  }

  void created(int id) {
    channel = MethodChannel('io.myyaris/map/$id');
    widget.controller?.channel = channel;
    final pendingPins = widget.controller?._pendingFavoritePins;
    if (pendingPins != null) {
      channel!.invokeMethod<void>('setFavoritePins', pendingPins);
    }
    final pendingRoute = widget.controller?._pendingRoute;
    final pendingMulti = widget.controller?._pendingMultiRoutes;
    final hasRouteOverlay =
        (pendingRoute != null && pendingRoute.isNotEmpty) ||
        (pendingMulti != null && pendingMulti.isNotEmpty);
    if (pendingRoute != null && pendingRoute.isNotEmpty) {
      channel!.invokeMethod<void>('setRoute', pendingRoute);
    } else if (pendingMulti != null && pendingMulti.isNotEmpty) {
      channel!.invokeMethod<void>('setMultiRoutes', pendingMulti);
    }
    final pendingScrub = widget.controller?._pendingScrubMarker;
    if (pendingScrub != null) {
      channel!.invokeMethod<void>('setScrubMarker', pendingScrub);
    }
    channel!.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'selected' && call.arguments is Map) {
        if (pointers.isNotEmpty) return;
        final args = call.arguments as Map;
        final lat = args['latitude'], lon = args['longitude'];
        if (lat is num &&
            lon is num &&
            lat.isFinite &&
            lon.isFinite &&
            lat.abs() <= 90 &&
            lon.abs() <= 180) {
          final pinTitle = args['title'] is String &&
                  (args['title'] as String).isNotEmpty
              ? args['title'] as String
              : '地图选点';
          final pinAddr = args['address'] is String &&
                  (args['address'] as String).isNotEmpty
              ? args['address'] as String
              : null;
          widget.onSelected(
            MapSelection(
              lat.toDouble(),
              lon.toDouble(),
              title: pinTitle,
              address: pinAddr,
            ),
          );
        }
      } else if (call.method == 'ready') {
        timer?.cancel();
        if (ready && error == null) return;
        setState(() {
          ready = true;
          error = null;
        });
      } else if (call.method == 'failed') {
        setState(() => error = '地图加载失败，请检查网络；仍可打开收藏或输入目的地');
      }
    });
    timer = Timer(const Duration(seconds: 20), () {
      if (mounted && !ready) setState(() => error = '地图暂未就绪，可继续浏览收藏或输入目的地');
    });
    center();
    updateActive();
    // Skip auto-centering on user location if a trip/footprint route is already active.
    if (!hasRouteOverlay) {
      unawaited(locate(automatic: true));
    }
  }

  void center() {
    final p = widget.selection;
    if (p != null) {
      channel?.invokeMethod<void>('center', {
        'latitude': p.latitude,
        'longitude': p.longitude,
        'title': p.title,
      });
    }
  }

  @override
  void didUpdateWidget(covariant AppleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) center();
    if (oldWidget.active != widget.active) {
      if (!widget.active && pointers.isNotEmpty) {
        pointers.clear();
        channel?.invokeMethod<void>('interaction', false);
        // Parent receives active=false in the same build and resets its hold.
      }
      updateActive();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (identical(widget.controller?.channel, channel)) {
      widget.controller?.channel = null;
    }
    channel?.setMethodCallHandler(null);
    channel?.invokeMethod<void>('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
        Listener(
          onPointerDown: pointerDown,
          onPointerUp: pointerEnd,
          onPointerCancel: pointerEnd,
          child: UiKitView(
            viewType: 'io.myyaris/map',
            onPlatformViewCreated: created,
            gestureRecognizers: recognizers,
          ),
        )
      else
        const Center(child: Text('Apple 地图仅支持 iPhone，仍可使用收藏与输入目的地')),
      if (error != null)
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: IgnorePointer(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(error!, style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
        ),
      if (locationMessage != null)
        Positioned(
          top: error == null ? 8 : 64,
          left: 12,
          right: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      locationMessage!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭定位提示',
                    onPressed: () => setState(() => locationMessage = null),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      Positioned(
        bottom: 100,
        right: 12,
        child: Material(
          color: const Color(0xED192435),
          borderRadius: BorderRadius.circular(16),
          child: IconButton(
            key: const ValueKey('map-style-toggle'),
            tooltip: satellite ? '切换到标准地图' : '切换到卫星地图',
            isSelected: satellite,
            onPressed:
                !widget.active || !ready || changingStyle || pointers.isNotEmpty
                ? null
                : toggleMapStyle,
            icon: const Icon(Icons.satellite_alt_outlined),
            selectedIcon: const Icon(Icons.map_outlined),
          ),
        ),
      ),
      Positioned(
        bottom: 46,
        right: 12,
        child: Material(
          color: const Color(0xED192435),
          borderRadius: BorderRadius.circular(16),
          child: IconButton(
            key: const ValueKey('map-locate'),
            tooltip: '回到当前位置',
            onPressed: locating || !widget.active ? null : () => locate(),
            icon: locating
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
          ),
        ),
      ),
    ],
  );
}
