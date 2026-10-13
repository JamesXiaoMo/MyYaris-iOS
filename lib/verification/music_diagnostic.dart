import 'dart:convert';
import 'dart:typed_data';
import '../api/backend.dart';
import 'favorites_evidence.dart' show saveEvidence;

/// Read-only phone diagnosis; no song selection or playback commands.
Future<void> diagnoseOnlineMusic(BackendSession session) async {
  final proof = <String, dynamic>{
    'configured': session.api.configured,
    'diagnostic_revision': 'utc-v2',
    'run_at_utc': DateTime.now().toUtc().toIso8601String(),
    'target_device': session.api.deviceId,
    'commands_sent': false,
    'playback_end_to_end': false,
  };
  try {
    if (!session.api.configured) throw ApiFailure('手机Token未配置');
    try {
      final login = await session.api.call(
        'GET',
        '/api/v1/music/netease/login/status',
      );
      proof['netease_logged_in'] = login['logged_in'] == true;
    } catch (e) {
      proof['login_check_error'] = e is ApiFailure ? e.message : '授权状态查询失败';
    }
    final result = await session.api.searchOnline('晴天');
    proof['search'] = 'success';
    proof['keyword'] = '晴天';
    proof['total'] = result['total'];
    proof['songs'] = (result['songs'] as List)
        .take(3)
        .map(
          (item) => {
            'song_id': item['song_id'],
            'source': item['source'],
            'title': item['title'],
            'playability': 'not_checked',
          },
        )
        .toList();
  } catch (e) {
    proof['search'] = 'failed';
    proof['error'] = e is ApiFailure ? e.message : '搜索诊断失败';
  }
  await session.refresh();
  proof['reported_playback'] = {
    for (final key in [
      'device_id',
      'current_track_id',
      'playback_state',
      'position_ms',
      'duration_ms',
      'software_volume',
      'loop_mode',
      'last_heartbeat_at',
      'updated_at',
    ])
      if (session.playback.containsKey(key)) key: session.playback[key],
  };
  proof['heartbeat_fresh'] = session.heartbeatFresh;
  proof['navigation_idle_confirmed'] = false;
  session.musicDiagnostic = proof;
  session.publish();
  await saveEvidence(
    'music-stage1-proof.json',
    Uint8List.fromList(utf8.encode(jsonEncode(proof))),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  await KeychainStore.channel.invokeMethod<void>(
    'captureHome',
    'music-stage1-device.png',
  );
}
