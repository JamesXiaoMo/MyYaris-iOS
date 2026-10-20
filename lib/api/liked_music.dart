import 'dart:async';
import 'package:flutter/foundation.dart';
import 'backend.dart';
import 'liked_music_store.dart';

class LikedMusicPageData {
  LikedMusicPageData(
    this.tracks,
    this.total,
    this.offset,
    this.limit,
    this.hasMore,
    this.playlistId, {
    this.revision,
    this.etag,
    this.ownerKey,
    this.syncedAt,
    this.stale = false,
  });
  final List<Map<String, dynamic>> tracks;
  final int total, offset, limit, playlistId;
  final bool hasMore, stale;
  final int? revision;
  final String? etag, ownerKey;
  final DateTime? syncedAt;

  factory LikedMusicPageData.parse(
    Map<String, dynamic> value,
    int requestedOffset,
  ) {
    final items = value['songs'] ?? value['tracks'];
    final playlistId = value['playlist_id'];
    final total = value['total'],
        offset = value['offset'],
        limit = value['limit'];
    if (value['code'] != 200 ||
        playlistId is! int ||
        playlistId <= 0 ||
        items is! List ||
        total is! int ||
        total < 0 ||
        offset != requestedOffset ||
        limit is! int ||
        limit < 1 ||
        limit > 100 ||
        value['has_more'] is! bool ||
        (value['has_more'] == true && items.isEmpty)) {
      throw ApiFailure('喜欢歌单响应格式错误，未当作空歌单');
    }
    final revision = value['revision'];
    if (revision != null && (revision is! int || revision <= 0)) {
      throw ApiFailure('喜欢歌单版本字段错误，未当作空歌单');
    }
    final tracks = items.map((item) {
      if (item is! Map) throw ApiFailure('喜欢歌单曲目格式错误');
      final track = Map<String, dynamic>.from(item);
      final id = track['song_id'] ?? track['id'];
      if (id is! int ||
          id <= 0 ||
          track['title'] is! String ||
          track['artist'] is! String ||
          track['duration_ms'] is! int ||
          (track['duration_ms'] as int) < 0 ||
          track['source'] != 'netease') {
        throw ApiFailure('喜欢歌单曲目格式错误，不发送播放指令');
      }
      return {...track, 'song_id': id, 'source': 'netease'};
    }).toList();
    return LikedMusicPageData(
      tracks,
      total,
      requestedOffset,
      limit,
      value['has_more'] as bool,
      playlistId,
      revision: revision as int?,
      etag: value['etag'] is String ? value['etag'] as String : null,
      ownerKey: value['owner_key'] is String
          ? value['owner_key'] as String
          : null,
      syncedAt: DateTime.tryParse('${value['synced_at'] ?? ''}'),
      stale: value['stale'] == true,
    );
  }
}

/// Answer of `POST /netease/playlist/favorite/sync`.
class LikedSyncReply {
  LikedSyncReply(
    this.revision,
    this.etag,
    this.ownerKey,
    this.playlistId,
    this.total,
    this.changed,
  );
  final int revision, playlistId, total;
  final String etag, ownerKey;
  final bool changed;

  factory LikedSyncReply.parse(Map<String, dynamic> value) {
    final revision = value['revision'],
        etag = value['etag'],
        owner = value['owner_key'],
        playlist = value['playlist_id'],
        total = value['total'],
        changed = value['changed'];
    if (value['code'] != 200 ||
        revision is! int ||
        revision <= 0 ||
        etag is! String ||
        owner is! String ||
        owner.isEmpty ||
        playlist is! int ||
        playlist <= 0 ||
        total is! int ||
        total < 0 ||
        changed is! bool) {
      throw ApiFailure('喜欢歌单同步响应格式错误，未当作空歌单');
    }
    return LikedSyncReply(revision, etag, owner, playlist, total, changed);
  }
}

class _Pulled {
  _Pulled(
    this.tracks,
    this.total,
    this.playlistId,
    this.revision,
    this.etag,
    this.ownerKey,
    this.syncedAt,
    this.stale,
  );
  final List<Map<String, dynamic>> tracks;
  final int total, playlistId;
  final int? revision;
  final String? etag, ownerKey;
  final DateTime? syncedAt;
  final bool stale;
}

/// Owner favorite list: shows the scoped persistent cache immediately, then
/// asks the backend (one tiny request when nothing changed) whether the list
/// changed. Failures never blank an already shown list or fake an empty one.
class LikedMusicController extends ChangeNotifier {
  LikedMusicController(
    this.session, {
    LikedMusicStore? store,
    DateTime Function()? clock,
  }) : store = store ?? LikedMusicStore.shared,
       _clock = clock ?? DateTime.now {
    _identity = identity;
    session.addListener(_sessionChanged);
  }
  final BackendSession session;
  final LikedMusicStore store;
  final DateTime Function() _clock;
  List<Map<String, dynamic>> tracks = [];
  int total = 0, _epoch = 0;
  int? playlistId, revision;
  String? ownerKey, error, syncError;
  DateTime? syncedAt, checkedAt;
  bool syncing = false,
      loaded = false,
      fromCache = false,
      hasMore = false,
      _disposed = false;
  Future<void>? _running;
  late String _identity;

  /// Anything in flight (refresh button / spinner state).
  bool get busy => syncing;
  bool get loadingFirst => syncing && tracks.isEmpty;
  String get identity =>
      '${session.api.baseUrl}\n${session.api.token}\n${session.userProfile['role']}'
      '\n${session.userProfile['id']}\n${session.api.deviceId}';
  bool get allowed =>
      session.userSignedIn && session.userProfile['role'] == 'admin';

  LikedMusicScope? _scope() {
    try {
      final origin = BackendApi.validateBase(session.api.baseUrl).origin;
      final account = session.requireUserLogin
          ? '${session.userProfile['id'] ?? ''}'
          : 'legacy-device';
      if (account.isEmpty || session.api.deviceId.isEmpty) return null;
      return LikedMusicScope(
        origin: origin,
        account: account,
        device: session.api.deviceId,
      );
    } catch (_) {
      return null;
    }
  }

  void _clearRows() {
    tracks = [];
    total = 0;
    playlistId = revision = null;
    ownerKey = null;
    syncedAt = checkedAt = null;
    loaded = fromCache = hasMore = false;
  }

  void _sessionChanged() {
    if (identity == _identity) return;
    _identity = identity;
    _epoch++;
    _running = null;
    _clearRows();
    syncing = false;
    error = syncError = null;
    notifyListeners();
    if (allowed) unawaited(open());
  }

  /// Entering the page: cached rows first, background check afterwards.
  Future<void> open() => _start(false);

  /// Manual refresh: forces the backend to re-read upstream; old rows stay.
  Future<void> refresh() => _start(true);

  Future<void> _start(bool force) {
    if (_disposed) return Future.value();
    final running = _running;
    if (running != null) {
      return force ? running.then((_) => _start(true)) : running;
    }
    late final Future<void> run;
    run = _run(force).whenComplete(() {
      if (identical(_running, run)) _running = null;
    });
    _running = run;
    return run;
  }

  Future<void> _run(bool force) async {
    if (_disposed) return;
    if (!allowed) {
      error = '仅服务器 Owner 的 MyYaris 管理员可查看此私人喜欢歌单';
      notifyListeners();
      return;
    }
    final epoch = ++_epoch, who = identity, scope = _scope();
    bool current() =>
        !_disposed && _epoch == epoch && identity == who && allowed;
    syncing = true;
    error = syncError = null;
    notifyListeners();
    try {
      if (!loaded && scope != null) {
        final cached = await store.load(scope);
        if (!current()) return;
        if (cached != null) {
          _applyCache(cached);
          notifyListeners();
        }
      }
      LikedSyncReply? reply;
      try {
        reply = await _sync(force);
      } on ApiFailure catch (e) {
        // Older backend without the sync endpoint: fall back to plain paging.
        if (!{404, 405, 501}.contains(e.statusCode)) rethrow;
      }
      if (!current()) return;
      if (reply != null) {
        if (ownerKey != null && ownerKey != reply.ownerKey) {
          // Different verified NetEase Owner than the cached rows: drop, never merge.
          _clearRows();
          if (scope != null) unawaited(store.clear(scope));
          notifyListeners();
        } else if (loaded && !reply.changed && revision == reply.revision) {
          checkedAt = _clock();
          fromCache = false;
          return;
        }
      }
      final pulled = await _pull(reply?.revision, current);
      if (pulled == null || !current()) return;
      _applyPulled(pulled);
      if (scope != null &&
          pulled.revision != null &&
          pulled.ownerKey != null &&
          pulled.etag != null &&
          !pulled.stale) {
        unawaited(
          store.save(
            scope,
            LikedMusicSnapshot(
              ownerKey: pulled.ownerKey!,
              playlistId: pulled.playlistId,
              revision: pulled.revision!,
              etag: pulled.etag!,
              syncedAt: syncedAt ?? _clock(),
              checkedAt: checkedAt ?? _clock(),
              tracks: pulled.tracks,
            ),
          ),
        );
      }
      if (pulled.stale) {
        syncError = '后端暂时连不上网易云，当前显示服务器上次校验的歌单；可稍后点击刷新';
      }
    } catch (e) {
      if (!current()) return;
      _failed(e, scope);
    } finally {
      if (current()) {
        syncing = false;
        notifyListeners();
      }
    }
  }

  Future<LikedSyncReply> _sync(bool force) async {
    final result = await session.api.call(
      'POST',
      '/api/v1/music/netease/playlist/favorite/sync',
      body: {
        if (loaded && revision != null) 'known_revision': revision,
        'force': force,
      },
    );
    return LikedSyncReply.parse(result);
  }

  /// Pulls the whole list pinned to one backend revision. The visible rows are
  /// only replaced once the new list is complete (cold start shows pages as
  /// they arrive instead).
  Future<_Pulled?> _pull(int? pin, bool Function() current) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final rows = <Map<String, dynamic>>[], seen = <int>{};
      var offset = 0, total = 0, pages = 0;
      int? rev = attempt == 0 ? pin : null, playlist;
      String? etag, owner;
      DateTime? synced;
      var stale = false;
      final progressive = tracks.isEmpty;
      try {
        while (true) {
          if (++pages > 200) throw ApiFailure('喜欢歌单分页异常，已停止');
          final result = await session.api.call(
            'GET',
            '/api/v1/music/netease/playlist/favorite',
            query: {
              'limit': offset == 0 ? '50' : '100',
              'offset': '$offset',
              if (rev != null) 'revision': '$rev',
            },
          );
          if (!current()) return null;
          final page = LikedMusicPageData.parse(result, offset);
          if (playlist != null && playlist != page.playlistId) {
            throw ApiFailure('网易云账号或喜欢歌单已变更，请刷新后重试');
          }
          if (rev != null && page.revision != null && page.revision != rev) {
            throw ApiFailure('喜欢歌单版本在分页中变化，请刷新后重试');
          }
          playlist = page.playlistId;
          rev ??= page.revision;
          etag ??= page.etag;
          owner ??= page.ownerKey;
          synced ??= page.syncedAt;
          stale = stale || page.stale;
          total = page.total;
          rows.addAll(page.tracks.where((t) => seen.add(t['song_id'] as int)));
          offset += page.tracks.length;
          if (progressive) {
            tracks = List.of(rows);
            this.total = total;
            hasMore = page.hasMore;
            notifyListeners();
          }
          if (!page.hasMore) break;
        }
        if (rev != null && rows.length != total) {
          throw ApiFailure('喜欢歌单分页不完整，未覆盖本地缓存');
        }
        return _Pulled(rows, total, playlist, rev, etag, owner, synced, stale);
      } on ApiFailure catch (e) {
        if (e.errorCode == 'FAVORITE_REVISION_CONFLICT') continue;
        rethrow;
      }
    }
    throw ApiFailure('喜欢歌单反复更新，请稍后重试');
  }

  void _applyCache(LikedMusicSnapshot s) {
    tracks = s.tracks;
    total = s.tracks.length;
    playlistId = s.playlistId;
    revision = s.revision;
    ownerKey = s.ownerKey;
    syncedAt = s.syncedAt;
    checkedAt = s.checkedAt;
    loaded = fromCache = true;
    hasMore = false;
  }

  void _applyPulled(_Pulled p) {
    tracks = p.tracks;
    total = p.total;
    playlistId = p.playlistId;
    revision = p.revision;
    ownerKey = p.ownerKey ?? ownerKey;
    syncedAt = p.syncedAt ?? _clock();
    checkedAt = _clock();
    loaded = true;
    fromCache = false;
    hasMore = false;
  }

  void _failed(Object e, LikedMusicScope? scope) {
    final status = e is ApiFailure ? e.statusCode : null;
    final message = switch (e) {
      ApiFailure(statusCode: 403) => '无权限：仅服务器 Owner 的 MyYaris 管理员可查看此私人喜欢歌单',
      ApiFailure(statusCode: 409) =>
        '后端网易云会话未授权或已失效，请管理者在设置中登录网易云；MyYaris 登录仍保留',
      ApiFailure(statusCode: 404) => '喜欢歌单未找到或后端接口尚未部署，请重试或联系管理者',
      ApiFailure(statusCode: 502 || 503 || 504) => '网易云上游暂不可用或超时，不是空歌单；请重试',
      ApiFailure() => e.message,
      _ => '喜欢歌单加载失败，请重试',
    };
    if (status == 403 || status == 409) {
      // Authorisation / Owner cannot be proven: never present the cache as current.
      _clearRows();
      if (status == 403 && scope != null) unawaited(store.clear(scope));
      error = message;
    } else if (tracks.isNotEmpty) {
      syncError =
          '更新失败（${message.split('；').first}），仍显示${_stamp(checkedAt ?? syncedAt)}的本地缓存';
    } else {
      error = message;
    }
  }

  String _stamp(DateTime? t) {
    if (t == null) return '上次';
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.month}/${l.day} ${two(l.hour)}:${two(l.minute)} ';
  }

  String get statusLine {
    if (!loaded) return '';
    final when = checkedAt ?? syncedAt;
    final stamp = when == null ? '' : ' · ${_stamp(when).trim()} 校验';
    return '共 $total 首$stamp${fromCache && syncing ? ' · 正在后台检查更新…' : ''}';
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    tracks = [];
    session.removeListener(_sessionChanged);
    super.dispose();
  }
}
