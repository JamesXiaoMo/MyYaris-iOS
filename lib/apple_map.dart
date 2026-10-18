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
  bool foreground = true;
  String? locationMessage;
  String locationStatus = 'not_requested';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
          widget.onSelected(MapSelection(lat.toDouble(), lon.toDouble()));
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
    // A one-shot foreground request; iOS owns the first-use permission dialog.
    unawaited(locate(automatic: true));
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
