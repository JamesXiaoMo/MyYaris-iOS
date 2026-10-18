import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/favorites.dart';
import 'package:myyaris_ios/api/favorite_library.dart';
import 'package:myyaris_ios/api/folder_row.dart';
import 'package:myyaris_ios/api/folder_editor.dart';
import 'widget_test.dart' show FixtureSession;

Map<String, dynamic> row(String id, {String? folder}) => {
  'id': id,
  'name': id,
  'address': '地址',
  'latitude': 34,
  'longitude': 132,
  'folder_id': folder,
  'folder_name': folder,
};
Map<String, dynamic> folder(String id) => {
  'id': id,
  'name': id,
  'favorite_count': 1,
};
http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);
Object page(List<Object> items, {bool more = false, int? total}) => {
  'items': items,
  'total': total ?? items.length,
  'has_more': more,
  'uncategorized_count': 2,
};
void main() {
  test(
    'folder omission preserves, explicit null clears; all and uncategorized differ',
    () async {
      final bodies = <Map>[], queries = <Map<String, String>>[];
      final api = BackendApi(
        client: MockClient((r) async {
          expect(r.headers['Authorization'], 'Bearer unit');
          if (r.method == 'GET') {
            queries.add(r.url.queryParameters);
            return json(page([]));
          }
          final body = jsonDecode(r.body) as Map;
          bodies.add(body);
          return json({...row('fav'), ...body});
        }),
      )..token = 'unit';
      final service = FavoritesApi(api);
      final body = Favorite.validate('名称', '地址', '34', '132');
      await service.save(body, id: 'fav');
      await service.save({...body, 'folder_id': null}, id: 'fav');
      await service.move('fav', 'fld_1');
      expect(bodies[0].containsKey('folder_id'), false);
      expect(bodies[1].containsKey('folder_id'), true);
      expect(bodies[1]['folder_id'], null);
      expect(bodies[2], {'folder_id': 'fld_1'});
      await service.page();
      await service.page(folderId: 'uncategorized', search: '家');
      expect(queries[0].containsKey('folder_id'), false);
      expect(queries[1]['folder_id'], 'uncategorized');
      expect(queries[1]['search'], '家');
    },
  );
  test(
    'has_more drives pages and write failure never silently retries',
    () async {
      var count = 0;
      final api = BackendApi(
        client: MockClient((r) async {
          if (r.method == 'POST') {
            count++;
            throw TimeoutException('unit');
          }
          final offset = int.parse(r.url.queryParameters['offset']!);
          return json(
            page([folder('fld_$offset')], more: offset == 0, total: 99),
          );
        }),
      )..token = 'unit';
      final service = FavoritesApi(api);
      expect((await service.allFolders()).map((v) => v.id), ['fld_0', 'fld_1']);
      await expectLater(
        service.save(Favorite.validate('', '地址', '34', '132')),
        throwsA(isA<FavoriteWriteUncertain>()),
      );
      expect(count, 1);
      for (final value in ['', ' ' * 2, 'a' * 65]) {
        await expectLater(
          service.saveFolder(value),
          throwsA(isA<ApiFailure>()),
        );
      }
    },
  );
  test(
    'HTTP statuses preserve login and forbidden semantics; repeat DELETE404 is absent',
    () async {
      for (final status in [401, 403, 404, 409, 422]) {
        var expired = 0;
        final api =
            BackendApi(
                client: MockClient(
                  (_) async => json({'detail': 'secret never exposed'}, status),
                ),
              )
              ..token = 'unit'
              ..isUserSession = true
              ..onSessionExpired = () async {
                expired++;
              };
        await expectLater(
          FavoritesApi(api).folders(),
          throwsA(
            isA<ApiFailure>().having((e) => e.statusCode, 'status', status),
          ),
        );
        expect(expired, status == 401 ? 1 : 0);
        expect(
          favoriteError(ApiFailure('raw', statusCode: status)),
          isNot(contains('secret')),
        );
        if (status == 404) await FavoritesApi(api).deleteFolder('gone');
      }
    },
  );
  test(
    'old service cannot write using new identity or expire new-origin session',
    () async {
      final delayed = Completer<http.Response>();
      var writes = 0, expired = 0;
      final api =
          BackendApi(
              client: MockClient((r) async {
                if (r.method != 'GET') writes++;
                return delayed.future;
              }),
            )
            ..token = 'old'
            ..isUserSession = true
            ..onSessionExpired = () async {
              expired++;
            };
      final service = FavoritesApi(api);
      final request = service.folders();
      api.baseUrl = 'https://other.example';
      delayed.complete(json({}, 401));
      await expectLater(request, throwsA(isA<ApiFailure>()));
      expect(expired, 0);
      await expectLater(service.saveFolder('new'), throwsA(isA<ApiFailure>()));
      expect(writes, 0);
    },
  );
  test(
    'browser blocks duplicate page requests, deduplicates and drops late query/account data',
    () async {
      final slow = Completer<http.Response>();
      var moreCalls = 0;
      final api = BackendApi(
        client: MockClient((r) async {
          if (r.url.path.startsWith('${FavoritesApi.foldersPath}/')) {
            return json(folder('fld'));
          }
          if (r.url.path == FavoritesApi.foldersPath) {
            return json(page([folder('fld')]));
          }
          if (r.url.queryParameters['search'] == 'slow') return slow.future;
          if (r.url.queryParameters['offset'] == '1') {
            moreCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return json(page([row('first'), row('next')], total: 3));
          }
          return json(
            page(
              [
                row(
                  r.headers['Authorization']!.contains('new') ? 'new' : 'first',
                ),
              ],
              more: true,
              total: 3,
            ),
          );
        }),
      )..token = 'old';
      final session = FixtureSession(api: api);
      final model = FavoriteLibrary(session);
      addTearDown(() => model.dispose());
      addTearDown(session.dispose);
      await model.refresh();
      await Future.wait([model.more(), model.more()]);
      expect(moreCalls, 1);
      expect(model.items.map((v) => v.id), ['first', 'next']);
      expect(model.hasMore, false);
      final earlier = model.query('slow');
      api.token = 'new';
      model.accountChanged();
      await Future<void>.delayed(Duration.zero);
      slow.complete(json(page([row('old-secret')])));
      await earlier;
      await model.refresh();
      expect(model.items.single.id, 'new');
      expect(model.search, '');
      expect(model.folderId, null);
    },
  );
  test(
    'delete selected category retains addresses and refreshes counts into uncategorized',
    () async {
      var removed = false;
      final api = BackendApi(
        client: MockClient((r) async {
          if (r.method == 'DELETE') {
            removed = true;
            return json({}, 404);
          }
          if (r.url.path.startsWith('${FavoritesApi.foldersPath}/')) {
            return json(folder('fld'));
          }
          if (r.url.path == FavoritesApi.foldersPath) {
            return json(page(removed ? [] : [folder('fld')]));
          }
          return json(page([row('kept', folder: removed ? null : 'fld')]));
        }),
      )..token = 'unit';
      final session = FixtureSession(api: api);
      final library = FavoriteLibrary(session);
      addTearDown(library.dispose);
      addTearDown(session.dispose);
      await library.filter('fld');
      expect(library.error, isNull);
      await library.removeFolder(
        const FavoriteFolder(id: 'fld', name: '通勤', count: 1),
      );
      expect(library.folderId, 'uncategorized');
      expect(library.items.single.id, 'kept');
      expect(library.items.single.folderId, null);
      expect(library.folders, isEmpty);
    },
  );
  test(
    'late search and removed folder cannot replace current results',
    () async {
      final old = Completer<http.Response>();
      final api = BackendApi(
        client: MockClient((r) async {
          if (r.url.path.startsWith('${FavoritesApi.foldersPath}/')) {
            return json({}, 404);
          }
          if (r.url.path == FavoritesApi.foldersPath) return json(page([]));
          if (r.url.queryParameters['folder_id'] == 'gone') {
            return json({}, 404);
          }
          if (r.url.queryParameters['search'] == 'old') return old.future;
          return json(page([row('current')]));
        }),
      )..token = 'unit';
      final session = FixtureSession(api: api);
      final library = FavoriteLibrary(session);
      addTearDown(library.dispose);
      addTearDown(session.dispose);
      final first = library.query('old');
      await library.query('current');
      old.complete(json(page([row('late')])));
      await first;
      expect(library.items.single.id, 'current');
      await library.filter('gone');
      expect(library.folderId, null);
      expect(library.items.single.id, 'current');
      expect(library.error, contains('已不存在'));
      api.baseUrl = 'https://different.example';
      library.accountChanged();
      expect(library.items, isEmpty);
      expect(library.search, '');
      await Future<void>.delayed(Duration.zero);
    },
  );
  testWidgets(
    'right swipe reveals management without deleting; editor conflict never reports success',
    (tester) async {
      var deleted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FolderRow(
              folder: const FavoriteFolder(id: 'fld', name: '通勤', count: 2),
              open: () {},
              rename: () {},
              remove: () => deleted++,
            ),
          ),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('folder-fld')),
        const Offset(170, 0),
      );
      await tester.pumpAndSettle();
      expect(deleted, 0);
      await tester.tap(find.byTooltip('删除分类，保留地址'));
      expect(deleted, 1);
      final api = BackendApi(client: MockClient((_) async => json({}, 409)))
        ..token = 'unit';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FolderEditor(service: FavoritesApi(api))),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('folder-name-input')),
        '通勤',
      );
      await tester.tap(find.byKey(const ValueKey('folder-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('分类名称已存在'), findsOneWidget);
    },
  );
}
