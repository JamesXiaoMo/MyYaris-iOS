import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';

class StubSocket implements WebSocket {
  StubSocket(this.onSend);
  final void Function(dynamic) onSend;
  @override
  int get readyState => WebSocket.open;
  @override
  void add(dynamic data) => onSend(data);
  @override
  Future<void> close([int? code, String? reason]) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'command follows live params schema and uses header auth only',
    () async {
      late http.Request captured;
      final api = BackendApi(
        client: MockClient((r) async {
          captured = r;
          return http.Response('{"status":"ok"}', 200);
        }),
      )..token = 'test-only-token';
      await api.command('seek', {'seek_ms': 42000});
      final body = jsonDecode(captured.body) as Map;
      expect(body['params'], {'seek_ms': 42000});
      expect(body.containsKey('payload'), false);
      expect(body['command_id'], isNotEmpty);
      expect(captured.headers['Authorization'], 'Bearer test-only-token');
      expect(captured.url.queryParameters.containsKey('token'), false);
      expect(captured.followRedirects, false);
      api.close();
    },
  );
  test('stream URL uses configured private origin, not returned localhost', () {
    final api = BackendApi();
    expect(
      api.canonicalStream({
        'id': 123,
        'stream_url': 'http://127.0.0.1:8000/api/v1/music/netease/stream/123',
      }),
      '$defaultBackend/api/v1/music/netease/stream/123',
    );
    api.close();
  });
  test(
    'invalid URL and unauthenticated commands fail before request',
    () async {
      expect(
        () => BackendApi.validateBase('http://127.0.0.1:8000'),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        () => BackendApi.validateBase('https://example.com?token=secret'),
        throwsA(isA<ApiFailure>()),
      );
      final api = BackendApi(
        client: MockClient((r) async => throw StateError('must not send')),
      );
      await expectLater(api.command('pause'), throwsA(isA<ApiFailure>()));
      api.close();
    },
  );
  test(
    'server failure does not blindly retry a write or expose body',
    () async {
      var requests = 0;
      final api = BackendApi(
        client: MockClient((r) async {
          requests++;
          return http.Response('{"cookie":"private"}', 500);
        }),
      )..token = 'test-only';
      try {
        await api.command('next');
        fail('should fail');
      } on ApiFailure catch (e) {
        expect(e.message, contains('500'));
        expect(e.message, isNot(contains('private')));
      }
      expect(requests, 1);
      api.close();
    },
  );
  test('task label never claims navigation has started', () {
    final s = BackendSession(requireUserLogin: false);
    s.lastTask = {'status': 'launch_requested'};
    expect(s.taskLabel, '已请求打开 NAVITIME');
    s.dispose();
  });
  test('realtime partial state merges and ignores a different device', () {
    final session = BackendSession(requireUserLogin: false);
    session.playback = {'software_volume': .6};
    session.consumeRealtime(
      jsonEncode({
        'type': 'status_update',
        'data': {'device_id': 'another-car', 'playback_state': 'playing'},
      }),
    );
    expect(session.playback['playback_state'], isNull);
    session.consumeRealtime(
      jsonEncode({
        'type': 'status_update',
        'data': {'device_id': 'car_p3pro', 'playback_state': 'playing'},
      }),
    );
    expect(session.playback['software_volume'], .6);
    expect(session.playing, true);
    session.dispose();
  });
  test('WebSocket command ack completes once without HTTP duplicate', () async {
    var requests = 0;
    final api = BackendApi(
      client: MockClient((r) async {
        requests++;
        return http.Response('{}', 200);
      }),
    )..token = 'test-only';
    final session = BackendSession(requireUserLogin: false, api: api);
    session.socket = StubSocket((raw) {
      final message = jsonDecode(raw as String) as Map;
      expect(message['data']['params'], {'loop_mode': 'one'});
      session.consumeRealtime(
        jsonEncode({
          'type': 'command_ack',
          'status': 'ok',
          'command_id': message['data']['command_id'],
        }),
      );
    });
    await session.sendCommand('set_loop', {'loop_mode': 'one'});
    expect(requests, 0);
    expect(session.pendingCommands, isEmpty);
    session.dispose();
  });
  test(
    'lost realtime connection yields unknown result without replay',
    () async {
      var requests = 0;
      final api = BackendApi(
        client: MockClient((r) async {
          requests++;
          return http.Response('{}', 200);
        }),
      )..token = 'test-only';
      final session = BackendSession(requireUserLogin: false, api: api)
        ..socket = StubSocket((_) {});
      final future = session.sendCommand('next');
      final assertion = expectLater(future, throwsA(isA<ApiFailure>()));
      session.disconnected(session.generation);
      await assertion;
      expect(requests, 0);
      session.dispose();
    },
  );
  test(
    'audio upload uses multipart, target device, idempotency and header auth',
    () async {
      final api = BackendApi(
        client: MockClient((r) async {
          if (r.url.path == '/health') {
            return http.Response(
              '{"capabilities":{"voice":{"asr_ready":true,"nlp_ready":true,"resolve_only":true,"mock":false}}}',
              200,
            );
          }
          expect(r.url.path, '/voice');
          expect(r.method, 'POST');
          expect(r.headers['Authorization'], 'Bearer test-only');
          expect(r.body, contains('name="target_device_id"'));
          expect(r.body, contains('name="idempotency_key"'));
          expect(r.body, contains('filename="test.wav"'));
          expect(r.followRedirects, false);
          return http.Response(
            '{"request_id":"voice-1","status":"resolving"}',
            200,
          );
        }),
      )..token = 'test-only';
      final result = await api.uploadAudio(
        Uint8List.fromList([1, 2, 3]),
        'test.wav',
      );
      expect(result['request_id'], 'voice-1');
      api.close();
    },
  );
  test('requested song metadata does not pretend the car already switched', () {
    final session = BackendSession(requireUserLogin: false);
    session.currentTrack = {'track_id': 'old', 'title': '旧曲'};
    session.rememberTrack({'id': 123, 'title': '请求曲目'});
    expect(session.currentTrack['title'], '旧曲');
    session.consumeRealtime(
      jsonEncode({
        'type': 'status_update',
        'data': {'current_track_id': 'netease_123'},
      }),
    );
    expect(session.currentTrack['title'], '请求曲目');
    session.dispose();
  });
}
