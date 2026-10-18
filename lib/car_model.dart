import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Only horizontal, single-pointer gestures reach the local renderer.
class CarModel extends StatefulWidget {
  const CarModel({super.key});
  @override
  State<CarModel> createState() => _CarModelState();
}

class _CarModelState extends State<CarModel> {
  MethodChannel? _channel;
  Timer? _timeout;
  final Set<int> _pointers = {};
  bool _multi = false;
  bool _ready = false;
  bool _failed = false;
  double _yaw = 45;
  @override
  void dispose() {
    _timeout?.cancel();
    _channel?.invokeMethod<void>('dispose');
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    _timeout = Timer(const Duration(seconds: 45), () {
      if (mounted && !_ready) setState(() => _failed = true);
    });
    _channel = MethodChannel('io.myyaris/model/$id');
    _channel!.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'loaded') {
        _timeout?.cancel();
        setState(() => _ready = true);
      }
      if (call.method == 'failed') setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final supported = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    return Semantics(
      label: _failed
          ? '本地3D模型加载失败'
          : !_ready
          ? '本地3D模型加载中'
          : 'Toyota Yaris 本地3D模型，单指水平拖动旋转，俯仰与缩放固定',
      child: Listener(
        onPointerDown: (e) {
          _pointers.add(e.pointer);
          if (_pointers.length > 1) _multi = true;
        },
        onPointerUp: (e) {
          _pointers.remove(e.pointer);
          if (_pointers.isEmpty) _multi = false;
        },
        onPointerCancel: (e) {
          _pointers.remove(e.pointer);
          if (_pointers.isEmpty) _multi = false;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (e) {
            if (!_ready || _failed || _multi || _pointers.length != 1) return;
            _yaw = (_yaw - e.delta.dx * .65) % 360;
            _channel?.invokeMethod<void>('yaw', _yaw);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (supported && !_failed)
                IgnorePointer(
                  child: UiKitView(
                    viewType: 'io.myyaris/model',
                    creationParams: const {
                      'verify': bool.fromEnvironment('MY_YARIS_VERIFY_LOGS'),
                    },
                    creationParamsCodec: const StandardMessageCodec(),
                    onPlatformViewCreated: _created,
                  ),
                ),
              if (!_ready || _failed)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Text(
                    _failed
                        ? '本地3D加载失败，请重新打开App'
                        : !supported
                        ? '3D 仅支持 iPhone'
                        : !_ready
                        ? '本地 3D 模型加载中…'
                        : '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
