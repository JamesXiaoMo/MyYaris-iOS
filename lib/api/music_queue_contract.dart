import 'backend.dart' show ApiFailure;

/// Metadata-only parsing for the draft V2.2 contract. No network or playback.
/// UI/transport integration remains gated on the reviewed deployed contract.
class MusicQueuePage {
  MusicQueuePage._(
    this.id,
    this.version,
    this.source,
    this.total,
    this.established,
    this.offset,
    this.limit,
    this.hasMore,
    this.tracks,
  );
  static const sources = {
    'netease_favorite',
    'netease_intelligence',
    'single_track',
  };
  final String id, source;
  final int version, total, offset, limit;
  final bool established, hasMore;
  final List<Map<String, dynamic>> tracks;

  factory MusicQueuePage.fromJson(Map<String, dynamic> data) {
    final id = data['queue_id'],
        version = data['queue_version'],
        source = data['source'];
    final total = data['total'], offset = data['offset'], limit = data['limit'];
    final established = data['is_complete'],
        more = data['has_more'],
        rows = data['tracks'];
    if (id is! String ||
        id.isEmpty ||
        version is! int ||
        version < 1 ||
        source is! String ||
        !sources.contains(source) ||
        total is! int ||
        total < 0 ||
        offset is! int ||
        offset < 0 ||
        offset > total ||
        limit is! int ||
        limit < 1 ||
        limit > 100 ||
        established is! bool ||
        more is! bool ||
        rows is! List ||
        rows.length > limit ||
        offset + rows.length > total ||
        more != (offset + rows.length < total) ||
        (more && rows.isEmpty)) {
      throw ApiFailure('队列分页或版本格式不符，未启用新播放模式');
    }
    final tracks = <Map<String, dynamic>>[], seen = <String>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is! Map ||
          row['track_id'] is! String ||
          (row['track_id'] as String).isEmpty ||
          row['queue_index'] != offset + i ||
          !seen.add(row['track_id'])) {
        throw ApiFailure('队列曲目索引缺失或重复，未建立完整队列');
      }
      if (source != 'single_track' &&
          (row['id'] is! int ||
              row['id'] <= 0 ||
              row['track_id'] != 'netease_${row['id']}')) {
        throw ApiFailure('网易云队列曲目ID不符，未建立完整队列');
      }
      // Never forward an example/CDN/local HTTP URL from queue metadata as a
      // playable stream. Existing HTTPS resolution must validate each selection.
      tracks.add(
        Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(row)..remove('stream_url'),
        ),
      );
    }
    return MusicQueuePage._(
      id,
      version,
      source,
      total,
      established,
      offset,
      limit,
      more,
      List.unmodifiable(tracks),
    );
  }
}

class MusicQueueAccumulator {
  MusicQueuePage? _first;
  final List<Map<String, dynamic>> _tracks = [];
  final Set<String> _ids = {};
  bool _hasMore = false;
  List<Map<String, dynamic>> get tracks => List.unmodifiable(_tracks);
  bool get complete =>
      _first != null &&
      _first!.established &&
      !_hasMore &&
      _tracks.length == _first!.total;
  void add(MusicQueuePage page) {
    final first = _first;
    if (page.offset != _tracks.length ||
        (first != null &&
            (page.id != first.id ||
                page.version != first.version ||
                page.source != first.source ||
                page.total != first.total ||
                page.established != first.established ||
                !_hasMore)) ||
        page.tracks.any((track) => _ids.contains(track['track_id']))) {
      throw ApiFailure('队列版本已变化或分页重复，请清空后重读；未混合队列');
    }
    _first ??= page;
    _tracks.addAll(page.tracks);
    _ids.addAll(page.tracks.map((track) => track['track_id'] as String));
    _hasMore = page.hasMore;
  }
}
