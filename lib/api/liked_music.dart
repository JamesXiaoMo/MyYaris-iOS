import 'dart:async';
import 'package:flutter/foundation.dart';
import 'backend.dart';

class LikedMusicPageData {
  LikedMusicPageData(
    this.tracks,
    this.total,
    this.offset,
    this.limit,
    this.hasMore,
    this.playlistId,
  );
  final List<Map<String, dynamic>> tracks;
  final int total, offset, limit, playlistId;
  final bool hasMore;

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
    );
  }
}

/// Memory-only metadata, scoped to the current user session and origin.
class LikedMusicController extends ChangeNotifier {
  LikedMusicController(this.session) {
    _identity = identity;
    session.addListener(_sessionChanged);
  }
  final BackendSession session;
  List<Map<String, dynamic>> tracks = [];
  int total = 0, nextOffset = 0, _epoch = 0;
  int? _playlistId;
  bool busy = false, loaded = false, hasMore = false, _disposed = false;
  String? error;
  late String _identity;
  String get identity =>
      '${session.api.baseUrl}\n${session.api.token}\n${session.userProfile['role']}';
  bool get allowed =>
      session.userSignedIn && session.userProfile['role'] == 'admin';

  void _sessionChanged() {
    if (identity == _identity) return;
    _identity = identity;
    _epoch++;
    tracks = [];
    _playlistId = null;
    total = nextOffset = 0;
    busy = loaded = hasMore = false;
    error = null;
    notifyListeners();
    if (allowed) unawaited(load(refresh: true));
  }

  Future<void> load({bool refresh = false}) async {
    if (_disposed || busy || (!refresh && loaded && !hasMore)) return;
    if (!allowed) {
      error = '仅服务器 Owner 的 MyYaris 管理员可查看此私人喜欢歌单';
      notifyListeners();
      return;
    }
    final epoch = ++_epoch, who = identity, offset = refresh ? 0 : nextOffset;
    busy = true;
    error = null;
    if (refresh) {
      tracks = [];
      _playlistId = null;
      loaded = hasMore = false;
      total = nextOffset = 0;
    }
    notifyListeners();
    bool current() =>
        !_disposed && _epoch == epoch && identity == who && allowed;
    try {
      final result = await session.api.call(
        'GET',
        '/api/v1/music/netease/playlist/favorite',
        query: {'limit': '30', 'offset': '$offset'},
      );
      if (!current()) return;
      final page = LikedMusicPageData.parse(result, offset);
      if (!refresh && _playlistId != null && _playlistId != page.playlistId) {
        tracks = [];
        loaded = hasMore = false;
        total = nextOffset = 0;
        _playlistId = null;
        throw ApiFailure('网易云账号或喜欢歌单已变更，请刷新后重试');
      }
      _playlistId = page.playlistId;
      final seen = {for (final track in tracks) track['song_id']};
      tracks = [
        ...tracks,
        ...page.tracks.where((track) => seen.add(track['song_id'])),
      ];
      total = page.total;
      nextOffset = page.offset + page.limit;
      hasMore = page.hasMore;
      loaded = true;
    } catch (e) {
      if (!current()) return;
      if (e is ApiFailure && e.statusCode == 403) {
        tracks = [];
        loaded = hasMore = false;
        total = nextOffset = 0;
        _playlistId = null;
      }
      error = switch (e) {
        ApiFailure(statusCode: 403) => '无权限：仅服务器 Owner 的 MyYaris 管理员可查看此私人喜欢歌单',
        ApiFailure(statusCode: 409) =>
          '后端网易云会话未授权或已失效，请管理者在设置中登录网易云；MyYaris 登录仍保留',
        ApiFailure(statusCode: 404) => '喜欢歌单未找到或后端接口尚未部署，请重试或联系管理者',
        ApiFailure(statusCode: 502 || 503 || 504) => '网易云上游暂不可用或超时，不是空歌单；请重试',
        ApiFailure() => e.message,
        _ => '喜欢歌单加载失败，请重试',
      };
    } finally {
      if (current()) {
        busy = false;
        notifyListeners();
      }
    }
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
