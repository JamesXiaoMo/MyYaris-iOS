import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/contracts.dart';

const fixtureBackend = 'https://backend.example.test';

Map<String, dynamic> syncedOpenApi() => {
  'components': {
    'schemas': {
      'DestinationCreateRequest': {
        'properties': {
          'auto_create_task': {'type': 'boolean'},
        },
      },
      'TaskDestinationRequest': {
        'properties': {
          'target_device_id': {'type': 'string'},
        },
      },
    },
  },
  'paths': {
    '/api/v1/tasks/destination': {
      'post': {
        'requestBody': {
          'content': {
            'application/json': {
              'schema': {
                r'$ref': '#/components/schemas/TaskDestinationRequest',
              },
            },
          },
        },
      },
    },
  },
};

class AckSocket implements WebSocket {
  AckSocket(this.onSend);
  final void Function(dynamic) onSend;
  @override
  int get readyState => WebSocket.open;
  @override
  void add(dynamic value) => onSend(value);
  @override
  Future<void> close([int? code, String? reason]) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('all nine canonical commands and parameter aliases validate', () {
    final origin = Uri.parse(fixtureBackend);
    for (final action in ['pause', 'resume', 'stop', 'next', 'prev']) {
      expect(MusicContract.params(action, {}, origin), {});
    }
    expect(MusicContract.params('seek', {'seek_position_ms': 1234}, origin), {
      'seek_ms': 1234,
    });
    expect(MusicContract.params('set_loop', {'mode': 'single'}, origin), {
      'loop_mode': 'one',
    });
    expect(MusicContract.params('set_shuffle', {'shuffle': false}, origin), {
      'shuffle': false,
    });
    expect(MusicContract.params('set_volume', {'volume': .4}, origin), {
      'volume': .4,
    });
    expect(
      () => MusicContract.params('set_volume', {'volume': 1.01}, origin),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () => MusicContract.params('seek', {'seek_ms': -1}, origin),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () => MusicContract.params('set_shuffle', {'shuffle': 1}, origin),
      throwsA(isA<ApiFailure>()),
    );
    final api = BackendApi(baseUrl: 'https://backend.example.test');
    final online = api.trackParams({
      'id': 123,
      'source': 'netease',
      'title': '曲目',
    });
    expect(online['track_id'], 'netease_123');
    expect(online['source'], 'netease');
    expect(online['song_id'], 123);
    expect(
      online['stream_url'],
      '$fixtureBackend/api/v1/music/netease/stream/123',
    );
    expect(
      MusicContract.params('play_track', online, origin)['source'],
      'netease',
    );
    final cached = api.trackParams({
      'track_id': 'netease_123',
      'id': 99,
      'source': 'netease_cache',
    });
    expect(
      cached['stream_url'],
      '$fixtureBackend/api/v1/music/stream/netease_123',
    );
    expect(
      api.trackParams({
        'track_id': 'local_1',
        'source': 'local_repo',
      })['source'],
      'local_repo',
    );
    expect(
      () => MusicContract.params('play_track', {
        ...online,
        'stream_url': 'https://elsewhere.invalid/a',
      }, origin),
      throwsA(isA<ApiFailure>()),
    );
    api.close();
  });
  test('data ack completes same command ID once, not playback', () async {
    var sends = 0, httpSends = 0;
    final api = BackendApi(
      baseUrl: 'https://backend.example.test',
      client: MockClient((_) async {
        httpSends++;
        return http.Response('{}', 200);
      }),
    )..token = 'fake';
    final s = BackendSession(requireUserLogin: false, api: api);
    s.playback = {'playback_state': 'paused'};
    s.socket = AckSocket((raw) {
      sends++;
      final body = jsonDecode(raw as String)['data'];
      s.consumeRealtime(
        jsonEncode({
          'type': 'command_ack',
          'data': {
            'command_id': body['command_id'],
            'status': 'dispatched',
            'device_id': 'different',
          },
        }),
      );
      expect(s.lastCommandReceipt, isEmpty);
      s.consumeRealtime(
        jsonEncode({
          'type': 'command_ack',
          'data': {
            'command_id': body['command_id'],
            'status': 'dispatched',
            'device_id': 'car_p3pro',
          },
        }),
      );
    });
    await s.sendCommand('next', {}, 'intent-1');
    await s.sendCommand('next', {}, 'intent-1');
    expect(sends, 1);
    expect(httpSends, 0);
    expect(s.playback['playback_state'], 'paused');
    await expectLater(
      s.sendCommand('prev', {}, 'intent-1'),
      throwsA(isA<ApiFailure>()),
    );
    s.dispose();
  });
  test(
    'dual state envelope aliases, empty/invalid frame and other target cannot clear status',
    () {
      final s = BackendSession(requireUserLogin: false);
      s.playback = {
        'playback_state': 'playing',
        'position_ms': 900,
        'software_volume': .7,
      };
      s.consumeRealtime(jsonEncode({'type': 'status_update', 'data': {}}));
      s.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'data': {'device_id': 'different', 'playback_state': 'stopped'},
        }),
      );
      s.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'data': {'position_ms': 'bad', 'software_volume': 2},
        }),
      );
      expect(s.playback['position_ms'], 900);
      expect(s.playback['playback_state'], 'playing');
      s.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'data': {
            'device_id': 'ottocast_p3_pro',
            'position_ms': 1200,
            'shuffle_enabled': true,
          },
        }),
      );
      expect(s.playback['position_ms'], 1200);
      expect(s.playback['software_volume'], .7);
      s.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'device_id': 'car_p3pro',
          'position_ms': 1500,
          'shuffle': false,
        }),
      );
      expect(s.playback['position_ms'], 1500);
      expect(s.playback['shuffle_enabled'], false);
      s.dispose();
    },
  );
  test(
    'old unidentifiable resolve implementation is blocked before POST',
    () async {
      var posts = 0;
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          if (r.method == 'POST') posts++;
          return http.Response('{}', 200);
        }),
      )..token = 'fake';
      await expectLater(
        api.resolveDestination('34,132', 'r1'),
        throwsA(isA<ApiFailure>()),
      );
      expect(posts, 0);
      api.close();
    },
  );
  test(
    'pure resolve does not dispatch; selected candidate route and target match contract',
    () async {
      final writes = <http.Request>[];
      final api =
          BackendApi(
              baseUrl: 'https://backend.example.test',
              client: MockClient((r) async {
                if (r.method == 'POST') writes.add(r);
                if (r.url.path == '/openapi.json') {
                  return http.Response(jsonEncode(syncedOpenApi()), 200);
                }
                if (r.url.path == '/api/v1/destinations/resolve') {
                  return http.Response(
                    '{"destination_id":"d1","confidence":0.98}',
                    200,
                  );
                }
                return http.Response(
                  '{"task_id":"t1","device_id":"custom-car","status":"queued"}',
                  200,
                );
              }),
            )
            ..token = 'fake'
            ..deviceId = 'custom-car';
      await api.resolveDestination('34,132', 'r1');
      expect(writes.length, 1);
      expect(writes.first.url.path, '/api/v1/destinations/resolve');
      await api.dispatchDestination('d1', 'c2', 'k1');
      expect(writes.last.url.path, '/destinations/d1/confirm');
      expect(jsonDecode(writes.last.body)['candidate_id'], 'c2');
      expect(jsonDecode(writes.last.body)['target_device_id'], 'custom-car');
      await api.dispatchDestination('d2', 'only', 'k2', singleCandidate: true);
      expect(writes.last.url.path, '/api/v1/tasks/destination');
      api.close();
    },
  );
  test(
    'voice missing providers stops before multipart upload and no fake success',
    () async {
      var posts = 0;
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          if (r.method == 'POST') posts++;
          return http.Response('{"status":"ok"}', 200);
        }),
      )..token = 'fake';
      await expectLater(
        api.uploadAudio(Uint8List.fromList([1]), 'fake.wav'),
        throwsA(isA<ApiFailure>()),
      );
      expect(posts, 0);
      api.close();
    },
  );
  test(
    'command_status distinguishes execution receipt and never fakes playback',
    () async {
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient(
          (_) async => http.Response(
            '{"command_id":"c1","status":"ok","lifecycle_status":"queued"}',
            200,
          ),
        ),
      )..token = 'fake';
      final session = BackendSession(requireUserLogin: false, api: api);
      await session.sendCommand('resume', {}, 'c1');
      expect(session.commandLabel, contains('已排队'));
      session.consumeRealtime(
        jsonEncode({
          'type': 'command_status',
          'data': {
            'command_id': 'c1',
            'device_id': 'car_p3pro',
            'status': 'received',
          },
        }),
      );
      expect(session.commandLabel, contains('尚未确认执行'));
      session.consumeRealtime(
        jsonEncode({
          'type': 'command_status',
          'data': {
            'command_id': 'c1',
            'device_id': 'wrong',
            'status': 'applied',
          },
        }),
      );
      expect(session.lastCommandState['status'], 'received');
      session.consumeRealtime(
        jsonEncode({
          'type': 'command_status',
          'data': {
            'command_id': 'c1',
            'device_id': 'ottocast_p3_pro',
            'status': 'applied',
          },
        }),
      );
      expect(session.commandLabel, contains('操作已应用'));
      session.consumeRealtime(
        jsonEncode({
          'type': 'command_status',
          'data': {
            'command_id': 'c1',
            'device_id': 'car_p3pro',
            'status': 'received',
          },
        }),
      );
      expect(session.lastCommandState['status'], 'applied');
      expect(session.playing, false);
      session.dispose();
    },
  );
}
