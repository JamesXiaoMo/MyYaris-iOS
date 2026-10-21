import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/local_audio.dart';
import 'widget_test.dart' show MemoryCredentials;

const nativeChannel = MethodChannel('io.myyaris/local_audio');
const origin = 'https://backend.example.test';

/// The native side of the phone player, driven through the real platform channel.
/// It records every call and models whether the phone is audible.
class FakeNativeAudio {
  FakeNativeAudio(this.world);
  final FakeWorld world;
  final calls = <MethodCall>[];
  int epoch = -1, positionMs = 0, durationMs = 200000;
  bool loaded = false;
  int _loadGeneration = 0;
  bool failNextLoad = false;
  bool buffering = false;
  bool failAllLoads = false;
  Set<int> failSongs = {};
  Uri? lastUrl;
  Map<String, String> lastHeaders = {};
  Completer<void>? holdLoad;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, _handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?) ?? {};
    switch (call.method) {
      case 'load':
        final generation = _loadGeneration;
        final url = Uri.parse(args['url'] as String);
        if (url.scheme != 'https') {
          throw PlatformException(code: 'INSECURE_URL');
        }
        if (holdLoad != null) await holdLoad!.future;
        if (generation != _loadGeneration) {
          throw PlatformException(code: 'LOAD_CANCELLED');
        }
        final song = int.tryParse(url.pathSegments.last) ?? 0;
        if (failAllLoads || failNextLoad || failSongs.contains(song)) {
          failNextLoad = false;
          world.setPhonePlaying(false);
          loaded = false;
          throw PlatformException(code: 'LOAD_FAILED');
        }
        epoch = args['epoch'] as int;
        lastUrl = url;
        lastHeaders = Map<String, String>.from(args['headers'] as Map);
        positionMs = args['positionMs'] as int;
        loaded = true;
        world.setPhonePlaying(args['autoplay'] == true && !buffering);
        return {
          'durationMs': durationMs,
          'positionMs': positionMs,
          'state': buffering
              ? 'buffering'
              : world.phonePlaying
              ? 'playing'
              : 'paused',
        };
      case 'play':
        if (!loaded || args['epoch'] != epoch) {
          throw PlatformException(code: 'NOT_LOADED');
        }
        world.setPhonePlaying(!buffering);
        await emit({
          'type': 'state',
          'state': buffering ? 'buffering' : 'playing',
        });
        return null;
      case 'pause':
        world.setPhonePlaying(false);
        return null;
      case 'seek':
        positionMs = args['positionMs'] as int;
        return null;
      case 'volume':
        return null;
      case 'stop':
        _loadGeneration++;
        loaded = false;
        world.setPhonePlaying(false);
        return null;
    }
    return null;
  }

  Iterable<MethodCall> of(String method) =>
      calls.where((c) => c.method == method);

  /// A message from the native side (state, position, completion, interruption…).
  Future<void> emit(Map<String, Object?> event) async {
    if ((event['epoch'] == null || event['epoch'] == epoch) &&
        ({'completed', 'routeLost'}.contains(event['type']) ||
            event['phase'] == 'began')) {
      world.setPhonePlaying(false);
    }
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall('event', {'epoch': epoch, ...event}),
    );
    await messenger.handlePlatformMessage(nativeChannel.name, data, (_) {});
    await Future<void>.delayed(Duration.zero);
  }
}

/// The two outputs. Any moment both are audible is recorded.
class FakeWorld {
  bool phonePlaying = false, carPlaying = false;
  bool doubleOutput = false;
  final timeline = <String>[];
  void setPhonePlaying(bool v) {
    if (v == phonePlaying) return;
    phonePlaying = v;
    timeline.add(v ? 'phone:sound' : 'phone:silent');
    if (phonePlaying && carPlaying) doubleOutput = true;
  }

  void setCarPlaying(bool v) {
    if (v == carPlaying) return;
    carPlaying = v;
    timeline.add(v ? 'car:sound' : 'car:silent');
    if (phonePlaying && carPlaying) doubleOutput = true;
  }
}

enum CommandPolicy { apply, fail, hang, httpError }

/// A deterministic backend: routes, queues, a vehicle that answers commands, and a request log.
class FakeBackend {
  FakeBackend(this.world) {
    resetCar();
  }
  final FakeWorld world;
  final log = <String>[];
  final commands = <String, Map<String, dynamic>>{};
  final posted = <Map<String, dynamic>>[];
  int favoriteCount = 137;
  final policies = <String, CommandPolicy>{};
  CommandPolicy defaultPolicy = CommandPolicy.apply;
  bool offline = false;
  int localVersion = 5000, carVersion = 40;
  int heartBatches = 0;
  Map<String, dynamic> car = {};
  final heartSongs = <int>[];
  final localQueues = <String, List<int>>{};
  final carQueues = <String, List<int>>{};
  int statusSeq = 100;
  String? lastLocalSession;
  bool carQueueGone = false;
  bool adoptFails = false;
  bool rejectHeart = false, corruptPage = false;
  Completer<void>? holdQueue;
  final transfers = <String, Map<String, dynamic>>{};

  void resetCar() {
    car = {
      'device_id': 'car_p3pro',
      'capabilities': ['queue_v2', 'handoff_v1'],
      'playback_state': 'stopped',
      'status_seq': 100,
      'software_volume': 0.4,
    };
  }

  void carShows({
    required String state,
    required int song,
    required String queueId,
    required int version,
    required String source,
    required int index,
    required int position,
    String mode = 'list_loop',
  }) {
    car = {
      ...car,
      'playback_state': state,
      'current_track_id': 'netease_$song',
      'queue_id': queueId,
      'queue_version': version,
      'queue_source': source,
      'current_index': index,
      'position_ms': position,
      'duration_ms': 200000,
      'applied_mode': mode,
      'requested_mode': mode,
      'status_seq': ++statusSeq,
    };
    world.setCarPlaying(state == 'playing');
    if (source == 'netease_favorite') {
      carQueues.putIfAbsent(
        '$queueId:$version',
        () => [for (var i = 0; i < favoriteCount; i++) 1000 + i],
      );
    }
  }

  List<int> favorite() => [for (var i = 0; i < favoriteCount; i++) 1000 + i];

  Map<String, dynamic> trackJson(int song, int index) => {
    'track_id': 'netease_$song',
    'song_id': song,
    'title': 'Song $song',
    'artist': 'Artist',
    'album': 'Album',
    'duration_ms': 200000,
    'cover_url': null,
    'stream_url': '/api/v1/music/netease/stream/$song',
    'fee': 0,
    'playable': null,
    'queue_index': index,
  };

  Map<String, dynamic> page(
    String id,
    int version,
    String source,
    List<int> songs,
    int offset,
  ) {
    final end = (offset + 50).clamp(0, songs.length);
    return {
      'code': 200,
      'queue_id': id,
      'queue_version': version,
      'source': source,
      'name': 'q',
      'total': songs.length,
      'is_complete': source != 'netease_intelligence',
      'queue_state': 'ready',
      'batch_index': 0,
      'offset': offset,
      'limit': 50,
      'has_more': end < songs.length,
      'tracks': [for (var i = offset; i < end; i++) trackJson(songs[i], i)],
    };
  }

  http.Response json(Object body, [int code = 200]) => http.Response(
    jsonEncode(body),
    code,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    final q = request.url.queryParameters;
    log.add(
      '${request.method} $path${q.isEmpty ? '' : '?${q.entries.map((e) => '${e.key}=${e.value}').join('&')}'}',
    );
    if (offline) return http.Response('down', 503);
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    if (path == '/health') return json({'status': 'ok'});
    if (path == '/api/v1/music/control/status') {
      final now = DateTime.now().toUtc().toIso8601String();
      return json({...car, 'last_heartbeat_at': now, 'updated_at': now});
    }
    if (path.startsWith('/api/v1/music/tracks/')) {
      return json({
        'track_id': path.split('/').last,
        'title': 'Song',
        'artist': 'Artist',
      });
    }
    if (path == '/api/v1/music/local/queue') {
      if (holdQueue != null) await holdQueue!.future;
      if (corruptPage && q['offset'] == '50') {
        return json(page('changed', 42, 'netease_favorite', favorite(), 50));
      }
      lastLocalSession = q['session_id'];
      final offset = int.parse(q['offset'] ?? '0');
      if (q['source'] == 'netease_favorite') {
        localQueues['q_fav_local:7001'] = favorite();
        return json(
          page('q_fav_local', 7001, 'netease_favorite', favorite(), offset),
        );
      }
      final key = '${q['queue_id']}:${q['queue_version']}';
      final songs = localQueues[key];
      if (songs == null) {
        return json({
          'detail': {'error_code': 'QUEUE_VERSION_CONFLICT'},
        }, 409);
      }
      final source = (q['queue_id'] ?? '').startsWith('q_intel')
          ? 'netease_intelligence'
          : 'netease_favorite';
      return json(
        page(
          q['queue_id']!,
          int.parse(q['queue_version']!),
          source,
          songs,
          offset,
        ),
      );
    }
    if (path == '/api/v1/music/local/intelligence') {
      if (rejectHeart) {
        return json({
          'detail': {'error_code': 'INTELLIGENCE_UNAVAILABLE'},
        }, 503);
      }
      final batch = body['batch_index'] as int;
      if (batch == 0) {
        heartSongs
          ..clear()
          ..addAll([for (var i = 0; i < 8; i++) 9000 + i]);
        heartBatches = 1;
        final version = ++localVersion;
        localQueues['q_intel_local:$version'] = List.of(heartSongs);
        return json({
          'mode': 'intelligence',
          'queue_id': 'q_intel_local',
          'queue_version': version,
          'batch_index': 0,
        });
      }
      heartBatches++;
      heartSongs.addAll([for (var i = 0; i < 8; i++) 9100 + batch * 10 + i]);
      final version = ++localVersion;
      localQueues['q_intel_local:$version'] = List.of(heartSongs);
      return json({
        'mode': 'intelligence',
        'queue_id': 'q_intel_local',
        'queue_version': version,
        'batch_index': batch,
      });
    }
    if (path == '/api/v1/music/local/queue/adopt') {
      if (adoptFails) {
        return json({
          'detail': {'error_code': 'QUEUE_VERSION_CONFLICT'},
        }, 409);
      }
      final key = 'adopt:${body['queue_id']}:${body['queue_version']}';
      final old = transfers[key];
      if (old != null) return json(old);
      final songs = carQueues['${body['queue_id']}:${body['queue_version']}'];
      if (songs == null) {
        return json({
          'detail': {'error_code': 'QUEUE_VERSION_CONFLICT'},
        }, 409);
      }
      final version = ++localVersion;
      localQueues['${body['queue_id']}:$version'] = List.of(songs);
      final source = '${body['queue_id']}'.startsWith('q_intel')
          ? 'netease_intelligence'
          : 'netease_favorite';
      final ref = {
        'queue_id': body['queue_id'],
        'queue_version': version,
        'source': source,
        'total': songs.length,
        'is_complete': source != 'netease_intelligence',
        'batch_index': 0,
      };
      transfers[key] = ref;
      return json(ref);
    }
    if (path == '/api/v1/music/local/queue/export') {
      final key = 'export:${body['queue_id']}:${body['queue_version']}';
      final old = transfers[key];
      if (old != null) return json(old);
      final songs = localQueues['${body['queue_id']}:${body['queue_version']}'];
      if (songs == null) {
        return json({
          'detail': {'error_code': 'QUEUE_VERSION_CONFLICT'},
        }, 409);
      }
      final version = ++carVersion;
      carQueues['${body['queue_id']}:$version'] = List.of(songs);
      final source = '${body['queue_id']}'.startsWith('q_intel')
          ? 'netease_intelligence'
          : 'netease_favorite';
      final ref = {
        'queue_id': body['queue_id'],
        'queue_version': version,
        'source': source,
        'total': songs.length,
        'is_complete': source != 'netease_intelligence',
        'batch_index': 0,
      };
      transfers[key] = ref;
      return json(ref);
    }
    if (path == '/api/v1/music/local/session/close') {
      return json({'status': 'closed'});
    }
    if (path == '/api/v1/music/queue') {
      final offset = int.parse(q['offset'] ?? '0');
      if (q['source'] == 'netease_favorite') {
        carQueues['q_fav_car:41'] = favorite();
        return json(
          page('q_fav_car', 41, 'netease_favorite', favorite(), offset),
        );
      }
      final key = '${q['queue_id']}:${q['queue_version']}';
      final songs = carQueues[key];
      if (carQueueGone || songs == null) {
        return json({
          'detail': {'error_code': 'QUEUE_VERSION_CONFLICT'},
        }, 409);
      }
      final source = (q['queue_id'] ?? '').startsWith('q_intel')
          ? 'netease_intelligence'
          : 'netease_favorite';
      return json(
        page(
          q['queue_id']!,
          int.parse(q['queue_version']!),
          source,
          songs,
          offset,
        ),
      );
    }
    if (path == '/api/v1/music/control/command' && request.method == 'POST') {
      return _command(body);
    }
    if (path.startsWith('/api/v1/music/control/command/')) {
      final id = Uri.decodeComponent(path.split('/').last);
      final command = commands[id];
      if (command == null) return json({'detail': 'missing'}, 404);
      return json({'command_id': id, 'status': command['status']});
    }
    return json({'detail': 'unrouted ${request.method} $path'}, 404);
  }

  http.Response _command(Map<String, dynamic> body) {
    final id = body['command_id'] as String;
    posted.add(body);
    final existing = commands[id];
    if (existing != null) {
      if (existing['action'] != body['action'] ||
          jsonEncode(existing['params']) != jsonEncode(body['params'])) {
        return json({
          'detail': {'error_code': 'COMMAND_CONFLICT'},
        }, 409);
      }
      return json({
        'command_id': id,
        'lifecycle_status': existing['status'],
        'status': 'ok',
        'duplicate': true,
      });
    }
    final action = body['action'] as String;
    final params = Map<String, dynamic>.from(body['params'] as Map);
    final policy = policies[id] ?? policies[action] ?? defaultPolicy;
    if (policy == CommandPolicy.httpError) {
      return json({
        'detail': {'error_code': 'QUEUE_VERSION_CONFLICT'},
      }, 409);
    }
    final status = switch (policy) {
      CommandPolicy.apply => 'applied',
      CommandPolicy.fail => 'failed',
      _ => 'sent',
    };
    commands[id] = {'action': action, 'params': params, 'status': status};
    if (status == 'applied') applyOnCar(action, params);
    return json({
      'command_id': id,
      'lifecycle_status': 'queued',
      'status': 'ok',
    });
  }

  void applyOnCar(String action, Map<String, dynamic> params) {
    switch (action) {
      case 'play_track':
        final autoplay = params['autoplay'] != false;
        carShows(
          state: autoplay ? 'playing' : 'paused',
          song: params['song_id'] as int,
          queueId: params['queue_id'] as String? ?? 'q_single_car',
          version: params['queue_version'] as int? ?? 1,
          source: params['source'] as String,
          index: params['queue_index'] as int? ?? 0,
          position: params['seek_ms'] as int? ?? 0,
          mode:
              (params['mode'] as String?) ??
              (params['source'] == 'netease_intelligence'
                  ? 'intelligence'
                  : 'list_loop'),
        );
      case 'resume':
        car = {
          ...car,
          'playback_state': 'playing',
          if (params['seek_ms'] != null) 'position_ms': params['seek_ms'],
          'status_seq': ++statusSeq,
        };
        world.setCarPlaying(true);
      case 'pause':
        car = {...car, 'playback_state': 'paused', 'status_seq': ++statusSeq};
        world.setCarPlaying(false);
    }
  }

  /// Marks a hung command as applied later (a late ACK).
  void lateAck(String id) {
    final command = commands[id]!;
    command['status'] = 'applied';
    applyOnCar(
      command['action'] as String,
      Map<String, dynamic>.from(command['params'] as Map),
    );
  }

  Iterable<String> get commandActions => posted.map((c) => '${c['action']}');
}

class HarnessSession extends BackendSession {
  HarnessSession({super.api, super.localEngine})
    : super(
        store: MemoryCredentials(),
        authStore: MemoryCredentials(),
        settingsStore: MemoryCredentials(),
        navigationStore: MemoryCredentials(),
        requireUserLogin: false,
      );
  @override
  void start() {}
}

class Harness {
  Harness._(this.world, this.native, this.backend, this.session);
  final FakeWorld world;
  final FakeNativeAudio native;
  final FakeBackend backend;
  final HarnessSession session;

  static Harness create({String role = 'admin'}) {
    final world = FakeWorld();
    final backend = FakeBackend(world);
    final native = FakeNativeAudio(world)..install();
    final client = MockClient(backend.handle);
    final session = HarnessSession(
      api: BackendApi(baseUrl: origin, client: client)..token = 'fixture-token',
      localEngine: NativeLocalAudioEngine(),
    );
    session.userProfile = {'role': role, 'has_device_control': true};
    session.foreground = true;
    return Harness._(world, native, backend, session);
  }

  void dispose() {
    session.dispose();
    native.uninstall();
  }
}

Future<void> settle([int ms = 5]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
