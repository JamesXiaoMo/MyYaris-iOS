import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'local_audio.dart';

const localModes = {'list_loop', 'shuffle', 'intelligence', 'single_loop'};

/// Playback queue owned by the phone while the phone is the output. Cursor and mode rules mirror the
/// vehicle's, but this object only ever schedules this phone's own engine.
class LocalQueue {
  LocalQueue({
    required this.source,
    required this.queueId,
    required this.version,
    required List<Map<String, dynamic>> tracks,
    this.complete = true,
    this.batchIndex = 0,
    int index = 0,
    String mode = 'list_loop',
    Random? random,
  }) : tracks = List.of(tracks),
       index = tracks.isEmpty ? 0 : index.clamp(0, tracks.length - 1),
       mode = localModes.contains(mode) ? mode : 'list_loop',
       _random = random ?? Random() {
    if (this.mode == 'shuffle') reshuffle(this.index);
  }

  factory LocalQueue.single(Map<String, dynamic> track, {Random? random}) =>
      LocalQueue(
        source: 'single_track',
        queueId: 'local_single_${track['song_id']}',
        version: 1,
        tracks: [track],
        random: random,
      );

  final String source;
  String queueId;
  int version;
  final List<Map<String, dynamic>> tracks;
  bool complete;
  int batchIndex;
  int index;
  String mode;
  final Random _random;
  List<int> _order = const [];
  int _position = 0;

  bool get isFavorite => source == 'netease_favorite';
  bool get isHeart => source == 'netease_intelligence';
  bool get isSingle => source == 'single_track';
  Map<String, dynamic>? get track =>
      index >= 0 && index < tracks.length ? tracks[index] : null;
  List<int> get shuffleOrder => List.unmodifiable(_order);

  void reshuffle(int seed) {
    final n = tracks.length;
    if (n == 0) {
      _order = const [];
      _position = 0;
      return;
    }
    final first = seed.clamp(0, n - 1);
    final rest = [
      for (var i = 0; i < n; i++)
        if (i != first) i,
    ]..shuffle(_random);
    _order = [first, ...rest];
    _position = 0;
  }

  /// Switches mode without moving the cursor. Returns false when the queue cannot support it.
  bool setMode(String value) {
    if (!localModes.contains(value)) return false;
    if ((value == 'list_loop' || value == 'shuffle') &&
        (!isFavorite || !complete)) {
      return false;
    }
    if (value == 'intelligence' && !isHeart) return false;
    mode = value;
    if (value == 'shuffle') reshuffle(index);
    return true;
  }

  /// Moves to the next track and returns its index; null means the queue is finished.
  int? advance() {
    if (tracks.isEmpty) return null;
    if (isSingle && mode != 'single_loop') return null;
    if (mode == 'single_loop') return index;
    if (mode == 'shuffle') {
      if (_order.length != tracks.length) reshuffle(index);
      _position++;
      if (_position >= _order.length) {
        reshuffle(_order.last);
        _position = tracks.length > 1 ? 1 : 0;
      }
      return index = _order[_position];
    }
    if (mode == 'intelligence') {
      if (index + 1 >= tracks.length) return null;
      return ++index;
    }
    return index = (index + 1) % tracks.length;
  }

  int? retreat() {
    if (tracks.isEmpty) return null;
    if (isSingle || mode == 'single_loop') return index;
    if (mode == 'shuffle') {
      if (_order.isEmpty) reshuffle(index);
      _position = max(0, _position - 1);
      return index = _order[_position];
    }
    if (mode == 'intelligence') return index = max(0, index - 1);
    return index = (index - 1 + tracks.length) % tracks.length;
  }

  void select(int target) {
    if (target < 0 || target >= tracks.length) return;
    index = target;
    if (mode == 'shuffle') reshuffle(target);
  }

  int get remaining => tracks.length - 1 - index;
}

class LocalMedia {
  const LocalMedia(this.url, this.headers);
  final Uri url;
  final Map<String, String> headers;
}

class HeartBatch {
  const HeartBatch({
    required this.tracks,
    required this.version,
    required this.batchIndex,
  });
  final List<Map<String, dynamic>> tracks;
  final int version, batchIndex;
}

enum LocalPhase { idle, loading, playing, buffering, paused, stopped }

/// Everything a handoff needs to know about the phone side, taken at one instant.
class LocalSnapshot {
  const LocalSnapshot({
    required this.track,
    required this.queue,
    required this.index,
    required this.positionMs,
    required this.durationMs,
    required this.mode,
    required this.playing,
  });
  final Map<String, dynamic> track;
  final LocalQueue queue;
  final int index, positionMs, durationMs;
  final String mode;
  final bool playing;
}

class LocalFailure implements Exception {
  const LocalFailure(this.message, [this.code]);
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// The phone's own player: one queue, one AVPlayer item at a time. It never starts by itself;
/// only explicit calls (or the natural end of an item the user started) cause sound.
class LocalPlayer extends ChangeNotifier {
  LocalPlayer({
    required this.engine,
    required this.resolveMedia,
    this.continueHeart,
  }) {
    _events = engine.events.listen(_onEvent);
  }

  final LocalAudioEngine engine;

  /// Builds a trusted media request (same-origin HTTPS stream of this backend) for one track.
  final LocalMedia Function(Map<String, dynamic> track) resolveMedia;
  final Future<HeartBatch> Function(LocalQueue queue)? continueHeart;
  late final StreamSubscription<LocalAudioEvent> _events;

  LocalQueue? queue;
  LocalPhase phase = LocalPhase.idle;
  int positionMs = 0, durationMs = 0;
  double volume = 1;
  String? error, notice;
  int _epoch = 0, _generation = 0;
  int? _loadedEpoch;
  bool _wantsPlay = false;
  bool _resumeAfterInterruption = false;
  int _failures = 0;
  int? _completedEpoch;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  Future<void>? _heartInFlight;
  Object? _heartTicket;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, dynamic>? get track => queue?.track;
  bool get hasMedia => _loadedEpoch != null;
  bool get isPlaying =>
      _wantsPlay &&
      (phase == LocalPhase.playing ||
          phase == LocalPhase.buffering ||
          phase == LocalPhase.loading);
  bool get busy => phase == LocalPhase.loading;

  Future<T> _serial<T>(Future<T> Function() op) {
    final gen = _generation;
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_disposed || gen != _generation) {
          throw const LocalFailure('播放会话已清除');
        }
        done.complete(await op());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------- engine events

  void _onEvent(LocalAudioEvent event) {
    if (_disposed) return;
    if (phase == LocalPhase.loading &&
        event.epoch == _epoch &&
        (event.type == 'routeLost' ||
            event.type == 'interruption' && event.phase == 'began')) {
      _wantsPlay = false;
      _resumeAfterInterruption = false;
      notice = '音频被中断，点播放继续';
      _notify();
      return;
    }
    if (event.epoch != _loadedEpoch || _loadedEpoch == null) return;
    switch (event.type) {
      case 'interruption':
        _onInterruption(event);
        return;
      case 'routeLost':
        if (_loadedEpoch != null && _wantsPlay) {
          _wantsPlay = false;
          _resumeAfterInterruption = false;
          phase = LocalPhase.paused;
          notice = '音频输出已断开，已暂停';
          _notify();
        }
        return;
    }
    if (event.epoch != _loadedEpoch || _loadedEpoch == null) return;
    switch (event.type) {
      case 'state':
        final next = switch (event.state) {
          'playing' => LocalPhase.playing,
          'buffering' => LocalPhase.buffering,
          'paused' => LocalPhase.paused,
          _ => null,
        };
        if (next == null || phase == LocalPhase.loading) return;
        if (next == LocalPhase.playing || next == LocalPhase.buffering) {
          // Sound only counts when this phone asked for it; a stray native "playing" never overrides intent.
          if (!_wantsPlay) return;
        } else if (phase == LocalPhase.stopped) {
          return;
        }
        phase = next;
        positionMs = event.positionMs ?? positionMs;
        durationMs = event.durationMs ?? durationMs;
        if (next == LocalPhase.playing) _failures = 0;
        _notify();
      case 'position':
        positionMs = event.positionMs ?? positionMs;
        durationMs = event.durationMs ?? durationMs;
        final now = DateTime.now();
        if (now.difference(_lastNotify).inMilliseconds >= 900) {
          _lastNotify = now;
          _notify();
        }
      case 'completed':
        if (_completedEpoch == event.epoch) return;
        _completedEpoch = event.epoch;
        positionMs = event.positionMs ?? positionMs;
        unawaited(
          _serial(
            () => _afterCompletion(event.epoch),
          ).catchError((Object _) {}),
        );
      case 'error':
        unawaited(
          _serial(
            () => _afterFailure(event.epoch, event.message),
          ).catchError((Object _) {}),
        );
    }
  }

  void _onInterruption(LocalAudioEvent event) {
    if (event.phase == 'began') {
      if (_loadedEpoch != null && _wantsPlay) {
        _resumeAfterInterruption = true;
        _wantsPlay = false;
        phase = LocalPhase.paused;
        // The system normally pauses the item itself; asking again keeps both sides in agreement.
        unawaited(engine.pause(_loadedEpoch!).catchError((Object _) {}));
        notice = '音频被系统中断，已暂停';
        _notify();
      }
    } else if (event.phase == 'ended') {
      final resume = _resumeAfterInterruption && event.shouldResume;
      _resumeAfterInterruption = false;
      if (resume && _loadedEpoch != null) {
        notice = null;
        unawaited(play().catchError((Object _) {}));
      } else if (_loadedEpoch != null) {
        notice = '音频中断已结束，点播放继续';
        _notify();
      }
    }
  }

  // ---------------------------------------------------------------- loading

  Future<void> _loadCurrent({
    required int positionMs,
    required bool autoplay,
  }) async {
    final current = queue?.track;
    if (current == null) throw const LocalFailure('没有可播放的曲目');
    if (_disposed) throw const LocalFailure('播放会话已清除');
    final media = resolveMedia(current);
    final epoch = ++_epoch;
    _loadedEpoch = null;
    phase = LocalPhase.loading;
    _wantsPlay = autoplay;
    this.positionMs = positionMs;
    durationMs = 0;
    error = null;
    _notify();
    try {
      final loaded = await engine.load(
        epoch: epoch,
        url: media.url,
        headers: media.headers,
        positionMs: positionMs,
        autoplay: autoplay,
        volume: volume,
      );
      if (epoch != _epoch) throw const LocalFailure('已被新的播放请求取代');
      _loadedEpoch = epoch;
      this.positionMs = loaded.positionMs > 0 ? loaded.positionMs : positionMs;
      durationMs = loaded.durationMs > 0
          ? loaded.durationMs
          : ((current['duration_ms'] as num?)?.toInt() ?? 0);
      phase = !_wantsPlay
          ? LocalPhase.paused
          : loaded.state == 'playing'
          ? LocalPhase.playing
          : LocalPhase.buffering;
      _completedEpoch = null;
      _notify();
      _maybeContinueHeart();
    } on LocalAudioFailure catch (e) {
      if (epoch == _epoch) {
        phase = LocalPhase.stopped;
        _wantsPlay = false;
        _notify();
      }
      throw LocalFailure(_describe(e), e.code);
    }
  }

  static String _describe(LocalAudioFailure e) => switch (e.code) {
    'INSECURE_URL' => '媒体地址不受信任，未播放',
    'LOAD_TIMEOUT' => '歌曲加载超时，请检查网络',
    'LOAD_FAILED' => '这首歌暂时无法播放；可能受版权、会员或网络限制',
    'AUDIO_SESSION' => '无法启用音频，请检查是否有其他通话或录音在占用',
    'UNAVAILABLE' => '本机播放不可用',
    'LOAD_CANCELLED' => '已被新的播放请求取代',
    _ => '歌曲无法播放，请稍后重试',
  };

  /// Starts [next] at [index]; on failure restores the previous item so a bad pick never kills playback.
  Future<void> _replaceAndLoad(
    LocalQueue next, {
    required int index,
    required int positionMs,
    required bool autoplay,
  }) async {
    final previousQueue = queue;
    final previousIndex = previousQueue?.index ?? 0;
    final previousPosition = this.positionMs;
    final wasPlaying = isPlaying;
    final hadMedia = hasMedia;
    final gen = _generation;
    next.select(index);
    queue = next;
    try {
      await _loadCurrent(positionMs: positionMs, autoplay: autoplay);
    } catch (e) {
      if (_disposed || gen != _generation) rethrow;
      queue = previousQueue;
      previousQueue?.index = previousIndex;
      if (hadMedia && previousQueue != null) {
        try {
          await _loadCurrent(
            positionMs: previousPosition,
            autoplay: wasPlaying,
          );
          notice = '新曲目无法播放，已回到原来的歌曲';
        } catch (_) {
          phase = LocalPhase.stopped;
          _wantsPlay = false;
          error = '播放失败，已停止';
        }
      } else {
        phase = LocalPhase.idle;
        _wantsPlay = false;
      }
      _notify();
      rethrow;
    }
  }

  // ---------------------------------------------------------------- public operations

  Future<void> start(
    LocalQueue next, {
    int index = 0,
    int positionMs = 0,
    bool autoplay = true,
  }) => _serial(() async {
    _failures = 0;
    notice = null;
    await _replaceAndLoad(
      next,
      index: index,
      positionMs: positionMs,
      autoplay: autoplay,
    );
  });

  Future<void> play() => _serial(() async {
    if (queue == null) throw const LocalFailure('没有可播放的曲目');
    notice = null;
    if (_loadedEpoch == null) {
      await _loadCurrent(positionMs: positionMs, autoplay: true);
      return;
    }
    _wantsPlay = true;
    phase = LocalPhase.buffering;
    _notify();
    try {
      await engine.play(_loadedEpoch!);
    } on LocalAudioFailure catch (e) {
      _wantsPlay = false;
      phase = LocalPhase.paused;
      _notify();
      throw LocalFailure(_describe(e), e.code);
    }
    // The native timeControlStatus event confirms actual playback. A play() receipt alone does not.
    _notify();
  });

  Future<void> pause() => _serial(() async {
    _resumeAfterInterruption = false;
    final epoch = _loadedEpoch;
    _wantsPlay = false;
    if (epoch != null) {
      try {
        await engine.pause(epoch);
      } on LocalAudioFailure catch (e) {
        throw LocalFailure('本机未能确认暂停，未转移播放', e.code);
      }
      phase = LocalPhase.paused;
    }
    _notify();
  });

  Future<void> seek(int ms) => _serial(() async {
    final epoch = _loadedEpoch;
    if (epoch == null) return;
    final bounded = ms.clamp(0, durationMs > 0 ? durationMs : ms);
    try {
      await engine.seek(epoch, bounded);
    } on LocalAudioFailure catch (e) {
      throw LocalFailure('跳转失败，请重试', e.code);
    }
    positionMs = bounded;
    _notify();
  });

  Future<void> setVolume(double value) async {
    volume = value.clamp(0.0, 1.0);
    _notify();
    try {
      await engine.setVolume(volume);
    } on LocalAudioFailure catch (_) {}
  }

  Future<void> next() => _serial(() async {
    final q = queue;
    if (q == null) return;
    if (q.isHeart && q.remaining <= 0) await _heartInFlight;
    final wasPlaying = isPlaying;
    final target = q.advance();
    if (target == null) {
      await _finishQueue(q.isHeart ? 'INTELLIGENCE_QUEUE_EXHAUSTED' : null);
      return;
    }
    await _loadWithSkips(startPlaying: wasPlaying, forward: true);
  });

  Future<void> previous() => _serial(() async {
    final q = queue;
    if (q == null) return;
    final wasPlaying = isPlaying;
    q.retreat();
    await _loadWithSkips(startPlaying: wasPlaying, forward: false);
  });

  /// Loads the cursor; unplayable songs are skipped, at most three in a row.
  Future<void> _loadWithSkips({
    required bool startPlaying,
    required bool forward,
  }) async {
    final q = queue!;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _loadCurrent(positionMs: 0, autoplay: startPlaying);
        _failures = 0;
        return;
      } on LocalFailure catch (e) {
        if (e.code == 'LOAD_CANCELLED' || e.code == 'INSECURE_URL') rethrow;
        _failures++;
        if (_failures >= 3 || q.isSingle) {
          await _finishQueue('PLAYBACK_CONSECUTIVE_FAILURES');
          return;
        }
        final moved = forward ? q.advance() : q.retreat();
        if (moved == null) {
          await _finishQueue(q.isHeart ? 'INTELLIGENCE_QUEUE_EXHAUSTED' : null);
          return;
        }
      }
    }
    await _finishQueue('PLAYBACK_CONSECUTIVE_FAILURES');
  }

  Future<void> _finishQueue(String? reason) async {
    _wantsPlay = false;
    _loadedEpoch = null;
    phase = LocalPhase.stopped;
    positionMs = 0;
    error = switch (reason) {
      'PLAYBACK_CONSECUTIVE_FAILURES' => '连续三首播放失败，请检查网络或网易云权限',
      'INTELLIGENCE_QUEUE_EXHAUSTED' => '心动歌曲已播完，请切回喜欢歌单',
      _ => null,
    };
    notice = reason == null ? '播放完毕' : null;
    try {
      await engine.stop();
    } on LocalAudioFailure catch (_) {}
    _notify();
  }

  Future<void> _afterCompletion(int epoch) async {
    if (epoch != _loadedEpoch || !_wantsPlay) return;
    final q = queue;
    if (q == null) return;
    if (q.isHeart && q.remaining <= 0) await _heartInFlight;
    if (epoch != _loadedEpoch || !_wantsPlay) return;
    final target = q.advance();
    if (target == null) {
      await _finishQueue(q.isHeart ? 'INTELLIGENCE_QUEUE_EXHAUSTED' : null);
      return;
    }
    await _loadWithSkips(startPlaying: true, forward: true);
  }

  Future<void> _afterFailure(int epoch, String? message) async {
    if (epoch != _loadedEpoch || !_wantsPlay) return;
    final q = queue;
    if (q == null) return;
    _failures++;
    if (_failures >= 3) {
      await _finishQueue('PLAYBACK_CONSECUTIVE_FAILURES');
      return;
    }
    if (q.advance() == null) {
      await _finishQueue(q.isHeart ? 'INTELLIGENCE_QUEUE_EXHAUSTED' : null);
      return;
    }
    await _loadWithSkips(startPlaying: true, forward: true);
  }

  /// Applies a mode without reloading the playing item.
  Future<bool> setMode(String mode) => _serial(() async {
    final q = queue;
    if (q == null || !q.setMode(mode)) return false;
    _maybeContinueHeart();
    _notify();
    return true;
  });

  /// Swaps in a different queue that still contains the current song, keeping the audio untouched.
  Future<void> adoptQueueKeepingAudio(
    LocalQueue next,
    int index,
    String mode,
  ) => _serial(() async {
    next.select(index);
    next.mode = mode;
    if (mode == 'shuffle') next.reshuffle(index);
    queue = next;
    _maybeContinueHeart();
    _notify();
  });

  void _maybeContinueHeart() {
    final q = queue;
    final provider = continueHeart;
    if (q == null ||
        provider == null ||
        !q.isHeart ||
        q.mode != 'intelligence') {
      return;
    }
    if (q.remaining > 5 || q.batchIndex >= 4 || _heartInFlight != null) return;
    final version = q.version, id = q.queueId;
    final ticket = Object();
    _heartTicket = ticket;
    final flight = () async {
      try {
        final batch = await provider(q);
        if (queue != q || q.queueId != id || q.version != version) return;
        final existing = q.tracks.length;
        if (batch.tracks.length <= existing) return;
        for (var i = 0; i < existing; i++) {
          if (batch.tracks[i]['track_id'] != q.tracks[i]['track_id']) {
            throw const LocalFailure('心动续批与原队列不一致');
          }
        }
        q.tracks.addAll(batch.tracks.sublist(existing));
        q.version = batch.version;
        q.batchIndex = batch.batchIndex;
        _notify();
      } catch (e) {
        if (queue == q) {
          error = e is LocalFailure ? e.message : '心动续批失败，未改用随机或相似歌曲';
          _notify();
        }
      } finally {
        if (identical(_heartTicket, ticket)) _heartInFlight = null;
      }
    }();
    _heartInFlight = flight;
  }

  LocalSnapshot? capture() {
    final q = queue, t = q?.track;
    if (q == null || t == null || !hasMedia) return null;
    return LocalSnapshot(
      track: t,
      queue: q,
      index: q.index,
      positionMs: positionMs,
      durationMs: durationMs,
      mode: q.mode,
      playing: isPlaying,
    );
  }

  /// Silences and forgets everything (account change, target switch). Safe to call repeatedly.
  Future<void> release() {
    _generation++;
    _epoch++;
    _wantsPlay = false;
    _loadedEpoch = null;
    _resumeAfterInterruption = false;
    queue = null;
    phase = LocalPhase.idle;
    final stopped = engine.stop().catchError((Object _) {});
    return _serial(() async {
      await stopped;
      _epoch++;
      _wantsPlay = false;
      _loadedEpoch = null;
      _resumeAfterInterruption = false;
      queue = null;
      phase = LocalPhase.idle;
      positionMs = durationMs = 0;
      error = notice = null;
      _failures = 0;
      _heartInFlight = null;
      _heartTicket = null;
      try {
        await engine.stop();
      } on LocalAudioFailure catch (_) {}
      _notify();
    });
  }

  /// Stops sound but keeps the queue so the same song can be resumed.
  Future<void> stopSound() => _serial(() async {
    final epoch = _loadedEpoch;
    _wantsPlay = false;
    if (epoch != null) {
      try {
        await engine.pause(epoch);
      } on LocalAudioFailure catch (_) {}
    }
    if (phase != LocalPhase.idle) phase = LocalPhase.paused;
    _notify();
  });

  Future<void> stop() => _serial(() async {
    _wantsPlay = false;
    _loadedEpoch = null;
    _epoch++;
    phase = LocalPhase.stopped;
    positionMs = 0;
    try {
      await engine.stop();
    } on LocalAudioFailure catch (_) {}
    _notify();
  });

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _epoch++;
    unawaited(_events.cancel());
    unawaited(engine.stop().catchError((Object _) {}));
    super.dispose();
  }
}
