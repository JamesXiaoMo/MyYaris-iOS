import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MapSelection {
  const MapSelection(this.latitude, this.longitude, {this.title = '地图选点'});
  final double latitude, longitude;
  final String title;
}

class AppleMap extends StatefulWidget {
  const AppleMap({super.key, required this.onSelected, this.selection});
  final ValueChanged<MapSelection> onSelected;
  final MapSelection? selection;
  @override
  State<AppleMap> createState() => _AppleMapState();
}

class _AppleMapState extends State<AppleMap> {
  MethodChannel? channel;
  String? error;
  Timer? timer;
  bool ready = false;
  void created(int id) {
    channel = MethodChannel('io.myyaris/map/$id');
    channel!.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'selected' && call.arguments is Map) {
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
  }

  @override
  void dispose() {
    timer?.cancel();
    channel?.setMethodCallHandler(null);
    channel?.invokeMethod<void>('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
        UiKitView(
          viewType: 'io.myyaris/map',
          onPlatformViewCreated: created,
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
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
    ],
  );
}
