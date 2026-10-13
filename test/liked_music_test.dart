import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/liked_music.dart';
import 'package:myyaris_ios/api/liked_music_page.dart';
import 'widget_test.dart' show FixtureSession;

Map<String, dynamic> song(int id) => {
  'id': id,
  'song_id': id,
  'source': 'netease',
  'title': '隔离测试曲目',
  'artist': '测试',
  'album': '测试专辑',
  'duration_ms': 123000,
  'cover_url': null,
  'playable': true,
  'fee': 0,
};
Map<String, dynamic> page(
  List<int> ids, {
  int offset = 0,
  bool more = false,
  int total = 60,
  int playlist = 123,
}) => {
  'code': 200,
  'playlist_id': playlist,
  'songs': ids.map(song).toList(),
  'total': total,
  'offset': offset,
  'limit': 30,
  'has_more': more,
};
http.Response reply(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
FixtureSession owner(http.Client client) => FixtureSession(
  api: BackendApi(client: client)
    ..token = 'isolated-admin-session'
    ..isUserSession = true,
)..userProfile = {'role': 'admin'};

void main() {
  test(
    'pagination uses offsets, deduplicates and never probes audio; duplicate request suppressed',
    () async {
      final requests = <Uri>[];
      final gate = Completer<http.Response>();
      final session = owner(
        MockClient((r) async {
          expect(r.method, 'GET');
          expect(r.headers['Authorization'], 'Bearer isolated-admin-session');
          requests.add(r.url);
          if (requests.length == 1) return gate.future;
          return reply(page([2, 3], offset: 30));
        }),
      );
      final model = LikedMusicController(session);
      addTearDown(() {
        model.dispose();
        session.dispose();
      });
      final first = model.load(refresh: true);
      await model.load();
      gate.complete(reply(page([1, 2], more: true)));
      await first;
      await model.load();
      await model.load();
      expect(model.tracks.map((x) => x['song_id']), [1, 2, 3]);
      expect(model.total, 60);
      expect(model.hasMore, false);
      expect(requests.map((x) => x.queryParameters['offset']), ['0', '30']);
      expect(
        requests.every(
          (x) =>
              x.path.endsWith('/playlist/favorite') &&
              x.queryParameters['limit'] == '30',
        ),
        true,
      );
    },
  );

  for (final status in [403, 409, 502, 504]) {
    test(
      'HTTP $status is distinct error, never empty playlist or session expiry',
      () async {
        final session = owner(
          MockClient(
            (r) async => reply({
              'detail': 'upstream private detail not surfaced',
            }, status),
          ),
        );
        var expired = false;
        session.api.onSessionExpired = () async {
          expired = true;
        };
        final model = LikedMusicController(session);
        addTearDown(() {
          model.dispose();
          session.dispose();
        });
        await model.load(refresh: true);
        expect(model.error, isNotNull);
        expect(model.loaded, false);
        expect(expired, false);
        expect(session.api.token, 'isolated-admin-session');
        expect(model.error, isNot(contains('private detail')));
      },
    );
  }

  test(
    '401 invalidates only MyYaris session and drops pending list data',
    () async {
      final session = owner(
        MockClient((r) async => reply({'detail': 'invalid session'}, 401)),
      );
      final model = LikedMusicController(session);
      addTearDown(() {
        model.dispose();
        session.dispose();
      });
      var expired = false;
      session.api.onSessionExpired = () async {
        expired = true;
        session.api.token = '';
        session.userProfile = {};
        session.publish();
      };
      await model.load(refresh: true);
      expect(expired, true);
      expect(model.tracks, isEmpty);
      expect(model.busy, false);
      expect(model.allowed, false);
    },
  );

  test(
    'ordinary role blocked without changing credentials or issuing request',
    () async {
      var requests = 0;
      final session = owner(
        MockClient((r) async {
          requests++;
          return reply(page([]));
        }),
      )..userProfile = {'role': 'user'};
      final model = LikedMusicController(session);
      addTearDown(() {
        model.dispose();
        session.dispose();
      });
      await model.load(refresh: true);
      expect(requests, 0);
      expect(model.error, contains('管理员'));
      expect(session.api.token, 'isolated-admin-session');
    },
  );

  test('late old account response cannot contaminate new account', () async {
    final old = Completer<http.Response>();
    final session = owner(
      MockClient(
        (r) async =>
            r.headers['Authorization'] == 'Bearer isolated-admin-session'
            ? old.future
            : reply(page([9])),
      ),
    );
    final model = LikedMusicController(session);
    addTearDown(() {
      model.dispose();
      session.dispose();
    });
    final first = model.load(refresh: true);
    session.api.token = 'isolated-second-session';
    session.publish();
    await Future<void>.delayed(Duration.zero);
    old.complete(reply(page([1, 2])));
    await first;
    expect(model.tracks.map((x) => x['song_id']), [9]);
    expect(model.busy, false);
  });

  test('playlist changes between pages clear previous private rows', () async {
    var count = 0;
    final session = owner(
      MockClient(
        (r) async => reply(
          ++count == 1
              ? page([1], more: true)
              : page([2], offset: 30, playlist: 456),
        ),
      ),
    );
    final model = LikedMusicController(session);
    addTearDown(() {
      model.dispose();
      session.dispose();
    });
    await model.load(refresh: true);
    await model.load();
    expect(model.tracks, isEmpty);
    expect(model.error, contains('已变更'));
  });

  test(
    'malformed or upstream failure is not a successful empty playlist; retry works',
    () async {
      var count = 0;
      final session = owner(
        MockClient(
          (r) async => reply(
            ++count == 1 ? {'code': 502, 'songs': []} : page([], total: 0),
          ),
        ),
      );
      final model = LikedMusicController(session);
      addTearDown(() {
        model.dispose();
        session.dispose();
      });
      await model.load(refresh: true);
      expect(model.loaded, false);
      expect(model.error, isNotNull);
      await model.load(refresh: true);
      expect(model.loaded, true);
      expect(model.error, isNull);
      expect(model.total, 0);
      expect(
        () => LikedMusicPageData.parse(page([], more: true), 0),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  testWidgets('list shows metadata and loading error retry without playing', (
    tester,
  ) async {
    var count = 0;
    final session = owner(
      MockClient(
        (r) async => reply(
          ++count == 1 ? {'detail': 'timeout'} : page([1]),
          count == 1 ? 504 : 200,
        ),
      ),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(home: LikedMusicPage(session: session)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('不是空歌单'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('隔离测试曲目'), findsOneWidget);
    expect(find.textContaining('song_id 1'), findsOneWidget);
    expect(count, 2);
    expect(tester.takeException(), isNull);
  });
}
