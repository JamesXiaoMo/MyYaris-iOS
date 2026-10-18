import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart';
import 'widget_test.dart' show FixtureSession;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';

void main() {
  testWidgets(
    'home removes chevron and renders actual red yellow green status labels',
    (tester) async {
      final session = FixtureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: YarisShell(session: session, initializeSession: false),
        ),
      );
      expect(find.text('Toyota Yaris'), findsOneWidget);
      expect(find.text('Toyota Yaris ⌄'), findsNothing);
      for (final state in [0, 1, 2]) {
        session.backendOnline = state != 0;
        session.playback = state == 2
            ? {'last_heartbeat_at': DateTime.now().toUtc().toIso8601String()}
            : {};
        session.publish();
        await tester.pump();
        final label = ['后端未连接', '车机未连接', '在线'][state];
        final color = [
          const Color(0xFFFF6370),
          const Color(0xFFFFCC66),
          const Color(0xFF48D882),
        ][state];
        expect(tester.widget<Text>(find.text(label)).style!.color, color);
      }
    },
  );

  test(
    'home badge prioritizes health and requires fresh target car heartbeat',
    () {
      final session = BackendSession(requireUserLogin: false);
      addTearDown(session.dispose);
      expect(session.homeConnectionState, HomeConnectionState.checking);
      session.backendOnline = false;
      session.playback = {
        'last_heartbeat_at': DateTime.now().toUtc().toIso8601String(),
      };
      expect(session.homeConnectionState, HomeConnectionState.backendOffline);
      session.backendOnline = true;
      expect(session.homeConnectionState, HomeConnectionState.online);
      session.playback['last_heartbeat_at'] = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 2))
          .toIso8601String();
      expect(session.homeConnectionState, HomeConnectionState.carOffline);
      session.playback['last_heartbeat_at'] = 'bad timestamp';
      expect(session.homeConnectionState, HomeConnectionState.carOffline);
      session.playback = {
        'last_heartbeat_at': DateTime.now().toUtc().toIso8601String(),
        'device_id': 'other-car',
      };
      expect(session.homeConnectionState, HomeConnectionState.carOffline);
      session.playback['device_id'] = session.api.deviceId;
      session.deviceDenied = true;
      expect(session.homeConnectionState, HomeConnectionState.carOffline);
    },
  );

  test(
    'backend label follows health alone, not playback availability; failure and timeout go offline',
    () async {
      var fail = false, timeout = false, malformed = false;
      final api = BackendApi(
        client: MockClient((r) async {
          if (r.url.path == '/health') {
            if (timeout) throw TimeoutException('fixture');
            return http.Response(
              jsonEncode({'status': malformed ? 'error' : 'ok'}),
              fail ? 503 : 200,
            );
          }
          return http.Response(
            '{}',
            401,
          ); // healthy backend, unavailable car/auth snapshot
        }),
      )..token = 'fixture';
      final session = BackendSession(requireUserLogin: false, api: api);
      addTearDown(session.dispose);
      expect(session.backendLabel, '检测中');
      await session.refresh();
      expect(session.backendLabel, '在线');
      expect(session.playback, isEmpty);
      fail = true;
      await session.refresh();
      expect(session.backendLabel, '离线');
      fail = false;
      await session.refresh();
      expect(session.backendLabel, '在线');
      timeout = true;
      await session.refresh();
      expect(session.backendLabel, '离线');
      timeout = false;
      malformed = true;
      await session.refresh();
      expect(session.backendLabel, '离线');
    },
  );
}
