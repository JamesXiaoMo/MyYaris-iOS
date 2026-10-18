import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/favorites.dart';
import 'package:myyaris_ios/main.dart';
import 'widget_test.dart' show FixtureSession;

http.Response jsonResponse(String body, int status) => http.Response(
  body,
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'WGS84 valid boundary and invalid finite/range/empty address checks',
    () {
      expect(Favorite.validate('', ' 极点 ', '-90', '180'), {
        'name': null,
        'address': '极点',
        'latitude': -90.0,
        'longitude': 180.0,
        'coord_system': 'wgs84',
      });
      for (final coords in [
        ['91', '34'],
        ['132', '34'],
        ['34', '181'],
        ['NaN', '132'],
        ['34', 'Infinity'],
        ['', '132'],
      ]) {
        expect(
          () => Favorite.validate('家', '地址', coords[0], coords[1]),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(
        () => Favorite.validate('家', ' ', '34', '132'),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        Favorite.fromJson({
          'id': 'x',
          'name': null,
          'address': '家',
          'latitude': 34,
          'longitude': 132,
          'coord_system': 'wgs84',
        }).displayName,
        '家',
      );
    },
  );
  test(
    'CRUD round trip and reopening a service uses backend, never navigation',
    () async {
      final rows = <String, Map<String, dynamic>>{};
      final writes = <String>[];
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          expect(r.headers['Authorization'], 'Bearer fixture');
          if (r.method == 'GET' && r.url.path == FavoritesApi.path) {
            return jsonResponse(
              jsonEncode({
                'items': rows.values.toList(),
                'total': rows.length,
                'has_more': false,
              }),
              200,
            );
          }
          if (r.method == 'POST') {
            writes.add(r.url.path);
            rows['fav_test'] = {...jsonDecode(r.body), 'id': 'fav_test'};
            return jsonResponse(jsonEncode(rows['fav_test']), 201);
          }
          if (r.method == 'PATCH') {
            writes.add(r.url.path);
            rows['fav_test']!.addAll(jsonDecode(r.body));
            return jsonResponse(jsonEncode(rows['fav_test']), 200);
          }
          if (r.method == 'DELETE') {
            rows.remove('fav_test');
            return jsonResponse(
              jsonEncode({'status': 'ok', 'deleted_id': 'fav_test'}),
              200,
            );
          }
          return jsonResponse(jsonEncode(rows['fav_test']), 200);
        }),
      )..token = 'fixture';
      final service = FavoritesApi(api);
      final created = await service.save(
        Favorite.validate('家', '广岛地址', '34.4', '132.4'),
      );
      expect((await FavoritesApi(api).list()).single.id, created.id);
      expect((await service.get(created.id)).address, '广岛地址');
      await service.save(
        Favorite.validate('公司', '改后地址', '35', '133'),
        id: created.id,
      );
      expect((await FavoritesApi(api).list()).single.latitude, 35);
      await service.delete(created.id);
      expect(await service.list(), isEmpty);
      expect(
        writes.every((path) => path.startsWith(FavoritesApi.path)),
        isTrue,
      );
    },
  );
  test('server and malformed responses do not claim saved', () async {
    final api = BackendApi(
      baseUrl: 'https://backend.example.test',
      client: MockClient(
        (_) async => jsonResponse('{"detail":"private response"}', 500),
      ),
    )..token = 'fixture';
    expect(
      FavoritesApi(api).save(Favorite.validate('', '地址', '34', '132')),
      throwsA(isA<ApiFailure>()),
    );
    expect(FavoritesApi(api).list(), throwsA(isA<ApiFailure>()));
    final malformed = BackendApi(
      baseUrl: 'https://backend.example.test',
      client: MockClient(
        (_) async => jsonResponse('{"items":[],"total":2}', 200),
      ),
    )..token = 'fixture';
    expect(FavoritesApi(malformed).list(), throwsA(isA<ApiFailure>()));
  });
  testWidgets(
    'driving omissions, favorite fill has no dispatch; delete requires confirmation',
    (tester) async {
      final writes = <String>[];
      final row = {
        'id': 'fav_test',
        'name': '家',
        'address': '测试地址',
        'latitude': 34.4,
        'longitude': 132.4,
        'coord_system': 'wgs84',
      };
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          if (r.url.path == FavoritesApi.foldersPath) {
            return jsonResponse(
              '{"items":[],"total":0,"has_more":false,"uncategorized_count":1}',
              200,
            );
          }
          if (r.method != 'GET') writes.add(r.url.path);
          if (r.method == 'DELETE') {
            return jsonResponse('{"status":"ok","deleted_id":"fav_test"}', 200);
          }
          return jsonResponse(
            jsonEncode({
              'items': [row],
              'total': 1,
              'has_more': false,
            }),
            200,
          );
        }),
      )..token = 'fixture';
      final session = FixtureSession(api: api);
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(home: YarisShell(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      expect(find.text('行驶'), findsNWidgets(2));
      expect(find.text('选择短音频并上传解析'), findsNothing);
      expect(find.text('刷新任务回执'), findsNothing);
      expect(find.text('先解析候选，确认后才派发到指定车机。'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('favorites-handle')),
        const Offset(0, -320),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('favorite-menu-fav_test')),
      );
      await tester.tap(find.byKey(const ValueKey('favorite-menu-fav_test')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('家'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('destination-input-open')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('destination-input')),
      );
      expect(field.controller!.text, '34.4, 132.4');
      expect(writes, isEmpty);
    },
  );
}
