import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'backend.dart';
import 'local_audio.dart';
import 'local_player.dart';
import 'music_queue_contract.dart';

enum PlaybackTarget { phone, car }

enum HandoffStatus { running, needsConfirmation, failed, cancelled, done }

enum PlayerPhase { unknown, idle, loading, playing, paused, stopped }

/// One explicit user request to move playback between the phone and the car.
class Handoff {
  Handoff({required this.id, required this.from, required this.to});
  final String id;
  final PlaybackTarget from, to;
  HandoffStatus status = HandoffStatus.running;
  String message = '正在准备…';

  /// Commands carry `ho_<id>_<step>_<attempt>`; the attempt only moves on after a definite failure,
  /// so a retry of an unknown outcome is idempotent on the backend.
  final attempts = <String, int>{};
  final outcomes = <String, String>{};
  bool running = false;
  bool prepared = false, sourceSilenced = false, targetStarted = false;
  bool wasPlaying = false;
  int resumePositionMs = 0;
  int? beforeStatusSeq;
  Map<String, dynamic>? plan;
  LocalQueue? queue;
  int? queueIndex;
  bool cancelled = false;
  bool get active =>
      status == HandoffStatus.running ||
      status == HandoffStatus.needsConfirmation;
  String commandId(String step) => 'ho_${id}_${step}_${attempts[step] ?? 0}';
}

/// What the player page shows. It is built from exactly one side, never a mix.
class PlayerView {
  const PlayerView({
    required this.target,
    required this.title,
    required this.artist,
    required this.phase,
    required this.stateLabel,
    this.coverUrl,
    this.trackId,
    this.songId,
    this.positionMs,
    this.durationMs,
    this.volume,
    this.notice,
    this.known = true,
  });
  final PlaybackTarget target;
  final String title, artist, stateLabel;
  final String? coverUrl, trackId, notice;
  final int? songId, positionMs, durationMs;
  final double? volume;
  final PlayerPhase phase;
  final bool known;
  bool get playing => phase == PlayerPhase.playing;
  String get targetLabel => target == PlaybackTarget.phone ? '本机' : '车机';
}

typedef Wait = Future<void> Function(Duration duration);

/// Chooses the one output (phone or car), runs the phone's own player, and performs handoffs.
/// The car's state lives in [BackendSession.playback]; the phone's in [local]. They are never merged.
class PlaybackHub extends ChangeNotifier {
  PlaybackHub(
    this.session, {
    LocalAudioEngine? engine,
    this.pollInterval = const Duration(milliseconds: 700),
    this.commandTimeout = const Duration(seconds: 14),
    this.statusTimeout = const Duration(seconds: 6),
    this.backgroundAudio = false,
    Wait? wait,
    Random? random,
  }) : _wait = wait ?? ((d) => Future<void>.delayed(d)),
       _random = random ?? Random.secure() {
    local = LocalPlayer(
      engine: engine ?? NativeLocalAudioEngine(),
      resolveMedia: (track) => session.api.localMedia(track),
      continueHeart: _continueHeart,
    )..addListener(notifyListeners);
    _sessionId = _newSessionId();
  }

  final BackendSession session;
  late final LocalPlayer local;
  Duration pollInterval, commandTimeout, statusTimeout;

  /// True only if the app is configured for background audio (UIBackgroundModes=audio).
  final bool backgroundAudio;
  final Wait _wait;
  final Random _random;
  PlaybackTarget target = PlaybackTarget.car;
  Handoff? handoff;
  String _sessionId = '';
  int _gen = 0;
  bool _disposed = false, _operationBusy = false;
  String? _unresolvedCarCommand;

  String get sessionId => _sessionId;
  bool get handoffActive => handoff?.active ?? false;
  bool get phoneTarget => target == PlaybackTarget.phone;

  String _newSessionId() =>
      List.generate(32, (_) => '0123456789abcdef'[_random.nextInt(16)]).join();

  String _newHandoffId() => List.generate(
    12,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
  ).join();

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  // ----------------------------------------------------------------- lifecycle

  /// Account, origin, device or session change: silence the phone, forget its queue, drop any handoff.
  void reset() {
    _gen++;
    final old = _sessionId;
    handoff = null;
    target = PlaybackTarget.car;
    _sessionId = _newSessionId();
    unawaited(local.release().catchError((Object _) {}));
    if (session.api.configured) {
      unawaited(_closeRemote(old));
    }
    _publish();
  }

  Future<void> _closeRemote(String id) async {
    try {
      await session.api
          .closeLocalSession(id)
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  /// Logout path: stop sound first, then ask the backend to forget this phone session.
  Future<void> closeRemoteSession() async {
    final id = _sessionId;
    await local.release();
    if (session.api.configured) await _closeRemote(id);
  }

  void onLifecycle(AppLifecycleState state) {
    if (backgroundAudio) return;
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) &&
        local.isPlaying) {
      unawaited(
        local.pause().then((_) {
          local.notice = '本机播放已随 App 进入后台暂停';
          _publish();
        }),
      );
    }
  }

  // ----------------------------------------------------------------- view

  PlayerView get view {
    if (target == PlaybackTarget.phone) {
      final t = local.track;
      final phase = switch (local.phase) {
        LocalPhase.idle => PlayerPhase.idle,
        LocalPhase.loading => PlayerPhase.loading,
        LocalPhase.playing => PlayerPhase.playing,
        LocalPhase.buffering => PlayerPhase.loading,
        LocalPhase.paused => PlayerPhase.paused,
        LocalPhase.stopped => PlayerPhase.stopped,
      };
      return PlayerView(
        target: target,
        title: _text(t?['title']) ?? (t == null ? '暂无曲目' : '曲名暂不可用'),
        artist: _text(t?['artist']) ?? '',
        coverUrl: _text(t?['cover_url']),
        trackId: _text(t?['track_id']),
        songId: t?['song_id'] is int ? t!['song_id'] as int : null,
        phase: phase,
        stateLabel: switch (local.phase) {
          LocalPhase.idle => '未开始',
          LocalPhase.loading => '加载中',
          LocalPhase.playing => '正在播放',
          LocalPhase.buffering => '缓冲中',
          LocalPhase.paused => '已暂停',
          LocalPhase.stopped => '已停止',
        },
        positionMs: local.hasMedia ? local.positionMs : null,
        durationMs: local.hasMedia && local.durationMs > 0
            ? local.durationMs
            : null,
        volume: local.volume,
        notice: local.error ?? local.notice,
      );
    }
    final p = session.playback;
    final fresh = session.heartbeatFresh && !session.playbackStale;
    final phase = !fresh
        ? PlayerPhase.unknown
        : switch (p['playback_state']) {
            'playing' => PlayerPhase.playing,
            'paused' => PlayerPhase.paused,
            'stopped' => PlayerPhase.stopped,
            'buffering' => PlayerPhase.loading,
            _ => PlayerPhase.unknown,
          };
    final trackId = _text(p['current_track_id']);
    return PlayerView(
      target: target,
      title: session.carMusicTitle,
      artist: _text(session.currentTrack['artist']) ?? '',
      coverUrl: _text(session.currentTrack['cover_url']),
      trackId: trackId,
      songId: session.currentTrack['song_id'] is int
          ? session.currentTrack['song_id'] as int
          : null,
      phase: phase,
      stateLabel: session.carMusicState,
      positionMs: fresh && p['position_ms'] is num
          ? (p['position_ms'] as num).toInt()
          : null,
      durationMs: fresh && p['duration_ms'] is num && p['duration_ms'] > 0
          ? (p['duration_ms'] as num).toInt()
          : null,
      volume: p['software_volume'] is num
          ? (p['software_volume'] as num).toDouble()
          : null,
      known: fresh,
    );
  }

  static String? _text(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : null;

  /// True when the selected output can take a control press right now.
  bool get controlsReady {
    if (handoffActive || _operationBusy) return false;
    if (target == PlaybackTarget.phone) {
      return session.userSignedIn && !local.busy;
    }
    return !session.commandPending &&
        !session.preparingTrack &&
        !session.awaitingExecution;
  }

  Future<void> _operation(Future<void> Function() action) async {
    if (_operationBusy || handoffActive) throw ApiFailure('已有播放操作正在处理');
    _operationBusy = true;
    _publish();
    try {
      await action();
    } finally {
      _operationBusy = false;
      _publish();
    }
  }

  // ----------------------------------------------------------------- transport (target aware)

  /// A transport control (play/pause/next/…) aimed at the selected output only.
  Future<void> command(
    String action, [
    Map<String, dynamic> params = const {},
  ]) => _operation(() async {
    if (handoffActive) {
      throw ApiFailure('正在转移播放，请先完成或取消');
    }
    if (target == PlaybackTarget.car) {
      await session.sendCommand(action, params);
      return;
    }
    if (!session.userSignedIn) throw ApiFailure('请先登录 MyYaris');
    switch (action) {
      case 'resume':
        final gen = _gen;
        await _quietCarBeforeLocalSound();
        _ensureSameSession(gen);
        if (local.hasMedia || local.queue != null) {
          await _guard(local.play());
        } else {
          await _defaultLocalPlay();
        }
      case 'pause':
        await local.pause();
      case 'stop':
        await local.stop();
      case 'next':
        await _guard(local.next());
      case 'prev':
        await _guard(local.previous());
      case 'seek':
        final ms = params['seek_ms'];
        if (ms is! int || ms < 0) throw ApiFailure('播放进度必须是非负毫秒整数');
        await _guard(local.seek(ms));
      case 'set_volume':
        final v = params['volume'];
        if (v is! num || v < 0 || v > 1) throw ApiFailure('音量必须为 0～1');
        await local.setVolume(v.toDouble());
      default:
        throw ApiFailure('本机播放不支持此操作');
    }
  });

  Future<void> _guard(Future<void> action) async {
    try {
      await action;
    } on LocalFailure catch (e) {
      throw ApiFailure(e.message);
    }
  }

  Future<void> _defaultLocalPlay() async {
    if (!session.ownerQueueAllowed) {
      throw ApiFailure('当前账号没有喜欢歌单的播放权限，请先搜索选歌');
    }
    final favorite = await _loadFavorite(mode: 'list_loop');
    await _startLocalAudible(favorite, 0);
  }

  /// Phone sound is ordered: prepare silently, silence a car that is known to be playing, then play.
  Future<void> _startLocalAudible(LocalQueue queue, int index) async {
    final gen = _gen;
    await _guard(local.start(queue, index: index, autoplay: false));
    _ensureSameSession(gen);
    await _quietCarBeforeLocalSound();
    _ensureSameSession(gen);
    await _guard(local.play());
  }

  Future<void> playFavorite(
    Map<String, dynamic> track, {
    String? queueId,
    int? queueVersion,
  }) => _operation(() async {
    final gen = _gen;
    if (handoffActive) throw ApiFailure('正在转移播放，请先完成或取消');
    if (target == PlaybackTarget.car) {
      await session.playFavoriteTrack(
        track,
        queueId: queueId,
        queueVersion: queueVersion,
      );
      return;
    }
    if (!session.ownerQueueAllowed) throw ApiFailure('当前账号没有此歌单的播放权限');
    final song = session.api.songId(track);
    final keepShuffle =
        local.queue?.isFavorite == true && local.queue?.mode == 'shuffle';
    final favorite = await _loadFavorite(
      mode: keepShuffle ? 'shuffle' : 'list_loop',
    );
    _ensureSameSession(gen);
    final index = favorite.tracks.indexWhere((t) => t['song_id'] == song);
    if (index < 0) throw ApiFailure('这首歌已不在喜欢歌单中，请刷新后重选');
    await _startLocalAudible(favorite, index);
  });

  Future<void> playSingle(Map<String, dynamic> track) => _operation(() async {
    if (handoffActive) throw ApiFailure('正在转移播放，请先完成或取消');
    if (target == PlaybackTarget.car) {
      await session.playTrack(track, singleTrack: true);
      return;
    }
    if (!session.userSignedIn) throw ApiFailure('请先登录 MyYaris');
    if (session.api.trackSource(track) != 'netease') {
      throw ApiFailure('本机播放请选择网易云在线歌曲');
    }
    final normalized = _normalizeTrack(track);
    await _startLocalAudible(LocalQueue.single(normalized), 0);
  });

  Map<String, dynamic> _normalizeTrack(Map<String, dynamic> track) {
    final id = session.api.songId(track);
    return Map.unmodifiable({
      'track_id': 'netease_$id',
      'song_id': id,
      'title': _text(track['title']) ?? '曲名暂不可用',
      'artist': _text(track['artist']) ?? '',
      'album': track['album'],
      'duration_ms': track['duration_ms'] is int ? track['duration_ms'] : 0,
      'cover_url': track['cover_url'],
      'source': 'netease',
    });
  }

  /// Applies a play mode to the selected output only.
  Future<void> chooseMode(String mode) => _operation(() async {
    final gen = _gen;
    if (handoffActive) throw ApiFailure('正在转移播放，请先完成或取消');
    if (target == PlaybackTarget.car) {
      await session.choosePlaybackMode(mode);
      return;
    }
    if (!localModes.contains(mode)) throw ApiFailure('未知播放模式');
    if (!session.userSignedIn) throw ApiFailure('请先登录 MyYaris');
    final current = local.queue;
    if (mode == 'single_loop') {
      if (current == null || !await local.setMode(mode)) {
        throw ApiFailure('当前队列无法使用该模式');
      }
      return;
    }
    if (!session.ownerQueueAllowed) throw ApiFailure('当前账号没有此歌单的播放权限');
    final currentSong = local.track?['song_id'];
    final wasPlaying = local.isPlaying;
    if (mode == 'list_loop' || mode == 'shuffle') {
      if (current != null && current.isFavorite && current.complete) {
        await local.setMode(mode);
        return;
      }
      final favorite = await _loadFavorite(mode: mode);
      _ensureSameSession(gen);
      final found = favorite.tracks.indexWhere(
        (t) => t['song_id'] == currentSong,
      );
      if (current != null && found >= 0 && local.hasMedia) {
        await local.adoptQueueKeepingAudio(favorite, found, mode);
      } else {
        await _guard(local.start(favorite, index: 0, autoplay: wasPlaying));
      }
      return;
    }
    // heart: seed from the current song when it is a favorite, else the first favorite.
    final favorite = current != null && current.isFavorite && current.complete
        ? current
        : await _loadFavorite(mode: 'list_loop');
    final seedIndex = favorite.tracks.indexWhere(
      (t) => t['song_id'] == currentSong,
    );
    final seed =
        favorite.tracks[seedIndex >= 0 ? seedIndex : 0]['song_id'] as int;
    final heart = await _createHeart(seed);
    _ensureSameSession(gen);
    final found = heart.tracks.indexWhere((t) => t['song_id'] == currentSong);
    if (found >= 0 && local.hasMedia) {
      await local.adoptQueueKeepingAudio(heart, found, 'intelligence');
    } else {
      await _guard(local.start(heart, index: 0, autoplay: wasPlaying));
    }
  });

  // ----------------------------------------------------------------- phone queues

  void _ensureSameSession(int gen) {
    if (gen != _gen || _disposed) throw ApiFailure('登录状态已切换，旧播放列表已清除');
  }

  Future<LocalQueue> _loadFavorite({
    required String mode,
    String? queueId,
    int? version,
  }) async {
    final gen = _gen;
    final accumulator = MusicQueueAccumulator();
    MusicQueuePage? first;
    var offset = 0;
    var id = queueId, ver = version;
    while (true) {
      final page = await session.api.readLocalQueue(
        sessionId: _sessionId,
        source: id == null ? 'netease_favorite' : null,
        queueId: id,
        version: ver,
        offset: offset,
      );
      _ensureSameSession(gen);
      if (page.source != 'netease_favorite') {
        throw ApiFailure('喜欢歌单已变化，请刷新后重试');
      }
      if (!page.established) throw ApiFailure('喜欢歌单尚未加载完成，请稍后重试');
      accumulator.add(page);
      first ??= page;
      id = page.id;
      ver = page.version;
      if (!page.hasMore) break;
      offset += page.tracks.length;
      if (offset > 10000) throw ApiFailure('播放列表过大，请刷新后重试');
    }
    if (!accumulator.complete) throw ApiFailure('喜欢歌单尚未加载完成，请稍后重试');
    return LocalQueue(
      source: 'netease_favorite',
      queueId: first.id,
      version: first.version,
      tracks: accumulator.tracks,
      mode: mode,
    );
  }

  Future<List<Map<String, dynamic>>> _readLocalPages(
    String queueId,
    int version,
    String source,
  ) async {
    final gen = _gen;
    final accumulator = MusicQueueAccumulator();
    var offset = 0;
    while (true) {
      final page = await session.api.readLocalQueue(
        sessionId: _sessionId,
        queueId: queueId,
        version: version,
        offset: offset,
      );
      _ensureSameSession(gen);
      if (page.source != source) throw ApiFailure('播放列表已变化，请重试');
      accumulator.add(page);
      if (!page.hasMore) break;
      offset += page.tracks.length;
      if (offset > 10000) throw ApiFailure('播放列表过大，请刷新后重试');
    }
    if (!accumulator.complete) throw ApiFailure('心动歌曲尚未准备好，请稍后重试');
    return accumulator.tracks;
  }

  Future<LocalQueue> _createHeart(int seedSongId) async {
    final gen = _gen;
    final response = await session.api.localHeartBatch(
      sessionId: _sessionId,
      requestId:
          'lh_${_sessionId.substring(0, 12)}_${DateTime.now().microsecondsSinceEpoch}',
      seedSongId: seedSongId,
      batchIndex: 0,
    );
    _ensureSameSession(gen);
    final id = response['queue_id'], version = response['queue_version'];
    if (response['mode'] != 'intelligence' ||
        id is! String ||
        id.isEmpty ||
        version is! int ||
        version < 1) {
      throw ApiFailure('心动模式暂时未准备好，请稍后重试');
    }
    final tracks = await _readLocalPages(id, version, 'netease_intelligence');
    return LocalQueue(
      source: 'netease_intelligence',
      queueId: id,
      version: version,
      tracks: tracks,
      complete: false,
      mode: 'intelligence',
    );
  }

  Future<HeartBatch> _continueHeart(LocalQueue queue) async {
    final gen = _gen;
    final batch = queue.batchIndex + 1;
    final response = await session.api.localHeartBatch(
      sessionId: _sessionId,
      requestId: 'lh_${queue.queueId}_b$batch',
      seedSongId: queue.tracks.last['song_id'] as int,
      batchIndex: batch,
      queueId: queue.queueId,
      queueVersion: queue.version,
    );
    _ensureSameSession(gen);
    final id = response['queue_id'], version = response['queue_version'];
    if (response['mode'] != 'intelligence' ||
        id != queue.queueId ||
        version is! int ||
        version <= queue.version) {
      throw ApiFailure('心动续批返回不一致，未追加');
    }
    return HeartBatch(
      tracks: await _readLocalPages(
        queue.queueId,
        version,
        'netease_intelligence',
      ),
      version: version,
      batchIndex: batch,
    );
  }

  // ----------------------------------------------------------------- car command helpers

  /// Sends one command over HTTP (idempotent by [id]) and waits for the vehicle's own verdict.
  /// 'applied' is the car's confirmation of execution, not proof that anything is audible.
  Future<String> _carCommand(
    String action,
    Map<String, dynamic> params,
    String id,
    Handoff? h,
  ) async {
    final gen = _gen;
    if (action == 'resume') _unresolvedCarCommand = id;
    try {
      await session.api.command(action, params, id);
    } on ApiFailure catch (e) {
      final code = e.statusCode;
      final failed = code != null && code >= 400 && code < 500;
      if (failed && _unresolvedCarCommand == id) _unresolvedCarCommand = null;
      return failed ? 'failed' : 'unknown';
    }
    final deadline = DateTime.now().add(commandTimeout);
    while (true) {
      if (gen != _gen || h?.cancelled == true) return 'cancelled';
      try {
        final result = await session.api.commandResult(id);
        if (gen != _gen || h?.cancelled == true) return 'cancelled';
        final status = result['status'];
        if (status == 'applied' || status == 'executed') return 'applied';
        if (status == 'failed' || status == 'expired') return 'failed';
      } on ApiFailure catch (e) {
        final code = e.statusCode;
        if (code != null && code >= 400 && code < 500 && code != 429) {
          return 'unknown';
        }
      }
      if (!DateTime.now().isBefore(deadline)) return 'unknown';
      await _wait(pollInterval);
    }
  }

  /// Before the phone makes sound on its own, a car that is known to be playing is paused first.
  Future<void> _quietCarBeforeLocalSound() async {
    final gen = _gen;
    if (_unresolvedCarCommand != null) {
      final result = await session.api.commandResult(_unresolvedCarCommand!);
      _ensureSameSession(gen);
      if (!{
        'applied',
        'executed',
        'failed',
        'expired',
      }.contains(result['status'])) {
        throw ApiFailure('先前车机指令结果未确认，本机保持静音；请重试转移或到车机核对');
      }
      _unresolvedCarCommand = null;
    }
    if (!session.api.configured || !session.canControlVehicle) return;
    await session.refresh();
    _ensureSameSession(gen);
    if (!session.heartbeatFresh || session.playbackStale) {
      throw ApiFailure('车机状态未知，无法确认单端输出，本机未播放');
    }
    if (!{
      'playing',
      'buffering',
    }.contains(session.playback['playback_state'])) {
      return;
    }
    final id = 'ho_${_newHandoffId()}_quiet_0';
    final outcome = await _carCommand('pause', const {}, id, null);
    _ensureSameSession(gen);
    if (outcome != 'applied') {
      if (outcome != 'failed') _unresolvedCarCommand = id;
      throw ApiFailure('车机仍在播放，未能先暂停车机；为避免两端同时出声，本机未播放');
    }
  }

  // ----------------------------------------------------------------- handoff

  /// Explicit user choice of output. Moving audible/loaded playback is an ordered handoff; with
  /// nothing loaded on the other side it only changes the selected output.
  Future<void> selectTarget(PlaybackTarget to) async {
    final running = handoff;
    if (running != null && running.active) {
      if (running.to == to) {
        return; // repeated tap: same handoff, nothing new is sent
      }
      throw ApiFailure('正在转移播放，请先完成或取消');
    }
    if (_operationBusy) throw ApiFailure('已有播放操作正在处理');
    if (!phoneTarget &&
        (session.commandPending ||
            session.preparingTrack ||
            session.awaitingExecution)) {
      throw ApiFailure('车机还有未确认指令，请先核对执行结果');
    }
    if (to == target) return;
    final h = Handoff(id: _newHandoffId(), from: target, to: to);
    handoff = h;
    _publish();
    await _run(h, _gen);
  }

  /// Runs the handoff steps. A thrown error before the source was silenced is a clean failure (the
  /// source keeps playing); after it, the outcome is uncertain and must be confirmed by the user.
  Future<void> _run(Handoff h, int gen) async {
    if (h.running) return;
    h.running = true;
    try {
      if (h.to == PlaybackTarget.car) {
        await _toCar(h, gen);
      } else {
        await _toPhone(h, gen);
      }
    } catch (e) {
      if (_stale(h, gen)) return;
      final message = e is ApiFailure ? e.message : '转移失败，原输出保持不变';
      final uncertain = h.to == PlaybackTarget.car
          ? h.sourceSilenced
          : h.prepared && h.outcomes['pause'] != 'failed';
      if (uncertain) {
        _needsConfirmation(h, message);
      } else {
        _fail(h, message);
      }
    } finally {
      h.running = false;
      _publish();
    }
  }

  void _fail(Handoff h, String message) {
    h.status = HandoffStatus.failed;
    h.message = message;
    _publish();
  }

  void _needsConfirmation(Handoff h, String message) {
    h.status = HandoffStatus.needsConfirmation;
    h.message = message;
    _publish();
  }

  void _done(Handoff h, PlaybackTarget to, String message) {
    target = to;
    h.status = HandoffStatus.done;
    h.message = message;
    _publish();
  }

  bool _stale(Handoff h, int gen) => gen != _gen || h.cancelled || handoff != h;

  void _bump(Handoff h, String step, String outcome) {
    h.outcomes[step] = outcome;
    if (outcome == 'applied' || outcome == 'failed') {
      if (_unresolvedCarCommand == h.commandId(step)) {
        _unresolvedCarCommand = null;
      }
    } else if (outcome == 'unknown') {
      _unresolvedCarCommand = h.commandId(step);
    }
    if (outcome == 'failed') h.attempts[step] = (h.attempts[step] ?? 0) + 1;
  }

  Future<void> retryHandoff() async {
    final h = handoff;
    if (h == null) return;
    final gen = _gen;
    if (h.status == HandoffStatus.failed) {
      handoff = null;
      _publish();
      await selectTarget(h.to);
      return;
    }
    if (h.status != HandoffStatus.needsConfirmation) return;
    h.status = HandoffStatus.running;
    h.message = '正在重新确认…';
    _publish();
    await _run(h, gen);
  }

  Future<void> cancelHandoff() async {
    final h = handoff;
    if (h == null) return;
    if (!h.active) {
      handoff = null;
      _publish();
      return;
    }
    h.cancelled = true;
    final gen = _gen;
    if (h.to == PlaybackTarget.car) {
      // Phone is the source and stays paused. The car may have started: ask it to pause, best effort.
      var confirmed = false;
      if (h.sourceSilenced ||
          h.targetStarted ||
          h.status == HandoffStatus.needsConfirmation) {
        final outcome = await _carCommand(
          'pause',
          const {},
          'ho_${h.id}_cancel_0',
          null,
        );
        confirmed = outcome == 'applied';
      }
      if (gen != _gen) return;
      final uncertain = h.status == HandoffStatus.needsConfirmation;
      h.status = HandoffStatus.cancelled;
      final phoneNote = local.isPlaying ? '本机继续播放' : '本机保持暂停';
      h.message = h.targetStarted || h.sourceSilenced || uncertain
          ? (confirmed
                ? '已取消转移：$phoneNote，车机已暂停'
                : '已取消转移：$phoneNote；车机状态未确认，请到车机核对')
          : '已取消转移：$phoneNote';
    } else {
      // Phone side was only prepared (silent): drop it. The car keeps whatever it is doing.
      h.prepared = false;
      await local.release();
      if (gen != _gen) return;
      h.status = HandoffStatus.cancelled;
      h.message = '已取消转移；车机状态请以车机为准';
    }
    _publish();
  }

  void dismissHandoff() {
    if (handoff != null && !handoff!.active) {
      handoff = null;
      _publish();
    }
  }

  // phone -> car ----------------------------------------------------------

  Future<Map<String, dynamic>> _planCarPlay(
    LocalSnapshot snap,
    Handoff h,
  ) async {
    final api = session.api;
    final song = snap.track['song_id'] as int;
    Map<String, dynamic> base(String source) => {
      'source': source,
      'song_id': song,
      'track_id': 'netease_$song',
      'stream_url': api.canonicalStream({...snap.track, 'source': 'netease'}),
      'title': snap.track['title'],
      'artist': snap.track['artist'],
    };
    final queue = snap.queue;
    if (queue.isSingle) {
      return {
        ...base('single_track'),
        if (queue.mode == 'single_loop') 'mode': 'single_loop',
      };
    }
    final ref = await api.transferQueue(
      'export',
      sessionId: _sessionId,
      queueId: queue.queueId,
      queueVersion: queue.version,
    );
    final id = ref['queue_id'], version = ref['queue_version'];
    if (id != queue.queueId ||
        version is! int ||
        ref['source'] != queue.source) {
      throw ApiFailure('播放队列无法完整交给车机，原输出保持不变');
    }
    return {
      ...base(queue.source),
      'queue_id': id,
      'queue_version': version,
      'queue_index': snap.index,
      if (const {'list_loop', 'shuffle', 'single_loop'}.contains(snap.mode))
        'mode': snap.mode,
    };
  }

  Future<void> _toCar(Handoff h, int gen) async {
    final snap = local.capture();
    if (snap == null && !h.prepared) {
      await local.release();
      if (_stale(h, gen)) return;
      _done(h, PlaybackTarget.car, '已切换到车机；本机没有正在播放的内容');
      return;
    }
    if (!session.canControlVehicle) {
      throw ApiFailure('当前账号未授权目标车机，仍在本机播放');
    }
    if (!h.prepared && session.api.configured) {
      h.message = '正在确认车机状态…';
      _publish();
      await session.refresh();
      if (_stale(h, gen)) return;
    }
    if (!(session.playback['capabilities'] is List &&
        (session.playback['capabilities'] as List).contains('handoff_v1'))) {
      throw ApiFailure('请先更新车机以支持静音准备，仍在本机播放');
    }
    if (!(session.heartbeatFresh &&
        !session.playbackStale &&
        session.queueV2Ready)) {
      throw ApiFailure('车机离线或状态未更新，仍在本机播放');
    }
    if (!h.prepared) {
      h.message = '正在让车机准备…';
      _publish();
      h.plan ??= {
        ...await _planCarPlay(snap!, h),
        'seek_ms': snap.positionMs,
        'autoplay': false,
      };
      if (_stale(h, gen)) return;
      h.resumePositionMs = snap!.positionMs;
      h.queueIndex = snap.index;
      final outcome = await _carCommand(
        'play_track',
        h.plan!,
        h.commandId('prepare'),
        h,
      );
      if (_stale(h, gen)) return;
      _bump(h, 'prepare', outcome);
      if (outcome != 'applied') {
        if (outcome != 'failed') {
          _needsConfirmation(h, '车机没有确认准备完成，本机继续播放；请重试确认或取消');
          return;
        }
        throw ApiFailure('车机未能准备好，仍在本机播放');
      }
      h.prepared = true;
      h.sourceSilenced = false;
      h.targetStarted = false;
      h.wasPlaying = snap.playing;
    }
    if (h.wasPlaying) {
      if (!h.sourceSilenced) {
        if (snap == null ||
            local.track?['song_id'] != h.plan!['song_id'] ||
            local.queue?.index != h.queueIndex) {
          throw ApiFailure('准备期间本机歌曲已变化，未启动车机，请重新转移');
        }
        h.message = '正在暂停本机并启动车机…';
        _publish();
        await local.pause();
        if (_stale(h, gen)) return;
        h.resumePositionMs = local.positionMs;
        h.sourceSilenced = true;
      }
      h.beforeStatusSeq = session.playback['status_seq'] as int?;
      final outcome = await _carCommand(
        'resume',
        {
          'seek_ms': h.resumePositionMs,
          if (h.plan!['queue_id'] != null)
            'expected_queue_id': h.plan!['queue_id'],
          if (h.plan!['queue_version'] != null)
            'expected_queue_version': h.plan!['queue_version'],
        },
        h.commandId('start'),
        h,
      );
      if (_stale(h, gen)) return;
      _bump(h, 'start', outcome);
      if (outcome != 'applied') {
        _needsConfirmation(
          h,
          outcome == 'failed'
              ? '车机未能开始播放，本机已暂停；为避免两端同时出声，不会自动恢复本机'
              : '车机没有确认开始播放，本机已暂停；车机可能已在播放，不会自动恢复本机',
        );
        return;
      }
      h.targetStarted = true;
      final confirmed = await _awaitCarState(h, gen, wantPlaying: true);
      if (_stale(h, gen)) return;
      await local.release();
      _done(h, PlaybackTarget.car, confirmed ? '已转到车机' : '车机已应用，播放状态待确认');
      return;
    }
    await local.release();
    if (_stale(h, gen)) return;
    _done(h, PlaybackTarget.car, '已转到车机，保持暂停');
  }

  /// Waits (bounded) until the car's own status shows the wanted state after our last command.
  Future<bool> _awaitCarState(
    Handoff h,
    int gen, {
    required bool wantPlaying,
  }) async {
    final deadline = DateTime.now().add(statusTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await session.refresh();
      if (_stale(h, gen)) return false;
      final state = session.playback['playback_state'];
      if (session.heartbeatFresh &&
          (h.beforeStatusSeq == null ||
              (session.playback['status_seq'] is int &&
                  session.playback['status_seq'] > h.beforeStatusSeq)) &&
          !session.playbackStale &&
          (h.to != PlaybackTarget.car ||
              h.plan == null ||
              !h.plan!.containsKey('queue_id') ||
              session.playback['queue_id'] == h.plan!['queue_id']) &&
          (wantPlaying
              ? state == 'playing'
              : {'paused', 'stopped'}.contains(state))) {
        return true;
      }
      await _wait(pollInterval);
    }
    return false;
  }

  // car -> phone ----------------------------------------------------------

  Future<void> _toPhone(Handoff h, int gen) async {
    final api = session.api;
    if (!h.prepared) {
      if (session.canControlVehicle && api.configured) {
        h.message = '正在读取车机播放状态…';
        _publish();
        await session.refresh();
        if (_stale(h, gen)) return;
      }
      final p = session.playback;
      final trackId = _text(p['current_track_id']);
      final known =
          session.canControlVehicle &&
          session.heartbeatFresh &&
          !session.playbackStale &&
          trackId != null &&
          p['playback_state'] != 'stopped';
      if (!known) {
        await local.release();
        _done(
          h,
          PlaybackTarget.phone,
          trackId == null || p['playback_state'] == 'stopped'
              ? '已切换到本机；车机没有正在播放的内容'
              : '已切换到本机；车机状态未知，未转移播放',
        );
        return;
      }
      if (!{'playing', 'buffering', 'paused'}.contains(p['playback_state'])) {
        throw ApiFailure('车机状态未知，未转移播放');
      }
      final carPlaying = {'playing', 'buffering'}.contains(p['playback_state']);
      final position = (p['position_ms'] as num?)?.toInt() ?? 0;
      h.outcomes['carPlaying'] = carPlaying ? 'yes' : 'no';
      h.resumePositionMs = position;
      h.plan = {
        'track_id': trackId,
        'queue_id': p['queue_id'],
        'queue_version': p['queue_version'],
      };
      h.message = '正在让本机准备…';
      _publish();
      final built = await _buildLocalQueueFromCar(h, gen);
      if (_stale(h, gen)) return;
      h.queue = built.$1;
      h.queueIndex = built.$2;
      try {
        await local.start(
          built.$1,
          index: built.$2,
          positionMs: position,
          autoplay: false,
        );
      } on LocalFailure catch (e) {
        await local.release();
        throw ApiFailure('本机未能准备好，车机继续播放（${e.message}）');
      }
      if (_stale(h, gen)) return;
      h.prepared = true;
    }
    final carPlaying = h.outcomes['carPlaying'] == 'yes';
    if (!h.sourceSilenced) {
      h.message = '正在暂停车机…';
      _publish();
      h.beforeStatusSeq ??= session.playback['status_seq'] as int?;
      final outcome = await _carCommand(
        'pause',
        const {},
        h.commandId('pause'),
        h,
      );
      if (_stale(h, gen)) return;
      _bump(h, 'pause', outcome);
      if (outcome == 'failed') {
        h.prepared = false;
        await local.release();
        throw ApiFailure('车机未能暂停，车机继续播放，本机未开始');
      }
      if (outcome != 'applied') {
        _needsConfirmation(h, '车机没有确认已暂停；为避免两端同时出声，本机保持静音，请重试或取消');
        return;
      }
      h.sourceSilenced = true;
      final silent = await _awaitCarState(h, gen, wantPlaying: false);
      if (!silent) {
        h.sourceSilenced = false;
        _needsConfirmation(h, '车机已应用暂停，但尚未回报静音状态，本机保持静音');
        return;
      }
      if (_stale(h, gen)) return;
      if (session.playback['current_track_id'] != h.plan!['track_id'] ||
          session.playback['queue_id'] != h.plan!['queue_id'] ||
          session.playback['queue_version'] != h.plan!['queue_version']) {
        h.sourceSilenced = false;
        _needsConfirmation(h, '准备期间车机歌曲或队列已变化，本机未开始，请取消后重新转移');
        return;
      }
      final reported = (session.playback['position_ms'] as num?)?.toInt();
      if (reported != null && session.playback['playback_state'] != 'playing') {
        h.resumePositionMs = reported;
      }
    }
    if (carPlaying) {
      if ((h.resumePositionMs - local.positionMs).abs() > 1200) {
        try {
          await local.seek(h.resumePositionMs);
        } on LocalFailure catch (_) {}
      }
      try {
        await local.play();
      } on LocalFailure catch (e) {
        _needsConfirmation(h, '车机已暂停，但本机无法开始播放（${e.message}）。可重试或取消');
        return;
      }
      if (_stale(h, gen)) return;
    }
    _done(h, PlaybackTarget.phone, carPlaying ? '已转到本机' : '已转到本机，保持暂停');
  }

  Future<(LocalQueue, int)> _buildLocalQueueFromCar(Handoff h, int gen) async {
    final p = session.playback;
    final trackId = _text(p['current_track_id'])!;
    final song = int.tryParse(trackId.replaceFirst('netease_', ''));
    if (song == null || song <= 0) throw ApiFailure('车机当前曲目无法识别，未转移');
    final source = p['queue_source'];
    final queueId = _text(p['queue_id']);
    final version = p['queue_version'] is int
        ? p['queue_version'] as int
        : null;
    final carMode = p['applied_mode'];
    LocalQueue single(String note) {
      h.message = note;
      final meta = session.currentTrack;
      final track = _normalizeTrack({
        'song_id': song,
        'title': meta['title'],
        'artist': meta['artist'],
        'album': meta['album'],
        'duration_ms': meta['duration_ms'] ?? p['duration_ms'],
        'cover_url': meta['cover_url'],
      });
      return LocalQueue.single(track);
    }

    if (source == 'single_track') {
      final q = single('正在让本机准备…');
      if (carMode == 'single_loop') q.mode = 'single_loop';
      return (q, 0);
    }
    if (queueId == null || version == null) throw ApiFailure('车机队列信息不完整，未转移');
    if (!session.ownerQueueAllowed) throw ApiFailure('当前账号没有此队列的播放权限');
    if (!{'netease_favorite', 'netease_intelligence'}.contains(source)) {
      throw ApiFailure('车机队列来源无法保留，未转移');
    }
    final ref = await session.api.transferQueue(
      'adopt',
      sessionId: _sessionId,
      queueId: queueId,
      queueVersion: version,
    );
    _ensureSameSession(gen);
    final id = ref['queue_id'], localVersion = ref['queue_version'];
    if (id != queueId || localVersion is! int || ref['source'] != source) {
      throw ApiFailure('车机队列无法完整保留，未转移');
    }
    final tracks = await _readLocalPages(
      id as String,
      localVersion,
      source as String,
    );
    final index = tracks.indexWhere((t) => t['song_id'] == song);
    if (index < 0) throw ApiFailure('当前歌曲已不在该队列中，未转移');
    return (
      LocalQueue(
        source: source,
        queueId: id,
        version: localVersion,
        tracks: tracks,
        complete: source == 'netease_favorite',
        batchIndex: ref['batch_index'] is int ? ref['batch_index'] as int : 0,
        mode: carMode == 'single_loop'
            ? 'single_loop'
            : source == 'netease_intelligence'
            ? 'intelligence'
            : carMode == 'shuffle'
            ? 'shuffle'
            : 'list_loop',
      ),
      index,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    local.removeListener(notifyListeners);
    local.dispose();
    super.dispose();
  }
}
