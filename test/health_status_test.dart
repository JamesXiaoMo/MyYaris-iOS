import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';

void main() {
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
