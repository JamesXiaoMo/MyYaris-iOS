import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/main.dart';
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'user_auth_test.dart' show MemoryStore;
import 'widget_test.dart' show FixtureSession;

http.Response reply(Object value, [int code = 200]) => http.Response(
  jsonEncode(value),
  code,
  headers: {'content-type': 'application/json'},
);
BackendSession sessionFor(http.Client client, {MemoryStore? navigation}) =>
    BackendSession(
      api: BackendApi(baseUrl: 'https://backend.example.test', client: client)
        ..token = 'fixture-only',
      requireUserLogin: false,
      navigationStore: navigation ?? MemoryStore(),
    );

void main() {
  test(
    'WS track IDs resolve real metadata; progress/state follow reports, not command ACK',
    () async {
      final paths = <String>[];
      final s = sessionFor(
        MockClient((r) async {
          paths.add(r.url.path);
          return reply({
            'track_id': 'netease_42',
            'title': '测试曲目',
            'artist': '测试歌手',
          });
        }),
      );
      addTearDown(s.dispose);
      s.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'data': {
            'device_id': 'car_p3pro',
            'current_track_id': 'netease_42',
            'playback_state': 'playing',
            'position_ms': 32000,
            'duration_ms': 180000,
            'last_heartbeat_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(s.homeMusicTitle, '测试曲目');
      expect(s.homeMusicDetail, '测试歌手 0:32 / 3:00');
      expect(s.homeMusicState, '正在播放');
      s.consumeRealtime(
        jsonEncode({
          'type': 'command_ack',
          'data': {'command_id': 'unissued', 'status': 'accepted'},
        }),
      );
      expect(s.homeMusicState, '正在播放');
      s.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'data': {'playback_state': 'paused', 'position_ms': 34000},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(s.homeMusicState, '已暂停');
      expect(s.homeMusicDetail, contains('0:34'));
      expect(paths, ['/api/v1/music/tracks/netease_42']);
      s.playback['last_heartbeat_at'] = DateTime.now()
          .subtract(const Duration(minutes: 2))
          .toIso8601String();
      expect(s.homeMusicState, '状态待更新');
    },
  );
  test(
    'late metadata cannot overwrite newer track or another account',
    () async {
      final slow = Completer<http.Response>();
      final s = sessionFor(
        MockClient(
          (r) => r.url.path.endsWith('/old')
              ? slow.future
              : Future.value(reply({'track_id': 'new', 'title': '新曲'})),
        ),
      );
      addTearDown(s.dispose);
      s.playback = {'current_track_id': 'old'};
      final pending = s.syncCurrentTrack();
      s.playback = {'current_track_id': 'new'};
      await s.syncCurrentTrack();
      slow.complete(reply({'track_id': 'old', 'title': '旧曲'}));
      await pending;
      expect(s.homeMusicTitle, '新曲');
      s.currentTrack = {};
      s.playback = {'current_track_id': 'old'};
      s.api.token = 'another-fixture';
      s.stop();
      s.resetAccountCaches();
      expect(s.homeMusicTitle, '暂无曲目');
    },
  );
  test(
    'metadata failure is unknown, not track ID as title; retries do not flood',
    () async {
      var requests = 0;
      final s = sessionFor(
        MockClient((r) async {
          requests++;
          return reply({}, 404);
        }),
      );
      addTearDown(s.dispose);
      s.playback = {'current_track_id': 'netease_404'};
      await s.syncCurrentTrack();
      await s.syncCurrentTrack();
      expect(s.homeMusicTitle, '曲名暂不可用');
      expect(requests, 1);
      s.playback['current_track_id'] = null;
      await s.syncCurrentTrack();
      expect(s.homeMusicTitle, '暂无曲目');
    },
  );
  test(
    'navigation reference survives restart; backend provides name/receipt, no task polling or dispatch',
    () async {
      final storage = MemoryStore();
      final requests = <String>[];
      final task = {
        'task_id': 'task-fixture',
        'device_id': 'car_p3pro',
        'title': '真实候选地点',
        'address': '测试地址',
        'status': 'launch_requested',
      };
      http.Client client() => MockClient((r) async {
        requests.add('${r.method} ${r.url.path}');
        return reply(task);
      });
      final first = sessionFor(client(), navigation: storage);
      await first.acceptNavigationTask(task, displayTitle: '地图搜索地点');
      first.dispose();
      final next = sessionFor(client(), navigation: storage);
      addTearDown(next.dispose);
      await next.restoreNavigation();
      expect(next.homeDestinationTitle, '地图搜索地点');
      expect(next.homeDestinationDetail, '测试地址');
      expect(next.taskLabel, '已请求打开 NAVITIME');
      expect(next.navigationVerified, true);
      expect(requests, ['GET /tasks/task-fixture']);
      final record = jsonDecode(storage.value!) as Map;
      record['owner'] = 'other-account';
      storage.value = jsonEncode(record);
      next.resetAccountCaches();
      await next.restoreNavigation();
      expect(next.lastTask, isEmpty);
      expect(requests.length, 1);
    },
  );
  test(
    'navigation scope domain/device mismatch is ignored, 404 clears visible reference',
    () async {
      final storage = MemoryStore();
      var requests = 0;
      final s = sessionFor(
        MockClient((r) async {
          requests++;
          return reply({}, 404);
        }),
        navigation: storage,
      );
      addTearDown(s.dispose);
      await s.acceptNavigationTask({
        'task_id': 'task-fixture',
        'title': '测试地点',
      });
      s.api.baseUrl = 'https://other.example.test';
      s.resetAccountCaches();
      await s.restoreNavigation();
      expect(s.lastTask, isEmpty);
      expect(requests, 0);
      s.api.baseUrl = 'https://backend.example.test';
      await s.restoreNavigation();
      expect(s.lastTask, isEmpty);
      expect(s.navigationVerified, false);
      expect(requests, 1);
    },
  );
  testWidgets(
    'home renders actual place/song labels, unknown freshness and clear glass',
    (tester) async {
      final s = FixtureSession();
      addTearDown(s.dispose);
      s.lastTask = {
        'task_id': 'task-fixture',
        'title': '测试目的地',
        'status': 'queued',
      };
      s.navigationVerified = true;
      s.currentTrack = {
        'track_id': 'netease_42',
        'title': '测试真实曲名',
        'artist': '测试歌手',
      };
      s.playback = {
        'current_track_id': 'netease_42',
        'playback_state': 'playing',
      };
      await tester.pumpWidget(
        MaterialApp(home: YarisShell(session: s, initializeSession: false)),
      );
      await tester.pumpAndSettle();
      expect(find.text('测试目的地'), findsOneWidget);
      expect(find.text('测试真实曲名'), findsOneWidget);
      expect(find.text('状态待更新'), findsOneWidget);
      final decorations = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(GlassTabBar),
          matching: find.byType(DecoratedBox),
        ),
      );
      final glass = decorations
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.gradient != null);
      expect(glass.gradient!.colors.every((c) => c.a < .25), true);
      expect(tester.takeException(), isNull);
    },
  );
}
