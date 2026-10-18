import 'sync_contract_test.dart' show syncedOpenApi;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/main.dart';
import 'package:myyaris_ios/api/backend.dart';

class MemoryCredentials implements CredentialStore {
  String? data;
  @override
  Future<String?> load() async => data;
  @override
  Future<void> save(String value) async {
    data = value;
  }

  @override
  Future<void> clear() async {
    data = null;
  }
}

class FixtureSession extends BackendSession {
  FixtureSession({super.api})
    : super(store: MemoryCredentials(), requireUserLogin: false);
  @override
  void start() {}
}

void main() {
  testWidgets(
    'navigation resolves candidates and only dispatches after explicit confirmation',
    (tester) async {
      final writes = <String>[];
      final api = BackendApi(
        client: MockClient((r) async {
          if (r.method == 'POST') writes.add(r.url.path);
          final data = switch (r.url.path) {
            '/openapi.json' => syncedOpenApi(),
            '/api/v1/destinations/resolve' => {
              'destination_id': 'd1',
              'name': '目标',
              'latitude': 34.0,
              'longitude': 132.0,
              'confidence': .98,
            },
            '/destinations/d1' => {
              'status': 'needs_clarification',
              'candidates': [
                {
                  'candidate_id': 'c1',
                  'title': '候选一',
                  'latitude': 34.0,
                  'longitude': 132.0,
                },
                {
                  'candidate_id': 'c2',
                  'title': '候选二',
                  'latitude': 35.0,
                  'longitude': 133.0,
                },
              ],
            },
            '/destinations/d1/confirm' => {
              'task_id': 't1',
              'title': '候选二',
              'status': 'queued',
            },
            _ => {},
          };
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..token = 'test-only';
      final session = FixtureSession(api: api);
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(home: YarisShell(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('destination-input-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('destination-input')),
        '34,132',
      );
      await tester.tap(find.widgetWithText(FilledButton, '解析目的地'));
      await tester.pumpAndSettle();
      expect(writes, ['/api/v1/destinations/resolve']);
      await tester.ensureVisible(find.text('候选二'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('候选二'));
      await tester.pumpAndSettle();
      expect(writes, ['/api/v1/destinations/resolve']);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(writes, [
        '/api/v1/destinations/resolve',
        '/destinations/d1/confirm',
      ]);
      expect(session.lastTask['status'], 'queued');
      for (var i = 2; i < 4; i++) {
        await tester.tap(find.byKey(ValueKey('tab-$i')));
        await tester.pumpAndSettle();
      }
      expect(find.text('保存并连接'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932),
  ]) {
    testWidgets('unconfigured offline layout at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = FixtureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: YarisShell(session: session),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('home-scroll')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (var i = 1; i < 4; i++) {
        await tester.tap(find.byKey(ValueKey('tab-$i')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
