import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/login_page.dart';
import 'package:myyaris_ios/api/user_auth.dart';

const fixtureBackend = 'https://backend.example.test';

const fixtureSession = 'isolated-test-session-012345678901234567890123';
Map<String, dynamic> profile({bool control = true}) => {
  'id': 'fixture-user',
  'username': 'fixture_user',
  'nickname': '测试昵称',
  'avatar_url': null,
  'role': 'user',
  'is_active': true,
  'has_device_control': control,
};
Map<String, dynamic> loginBody({bool control = true}) => {
  'session_id': fixtureSession,
  'token_type': 'bearer',
  'expires_at': DateTime.now()
      .toUtc()
      .add(const Duration(days: 1))
      .toIso8601String(),
  'user': profile(control: control),
};
http.Response jsonReply(Object data, int status) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class MemoryStore implements CredentialStore {
  String? value;
  int cleared = 0;
  bool failSave = false;
  @override
  Future<String?> load() async => value;
  @override
  Future<void> save(String value) async {
    if (failSave) throw StateError('fixture storage failure');
    this.value = value;
  }

  @override
  Future<void> clear() async {
    value = null;
    cleared++;
  }
}

class AccountSession extends BackendSession {
  AccountSession({
    required super.api,
    required super.store,
    required super.authStore,
    required super.settingsStore,
    super.webSocketConnector,
  });
  int starts = 0;
  @override
  void start() {
    starts++;
  }
}

class FakeSocket implements WebSocket {
  final controller = StreamController<dynamic>();
  @override
  int get readyState => WebSocket.open;
  @override
  int? closeCode;
  @override
  String? get closeReason => null;
  @override
  void add(dynamic value) {}
  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode = code;
    await controller.close();
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => controller.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'login uses no old credentials; restores dynamic session and logout preserves legacy/domain',
    () async {
      final legacy = MemoryStore()
        ..value = jsonEncode({
          'base': fixtureBackend,
          'device': 'car_p3pro',
          'token': 'isolated-legacy-fixture',
        });
      final auth = MemoryStore(), settings = MemoryStore();
      final requests = <http.Request>[];
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/login')) {
            expect(r.headers.containsKey('Authorization'), false);
            expect(r.headers.containsKey('Cookie'), false);
            return jsonReply(loginBody(), 200);
          }
          expect(r.headers['Authorization'], 'Bearer $fixtureSession');
          return jsonReply(
            r.url.path.endsWith('/me') ? profile() : {'code': 200},
            200,
          );
        }),
      );
      final session = AccountSession(
        api: api,
        store: legacy,
        authStore: auth,
        settingsStore: settings,
      );
      addTearDown(session.dispose);
      await session.initialize();
      expect(session.authenticated, false);
      expect(api.token, isEmpty);
      expect(legacy.cleared, 0);
      await session.login(fixtureBackend, 'fixture_user', 'fixture-password');
      expect(session.authenticated, true);
      expect(session.canControlVehicle, true);
      expect(auth.value!.contains('fixture-password'), false);
      expect(settings.value!.contains(fixtureSession), false);
      expect(legacy.value, contains('isolated-legacy-fixture'));
      await session.logout();
      expect(session.authenticated, false);
      expect(auth.value, isNull);
      expect(api.token, isEmpty);
      expect(settings.value, contains(fixtureBackend));
      expect(legacy.cleared, 0);
      expect(
        requests.map((r) => r.url.path),
        isNot(contains('/api/v1/auth/bootstrap-admin')),
      );
    },
  );
  test(
    'valid cached session is verified and restored without resending a password',
    () async {
      final auth = MemoryStore()
        ..value = UserSessionRecord.fromLogin(
          loginBody(control: false),
        ).encode(fixtureBackend, 'car_p3pro');
      final settings = MemoryStore()
        ..value = jsonEncode({'base': fixtureBackend, 'device': 'car_p3pro'});
      final methods = <String>[];
      final api = BackendApi(
        client: MockClient((r) async {
          expect(r.url.origin, fixtureBackend);
          methods.add(r.method);
          expect(r.url.path, '/api/v1/auth/me');
          expect(r.headers['Authorization'], 'Bearer $fixtureSession');
          expect(r.headers.containsKey('Cookie'), false);
          return jsonReply(profile(control: false), 200);
        }),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: auth,
        settingsStore: settings,
      );
      addTearDown(session.dispose);
      await session.initialize();
      expect(api.baseUrl, fixtureBackend);
      expect(settings.cleared, 0);
      expect(auth.cleared, 0);
      expect(session.authenticated, true);
      expect(session.userProfile['nickname'], '测试昵称');
      expect(session.canControlVehicle, false);
      expect(methods, ['GET']);
    },
  );
  test(
    'register is a normal user request with no role/bootstrap/binding and no implicit login',
    () async {
      final auth = MemoryStore();
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((r) async {
          expect(r.url.path, '/api/v1/auth/register');
          final body = jsonDecode(r.body) as Map;
          expect(body.containsKey('role'), false);
          expect(body.containsKey('has_device_control'), false);
          expect(r.headers.containsKey('Authorization'), false);
          return jsonReply(profile(control: false), 201);
        }),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: auth,
        settingsStore: MemoryStore(),
      );
      addTearDown(session.dispose);
      await session.register(
        fixtureBackend,
        'fixture_user',
        'fixture-password',
        '',
      );
      expect(session.authenticated, false);
      expect(auth.value, isNull);
      expect(session.canControlVehicle, false);
    },
  );
  test(
    'wrong password and disabled registration are clear and do not persist passwords',
    () async {
      final auth = MemoryStore();
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient(
          (r) async => jsonReply({
            'detail': 'must not echo private server body',
          }, r.url.path.endsWith('/login') ? 401 : 403),
        ),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: auth,
        settingsStore: MemoryStore(),
      );
      addTearDown(session.dispose);
      await expectLater(
        session.login(fixtureBackend, 'fixture_user', 'wrong-fixture-password'),
        throwsA(
          predicate(
            (e) =>
                e is ApiFailure &&
                e.statusCode == 401 &&
                e.message == '用户名或密码不正确',
          ),
        ),
      );
      expect(auth.value, isNull);
      expect(session.authenticated, false);
      await expectLater(
        session.register(
          fixtureBackend,
          'fixture_user',
          'fixture-password',
          '',
        ),
        throwsA(predicate((e) => e is ApiFailure && e.message == '后端未开放普通注册')),
      );
    },
  );
  test(
    'restore verifies me; 401 expires session and stops transport',
    () async {
      final auth = MemoryStore()
        ..value = UserSessionRecord.fromLogin(
          loginBody(),
        ).encode(fixtureBackend, 'car_p3pro');
      final settings = MemoryStore()
        ..value = jsonEncode({'base': fixtureBackend, 'device': 'car_p3pro'});
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((_) async => jsonReply({'detail': 'expired'}, 401)),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: auth,
        settingsStore: settings,
      );
      addTearDown(session.dispose);
      await session.initialize();
      expect(session.authInitialized, true);
      expect(session.authenticated, false);
      expect(api.token, isEmpty);
      expect(auth.value, isNull);
      expect(session.pollTimer?.isActive ?? false, false);
      expect(session.authMessage, contains('失效'));
    },
  );
  test(
    '403 blocks device access without expiring a valid user session or granting rights',
    () async {
      final auth = MemoryStore();
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient(
          (r) async => jsonReply(
            r.url.path.endsWith('/login')
                ? loginBody()
                : {'detail': 'forbidden'},
            r.url.path.endsWith('/login') ? 200 : 403,
          ),
        ),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: auth,
        settingsStore: MemoryStore(),
      );
      addTearDown(session.dispose);
      await session.login(fixtureBackend, 'fixture_user', 'fixture-password');
      await expectLater(
        api.call('GET', '/api/v1/music/control/status'),
        throwsA(predicate((e) => e is ApiFailure && e.statusCode == 403)),
      );
      expect(session.authenticated, true);
      expect(api.token, fixtureSession);
      expect(session.deviceDenied, true);
      expect(session.canControlVehicle, false);
      expect(auth.value, isNotNull);
      await expectLater(
        session.sendCommand('resume'),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test(
    'ordinary login without binding keeps identity and no vehicle control',
    () async {
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient(
          (_) async => jsonReply(loginBody(control: false), 200),
        ),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: MemoryStore(),
        settingsStore: MemoryStore(),
      );
      addTearDown(session.dispose);
      await session.login(fixtureBackend, 'fixture_user', 'fixture-password');
      expect(session.userProfile['role'], 'user');
      expect(session.authenticated, true);
      expect(session.canControlVehicle, false);
      await expectLater(
        session.sendCommand('resume'),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test(
    'websocket handshake uses same dynamic Bearer header, no query credentials; expired close logs out',
    () async {
      final socket = FakeSocket();
      Uri? wsUri;
      Map<String, String>? headers;
      final auth = MemoryStore();
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient(
          (r) async => jsonReply(
            r.url.path.endsWith('/login') ? loginBody() : profile(),
            200,
          ),
        ),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: auth,
        settingsStore: MemoryStore(),
        webSocketConnector: (uri, h) async {
          wsUri = uri;
          headers = h;
          return socket;
        },
      );
      addTearDown(session.dispose);
      await session.login(fixtureBackend, 'fixture_user', 'fixture-password');
      await session.connect();
      expect(headers!['Authorization'], 'Bearer $fixtureSession');
      expect(headers!.containsKey('Cookie'), false);
      expect(wsUri!.queryParameters['client_type'], 'phone');
      expect(wsUri!.toString().contains(fixtureSession), false);
      await socket.close(4401);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.authenticated, false);
      expect(api.token, isEmpty);
      expect(auth.value, isNull);
      expect(session.reconnectTimer?.isActive ?? false, false);
    },
  );
  testWidgets(
    'login page clears password on failure and gate hides old navigation routes',
    (tester) async {
      final api = BackendApi(
        baseUrl: 'https://backend.example.test',
        client: MockClient((_) async => jsonReply({}, 401)),
      );
      final session = AccountSession(
        api: api,
        store: MemoryStore(),
        authStore: MemoryStore(),
        settingsStore: MemoryStore(),
      );
      addTearDown(session.dispose);
      session.authInitialized = true;
      await tester.pumpWidget(
        MaterialApp(
          home: AuthenticationGate(
            session: session,
            child: const Text('private account data'),
          ),
        ),
      );
      expect(find.text('private account data'), findsNothing);
      expect(find.text('手机 Token'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('login-username')),
        'fixture_user',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-password')),
        'wrong-fixture-password',
      );
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('用户名或密码不正确'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('login-password')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );
}
