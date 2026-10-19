import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/favorites.dart';
import 'package:myyaris_ios/api/favorite_library.dart';
import 'package:myyaris_ios/api/favorites_page.dart';
import 'widget_test.dart' show FixtureSession;
import 'sync_contract_test.dart' show syncedOpenApi;

http.Response json(Object body, [int code = 200]) => http.Response(
  jsonEncode(body),
  code,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Map<String, dynamic> row(String id, {String? folder}) => {
  'id': id,
  'name': '测试收藏',
  'address': '',
  'latitude': 37.422,
  'longitude': -122.084,
  'coord_system': 'wgs84',
  'folder_id': folder,
};
Map<String, dynamic> page(List<Object> items, {bool more = false}) => {
  'items': items,
  'total': more ? 2 : items.length,
  'has_more': more,
};
Map<String, dynamic> candidate() => {
  'latitude': 37.422,
  'longitude': -122.084,
  'coord_system': 'wgs84',
  'title': 'Plus Code',
};

void main() {
  test(
    'root uses server uncategorized filter on every page; folders keep their members',
    () async {
      final filters = <String?>[];
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          if (r.url.path == FavoritesApi.foldersPath) {
            return json({
              ...page([
                {'id': 'group', 'name': '测试分类', 'favorite_count': 1},
              ]),
              'uncategorized_count': 2,
            });
          }
          if (r.url.path == '${FavoritesApi.foldersPath}/group') {
            return json({'id': 'group', 'name': '测试分类', 'favorite_count': 1});
          }
          final filter = r.url.queryParameters['folder_id'];
          filters.add(filter);
          if (filter == 'group') {
            return json(page([row('grouped', folder: 'group')]));
          }
          if (filter != 'uncategorized') {
            return json(
              page([row('grouped', folder: 'group'), row('plain-1')]),
            );
          }
          return json(
            page([
              row(
                r.url.queryParameters['offset'] == '0' ? 'plain-1' : 'plain-2',
              ),
            ], more: r.url.queryParameters['offset'] == '0'),
          );
        }),
      )..token = 'fixture';
      final s = FixtureSession(api: api);
      final model = FavoriteLibrary(s);
      addTearDown(model.dispose);
      addTearDown(s.dispose);
      await model.refresh();
      await model.more();
      expect(model.items.map((x) => x.id), ['plain-1', 'plain-2']);
      expect(filters, ['uncategorized', 'uncategorized']);
      await model.filter('group');
      expect(model.items.single.id, 'grouped');
    },
  );
  test(
    'empty display address persists and null response has coordinate fallback',
    () async {
      late Map<String, dynamic> saved;
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          if (r.method == 'POST') {
            saved = Map<String, dynamic>.from(jsonDecode(r.body));
            return json({'id': 'fixture', ...saved});
          }
          return json({'id': 'fixture', ...saved, 'address': null});
        }),
      )..token = 'fixture';
      addTearDown(api.close);
      final service = FavoritesApi(api);
      final created = await service.save(
        Favorite.validate('', '', '37.422', '-122.084'),
      );
      expect(created.address, '');
      expect(saved['address'], '');
      final reread = await service.get('fixture');
      expect(reread.displayName, '37.422, -122.084');
    },
  );
  test(
    'full Plus Code only resolves; no navigation, returns validated WGS84',
    () async {
      final calls = <String>[];
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          calls.add('${r.method} ${r.url.path}');
          if (r.url.path == '/openapi.json') return json(syncedOpenApi());
          if (r.url.path.endsWith('/resolve')) {
            expect(jsonDecode(r.body)['purpose'], 'favorite_preview');
            return json({'destination_id': 'code-ref'});
          }
          return json({
            'status': 'resolved',
            'candidates': [candidate()],
          });
        }),
      )..token = 'fixture';
      addTearDown(api.close);
      expect(await FavoritesApi(api).resolvePlusCode('849vcwc8+r9'), {
        'latitude': 37.422,
        'longitude': -122.084,
      });
      expect(calls, [
        'GET /openapi.json',
        'POST /api/v1/destinations/resolve',
        'GET /destinations/code-ref',
      ]);
    },
  );
  test(
    'short or malformed codes require reference and never issue request',
    () async {
      var calls = 0;
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          calls++;
          return json({});
        }),
      )..token = 'fixture';
      addTearDown(api.close);
      for (final code in [
        'CWC8+R9',
        'CWC8+R9 Tokyo',
        'invalid',
        '849VCWC8++R9',
      ]) {
        await expectLater(
          FavoritesApi(api).resolvePlusCode(code),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(calls, 0);
    },
  );
  test(
    'parse unexpectedly returning navigation task is rejected before favorite save',
    () async {
      final calls = <String>[];
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          calls.add(r.url.path);
          return json(
            r.url.path == '/openapi.json'
                ? syncedOpenApi()
                : {'destination_id': 'code-ref', 'task_id': 'unexpected'},
          );
        }),
      )..token = 'fixture';
      addTearDown(api.close);
      await expectLater(
        FavoritesApi(api).resolvePlusCode('849VCWC8+R9'),
        throwsA(isA<ApiFailure>()),
      );
      expect(calls, ['/openapi.json', '/api/v1/destinations/resolve']);
    },
  );

  for (final mode in [
    'multiple',
    'preview-confirmation',
    'query-confirmation',
  ]) {
    test(
      'favorite preview rejects $mode despite flattened valid coordinate',
      () async {
        final writes = <String>[];
        final api = BackendApi(
          baseUrl: 'https://backend.example.test',
          client: MockClient((r) async {
            if (r.method == 'POST') writes.add(r.url.path);
            if (r.url.path == '/openapi.json') return json(syncedOpenApi());
            if (r.url.path.endsWith('/resolve')) {
              expect(jsonDecode(r.body)['purpose'], 'favorite_preview');
              return json({
                'destination_id': 'code-ref',
                ...candidate(),
                'needs_confirmation': mode == 'preview-confirmation',
                'candidates': [
                  candidate(),
                  if (mode == 'multiple') candidate(),
                ],
              });
            }
            return json({
              'status': 'resolved',
              'needs_confirmation': mode == 'query-confirmation',
              'candidates': [candidate()],
            });
          }),
        )..token = 'fixture';
        addTearDown(api.close);
        await expectLater(
          FavoritesApi(api).resolvePlusCode('849VCWC8+R9'),
          throwsA(isA<ApiFailure>()),
        );
        expect(writes, ['/api/v1/destinations/resolve']);
      },
    );
  }

  for (final mode in ['full', 'short-cancel', 'short-save']) {
    testWidgets(
      'Plus Code editor $mode keeps optional address and requires short-position approval',
      (tester) async {
        final posts = <String>[], resolutions = <Map>[];
        Map<String, dynamic>? saved;
        final spec = syncedOpenApi();
        ((spec['components'] as Map)['schemas']
            as Map)['DestinationResolveRequest'] = {
          'properties': {
            'reference_coordinate': {'type': 'object'},
          },
        };
        final api = BackendApi(
          baseUrl: 'https://backend.example.test',
          client: MockClient((r) async {
            if (r.method == 'POST') posts.add(r.url.path);
            if (r.url.path == FavoritesApi.foldersPath) return json(page([]));
            if (r.url.path == '/openapi.json') return json(spec);
            if (r.url.path.endsWith('/resolve')) {
              resolutions.add(jsonDecode(r.body) as Map);
              expectSync(resolutions.last['purpose'], 'favorite_preview');
              return json({
                'destination_id': 'code-ref',
                'needs_confirmation': mode != 'full',
              });
            }
            if (r.url.path.startsWith('/destinations/')) {
              return json({
                'status': mode == 'full' ? 'resolved' : 'needs_clarification',
                'candidates': [candidate()],
              });
            }
            saved = Map<String, dynamic>.from(jsonDecode(r.body));
            return json({'id': 'fixture', ...saved!});
          }),
        )..token = 'fixture';
        addTearDown(api.close);
        var completed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    completed =
                        await showDialog<bool>(
                          context: context,
                          builder: (_) =>
                              FavoriteEditor(service: FavoritesApi(api)),
                        ) ==
                        true;
                  },
                  child: const Text('新增'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('新增'));
        await tester.pumpAndSettle();
        expect(find.text('显示地址（选填）'), findsOneWidget);
        await tester.tap(find.text('Plus Code'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('favorite-plus-code')),
          mode == 'full' ? '849VCWC8+R9' : 'CWC8+R9',
        );
        await tester.pumpAndSettle();
        if (mode != 'full') {
          await tester.enterText(
            find.byKey(const ValueKey('favorite-reference-latitude')),
            '37.42',
          );
          await tester.enterText(
            find.byKey(const ValueKey('favorite-reference-longitude')),
            '-122.08',
          );
        }
        await tester.ensureVisible(find.byKey(const ValueKey('favorite-save')));
        await tester.tap(find.byKey(const ValueKey('favorite-save')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        if (mode != 'full') {
          expect(posts, ['/api/v1/destinations/resolve']);
          expect(resolutions.single['reference_coordinate'], {
            'latitude': 37.42,
            'longitude': -122.08,
            'coord_system': 'wgs84',
          });
          expect(
            find.byKey(const ValueKey('favorite-short-code-confirm')),
            findsOneWidget,
          );
          if (mode == 'short-cancel') {
            await tester.tap(
              find.descendant(
                of: find.byKey(const ValueKey('favorite-short-code-confirm')),
                matching: find.widgetWithText(TextButton, '取消'),
              ),
            );
            await tester.pumpAndSettle();
            expect(saved, isNull);
            expect(completed, false);
            expect(posts, ['/api/v1/destinations/resolve']);
            return;
          }
          await tester.tap(
            find.byKey(const ValueKey('favorite-short-code-save')),
          );
          await tester.pumpAndSettle();
        }
        expect(completed, true);
        expect(posts, ['/api/v1/destinations/resolve', FavoritesApi.path]);
        expect(saved!['address'], '');
        expect(saved!['latitude'], 37.422);
        expect(saved!['folder_id'], null);
      },
    );
  }
}
