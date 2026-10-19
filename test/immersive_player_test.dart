import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/music_home.dart';
import 'widget_test.dart' show FixtureSession;

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'immersive player fits $size and unknown controls cannot send',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var requests = 0;
        final session = FixtureSession(
          api: BackendApi(
            baseUrl: 'https://backend.example.test',
            client: MockClient((_) async {
              requests++;
              return http.Response('{}', 200);
            }),
          )..token = 'fixture',
        );
        addTearDown(session.dispose);
        await tester.pumpWidget(
          MaterialApp(home: MusicPlayerPage(session: session)),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('player-toggle')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<Slider>(find.byKey(const ValueKey('player-seek')))
              .onChanged,
          isNull,
        );
        expect(
          tester
              .widget<Slider>(find.byKey(const ValueKey('player-volume')))
              .onChanged,
          isNull,
        );
        expect(find.text('--:--'), findsNWidgets(2));
        await tester.drag(
          find.byKey(const ValueKey('immersive-player-scroll')),
          const Offset(0, -800),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(requests, 0);
      },
    );
  }
  testWidgets(
    'immersive volume drags issue one command only at end and preserve real value until status',
    (tester) async {
      final writes = <Map>[];
      final session = FixtureSession(
        api: BackendApi(
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
        )..token = 'fixture',
      );
      final now = DateTime.now().toUtc().toIso8601String();
      session.playback = {
        'current_track_id': 'fixture-track',
        'software_volume': .2,
        'loop_mode': 'all',
        'position_ms': 84000,
        'duration_ms': 248000,
        'updated_at': now,
        'last_heartbeat_at': now,
        'playback_state': 'paused',
      };
      session.currentTrack = {'title': '测试曲目', 'artist': '测试歌手'};
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(home: MusicPlayerPage(session: session)),
      );
      await tester.pumpAndSettle();
      expect(find.text('测试曲目'), findsOneWidget);
      expect(find.text('01:24'), findsOneWidget);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('player-volume')),
      );
      slider.onChanged!(.3);
      slider.onChanged!(.4);
      expect(writes, isEmpty);
      slider.onChangeEnd!(.4);
      await tester.pumpAndSettle();
      expect(writes.single['action'], 'set_volume');
      expect(writes.single['params']['volume'], .4);
      expect(session.playback['software_volume'], .2);
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('player-volume')))
            .onChanged,
        isNull,
      );
    },
  );
  for (final status in [200, 403]) {
    testWidgets(
      'lyrics consumes frozen string lrc schema and handles HTTP $status',
      (tester) async {
        final requests = <http.Request>[];
        final session = FixtureSession(
          api: BackendApi(
            baseUrl: 'https://backend.example.test',
            client: MockClient((r) async {
              requests.add(r);
              return http.Response(
                jsonEncode({'lrc': '[00:01.00]测试歌词'}),
                status,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          )..token = 'fixture',
        );
        session.currentTrack = {'song_id': 123, 'title': '测试歌曲'};
        session.playback = {'current_track_id': 'fixture-song'};
        addTearDown(session.dispose);
        await tester.pumpWidget(
          MaterialApp(home: MusicPlayerPage(session: session)),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('player-lyrics')));
        await tester.tap(find.byKey(const ValueKey('player-lyrics')));
        await tester.pumpAndSettle();
        expect(requests.length, 1);
        expect(requests.single.method, 'GET');
        expect(requests.single.url.queryParameters['song_id'], '123');
        expect(
          find.text(status == 200 ? '测试歌词' : '歌词读取失败，请关闭后重试'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
