import 'backend.dart' show ApiFailure;

/// Client-only validation. No mutation or secret logging.
class MusicContract {
  static const actions = {
    'play_track',
    'pause',
    'resume',
    'stop',
    'next',
    'prev',
    'seek',
    'set_loop',
    'set_shuffle',
    'set_volume',
    'set_playback_mode',
    'switch_queue',
  };
  static const queueModes = {
    'list_loop',
    'shuffle',
    'intelligence',
    'single_loop',
  };
  static String loop(Object? mode) => switch (mode) {
    'all' => 'all',
    'one' || 'single' => 'one',
    'off' || 'none' => 'off',
    _ => throw ApiFailure('不支持的循环模式'),
  };
  static Map<String, dynamic> params(
    String action,
    Map<String, dynamic> input,
    Uri origin,
  ) {
    if (!actions.contains(action)) throw ApiFailure('不支持的播放操作');
    switch (action) {
      case 'play_track':
        final id = '${input['track_id'] ?? ''}';
        final url = Uri.tryParse('${input['stream_url'] ?? ''}');
        if (id.isEmpty ||
            url == null ||
            url.scheme != 'https' ||
            url.origin != origin.origin ||
            !url.path.startsWith('/api/v1/music/')) {
          throw ApiFailure('曲目或私网流地址无效');
        }
        final source = input['source'];
        if (!{
          'local_repo',
          'netease_cache',
          'netease',
          'single_track',
          'netease_favorite',
        }.contains(source)) {
          throw ApiFailure('曲目来源无效');
        }
        if ((input['expected_queue_id'] != null &&
                (input['expected_queue_id'] is! String ||
                    (input['expected_queue_id'] as String).isEmpty)) ||
            (input['expected_queue_version'] != null &&
                (input['expected_queue_version'] is! int ||
                    input['expected_queue_version'] < 0))) {
          throw ApiFailure('队列前置条件无效');
        }
        if (source == 'netease_favorite' &&
            (input['queue_id'] is! String ||
                (input['queue_id'] as String).isEmpty ||
                input['queue_version'] is! int ||
                input['queue_version'] <= 0 ||
                (input['queue_index'] != null &&
                    (input['queue_index'] is! int ||
                        input['queue_index'] < 0)))) {
          throw ApiFailure('喜欢快照标识或索引无效');
        }
        return {
          'track_id': id,
          'stream_url': url.toString(),
          'source': source,
          if (source == 'netease_favorite') ...{
            'queue_id': input['queue_id'],
            'queue_version': input['queue_version'],
            if (input['queue_index'] != null)
              'queue_index': input['queue_index'],
          },
          if (input['expected_queue_id'] is String)
            'expected_queue_id': input['expected_queue_id'],
          if (input['expected_queue_version'] is int &&
              input['expected_queue_version'] >= 0)
            'expected_queue_version': input['expected_queue_version'],
          if (input['song_id'] != null) 'song_id': input['song_id'],
          if (input['title'] != null) 'title': input['title'],
          if (input['artist'] != null) 'artist': input['artist'],
        };
      case 'seek':
        final aliases = [
          'seek_ms',
          'seek_position_ms',
          'position_ms',
        ].where((k) => input[k] != null).map((k) => input[k]).toSet();
        if (aliases.length > 1) throw ApiFailure('进度参数冲突');
        final value =
            input['seek_ms'] ??
            input['seek_position_ms'] ??
            input['position_ms'];
        if (value is! num ||
            !value.isFinite ||
            value < 0 ||
            value != value.round()) {
          throw ApiFailure('播放进度必须是非负毫秒整数');
        }
        return {'seek_ms': value.toInt()};
      case 'set_playback_mode':
      case 'switch_queue':
        if (action == 'set_playback_mode' &&
            !queueModes.contains(input['mode'])) {
          throw ApiFailure('未知播放模式');
        }
        if (action == 'switch_queue' &&
            !{'netease_favorite', 'single_track'}.contains(input['source'])) {
          throw ApiFailure('未知队列来源');
        }
        final result = <String, dynamic>{
          if (action == 'set_playback_mode')
            'mode': input['mode']
          else
            'source': input['source'],
        };
        for (final key in ['expected_queue_id', 'start_track_id']) {
          if (input[key] != null) {
            if (input[key] is! String || (input[key] as String).isEmpty) {
              throw ApiFailure('队列参数无效');
            }
            result[key] = input[key];
          }
        }
        for (final key in [
          'expected_queue_version',
          'seed_song_id',
          'song_id',
          'start_index',
        ]) {
          if (input[key] != null) {
            if (input[key] is! int ||
                input[key] < 0 ||
                ((key == 'song_id' || key == 'seed_song_id') &&
                    input[key] == 0)) {
              throw ApiFailure('队列数字参数无效');
            }
            result[key] = input[key];
          }
        }
        return result;
      case 'set_loop':
        return {'loop_mode': loop(input['loop_mode'] ?? input['mode'])};
      case 'set_shuffle':
        if (input['shuffle'] is! bool) throw ApiFailure('随机播放必须是布尔值');
        return {'shuffle': input['shuffle']};
      case 'set_volume':
        final value = input['volume'];
        if (value is! num || !value.isFinite || value < 0 || value > 1) {
          throw ApiFailure('软件音量必须为 0～1');
        }
        return {'volume': value.toDouble()};
      default:
        return {};
    }
  }

  /// Backend UTC timestamps may lose timezone in SQLite serialization.
  static DateTime? backendTimestamp(Object? raw) {
    if (raw is! String) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    if (RegExp(
      r'(Z|[+-][0-9]{2}:?[0-9]{2})$',
      caseSensitive: false,
    ).hasMatch(raw)) {
      return parsed.toUtc();
    }
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }

  static Map<String, dynamic> statusPatch(Map raw) {
    raw = envelope(raw);
    final result = <String, dynamic>{};
    for (final field in ['applied_mode', 'requested_mode']) {
      if (raw.containsKey(field) &&
          (raw[field] == null || queueModes.contains(raw[field]))) {
        result[field] = raw[field];
      }
    }
    for (final field in [
      'queue_id',
      'queue_source',
      'last_applied_command_id',
      'error_code',
    ]) {
      if (raw.containsKey(field) &&
          (raw[field] == null || raw[field] is String)) {
        result[field] = raw[field];
      }
    }
    for (final field in [
      'queue_version',
      'current_index',
      'status_seq',
      'consecutive_failures',
    ]) {
      if (raw[field] is int && raw[field] >= 0) result[field] = raw[field];
    }
    if (raw['capabilities'] is List &&
        (raw['capabilities'] as List).every((v) => v is String)) {
      result['capabilities'] = List<String>.from(raw['capabilities']);
    }
    if (raw['device_id'] is String) result['device_id'] = raw['device_id'];
    if ({
      'playing',
      'paused',
      'stopped',
      'buffering',
    }.contains(raw['playback_state'])) {
      result['playback_state'] = raw['playback_state'];
    }
    if (raw.containsKey('current_track_id') &&
        (raw['current_track_id'] == null ||
            raw['current_track_id'] is String)) {
      result['current_track_id'] = raw['current_track_id'];
    }
    for (final field in ['position_ms', 'duration_ms']) {
      final value = raw[field];
      if (value is num &&
          value.isFinite &&
          value >= 0 &&
          value == value.round()) {
        result[field] = value.toInt();
      }
    }
    final volume = raw['software_volume'];
    if (volume is num && volume.isFinite && volume >= 0 && volume <= 1) {
      result['software_volume'] = volume.toDouble();
    }
    if ({'all', 'one', 'off', 'single', 'none'}.contains(raw['loop_mode'])) {
      result['loop_mode'] = loop(raw['loop_mode']);
    }
    final shuffle = raw['shuffle_enabled'] ?? raw['shuffle'];
    if (shuffle is bool) result['shuffle_enabled'] = shuffle;
    for (final field in ['last_heartbeat_at', 'updated_at']) {
      final value = raw[field];
      final timestamp = backendTimestamp(value);
      if (timestamp != null) result[field] = timestamp.toIso8601String();
    }
    if (result.keys.every(
      (key) => {'device_id', 'last_heartbeat_at', 'updated_at'}.contains(key),
    )) {
      return {};
    }
    return result;
  }

  static Map<String, dynamic> envelope(Map frame) =>
      frame['data'] is Map && (frame['data'] as Map).isNotEmpty
      ? Map<String, dynamic>.from(frame['data'] as Map)
      : Map<String, dynamic>.from(frame);
  static bool sameDevice(Object? reported, String configured) {
    if (reported == configured) return true;
    const aliases = {'car_p3pro', 'ottocast_p3_pro'};
    return aliases.contains(reported) && aliases.contains(configured);
  }
}
