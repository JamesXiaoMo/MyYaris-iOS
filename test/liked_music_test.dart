import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/liked_music.dart';
import 'package:myyaris_ios/api/liked_music_page.dart';
import 'package:myyaris_ios/api/liked_music_store.dart';
import 'widget_test.dart' show MemoryCredentials;

const syncPath = '/api/v1/music/netease/playlist/favorite/sync';
const listPath = '/api/v1/music/netease/playlist/favorite';

Map<String, dynamic> song(int id) => {
  'id': id,
  'song_id': id,
  'source': 'netease',
  'title': '隔离测试曲目$id',
  'artist': '测试',
  'album': '测试专辑',
  'duration_ms': 123000,
  'cover_url': null,
  'playable': true,
  'fee': 0,
};

http.Response reply(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Scripted backend: one immutable catalog revision at a time, recorded calls.
class FakeBackend {
  List<int> ids;
  int revision;
  String owner;
  int playlist;
  Completer<void>? syncGate, pageGate;
  Object? syncFailure; // http.Response or Exception
  int? pageFailureOnce;
  bool legacy = false, stale = false;
  final calls = <String>[];
  final syncBodies = <Map<String, dynamic>>[];
  final pageQueries = <Map<String, String>>[];
  FakeBackend({
    this.ids = const [1, 2, 3],
    this.revision = 100,
    this.owner = 'owner-a',
    this.playlist = 123,
  });

  Map<String, dynamic> page(int offset, int limit) {
    final slice = ids.skip(offset).take(limit).toList();
    return {
      if (legacy) 'legacy': true,
      'code': 200,
      'playlist_id': playlist,
      'songs': slice.map(song).toList(),
      'total': ids.length,
      'offset': offset,
      'limit': limit,
      'has_more': offset + slice.length < ids.length,
      'revision': revision,
      'etag': 'etag$revision',
      'owner_key': owner,
      'synced_at': '2026-10-20T01:02:03Z',
      'stale': stale,
    };
  }

  Future<http.Response> handle(http.Request r) async {
    expect(r.headers['Authorization'], isNotNull);
    if (r.url.path == syncPath) {
      calls.add('sync');
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      syncBodies.add(body);
      if (legacy) return reply({'detail': 'Not Found'}, 404);
      if (syncGate != null) await syncGate!.future;
      final f = syncFailure;
      if (f is http.Response) return f;
      if (f != null) throw f;
      return reply({
        'code': 200,
        'status': body['known_revision'] == revision ? 'unchanged' : 'updated',
        'changed': body['known_revision'] != revision,
        'revision': revision,
        'etag': 'etag$revision',
        'owner_key': owner,
        'playlist_id': playlist,
        'total': ids.length,
      });
    }
    expect(r.url.path, listPath);
    calls.add('page');
    pageQueries.add(r.url.queryParameters);
    if (pageGate != null) await pageGate!.future;
    if (pageFailureOnce != null) {
      final code = pageFailureOnce!;
      pageFailureOnce = null;
      return reply({
        'detail': {'code': 409, 'error_code': 'FAVORITE_REVISION_CONFLICT'},
      }, code);
    }
    final pin = r.url.queryParameters['revision'];
    if (pin != null && !legacy && int.parse(pin) != revision) {
      return reply({
        'detail': {'error_code': 'FAVORITE_REVISION_CONFLICT'},
      }, 409);
    }
    final body = page(
      int.parse(r.url.queryParameters['offset']!),
      int.parse(r.url.queryParameters['limit']!),
    );
    if (legacy) {
      for (final k in [
        'revision',
        'etag',
        'owner_key',
        'synced_at',
        'legacy',
      ]) {
        body.remove(k);
      }
    }
    return reply(body);
  }
}

class UserFixture extends BackendSession {
  UserFixture({super.api})
    : super(store: MemoryCredentials(), requireUserLogin: true);
  @override
  void start() {}
}

UserFixture owner(
  http.Client client, {
  String account = 'acct-1',
  String token = 'isolated-admin-session',
}) =>
    UserFixture(
        api: BackendApi(baseUrl: 'https://backend.example.test', client: client)
          ..token = token
          ..isUserSession = true,
      )
      ..userProfile = {'role': 'admin', 'id': account}
      ..authenticated = true;

LikedMusicScope scopeOf(UserFixture s, {String? account}) => LikedMusicScope(
  origin: 'https://backend.example.test',
  account: account ?? '${s.userProfile['id']}',
  device: s.api.deviceId,
);

LikedMusicSnapshot snapshot(
  List<int> ids, {
  int revision = 100,
  String owner = 'owner-a',
}) => LikedMusicSnapshot(
  ownerKey: owner,
  playlistId: 123,
  revision: revision,
  etag: 'etag$revision',
  syncedAt: DateTime.utc(2026, 10, 20, 1),
  checkedAt: DateTime.utc(2026, 10, 20, 1),
  tracks: ids.map((i) => {...song(i), 'id': i}).toList(),
);

class RecordingStore extends MemoryLikedMusicStore {
  final saves = <String>[], clears = <String>[];
  @override
  Future<void> save(LikedMusicScope scope, LikedMusicSnapshot s) {
    saves.add('${scope.account}:${s.revision}');
    return super.save(scope, s);
  }

  @override
  Future<void> clear(LikedMusicScope scope) {
    clears.add(scope.account);
    return super.clear(scope);
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late FakeBackend backend;
  late RecordingStore store;
  late UserFixture session;
  late LikedMusicController model;
  setUp(() => store = RecordingStore());

  void make({FakeBackend? b, String account = 'acct-1'}) {
    backend = b ?? FakeBackend();
    session = owner(MockClient(backend.handle), account: account);
    final m = model = LikedMusicController(session, store: store);
    final sess = session;
    addTearDown(() {
      m.dispose();
      sess.dispose();
    });
  }

  test(
    'first use without cache: sync then pinned pages; persisted whitelist',
    () async {
      make(b: FakeBackend(ids: List.generate(130, (i) => i + 1)));
      await model.open();
      expect(model.tracks.length, 130);
      expect(model.total, 130);
      expect(model.loaded && !model.fromCache && model.error == null, true);
      expect(backend.calls, ['sync', 'page', 'page']);
      expect(backend.syncBodies.single.containsKey('known_revision'), false);
      // pages are pinned to the revision announced by sync; never audio/stream URLs
      expect(backend.pageQueries.every((q) => q['revision'] == '100'), true);
      expect(backend.pageQueries.map((q) => q['offset']), ['0', '50']);
      final saved = await store.load(scopeOf(session));
      expect(saved!.revision, 100);
      expect(saved.tracks.length, 130);
      expect(saved.ownerKey, 'owner-a');
    },
  );

  test(
    'warm open shows cache immediately and an unchanged check downloads no list',
    () async {
      await store.save(
        scopeOf(owner(MockClient((_) async => reply({})))),
        snapshot([1, 2, 3]),
      );
      make();
      backend.syncGate = Completer<void>();
      final run = model.open();
      await settle();
      // cached rows are visible while the background check is still pending
      expect(model.tracks.map((t) => t['song_id']), [1, 2, 3]);
      expect(model.fromCache && model.syncing && model.loaded, true);
      expect(model.statusLine, contains('后台检查更新'));
      backend.syncGate!.complete();
      await run;
      expect(backend.calls, ['sync']); // 0 page downloads
      expect(backend.syncBodies.single['known_revision'], 100);
      expect(model.fromCache, false);
      expect(model.tracks.length, 3);
    },
  );

  test(
    'changed revision: old rows stay until the new list is complete, then replace and persist',
    () async {
      await store.save(
        scopeOf(owner(MockClient((_) async => reply({})))),
        snapshot([1, 2, 3]),
      );
      make(b: FakeBackend(ids: [9, 1, 3], revision: 200));
      backend.pageGate = Completer<void>();
      final run = model.open();
      await settle();
      await settle();
      expect(model.tracks.map((t) => t['song_id']), [
        1,
        2,
        3,
      ]); // not blanked, not mixed
      backend.pageGate!.complete();
      await run;
      expect(model.tracks.map((t) => t['song_id']), [9, 1, 3]);
      expect(model.revision, 200);
      await settle();
      expect((await store.load(scopeOf(session)))!.revision, 200);
    },
  );

  test(
    'manual refresh keeps old list and forces the backend re-read',
    () async {
      make();
      await model.open();
      backend.syncGate = Completer<void>();
      final run = model.refresh();
      await settle();
      expect(model.tracks.length, 3);
      expect(model.syncing, true);
      backend.syncGate!.complete();
      await run;
      expect(backend.syncBodies.last['force'], true);
      expect(backend.syncBodies.last['known_revision'], 100);
      expect(model.tracks.length, 3);
    },
  );

  test('duplicate open calls collapse into one check', () async {
    make();
    backend.syncGate = Completer<void>();
    final a = model.open(), b = model.open();
    await settle();
    backend.syncGate!.complete();
    await Future.wait([a, b]);
    expect(backend.calls.where((c) => c == 'sync').length, 1);
  });

  test(
    'offline/timeout with cache keeps rows and says update failed; without cache is an error not empty',
    () async {
      await store.save(
        scopeOf(owner(MockClient((_) async => reply({})))),
        snapshot([1, 2]),
      );
      make();
      backend.syncFailure = TimeoutException('slow');
      await model.open();
      expect(model.tracks.length, 2);
      expect(model.error, isNull);
      expect(model.syncError, contains('更新失败'));
      expect(model.loaded, true);

      store = RecordingStore();
      make(b: FakeBackend()..syncFailure = reply({'detail': 'x'}, 504));
      await model.open();
      expect(model.tracks, isEmpty);
      expect(model.loaded, false);
      expect(model.error, contains('不是空歌单'));
    },
  );

  for (final status in [403, 409]) {
    test(
      'HTTP $status is an auth failure: cache is not shown as current, no session expiry',
      () async {
        await store.save(
          scopeOf(owner(MockClient((_) async => reply({})))),
          snapshot([1, 2]),
        );
        make();
        backend.syncFailure = reply({
          'detail': 'private detail not surfaced',
        }, status);
        var expired = false;
        session.api.onSessionExpired = () async => expired = true;
        await model.open();
        expect(model.tracks, isEmpty);
        expect(model.loaded, false);
        expect(model.error, isNotNull);
        expect(model.error, isNot(contains('private detail')));
        expect(model.syncError, isNull); // not the offline path
        expect(expired, false);
        expect(session.api.token, 'isolated-admin-session');
        // 403 also deletes the stored copy; 409 keeps it for a later verified Owner
        expect(store.clears.contains('acct-1'), status == 403);
      },
    );
  }

  test(
    '401 invalidates only the MyYaris session and drops list data',
    () async {
      make();
      backend.syncFailure = reply({'detail': 'invalid session'}, 401);
      var expired = false;
      session.api.onSessionExpired = () async {
        expired = true;
        session.api.token = '';
        session.userProfile = {};
        session.authenticated = false;
        session.publish();
      };
      await model.open();
      expect(expired, true);
      expect(model.tracks, isEmpty);
      expect(model.busy, false);
      expect(model.allowed, false);
      expect(store.saves, isEmpty);
    },
  );

  test('ordinary role is blocked without any request', () async {
    make();
    session.userProfile = {'role': 'user', 'id': 'acct-1'};
    await model.open();
    expect(backend.calls, isEmpty);
    expect(model.error, contains('管理员'));
  });

  test(
    'late response of the previous account writes nothing and shows nothing',
    () async {
      make(b: FakeBackend(ids: [1, 2]));
      backend.pageGate = Completer<void>();
      final first = model.open();
      await settle();
      await settle();
      // switch account while the old account's pull is in flight
      session.userProfile = {'role': 'admin', 'id': 'acct-2'};
      session.api.token = 'isolated-second-session';
      backend.ids = [7];
      backend.revision = 300;
      session.publish();
      backend.pageGate!.complete();
      await first;
      await settle();
      await settle();
      expect(model.tracks.map((t) => t['song_id']), [7]);
      expect(store.saves.any((s) => s.startsWith('acct-1')), false);
      expect(await store.load(scopeOf(session, account: 'acct-1')), isNull);
      expect((await store.load(scopeOf(session)))!.revision, 300);
    },
  );

  test('different verified Owner: cached rows dropped, never merged', () async {
    await store.save(
      scopeOf(owner(MockClient((_) async => reply({})))),
      snapshot([1, 2, 3], owner: 'owner-old'),
    );
    make(
      b: FakeBackend(ids: [50], owner: 'owner-new', revision: 500),
    );
    await model.open();
    expect(model.tracks.map((t) => t['song_id']), [50]);
    expect(model.ownerKey, 'owner-new');
    await settle();
    expect((await store.load(scopeOf(session)))!.ownerKey, 'owner-new');
  });

  test(
    'revision lost between pages restarts from page one, never mixes',
    () async {
      make(
        b: FakeBackend(ids: List.generate(120, (i) => i + 1))
          ..pageFailureOnce = 409,
      );
      await model.open();
      expect(model.tracks.length, 120);
      expect(model.tracks.map((t) => t['song_id']).toSet().length, 120);
    },
  );

  test(
    'older backend without the sync endpoint falls back to plain paging',
    () async {
      make(b: FakeBackend(ids: [1, 2, 3])..legacy = true);
      await model.open();
      expect(model.tracks.length, 3);
      expect(
        backend.pageQueries.every((q) => !q.containsKey('revision')),
        true,
      );
      expect(
        store.saves,
        isEmpty,
      ); // nothing verifiable to persist without a revision
    },
  );

  test('backend stale flag is surfaced and not persisted as fresh', () async {
    make(b: FakeBackend()..stale = true);
    await model.open();
    expect(model.tracks.length, 3);
    expect(model.syncError, contains('暂时连不上网易云'));
    expect(store.saves, isEmpty);
  });

  test(
    'playlist switching mid-pull clears nothing silently and reports',
    () async {
      var n = 0;
      final b = FakeBackend(ids: List.generate(120, (i) => i + 1));
      session = owner(
        MockClient((r) async {
          if (r.url.path == listPath && ++n == 2) {
            b.playlist = 456;
          }
          return b.handle(r);
        }),
      );
      model = LikedMusicController(session, store: store);
      addTearDown(() {
        model.dispose();
        session.dispose();
      });
      await model.open();
      expect(model.error ?? model.syncError, contains('已变更'));
      expect(model.loaded, false);
    },
  );

  test(
    'malformed response is not a successful empty playlist; retry works',
    () async {
      var count = 0;
      session = owner(
        MockClient((r) async {
          if (r.url.path == syncPath) {
            return reply({'code': 502, 'songs': []});
          }
          count++;
          return reply({});
        }),
      );
      model = LikedMusicController(session, store: store);
      addTearDown(() {
        model.dispose();
        session.dispose();
      });
      await model.open();
      expect(model.loaded, false);
      expect(model.error, isNotNull);
      expect(count, 0);
      expect(
        () => LikedMusicPageData.parse({
          'code': 200,
          'playlist_id': 1,
          'songs': [],
          'total': 5,
          'offset': 0,
          'limit': 30,
          'has_more': true,
        }, 0),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  group('file store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('liked_store_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    const scope = LikedMusicScope(
      origin: 'https://b.example.test',
      account: 'u1',
      device: 'car1',
    );

    test(
      'round trip keeps only whitelisted fields and no credentials',
      () async {
        final fs = FileLikedMusicStore(dir);
        final snap = snapshot([1, 2]);
        snap.tracks[0]['stream_url'] = '/api/v1/music/netease/stream/1';
        snap.tracks[0]['token'] = 'must-not-persist';
        await fs.save(scope, snap);
        final text = dir.listSync().whereType<File>().single.readAsStringSync();
        expect(text, isNot(contains('stream')));
        expect(text, isNot(contains('must-not-persist')));
        expect(text, isNot(contains('Bearer')));
        final back = await fs.load(scope);
        expect(back!.tracks.map((t) => t['song_id']), [1, 2]);
        expect(back.tracks.first['source'], 'netease');
      },
    );

    test('origin, account, device and schema isolate entries', () async {
      final fs = FileLikedMusicStore(dir);
      await fs.save(scope, snapshot([1]));
      for (final other in [
        const LikedMusicScope(
          origin: 'https://other.example.test',
          account: 'u1',
          device: 'car1',
        ),
        const LikedMusicScope(
          origin: 'https://b.example.test',
          account: 'u2',
          device: 'car1',
        ),
        const LikedMusicScope(
          origin: 'https://b.example.test',
          account: 'u1',
          device: 'car2',
        ),
      ]) {
        expect(await fs.load(other), isNull);
      }
      expect((await fs.load(scope)), isNotNull);
    });

    for (final damage in [
      'garbage',
      'truncated',
      'wrong-scope',
      'dup-id',
      'bad-type',
    ]) {
      test(
        'corrupt entry ($damage) is discarded safely after restart',
        () async {
          final fs = FileLikedMusicStore(dir);
          await fs.save(scope, snapshot([1, 2, 3]));
          final f = dir.listSync().whereType<File>().single;
          final map = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
          switch (damage) {
            case 'garbage':
              f.writeAsBytesSync([0, 255, 1, 2]);
            case 'truncated':
              f.writeAsStringSync(f.readAsStringSync().substring(0, 40));
            case 'wrong-scope':
              (map['scope'] as Map)['account'] = 'someone-else';
              f.writeAsStringSync(jsonEncode(map));
            case 'dup-id':
              (map['tracks'] as List)[1]['song_id'] = 1;
              f.writeAsStringSync(jsonEncode(map));
            default:
              (map['tracks'] as List)[0]['duration_ms'] = 'x';
              f.writeAsStringSync(jsonEncode(map));
          }
          expect(await FileLikedMusicStore(dir).load(scope), isNull);
          expect(f.existsSync(), false);
        },
      );
    }

    test(
      'purge removes everything and a late write after purge leaves nothing',
      () async {
        final fs = FileLikedMusicStore(dir);
        await fs.save(scope, snapshot([1]));
        final late = fs.save(scope, snapshot([1, 2], revision: 101));
        await fs.purgeAll();
        await late;
        expect(dir.existsSync() ? dir.listSync() : [], isEmpty);
        expect(await fs.load(scope), isNull);
      },
    );

    test('capacity bound: oversized lists are never persisted', () async {
      final fs = FileLikedMusicStore(dir);
      await fs.save(
        scope,
        snapshot(List.generate(LikedMusicStore.maxTracks + 1, (i) => i + 1)),
      );
      expect(await fs.load(scope), isNull);
    });
  });

  testWidgets(
    'page shows cached rows with status, then retry flow without playing',
    (tester) async {
      await store.save(
        scopeOf(owner(MockClient((_) async => reply({})))),
        snapshot([1]),
      );
      final b = FakeBackend(ids: [1])
        ..syncFailure = reply({'detail': 'timeout'}, 504);
      final s = owner(MockClient(b.handle));
      addTearDown(s.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LikedMusicPage(session: s, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('隔离测试曲目1'), findsOneWidget);
      expect(find.byKey(const ValueKey('liked-sync-error')), findsOneWidget);
      expect(find.textContaining('更新失败'), findsWidgets);
      b.syncFailure = null;
      await tester.tap(find.byKey(const ValueKey('liked-sync-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('liked-sync-error')), findsNothing);
      expect(find.textContaining('song_id 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty list with no cache and failed first load shows error and retry',
    (tester) async {
      var n = 0;
      final b = FakeBackend(ids: [4]);
      final s = owner(
        MockClient((r) async {
          if (r.url.path == syncPath && ++n == 1) {
            return reply({'detail': 'x'}, 504);
          }
          return b.handle(r);
        }),
      );
      addTearDown(s.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LikedMusicPage(session: s, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('不是空歌单'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('隔离测试曲目4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
