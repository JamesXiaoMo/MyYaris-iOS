import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/music_home.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/netease_account_view.dart';
import 'widget_test.dart' show FixtureSession;

http.Response response(Object value, [int code = 200]) => http.Response(
  jsonEncode(value),
  code,
  headers: {'content-type': 'application/json'},
);
void main() {
  test(
    'NetEase nickname and UID are separate, scoped to admin; HTTP error is not logged out',
    () async {
      var status = 200;
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient(
          (_) async => response({
            'logged_in': true,
            'user_id': 123,
            'nickname': 'fixture',
            'avatar_url': 'https://example.org/avatar',
            'vip_type': 11,
            'cookie': 'must-not-be-copied',
          }, status),
        ),
      )..token = 'fixture';
      final session = FixtureSession(api: api)..userProfile = {'role': 'admin'};
      final model = NeteaseAccountView(session);
      addTearDown(model.dispose);
      addTearDown(session.dispose);
      await model.refresh();
      expect(model.headline, 'fixture');
      expect(model.userIdLine, 'UID：123');
      expect(model.profile.containsKey('cookie'), false);
      session.userProfile = {'role': 'user'};
      model.accountChanged();
      await Future<void>.delayed(Duration.zero);
      expect(model.profile, {'logged_in': true});
      expect(model.manager, false);
      expect(model.headline, '网易云已连接');
      expect(model.userIdLine, '账号资料仅管理员可见');
      status = 503;
      await model.refresh();
      expect(model.loaded, false);
      expect(model.headline, '网易云账号状态未知');
      expect(model.error, isNotNull);
    },
  );
  test('session/domain switch drops late private account response', () async {
    final old = Completer<http.Response>();
    final api = BackendApi(
      baseUrl: 'https://backend.example.test',
      client: MockClient(
        (r) async => r.headers['Authorization'] == 'Bearer old'
            ? old.future
            : response({'logged_in': false}),
      ),
    )..token = 'old';
    final session = FixtureSession(api: api)..userProfile = {'role': 'admin'};
    final model = NeteaseAccountView(session);
    addTearDown(model.dispose);
    addTearDown(session.dispose);
    final first = model.refresh();
    api.token = 'new';
    api.baseUrl = 'https://other.example';
    model.accountChanged();
    await Future<void>.delayed(Duration.zero);
    old.complete(
      response({
        'logged_in': true,
        'user_id': 999,
        'avatar_url': 'https://example.org/private',
      }),
    );
    await first;
    expect(model.profile, {'logged_in': false});
    expect(model.profile.containsKey('user_id'), false);
  });
  testWidgets(
    'music home removes old controls; search/player routes stay local and do not issue commands',
    (tester) async {
      final writes = <String>[];
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          if (r.method != 'GET') writes.add(r.url.path);
          return response({'logged_in': false});
        }),
      )..token = 'fixture';
      final session = FixtureSession(api: api)..userProfile = {'role': 'admin'};
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MusicPage(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索曲库，选择歌曲发送到车机播放。'), findsNothing);
      expect(find.byType(PlaybackPanel), findsNothing);
      final record = tester.widget<VinylRecord>(
        find.byKey(const ValueKey('music-record-open')),
      );
      final cover = tester.widget<MusicArtwork>(
        find.byKey(const ValueKey('vinyl-cover')),
      );
      expect(cover.size, record.size * .64);
      expect(find.byKey(const ValueKey('music-input')), findsNothing);
      expect(find.byKey(const ValueKey('liked-music-entry')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('music-search-open')));
      await tester.pumpAndSettle();
      expect(find.byType(MusicSearchPage), findsOneWidget);
      expect(find.byKey(const ValueKey('music-input')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('music-record-open')));
      await tester.pumpAndSettle();
      expect(find.byType(MusicPlayerPage), findsOneWidget);
      expect(find.byType(PlaybackPanel), findsOneWidget);
      expect(writes, isEmpty);
    },
  );
  testWidgets(
    'vinyl rotates on fresh actual playing only; pause holds angle and stale/reduced motion stops',
    (tester) async {
      final session = FixtureSession();
      addTearDown(session.dispose);
      void state(String status, {bool stale = false}) {
        final stamp = DateTime.now()
            .toUtc()
            .subtract(stale ? const Duration(minutes: 2) : Duration.zero)
            .toIso8601String();
        session.playback = {
          'playback_state': status,
          'last_heartbeat_at': stamp,
          'updated_at': stamp,
        };
        session.publish();
      }

      state('playing');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VinylRecord(session: session)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      Animation<double> turns() => tester
          .widget<RotationTransition>(
            find.byKey(const ValueKey('vinyl-rotation')),
          )
          .turns;
      expect(turns().value, greaterThan(0));
      state('paused');
      await tester.pump();
      final angle = turns().value;
      await tester.pump(const Duration(seconds: 1));
      expect(turns().value, angle);
      state('playing', stale: true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(turns().value, angle);
      state('playing');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(body: VinylRecord(session: session)),
          ),
        ),
      );
      await tester.pump();
      final reduced = turns().value;
      await tester.pump(const Duration(seconds: 1));
      expect(turns().value, reduced);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'artwork never attaches credentials or allows insecure/untrusted scheme',
    () {
      expect(musicArtworkUrl('http://example.org/a'), null);
      expect(musicArtworkUrl('https://user:pass@example.org/a'), null);
      expect(musicArtworkUrl('http://p1.music.126.net/a')?.scheme, 'https');
      expect(musicArtworkUrl(null), null);
    },
  );
}
