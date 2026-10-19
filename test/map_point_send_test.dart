import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/apple_map.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'widget_test.dart' show FixtureSession;
import 'sync_contract_test.dart' show syncedOpenApi;

void main() {
  for (final outcome in [
    'send',
    'mismatch',
    'account-change',
    'multiple',
    'confirmation',
    'legacy-confirmation',
  ]) {
    testWidgets(
      'map point immediate confirmation: $outcome; never sends before confirm',
      (tester) async {
        final writes = <String>[];
        final dispatchedBodies = <String>[];
        final api = BackendApi(
          baseUrl: 'https://backend.example.test',
          client: MockClient((r) async {
            if (r.method == 'POST') writes.add(r.url.path);
            if (r.url.path.endsWith('/resolve')) {
              expectSync(jsonDecode(r.body)['purpose'], 'navigation');
            }
            final candidates = [
              {
                'candidate_id': 'point-candidate',
                'title': '选点',
                'latitude': outcome == 'mismatch' ? 35.0 : 34.4,
                'longitude': 132.4,
              },
              if (outcome == 'multiple')
                {
                  'candidate_id': 'other',
                  'title': '其他',
                  'latitude': 35.0,
                  'longitude': 132.4,
                },
            ];
            final value = switch (r.url.path) {
              '/openapi.json' => syncedOpenApi(),
              '/api/v1/destinations/resolve' => {
                'destination_id': 'point-request',
                'name': '选点',
                'latitude': 34.4,
                'longitude': 132.4,
                'needs_confirmation': [
                  'multiple',
                  'confirmation',
                  'legacy-confirmation',
                ].contains(outcome),
                if (['multiple', 'confirmation'].contains(outcome))
                  'candidates': candidates,
              },
              '/destinations/point-request' => {
                'status': 'resolved',
                'candidates': [
                  {
                    'candidate_id': 'point-candidate',
                    'title': '选点',
                    'latitude': outcome == 'mismatch' ? 35.0 : 34.4,
                    'longitude': 132.4,
                  },
                ],
              },
              '/api/v1/tasks/destination' => {
                'task_id': 'point-task',
                'device_id': 'car_p3pro',
                'title': '选点',
                'latitude': 34.4,
                'longitude': 132.4,
                'status': 'queued',
              },
              _ => {'items': [], 'total': 0, 'has_more': false},
            };
            if (r.url.path == '/api/v1/tasks/destination') {
              dispatchedBodies.add(r.body);
            }
            return http.Response(
              jsonEncode(value),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        )..token = 'fixture-session';
        final s = FixtureSession(api: api);
        addTearDown(s.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: NavigationPage(session: s)),
          ),
        );
        await tester.pumpAndSettle();
        void point() => tester
            .widget<AppleMap>(find.byType(AppleMap))
            .onSelected(const MapSelection(34.4, 132.4, title: '测试地点'));
        point();
        point();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('map-point-confirmation')),
          findsOneWidget,
        );
        expect(writes, isEmpty);
        expect(find.byKey(const ValueKey('destination-preview')), findsNothing);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        expect(find.byKey(const ValueKey('destination-preview')), findsNothing);
        point();
        await tester.pumpAndSettle();
        if (outcome == 'account-change') api.token = 'another-fixture';
        await tester.tap(find.byKey(const ValueKey('map-point-send')));
        await tester.pumpAndSettle();
        if (outcome == 'send') {
          expect(
            writes,
            ['/api/v1/destinations/resolve', '/api/v1/tasks/destination'],
            reason:
                '${(tester.state(find.byType(NavigationPage)) as dynamic).error}',
          );
          expect(
            jsonDecode(dispatchedBodies.single)['target_device_id'],
            'car_p3pro',
          );
          expect(
            jsonDecode(dispatchedBodies.single)['destination_id'],
            'point-request',
          );
          expect(
            s.lastTask['task_id'],
            'point-task',
            reason:
                '${(tester.state(find.byType(NavigationPage)) as dynamic).error} / ${s.lastMessage}',
          );
          expect(s.homeDestinationTitle, '测试地点');
        } else if (outcome != 'account-change') {
          expect(writes, ['/api/v1/destinations/resolve']);
          expect(s.lastTask, isEmpty);
          expect(find.textContaining('解析结果与确认的选点不一致'), findsOneWidget);
        } else {
          expect(writes, isEmpty);
        }
        expect(
          find.byKey(const ValueKey('map-point-confirmation')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('destination-preview')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
