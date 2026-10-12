import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const defaultBackend =
    'https://myyaris.example.com';
String requestId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

abstract class CredentialStore {
  Future<String?> load();
  Future<void> save(String value);
  Future<void> clear();
}

class KeychainStore implements CredentialStore {
  static const channel = MethodChannel('io.myyaris/credentials');
  @override
  Future<String?> load() => channel.invokeMethod<String>('load');
  @override
  Future<void> save(String value) => channel.invokeMethod<void>('save', value);
  @override
  Future<void> clear() => channel.invokeMethod<void>('clear');
}

class ApiFailure implements Exception {
  ApiFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackendApi {
  BackendApi({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  String baseUrl = defaultBackend;
  String token = '';
  String deviceId = 'car_p3pro';
  bool get configured => token.isNotEmpty;
  static Uri validateBase(String value) {
    final u = Uri.tryParse(value.trim());
    if (u == null ||
        u.scheme != 'https' ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        (u.path.isNotEmpty && u.path != '/')) {
      throw ApiFailure('请输入无路径、无凭据的 HTTPS 后端地址');
    }
    return u;
  }

  Uri endpoint(String path, [Map<String, String>? query]) =>
      validateBase(baseUrl).replace(path: path, queryParameters: query);
  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    if (auth && !configured) throw ApiFailure('请先在设置中配置手机 Token');
    final request = http.Request(method, endpoint(path, query))
      ..followRedirects = false;
    request.headers['Accept'] = 'application/json';
    if (auth) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 15)),
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiFailure(
          response.statusCode == 401 || response.statusCode == 403
              ? '鉴权失败（${response.statusCode}），请检查手机 Token／权限'
              : '接口返回 HTTP ${response.statusCode}，请重试或核对后端',
        );
      }
      if (response.body.isEmpty) return {};
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is! Map<String, dynamic>) throw ApiFailure('接口响应格式不符');
      if (value['code'] is num &&
          (value['code'] as num) >= 400 &&
          (value['code'] as num) != 800 &&
          !path.contains('/qr/check')) {
        throw ApiFailure('上游返回错误状态 ${value['code']}');
      }
      return value;
    } on ApiFailure {
      rethrow;
    } on TimeoutException {
      throw ApiFailure('请求超时；写操作结果可能不确定，请先查询状态，不自动重发');
    } catch (_) {
      throw ApiFailure('网络连接失败，请检查 Tailscale、HTTPS 和后端状态');
    }
  }

  Future<Map<String, dynamic>> uploadAudio(Uint8List bytes, String name) async {
    if (!configured) throw ApiFailure('请先配置手机 Token');
    if (bytes.length > 10 * 1024 * 1024) throw ApiFailure('请选择 10 MB 以内的短音频');
    final request = http.MultipartRequest('POST', endpoint('/voice'))
      ..followRedirects = false;
    request.headers['Authorization'] = 'Bearer $token';
    request.fields.addAll({
      'idempotency_key': requestId(),
      'target_device_id': deviceId,
    });
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: name),
    );
    try {
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 60)),
      ).timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiFailure('音频上传返回 HTTP ${response.statusCode}');
      }
      return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw ApiFailure('音频上传失败或超时；可能已被处理，请先核对任务状态');
    }
  }

  Future<Map<String, dynamic>> command(
    String action, [
    Map<String, dynamic> params = const {},
  ]) => call(
    'POST',
    '/api/v1/music/control/command',
    body: {
      'device_id': deviceId,
      'command_id': requestId(),
      'action': action,
      'params': params,
    },
  );
  String streamPath(Map<String, dynamic> track) => track['id'] != null
      ? '/api/v1/music/netease/stream/${Uri.encodeComponent('${track['id']}')}'
      : '/api/v1/music/stream/${Uri.encodeComponent('${track['track_id']}')}';
  String canonicalStream(Map<String, dynamic> track) =>
      endpoint(streamPath(track)).toString();
  Future<Map<String, dynamic>> playTrack(Map<String, dynamic> track) =>
      command('play_track', {
        'track_id': track['track_id'] ?? 'netease_${track['id']}',
        'stream_url': canonicalStream(track),
        'title': track['title'],
        'artist': track['artist'],
      });
  Future<Map<String, dynamic>> probeStream(Map<String, dynamic> track) async {
    if (!configured) throw ApiFailure('请先配置手机 Token');
    final request = http.Request('GET', endpoint(streamPath(track)))
      ..followRedirects = false;
    request.headers.addAll({
      'Authorization': 'Bearer $token',
      'Range': 'bytes=0-1023',
    });
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.drain<void>();
        throw ApiFailure('流媒体返回 HTTP ${response.statusCode}');
      }
      final first = await response.stream.first.timeout(
        const Duration(seconds: 15),
      );
      return {
        'http_status': response.statusCode,
        'content_type': response.headers['content-type'],
        'content_range': response.headers['content-range'],
        'first_chunk_bytes': first.length,
        'note': '仅检查首块响应，不代表车机已播放',
      };
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw ApiFailure('流媒体检查失败或超时');
    }
  }

  void close() => client.close();
}

class BackendSession extends ChangeNotifier {
  BackendSession({BackendApi? api, CredentialStore? store})
    : api = api ?? BackendApi(),
      store = store ?? KeychainStore();
  final BackendApi api;
  final CredentialStore store;
  Map<String, dynamic> health = {},
      playback = {},
      lastTask = {},
      currentTrack = {};
  final knownTracks = <String, Map<String, dynamic>>{};
  String connection = '未配置', realtime = '未连接', lastMessage = '';
  DateTime? statusReceivedAt;
  DateTime? lastPongAt;
  bool foreground = true, disposed = false;
  WebSocket? socket;
  Timer? pollTimer, reconnectTimer, pingTimer;
  int generation = 0, failures = 0;
  bool refreshing = false;
  final pendingCommands = <String, Completer<void>>{};
  void publish() {
    if (!disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final raw = await store.load();
      if (disposed) return;
      if (raw != null) {
        final data = jsonDecode(raw) as Map;
        BackendApi.validateBase('${data['base']}');
        api.baseUrl = '${data['base']}';
        api.token = '${data['token']}';
        api.deviceId = '${data['device']}';
      }
      if (api.configured) start();
    } catch (_) {
      connection = '未配置（凭据未载入）';
    }
    publish();
  }

  Future<void> configure(
    String base,
    String token,
    String device, {
    bool tokenProvided = false,
  }) async {
    final u = BackendApi.validateBase(base);
    if (token.trim().isEmpty || device.trim().isEmpty) {
      throw ApiFailure('手机 Token 和车机 ID 不能为空');
    }
    if (api.configured &&
        u.origin != BackendApi.validateBase(api.baseUrl).origin &&
        !tokenProvided) {
      throw ApiFailure('更换后端地址时，请重新提供对应手机 Token；不会把旧凭据发往新地址');
    }
    if (RegExp(r'\s').hasMatch(token.trim())) {
      throw ApiFailure('请只输入手机 Token，不包含 Bearer 前缀或空白');
    }
    await store.save(
      jsonEncode({
        'base': u.origin,
        'token': token.trim(),
        'device': device.trim(),
      }),
    );
    if (disposed) return;
    stop();
    api.baseUrl = u.origin;
    api.token = token.trim();
    api.deviceId = device.trim();
    playback = {};
    lastTask = {};
    currentTrack = {};
    knownTracks.clear();
    statusReceivedAt = null;
    health = {};
    connection = '连接中';
    start();
    publish();
  }

  Future<void> clear() async {
    await store.clear();
    stop();
    api.token = '';
    playback = {};
    lastTask = {};
    currentTrack = {};
    health = {};
    statusReceivedAt = null;
    connection = '未配置';
    publish();
  }

  void start() {
    if (!foreground || !api.configured || disposed) return;
    stop();
    foreground = true;
    unawaited(refresh());
    unawaited(connect());
    pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(refresh()),
    );
  }

  void stop() {
    generation++;
    pollTimer?.cancel();
    reconnectTimer?.cancel();
    pingTimer?.cancel();
    final old = socket;
    socket = null;
    unawaited(old?.close());
    realtime = '未连接';
    for (final pending in pendingCommands.values) {
      if (!pending.isCompleted) {
        pending.completeError(ApiFailure('连接中断，指令执行结果未知；请核对车机状态'));
      }
    }
    pendingCommands.clear();
  }

  void setForeground(bool value) {
    foreground = value;
    if (value) {
      start();
    } else {
      stop();
      publish();
    }
  }

  Future<void> refresh() async {
    if (refreshing || !foreground || !api.configured || disposed) return;
    refreshing = true;
    final gen = generation;
    try {
      final h = await api.call('GET', '/health', auth: false);
      final p = await api.call(
        'GET',
        '/api/v1/music/control/status',
        query: {'device_id': api.deviceId},
      );
      if (gen != generation || disposed) return;
      health = h;
      playback = p;
      connection = '后端可达';
      statusReceivedAt = DateTime.now();
      final track = '${p['current_track_id'] ?? ''}';
      if (track.isEmpty) currentTrack = {};
      if (track.isNotEmpty &&
          currentTrack['track_id'] != track &&
          knownTracks.containsKey(track)) {
        currentTrack = knownTracks[track]!;
      }
      if (track.isNotEmpty && currentTrack['track_id'] != track) {
        try {
          final t = await api.call(
            'GET',
            '/api/v1/music/tracks/${Uri.encodeComponent(track)}',
          );
          if (gen == generation) currentTrack = t;
        } catch (_) {
          if (gen == generation) {
            currentTrack = {'track_id': track, 'title': track};
          }
        }
      }
      if (lastTask['task_id'] != null) {
        final task = await api.call(
          'GET',
          '/tasks/${Uri.encodeComponent('${lastTask['task_id']}')}',
        );
        if (gen == generation) lastTask = task;
      }
    } catch (e) {
      if (gen == generation) {
        connection = '连接异常';
        lastMessage = e.toString();
      }
    } finally {
      refreshing = false;
      publish();
    }
  }

  Future<void> connect() async {
    if (disposed || !foreground || !api.configured) return;
    final gen = generation;
    try {
      final uri = api
          .endpoint('/api/v1/ws/music', {
            'client_type': 'phone',
            'device_id': api.deviceId,
          })
          .replace(scheme: 'wss');
      final ws = await WebSocket.connect(
        uri.toString(),
        headers: {'Authorization': 'Bearer ${api.token}'},
      ).timeout(const Duration(seconds: 12));
      if (gen != generation || !foreground || disposed) {
        await ws.close();
        return;
      }
      socket = ws;
      realtime = '实时已连接';
      failures = 0;
      lastPongAt = DateTime.now();
      publish();
      pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (socket == ws) {
          if (lastPongAt != null &&
              DateTime.now().difference(lastPongAt!).inSeconds > 60) {
            unawaited(ws.close());
            disconnected(gen);
            return;
          }
          ws.add(jsonEncode({'type': 'ping'}));
        }
      });
      ws.listen(
        (event) {
          if (gen != generation || disposed) return;
          consumeRealtime(event);
        },
        onDone: () => disconnected(gen),
        onError: (_) => disconnected(gen),
        cancelOnError: true,
      );
    } catch (_) {
      disconnected(gen);
    }
  }

  void rememberTrack(Map<String, dynamic> track) {
    final id = '${track['track_id'] ?? 'netease_${track['id']}'}';
    knownTracks[id] = {...track, 'track_id': id};
    if (knownTracks.length > 200) knownTracks.remove(knownTracks.keys.first);
  }

  void consumeRealtime(dynamic event) {
    try {
      final m = jsonDecode(event as String) as Map;
      if (m['type'] == 'pong') lastPongAt = DateTime.now();
      if (m['type'] == 'command_ack') {
        final pending = pendingCommands.remove('${m['command_id']}');
        if (m['status'] == 'ok' || m['status'] == 'dispatched') {
          pending?.complete();
        } else {
          pending?.completeError(ApiFailure('实时指令未被接受'));
        }
      }
      if (m['type'] == 'status_snapshot' || m['type'] == 'status_update') {
        final data = Map<String, dynamic>.from(m['data'] as Map);
        if (data['device_id'] != null && data['device_id'] != api.deviceId) {
          return;
        }
        playback = {...playback, ...data};
        final id = '${playback['current_track_id'] ?? ''}';
        if (id.isEmpty) {
          currentTrack = {};
        } else if (knownTracks.containsKey(id)) {
          currentTrack = knownTracks[id]!;
        } else if (currentTrack['track_id'] != id) {
          currentTrack = {'track_id': id, 'title': id};
        }
        statusReceivedAt = DateTime.now();
        publish();
      }
    } catch (_) {
      realtime = '实时消息格式异常';
      publish();
    }
  }

  void disconnected(int gen) {
    if (gen != generation ||
        !foreground ||
        disposed ||
        !api.configured ||
        reconnectTimer?.isActive == true) {
      return;
    }
    socket = null;
    for (final pending in pendingCommands.values) {
      if (!pending.isCompleted) {
        pending.completeError(ApiFailure('实时连接断开，指令执行结果未知'));
      }
    }
    pendingCommands.clear();
    pingTimer?.cancel();
    realtime = '实时断开，HTTP 状态补偿';
    publish();
    final delay = min(30, 1 << min(5, failures++));
    reconnectTimer = Timer(
      Duration(seconds: delay),
      () => unawaited(connect()),
    );
  }

  Future<void> sendCommand(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (!api.configured) throw ApiFailure('请先配置手机 Token');
    final ws = socket;
    if (ws != null && ws.readyState == WebSocket.open) {
      final id = requestId();
      final pending = Completer<void>();
      pendingCommands[id] = pending;
      try {
        ws.add(
          jsonEncode({
            'type': 'command',
            'data': {
              'command_id': id,
              'device_id': api.deviceId,
              'action': action,
              'params': params,
            },
          }),
        );
        await pending.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        throw ApiFailure('指令确认超时，结果未知；不自动通过 HTTP 重发');
      } finally {
        pendingCommands.remove(id);
      }
    } else {
      await api.command(action, params);
    }
    lastMessage = '指令已提交，等待车机状态回报';
    publish();
  }

  bool get playing => playback['playback_state'] == 'playing';
  String get taskLabel => switch (lastTask['status']) {
    'queued' => '已排队',
    'received' => '车机已接收',
    'launch_requested' => '已请求打开 NAVITIME',
    'failed' => '任务失败',
    'expired' => '任务过期',
    'superseded' => '已被替代',
    _ => '暂无导航任务',
  };
  bool get heartbeatFresh {
    final h = DateTime.tryParse('${playback['last_heartbeat_at'] ?? ''}');
    return h != null &&
        DateTime.now().toUtc().difference(h.toUtc()).inSeconds.abs() < 60;
  }

  @override
  void dispose() {
    disposed = true;
    stop();
    api.close();
    super.dispose();
  }
}
