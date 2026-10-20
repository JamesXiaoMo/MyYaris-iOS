import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/contracts.dart';
import 'widget_test.dart' show FixtureSession;

class ProbeClient extends http.BaseClient {
  int status = 206, reads = 0, extraReads = 0, commands = 0;
  bool aborted = false;
  String type = 'audio/mpeg', range = 'bytes 0-1023/4096';
  bool hasUrl = true;
  List<int> bytes = [73, 68, 51, ...List.filled(2045, 0)];
  Completer<void>? hold;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.headers['Authorization'], 'Bearer fixture');
    if (request.url.path.endsWith('/song_url')) {
      if (hold != null) await hold!.future;
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'song_id': 123,
              'url': hasUrl ? 'https://cdn.example/audio.mp3' : null,
            }),
          ),
        ),
        200,
      );
    }
    if (request.method == 'POST') {
      commands++;
      final body = jsonDecode((request as http.Request).body);
      expect(body['device_id'], 'car_p3pro');
      expect(body['params']['song_id'], 123);
      expect(body['params']['source'], 'netease');
      expect(
        body['params']['stream_url'],
        contains('/api/v1/music/netease/stream/123'),
      );
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'command_id': body['command_id'],
              'lifecycle_status': 'queued',
            }),
          ),
        ),
        200,
      );
    }
    expect(request.followRedirects, false);
    expect(request.headers['Range'], 'bytes=0-1023');
    (request as http.AbortableRequest).abortTrigger!.then(
      (_) => aborted = true,
    );
    Stream<List<int>> content() async* {
      reads++;
      yield bytes;
      extraReads++;
      yield List.filled(100000, 1);
    }

    return http.StreamedResponse(
      content(),
      status,
      headers: {
        'content-type': type,
        if (status == 206) 'content-range': range,
      },
    );
  }
}

void main() {
  test('SQLite naive UTC timestamp is not interpreted as phone local time', () {
    expect(
      MusicContract.backendTimestamp('2026-10-13T10:00:00'),
      DateTime.utc(2026, 10, 13, 10),
    );
    expect(
      MusicContract.backendTimestamp('2026-10-13T19:00:00+09:00'),
      DateTime.utc(2026, 10, 13, 10),
    );
    expect(MusicContract.backendTimestamp('invalid'), isNull);
    final api = BackendApi(baseUrl: 'https://backend.example.test')
      ..token = 'fixture';
    final session = BackendSession(requireUserLogin: false, api: api);
    addTearDown(session.dispose);
    final naive = DateTime.now().toUtc().toIso8601String().replaceFirst(
      'Z',
      '',
    );
    session.playback = {'last_heartbeat_at': naive, 'updated_at': naive};
    expect(session.heartbeatFresh, true);
    expect(session.playbackStale, false);
  });
  test(
    'configuration change during preflight does not send stale play command',
    () async {
      final client = ProbeClient()..hold = Completer<void>();
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: client,
      )..token = 'fixture';
      final session = BackendSession(requireUserLogin: false, api: api);
      addTearDown(session.dispose);
      final pending = session.playTrack({'id': 123, 'source': 'netease'});
      api.deviceId = 'different-car';
      client.hold!.complete();
      await expectLater(pending, throwsA(isA<ApiFailure>()));
      expect(client.commands, 0);
    },
  );
  test(
    'search errors are not empty success, and online IDs/source normalize',
    () async {
      var error = false, malformed = false;
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          expect(r.url.queryParameters['keyword'], '测试');
          return http.Response(
            jsonEncode(
              error
                  ? {'error_code': 'UPSTREAM_FAILED'}
                  : malformed
                  ? {}
                  : {
                      'total': 1,
                      'songs': [
                        {'song_id': 123, 'title': 'Fixture'},
                      ],
                    },
            ),
            error ? 502 : 200,
          );
        }),
      )..token = 'fixture';
      final result = await api.searchOnline('测试');
      expect(result['songs'][0]['id'], 123);
      expect(result['songs'][0]['source'], 'netease');
      error = true;
      expect(api.searchOnline('测试'), throwsA(isA<ApiFailure>()));
      error = false;
      malformed = true;
      expect(api.searchOnline('测试'), throwsA(isA<ApiFailure>()));
    },
  );
  test(
    'Range probe is bounded and aborted; does not read remaining audio',
    () async {
      final client = ProbeClient();
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: client,
      )..token = 'fixture';
      final result = await api.ensureOnlinePlayable({
        'id': 123,
        'source': 'netease',
      });
      await Future<void>.delayed(Duration.zero);
      expect(result['first_chunk_bytes'], 1024);
      expect(result['range_supported'], true);
      expect(client.aborted, true);
      expect(client.extraReads, 0);
      expect(client.commands, 0);
    },
  );
  test(
    'status/content type/range/audio header and unavailable resource block commands',
    () async {
      for (final kind in [
        '401',
        '502',
        'redirect',
        'json',
        'bad-range',
        'bad-audio',
        'no-url',
      ]) {
        final client = ProbeClient();
        if (kind == '401') client.status = 401;
        if (kind == '502') client.status = 502;
        if (kind == 'redirect') client.status = 302;
        if (kind == 'json') client.type = 'application/json';
        if (kind == 'bad-range') client.range = 'bytes 1-1024/4096';
        if (kind == 'bad-audio') client.bytes = utf8.encode('{"not":"audio"}');
        if (kind == 'no-url') client.hasUrl = false;
        final api = BackendApi(
          baseUrl: 'https://backend.example.test',
          client: client,
        )..token = 'fixture';
        final session = BackendSession(requireUserLogin: false, api: api);
        await expectLater(
          session.playTrack({'id': 123, 'source': 'netease'}),
          throwsA(isA<ApiFailure>()),
        );
        expect(client.commands, 0);
        expect(session.lastCommandState, isEmpty);
        session.dispose();
      }
    },
  );
  test(
    'double selection does one preflight and one command; queued is not playing',
    () async {
      final client = ProbeClient()..hold = Completer<void>();
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: client,
      )..token = 'fixture';
      final session = BackendSession(requireUserLogin: false, api: api);
      addTearDown(session.dispose);
      final first = session.playTrack({
        'id': 123,
        'source': 'netease',
        'title': 'Requested',
      });
      await expectLater(
        session.playTrack({'id': 123, 'source': 'netease'}),
        throwsA(isA<ApiFailure>()),
      );
      client.hold!.complete();
      await first;
      expect(client.commands, 1);
      expect(session.lastCommandState['status'], 'queued');
      expect(session.playing, false);
      expect(session.currentTrack, isEmpty);
      expect(session.awaitingExecution, true);
    },
  );
  testWidgets(
    'unknown state has no volume/seek defaults; drag sends once at end',
    (tester) async {
      final writes = <Map>[];
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          final data = jsonDecode(r.body) as Map;
          writes.add(data);
          return http.Response(
            jsonEncode({
              'command_id': data['command_id'],
              'lifecycle_status': 'queued',
            }),
            200,
          );
        }),
      )..token = 'fixture';
      final session = FixtureSession(api: api);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PlaybackPanel(session: session)),
          ),
        ),
      );
      expect(find.byType(Slider), findsNothing);
      expect(find.text('音量：暂无车机音量，未采用默认值'), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-mode-menu')), findsOneWidget);
      expect(find.textContaining('模式待确认'), findsOneWidget);
      final now = DateTime.now().toUtc().toIso8601String();
      session.playback = {
        'current_track_id': 'netease_123',
        'software_volume': .2,
        'loop_mode': 'all',
        'position_ms': 1000,
        'duration_ms': 100000,
        'updated_at': now,
        'last_heartbeat_at': now,
        'playback_state': 'paused',
      };
      session.publish();
      await tester.pump();
      final slider = tester.widget<Slider>(find.byType(Slider).last);
      slider.onChanged!(.3);
      slider.onChanged!(.4);
      slider.onChanged!(.5);
      expect(writes, isEmpty);
      slider.onChangeEnd!(.5);
      await tester.pumpAndSettle();
      expect(writes.length, 1);
      expect(writes.single['action'], 'set_volume');
      expect(writes.single['params']['volume'], .5);
      expect(session.playback['software_volume'], .2);
      expect(tester.widget<Slider>(find.byType(Slider).last).onChanged, isNull);
    },
  );
}
