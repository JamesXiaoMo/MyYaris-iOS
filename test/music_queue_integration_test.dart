import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/contracts.dart';
import 'package:myyaris_ios/api/music_queue_browser.dart';
import 'widget_test.dart' show FixtureSession;
import 'music_queue_contract_test.dart' show fixture;

http.Response reply(Object value, [int code = 200]) => http.Response(
  jsonEncode(value),
  code,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
FixtureSession sessionWith(http.Client client) => FixtureSession(
  api: BackendApi(baseUrl: 'https://backend.example.test', client: client)
    ..token = 'fixture',
)..userProfile = {'role': 'admin'};
Map<String, dynamic> actual({String mode = 'list_loop', int seq = 10}) {
  final now = DateTime.now().toUtc().toIso8601String();
  return {
    'device_id': 'car_p3pro',
    'queue_id': 'fixture-queue',
    'queue_version': 1,
    'queue_source': 'netease_favorite',
    'applied_mode': mode,
    'requested_mode': 'shuffle',
    'capabilities': ['queue_v2'],
    'status_seq': seq,
    'current_track_id': 'netease_1',
    'last_heartbeat_at': now,
    'updated_at': now,
    'playback_state': 'paused',
  };
}

class QueueProbeApi extends BackendApi {
  QueueProbeApi(http.Client client)
    : super(baseUrl: 'https://backend.example.test', client: client);
  int probes = 0;
  @override
  Future<Map<String, dynamic>> ensureOnlinePlayable(
    Map<String, dynamic> track,
  ) async {
    probes++;
    return {'status': 'playable'};
  }
}

void main() {
  test('device permission blocks queue actions before any request', () async {
    var requests = 0;
    final s = BackendSession(
      api: BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((_) async {
          requests++;
          return reply({});
        }),
      ),
    );
    addTearDown(s.dispose);
    s.authenticated = true;
    s.userProfile = {'role': 'admin', 'has_device_control': false};
    s.playback = actual();
    await expectLater(
      s.choosePlaybackMode('intelligence'),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(
      s.playFavoriteTrack({'song_id': 1}),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, 0);
  });

  test(
    'dual envelope actual status rejects late sequence; command applied never substitutes mode',
    () {
      final s = sessionWith(MockClient((_) async => reply({})));
      addTearDown(s.dispose);
      s.acceptPlaybackPatch(MusicContract.statusPatch({'data': actual()}));
      expect(s.appliedQueueMode, 'list_loop');
      s.lastCommandState = {'command_id': 'fixture-cmd', 'status': 'accepted'};
      s.acceptCommandState({
        'command_id': 'fixture-cmd',
        'status': 'applied',
        'applied_mode': 'shuffle',
      });
      expect(s.appliedQueueMode, 'list_loop');
      expect(
        s.acceptPlaybackPatch(
          MusicContract.statusPatch(actual(mode: 'shuffle', seq: 9)),
        ),
        false,
      );
      expect(s.appliedQueueMode, 'list_loop');
      s.acceptPlaybackPatch(
        MusicContract.statusPatch({'data': actual(mode: 'shuffle', seq: 11)}),
      );
      expect(s.appliedQueueMode, 'shuffle');
    },
  );
  test(
    'seek aliases conflict fails locally; V2 mode has no legacy shuffle fallback',
    () {
      final origin = Uri.parse('https://backend.example.test');
      expect(
        () => MusicContract.params('seek', {
          'seek_ms': 10,
          'position_ms': 20,
        }, origin),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        MusicContract.params('seek', {
          'seek_ms': 10,
          'seek_position_ms': 10,
          'position_ms': 10,
        }, origin),
        {'seek_ms': 10},
      );
      expect(
        MusicContract.params('set_playback_mode', {
          'mode': 'shuffle',
          'expected_queue_id': 'q',
          'expected_queue_version': 1,
        }, origin),
        {
          'mode': 'shuffle',
          'expected_queue_id': 'q',
          'expected_queue_version': 1,
        },
      );
    },
  );
  for (final activeSingle in [false, true]) {
    test(
      'cold snapshot to one favorite intent, active single=$activeSingle',
      () async {
        final requests = <http.Request>[];
        final api = QueueProbeApi(
          MockClient((r) async {
            requests.add(r);
            if (r.method == 'GET') return reply(fixture(0, 50));
            final body = jsonDecode(r.body);
            return reply({
              'command_id': body['command_id'],
              'lifecycle_status': 'queued',
            });
          }),
        )..token = 'fixture';
        final s = FixtureSession(api: api)..userProfile = {'role': 'admin'};
        addTearDown(s.dispose);
        s.playback = actual();
        if (activeSingle) {
          s.playback.addAll({
            'queue_id': 'actual-single',
            'queue_version': 9,
            'queue_source': 'single_track',
          });
        } else {
          s.playback.remove('queue_id');
          s.playback.remove('queue_version');
          s.playback.remove('queue_source');
        }
        await s.playFavoriteTrack({'song_id': 1});
        expect(requests.where((r) => r.method == 'POST').length, 1);
        expect(
          requests.first.url.queryParameters['source'],
          'netease_favorite',
        );
        final body = jsonDecode(requests.last.body);
        expect(body['action'], 'play_track');
        final params = body['params'];
        expect(params['source'], 'netease_favorite');
        expect(params['queue_id'], 'fixture-queue');
        expect(params['queue_version'], 1);
        expect(params['queue_index'], 0);
        expect(params['song_id'], 1);
        expect(
          params['expected_queue_id'],
          activeSingle ? 'actual-single' : null,
        );
        expect(params['expected_queue_version'], activeSingle ? 9 : null);
        expect(s.playback['queue_id'], activeSingle ? 'actual-single' : null);
        expect(api.probes, 1);
      },
    );
  }
  for (final pair in {
    409: 'QUEUE_VERSION_CONFLICT',
    404: 'TRACK_NOT_IN_QUEUE',
    422: 'QUEUE_INDEX_MISMATCH',
    403: 'OWNER_QUEUE_PERMISSION_DENIED',
  }.entries) {
    test(
      'favorite server error ${pair.key} never falls back or retries',
      () async {
        var posts = 0;
        final api = QueueProbeApi(
          MockClient((r) async {
            if (r.method == 'GET') return reply(fixture(0, 50));
            posts++;
            return reply({
              'detail': {'error_code': pair.value},
            }, pair.key);
          }),
        )..token = 'fixture';
        final s = FixtureSession(api: api)..userProfile = {'role': 'admin'};
        addTearDown(s.dispose);
        s.playback = actual();
        await expectLater(
          s.playFavoriteTrack({'song_id': 1}),
          throwsA(
            isA<ApiFailure>().having((e) => e.errorCode, 'code', pair.value),
          ),
        );
        expect(posts, 1);
        expect(s.playback['queue_id'], 'fixture-queue');
      },
    );
  }
  test(
    'favorite lookup duplicate blocked, late account response sends zero commands',
    () async {
      final pending = Completer<http.Response>();
      var gets = 0, posts = 0;
      final api = QueueProbeApi(
        MockClient((r) async {
          if (r.method == 'GET') {
            gets++;
            return pending.future;
          }
          posts++;
          return reply({});
        }),
      )..token = 'fixture';
      final s = FixtureSession(api: api)..userProfile = {'role': 'admin'};
      addTearDown(s.dispose);
      s.playback = actual();
      final first = s.playFavoriteTrack(
        {'song_id': 1},
        queueId: 'fixture-queue',
        queueVersion: 1,
      );
      final rejected = expectLater(first, throwsA(isA<ApiFailure>()));
      await expectLater(
        s.playFavoriteTrack({'song_id': 1}),
        throwsA(isA<ApiFailure>()),
      );
      api.token = 'other-fixture';
      pending.complete(reply(fixture(0, 50)));
      await rejected;
      expect(gets, 1);
      expect(posts, 0);
      expect(api.probes, 0);
    },
  );
  test('favorite non-member and source mismatch send no command', () async {
    for (final wrongSource in [false, true]) {
      var posts = 0;
      final api = QueueProbeApi(
        MockClient((r) async {
          if (r.method == 'POST') {
            posts++;
            return reply({});
          }
          final data = fixture(0, 50);
          if (wrongSource) {
            data['source'] = 'single_track';
          } else {
            data['total'] = 50;
            data['has_more'] = false;
          }
          return reply(data);
        }),
      )..token = 'fixture';
      final s = FixtureSession(api: api)..userProfile = {'role': 'admin'};
      s.playback = actual();
      await expectLater(
        s.playFavoriteTrack({'song_id': 999}),
        throwsA(isA<ApiFailure>()),
      );
      expect(posts, 0);
      expect(api.probes, 0);
      s.dispose();
    }
  });
  test(
    'pinned browser snapshot keeps identity through member pagination',
    () async {
      final requests = <http.Request>[];
      final api = QueueProbeApi(
        MockClient((r) async {
          requests.add(r);
          if (r.method == 'GET') {
            expect(r.url.queryParameters['queue_id'], 'fixture-queue');
            expect(r.url.queryParameters['queue_version'], '1');
            final offset = int.parse(r.url.queryParameters['offset']!);
            return reply(fixture(offset, offset == 0 ? 50 : 15));
          }
          final b = jsonDecode(r.body);
          return reply({
            'command_id': b['command_id'],
            'lifecycle_status': 'queued',
          });
        }),
      )..token = 'fixture';
      final s = FixtureSession(api: api)..userProfile = {'role': 'admin'};
      addTearDown(s.dispose);
      s.playback = actual();
      await s.playFavoriteTrack(
        {'song_id': 65},
        queueId: 'fixture-queue',
        queueVersion: 1,
      );
      expect(requests.length, 3);
      expect(jsonDecode(requests.last.body)['params']['queue_index'], 64);
      await expectLater(
        s.playFavoriteTrack({'song_id': 65}),
        throwsA(isA<ApiFailure>()),
      );
      expect(requests.length, 3);
    },
  );
  test(
    'favorite target schema validates index and separates actual precondition',
    () {
      final params = {
        'track_id': 'netease_1',
        'song_id': 1,
        'source': 'netease_favorite',
        'stream_url':
            'https://backend.example.test/api/v1/music/netease/stream/1',
        'queue_id': 'browse',
        'queue_version': 8,
        'queue_index': 0,
        'expected_queue_id': 'actual',
        'expected_queue_version': 3,
      };
      final validated = MusicContract.params(
        'play_track',
        params,
        Uri.parse('https://backend.example.test'),
      );
      expect(validated['queue_id'], 'browse');
      expect(validated['expected_queue_id'], 'actual');
      for (final patch in [
        {'queue_version': 0},
        {'queue_id': ''},
        {'queue_index': -1},
      ]) {
        expect(
          () => MusicContract.params('play_track', {
            ...params,
            ...patch,
          }, Uri.parse('https://backend.example.test')),
          throwsA(isA<ApiFailure>()),
        );
      }
    },
  );
  test(
    'owner 403 not logout or device-permission revocation; 401 still expires session',
    () async {
      var status = 403, expired = 0, denied = 0;
      final api =
          BackendApi(
              baseUrl: 'https://backend.example.test',
              client: MockClient(
                (_) async => reply({
                  'detail': {'error_code': 'OWNER_QUEUE_PERMISSION_DENIED'},
                }, status),
              ),
            )
            ..token = 'fixture'
            ..isUserSession = true
            ..onSessionExpired = () async {
              expired++;
            }
            ..onDeviceForbidden = (_) {
              denied++;
            };
      addTearDown(api.close);
      await expectLater(
        api.call('POST', '/api/v1/music/control/command'),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.errorCode,
            'code',
            'OWNER_QUEUE_PERMISSION_DENIED',
          ),
        ),
      );
      expect(expired, 0);
      expect(denied, 0);
      status = 401;
      await expectLater(
        api.call('GET', '/api/v1/music/queue'),
        throwsA(isA<ApiFailure>()),
      );
      expect(expired, 1);
    },
  );
  testWidgets(
    'queue browser pins 65-song pages and never emits writes on entry',
    (tester) async {
      final requests = <http.Request>[];
      final s = sessionWith(
        MockClient((r) async {
          requests.add(r);
          return reply(
            fixture(
              r.url.queryParameters['offset'] == '0' ? 0 : 50,
              r.url.queryParameters['offset'] == '0' ? 50 : 15,
            ),
          );
        }),
      );
      addTearDown(s.dispose);
      await tester.pumpWidget(MaterialApp(home: MusicQueueBrowser(session: s)));
      await tester.pumpAndSettle();
      expect(find.textContaining('50 / 65'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('加载更多'), 500, maxScrolls: 15);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(requests.length, 2);
      expect(requests.every((r) => r.method == 'GET'), true);
      expect(requests.last.url.queryParameters['queue_id'], 'fixture-queue');
      expect(requests.last.url.queryParameters['queue_version'], '1');
    },
  );
  testWidgets(
    'queue version 409 discards all partial pages, no automatic retry',
    (tester) async {
      var count = 0;
      final s = sessionWith(
        MockClient((_) async {
          count++;
          return count == 1
              ? reply(fixture(0, 50))
              : reply({'error_code': 'QUEUE_VERSION_CONFLICT'}, 409);
        }),
      );
      addTearDown(s.dispose);
      await tester.pumpWidget(MaterialApp(home: MusicQueueBrowser(session: s)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('加载更多'), 500, maxScrolls: 15);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未混合分页'), findsOneWidget);
      expect(find.textContaining('50 / 65'), findsNothing);
      expect(count, 2);
    },
  );
  testWidgets(
    'mode menu shows applied and pending distinctly; missing capability disables all mode actions',
    (tester) async {
      var requests = 0;
      final s = sessionWith(
        MockClient((_) async {
          requests++;
          return reply({});
        }),
      );
      addTearDown(s.dispose);
      s.playback = actual()..['capabilities'] = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QueueModeCaption(session: s)),
        ),
      );
      expect(find.textContaining('已应用：'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('queue-mode-menu')));
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('queue-mode-intelligence')),
      );
      expect(tile.enabled, false);
      expect(requests, 0);
    },
  );
  testWidgets('late account-switch response does not leak prior queue', (
    tester,
  ) async {
    final late = Completer<http.Response>();
    var first = true;
    final s = sessionWith(
      MockClient((_) async {
        if (first) {
          first = false;
          return late.future;
        }
        return reply({'error_code': 'OWNER_QUEUE_PERMISSION_DENIED'}, 403);
      }),
    );
    addTearDown(s.dispose);
    await tester.pumpWidget(MaterialApp(home: MusicQueueBrowser(session: s)));
    await tester.pump();
    s.api.token = 'new-fixture';
    s.userProfile = {'role': 'user'};
    s.publish();
    await tester.pump();
    late.complete(reply(fixture(0, 50)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Owner喜欢歌单权限'), findsOneWidget);
    expect(find.textContaining('50 / 65'), findsNothing);
  });
  test(
    'explicit mode change emits one V2 command with actual precondition, never fakes applied',
    () async {
      final requests = <http.Request>[];
      final s = sessionWith(
        MockClient((r) async {
          requests.add(r);
          final body = jsonDecode(r.body);
          return reply({
            'command_id': body['command_id'],
            'lifecycle_status': 'queued',
          });
        }),
      );
      addTearDown(s.dispose);
      s.playback = actual();
      await s.choosePlaybackMode('shuffle');
      expect(requests.length, 1);
      final body = jsonDecode(requests.single.body);
      expect(body['action'], 'set_playback_mode');
      expect(body['params'], {
        'mode': 'shuffle',
        'expected_queue_id': 'fixture-queue',
        'expected_queue_version': 1,
      });
      expect(s.appliedQueueMode, 'list_loop');
    },
  );
  test('unreviewed car capability cannot fall back to legacy modes', () async {
    var requests = 0;
    final s = sessionWith(
      MockClient((_) async {
        requests++;
        return reply({});
      }),
    );
    addTearDown(s.dispose);
    s.playback = actual()..['capabilities'] = [];
    await expectLater(
      s.choosePlaybackMode('intelligence'),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests, 0);
  });
}
