import 'backend.dart' show ApiFailure;

/// User intent only. Transport/queue ownership must use the frozen three-end
/// contract; this does not turn existing loop/shuffle into a favorite queue.
enum FavoritePlaybackIntent {
  loop('喜欢歌单循环'),
  shuffle('喜欢歌单随机'),
  intelligence('网易云心动');

  const FavoritePlaybackIntent(this.label);
  final String label;
}

/// Current NetEase intelligence response guard. Similar-song fallback is never
/// relabelled as the requested intelligence mode or sent as a playback queue.
List<Map<String, dynamic>> requireTrueIntelligence(
  Map<String, dynamic> response,
) {
  if (response['mode'] != 'intelligence') {
    throw ApiFailure('网易云心动模式暂不可用，未切换为相似歌曲或普通随机');
  }
  final songs = response['songs'];
  if (songs is! List || songs.isEmpty || songs.length > 100) {
    throw ApiFailure('心动模式暂时没有可用歌曲，请稍后重试');
  }
  final seen = <int>{};
  final tracks = <Map<String, dynamic>>[];
  for (final song in songs) {
    if (song is! Map) throw ApiFailure('心动歌曲信息异常，请稍后重试');
    final id = song['id'];
    if (id is! int || id <= 0) {
      throw ApiFailure('心动歌曲信息不完整，请稍后重试');
    }
    if (seen.add(id)) tracks.add(Map<String, dynamic>.from(song));
  }
  return tracks;
}
