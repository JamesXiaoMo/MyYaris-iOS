import 'dart:async';
import 'package:flutter/services.dart';

/// One message from the native player. Every message carries the epoch of the item it belongs to so
/// a late event from a previous item can never change the current one.
class LocalAudioEvent {
  const LocalAudioEvent({
    required this.type,
    this.epoch = -1,
    this.state,
    this.positionMs,
    this.durationMs,
    this.code,
    this.message,
    this.phase,
    this.shouldResume = false,
  });
  final String type;
  final int epoch;
  final String? state, code, message, phase;
  final int? positionMs, durationMs;
  final bool shouldResume;

  static LocalAudioEvent? parse(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    if (type is! String) return null;
    int? integer(Object? v) => v is num && v.isFinite ? v.toInt() : null;
    return LocalAudioEvent(
      type: type,
      epoch: integer(raw['epoch']) ?? -1,
      state: raw['state'] is String ? raw['state'] as String : null,
      positionMs: integer(raw['positionMs']),
      durationMs: integer(raw['durationMs']),
      code: raw['code'] is String ? raw['code'] as String : null,
      message: raw['message'] is String ? raw['message'] as String : null,
      phase: raw['phase'] is String ? raw['phase'] as String : null,
      shouldResume: raw['shouldResume'] == true,
    );
  }
}

class LocalAudioLoaded {
  const LocalAudioLoaded({
    required this.durationMs,
    required this.positionMs,
    this.state,
  });
  final int durationMs, positionMs;
  final String? state;
}

class LocalAudioFailure implements Exception {
  const LocalAudioFailure(this.code, [this.message = '']);
  final String code, message;
  @override
  String toString() => message.isEmpty ? code : message;
}

/// The only thing the local player needs from the platform. The production implementation is a thin
/// AVPlayer / AVAudioSession bridge; tests drive the same channel with a fake native side.
abstract class LocalAudioEngine {
  Stream<LocalAudioEvent> get events;

  /// Prepares [url] at [positionMs]. Resolves only once the item can play (or throws).
  /// With [autoplay] false nothing is audible until [play].
  Future<LocalAudioLoaded> load({
    required int epoch,
    required Uri url,
    required Map<String, String> headers,
    required int positionMs,
    required bool autoplay,
    required double volume,
  });
  Future<void> play(int epoch);
  Future<void> pause(int epoch);
  Future<void> seek(int epoch, int positionMs);
  Future<void> setVolume(double volume);

  /// Releases the media and the audio session.
  Future<void> stop();
}

class NativeLocalAudioEngine implements LocalAudioEngine {
  NativeLocalAudioEngine({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('io.myyaris/local_audio') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        final event = LocalAudioEvent.parse(call.arguments);
        if (event != null) _events.add(event);
      }
      return null;
    });
  }
  final MethodChannel _channel;
  final _events = StreamController<LocalAudioEvent>.broadcast();

  @override
  Stream<LocalAudioEvent> get events => _events.stream;

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw LocalAudioFailure(e.code, e.message ?? '');
    } on MissingPluginException {
      throw const LocalAudioFailure('UNAVAILABLE', '本机播放不可用');
    }
  }

  @override
  Future<LocalAudioLoaded> load({
    required int epoch,
    required Uri url,
    required Map<String, String> headers,
    required int positionMs,
    required bool autoplay,
    required double volume,
  }) async {
    final reply = await _invoke<Map<Object?, Object?>>('load', {
      'epoch': epoch,
      'url': url.toString(),
      'headers': headers,
      'positionMs': positionMs,
      'autoplay': autoplay,
      'volume': volume,
    });
    int number(Object? v) => v is num && v.isFinite ? v.toInt() : 0;
    return LocalAudioLoaded(
      durationMs: number(reply?['durationMs']),
      positionMs: number(reply?['positionMs']),
      state: reply?['state'] is String ? reply!['state'] as String : null,
    );
  }

  @override
  Future<void> play(int epoch) => _invoke<void>('play', {'epoch': epoch});
  @override
  Future<void> pause(int epoch) => _invoke<void>('pause', {'epoch': epoch});
  @override
  Future<void> seek(int epoch, int positionMs) =>
      _invoke<void>('seek', {'epoch': epoch, 'positionMs': positionMs});
  @override
  Future<void> setVolume(double volume) =>
      _invoke<void>('volume', {'volume': volume});
  @override
  Future<void> stop() => _invoke<void>('stop');
}
