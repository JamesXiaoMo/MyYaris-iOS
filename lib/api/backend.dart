import 'contracts.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const defaultBackend =
    'https://myyaris.example.com';
const verifyMode = bool.fromEnvironment('MY_YARIS_VERIFY_LOGS');
void verifyLog(String event) {
  if (verifyMode) debugPrint('[MyYarisVerify] $event');
}

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

String safeErrorCode(Map value) {
  final code = '${value['error_code'] ?? value['code'] ?? ''}';
  const allowed = {
    'INVALID_ACTION',
    'INVALID_PARAMS',
    'FORBIDDEN',
    'AUTH_FAILED',
    'ASR_UNAVAILABLE',
    'ASR_NOT_CONFIGURED',
    'NLP_UNAVAILABLE',
    'NLP_NOT_CONFIGURED',
    'VOICE_PROVIDER_UNAVAILABLE',
    'PROVIDER_UNAVAILABLE',
    'TRACK_DECODE_ERROR',
    'AUDIO_DECODE_ERROR',
    'STREAM_HTTP_ERROR',
    'TRACK_NOT_FOUND',
    'UNSUPPORTED_SOURCE',
    'PLAYER_NOT_READY',
    'COMMAND_EXPIRED',
    'COMMAND_EXECUTION_ERROR',
  };
  return allowed.contains(code) ? code : '接口错误（请核对后端脱敏日志）';
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

  Future<void> ensureResolveOnlyContract() async {
    final spec = await call('GET', '/openapi.json', auth: false);
    Map<String, dynamic> schema(Map<String, dynamic> value) {
      final ref = value[r'$ref'];
      if (ref is String) {
        return Map<String, dynamic>.from(
          (spec['components'] as Map?)?['schemas']?[ref.split('/').last]
                  as Map? ??
              {},
        );
      }
      return value;
    }

    final paths = spec['paths'] as Map? ?? {};
    final request =
        ((paths['/api/v1/tasks/destination'] as Map?)?['post']
            as Map?)?['requestBody']?['content']?['application/json']?['schema'];
    final task = request is Map
        ? schema(Map<String, dynamic>.from(request))['properties'] as Map?
        : null;
    final legacy =
        (spec['components']
                as Map?)?['schemas']?['DestinationCreateRequest']?['properties']
            as Map?;
    if (legacy?.containsKey('auto_create_task') != true ||
        task?.containsKey('target_device_id') != true) {
      throw ApiFailure('后端尚未提供本轮两阶段契约标识；已阻止旧版提前派发，请等待后端部署');
    }
  }

  Future<Map<String, dynamic>> resolveDestination(
    String input,
    String key,
  ) async {
    await ensureResolveOnlyContract();
    final result = await call(
      'POST',
      '/api/v1/destinations/resolve',
      body: {'raw_input': input, 'source': 'ios_share'},
    );
    if (result['task_id'] != null) {
      throw ApiFailure('解析阶段意外生成任务，已停止后续派发，请核对后端契约');
    }
    return result;
  }

  Future<Map<String, dynamic>> dispatchDestination(
    String id,
    String candidateId,
    String key, {
    bool singleCandidate = false,
  }) async {
    final result = singleCandidate
        ? await call(
            'POST',
            '/api/v1/tasks/destination',
            body: {
              'destination_id': id,
              'target_device_id': deviceId,
              'expires_in_seconds': 3600,
            },
          )
        : await call(
            'POST',
            '/destinations/${Uri.encodeComponent(id)}/confirm',
            body: {'candidate_id': candidateId, 'target_device_id': deviceId},
          );
    if (result['device_id'] != null &&
        !MusicContract.sameDevice(result['device_id'], deviceId)) {
      throw ApiFailure('已提交但后端返回目标设备不符，勿重复派发');
    }
    return result;
  }

  Future<void> ensureVoiceProvider() async {
    final h = await call('GET', '/health', auth: false);
    final capabilities = h['capabilities'];
    final voice = capabilities is Map ? capabilities['voice'] : null;
    final ready =
        voice is Map &&
        voice['asr_ready'] == true &&
        voice['nlp_ready'] == true &&
        voice['resolve_only'] == true &&
        voice['mock'] != true;
    if (!ready) {
      throw ApiFailure('后端未确认真实 ASR/NLP provider 就绪，语音解析暂不可用；文字导航仍可使用');
    }
  }

  Future<Map<String, dynamic>> uploadAudio(Uint8List bytes, String name) async {
    if (!configured) throw ApiFailure('请先配置手机 Token');
    await ensureVoiceProvider();
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
        throw ApiFailure(
          response.statusCode == 501 || response.statusCode == 503
              ? '语音能力暂不可用（HTTP ${response.statusCode}），请配置后端 ASR/NLP provider'
              : '音频上传返回 HTTP ${response.statusCode}',
        );
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
      if (data['status'] == 'failed' || data['status'] == 'unavailable') {
        throw ApiFailure('后端未完成语音转写/解析；${safeErrorCode(data)}');
      }
      return data;
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw ApiFailure('音频上传失败或超时；可能已被处理，请先核对任务状态');
    }
  }

  Future<Map<String, dynamic>> command(
    String action, [
    Map<String, dynamic> params = const {},
    String? commandId,
  ]) => call(
    'POST',
    '/api/v1/music/control/command',
    body: {
      'device_id': deviceId,
      'command_id': commandId ?? requestId(),
      'action': action,
      'params': MusicContract.params(action, params, validateBase(baseUrl)),
    },
  );
  String trackSource(Map<String, dynamic> track) {
    if (track['source'] == 'local_repo' || track['source'] == 'netease_cache') {
      return '${track['source']}';
    }
    if (track['source'] == 'netease' ||
        track['id'] != null ||
        track['song_id'] != null) {
      return 'netease';
    }
    if (track['track_id'] != null) return 'local_repo';
    throw ApiFailure('缺少曲目来源');
  }

  int songId(Map<String, dynamic> track) {
    final id = int.tryParse(
      '${track['song_id'] ?? track['id'] ?? '${track['track_id'] ?? ''}'.replaceFirst('netease_', '')}',
    );
    if (id == null || id <= 0) throw ApiFailure('网易云歌曲 ID 无效');
    return id;
  }

  String trackId(Map<String, dynamic> track) {
    if (trackSource(track) == 'netease') return 'netease_${songId(track)}';
    final id = '${track['track_id'] ?? ''}';
    if (id.isEmpty) throw ApiFailure('缺少本地曲目 ID');
    return id;
  }

  String streamPath(Map<String, dynamic> track) =>
      trackSource(track) == 'netease'
      ? '/api/v1/music/netease/stream/${songId(track)}'
      : '/api/v1/music/stream/${Uri.encodeComponent(trackId(track))}';
  String canonicalStream(Map<String, dynamic> track) =>
      endpoint(streamPath(track)).toString();
  Map<String, dynamic> trackParams(Map<String, dynamic> track) => {
    'track_id': trackId(track),
    'source': trackSource(track),
    'stream_url': canonicalStream(track),
    if (trackSource(track) == 'netease') 'song_id': songId(track),
    if (track['title'] != null) 'title': track['title'],
    if (track['artist'] != null) 'artist': track['artist'],
  };
  Future<Map<String, dynamic>> playTrack(Map<String, dynamic> track) =>
      command('play_track', trackParams(track));
  Future<Map<String, dynamic>> searchOnline(
    String keyword, {
    int page = 1,
  }) async {
    if (keyword.trim().isEmpty) throw ApiFailure('请输入网易云搜索关键词');
    final response = await call(
      'GET',
      '/api/v1/music/netease/search',
      query: {'keyword': keyword.trim(), 'page': '$page', 'limit': '20'},
    );
    final songs = response['songs'];
    if (response['success'] == false ||
        response['available'] == false ||
        response['error_code'] != null) {
      throw ApiFailure('网易云搜索服务不可用，请核对后端及账号/地区条件');
    }
    if (songs is! List || response['total'] is! num) {
      throw ApiFailure('网易云搜索响应格式错误，不当作无结果');
    }
    final normalized = songs.map((item) {
      if (item is! Map) throw ApiFailure('搜索曲目格式错误');
      final track = Map<String, dynamic>.from(item);
      final id = songId(track);
      return {...track, 'id': id, 'song_id': id, 'source': 'netease'};
    }).toList();
    return {...response, 'songs': normalized};
  }

  Future<Map<String, dynamic>> ensureOnlinePlayable(
    Map<String, dynamic> track,
  ) async {
    final id = songId(track);
    final resource = await call(
      'GET',
      '/api/v1/music/netease/song_url',
      query: {'song_id': '$id', 'level': 'exhigh'},
    );
    if (resource['song_id'] != id ||
        resource['url'] is! String ||
        (resource['url'] as String).trim().isEmpty) {
      throw ApiFailure('该曲目未取得可播资源；可能受账号、会员、地区或上游限制。请在App设置检查网易云授权或换歌');
    }
    return probeStream({...track, 'source': 'netease', 'song_id': id});
  }

  Future<Map<String, dynamic>> probeStream(Map<String, dynamic> track) async {
    if (!configured) throw ApiFailure('请先配置手机 Token');
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      endpoint(streamPath(track)),
      abortTrigger: abort.future,
    )..followRedirects = false;
    request.headers.addAll({
      'Authorization': 'Bearer $token',
      'Range': 'bytes=0-1023',
      'Accept': 'audio/*',
    });
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw ApiFailure('音频首段检查返回 HTTP ${response.statusCode}，未发送播放指令');
      }
      final type = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .toLowerCase()
          .trim();
      if (!type.startsWith('audio/') &&
          type != 'application/octet-stream' &&
          type != 'application/ogg') {
        throw ApiFailure('响应不是音频 Content-Type，未发送播放指令');
      }
      final range = response.headers['content-range'] ?? '';
      final match = RegExp(r'^bytes 0-([0-9]+)/([0-9]+)$').firstMatch(range);
      if (response.statusCode == 206 &&
          (match == null ||
              int.parse(match[1]!) > 1023 ||
              int.parse(match[2]!) <= int.parse(match[1]!))) {
        throw ApiFailure('206音频范围不符合请求，未发送播放指令');
      }
      final sample = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        sample.addAll(chunk.take(1024 - sample.length));
        if (sample.length >= 1024) break;
      }
      bool starts(List<int> bytes) =>
          sample.length >= bytes.length &&
          List.generate(
            bytes.length,
            (i) => sample[i] == bytes[i],
          ).every((v) => v);
      final audioHeader =
          starts([73, 68, 51]) ||
          (sample.length >= 2 && sample[0] == 255 && sample[1] & 224 == 224) ||
          starts([79, 103, 103, 83]) ||
          starts([102, 76, 97, 67]) ||
          (starts([82, 73, 70, 70]) &&
              sample.length >= 12 &&
              ascii.decode(sample.sublist(8, 12), allowInvalid: true) ==
                  'WAVE') ||
          (sample.length >= 12 &&
              ascii.decode(sample.sublist(4, 8), allowInvalid: true) == 'ftyp');
      if (!audioHeader) throw ApiFailure('首段缺少支持的音频头，未发送播放指令');
      return {
        'http_status': response.statusCode,
        'content_type': type,
        'content_range': range,
        'range_supported': response.statusCode == 206,
        'first_chunk_bytes': sample.length,
        'audio_header_detected': true,
        'note': '仅首段检查，不证明完整音频、版权/会员权限或车机已播放',
      };
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw ApiFailure('音频首段检查失败或超时，未发送播放指令');
    } finally {
      if (!abort.isCompleted) abort.complete();
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
  bool? backendOnline;
  bool? verificationBackendOverride;
  bool? get displayedBackendOnline =>
      const bool.fromEnvironment('MY_YARIS_HOME_VERIFY')
      ? verificationBackendOverride ?? backendOnline
      : backendOnline;
  String get backendLabel => !api.configured
      ? '未配置'
      : displayedBackendOnline == true
      ? '在线'
      : displayedBackendOnline == false
      ? '离线'
      : '检测中';
  DateTime? statusReceivedAt;
  DateTime? lastPongAt;
  bool foreground = true, disposed = false;
  WebSocket? socket;
  Timer? pollTimer, reconnectTimer, pingTimer;
  int generation = 0, failures = 0;
  bool refreshing = false;
  Map<String, dynamic> lastCommandReceipt = {}, lastCommandState = {};
  bool commandPending = false, preparingTrack = false;
  bool get awaitingExecution => {
    'submitting',
    'accepted',
    'queued',
    'sent',
    'received',
    'unknown',
  }.contains(lastCommandState['status']);
  Map<String, dynamic> lastTrackProbe = {}, musicDiagnostic = {};
  final issuedCommands = <String, String>{};
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
      verifyLog(api.configured ? 'CONFIG_PRESENT' : 'CONFIG_MISSING');
      if (api.configured) start();
    } catch (_) {
      connection = '未配置（凭据未载入）';
      verifyLog('CONFIG_LOAD_UNAVAILABLE');
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
    issuedCommands.clear();
    lastCommandReceipt = {};
    lastCommandState = {};
    statusReceivedAt = null;
    health = {};
    backendOnline = null;
    connection = '连接中';
    start();
    publish();
  }

  Future<void> clear() async {
    await store.clear();
    stop();
    api.token = '';
    knownTracks.clear();
    issuedCommands.clear();
    lastCommandReceipt = {};
    lastCommandState = {};
    playback = {};
    lastTask = {};
    currentTrack = {};
    health = {};
    statusReceivedAt = null;
    backendOnline = null;
    connection = '未配置';
    publish();
  }

  void start() {
    if (!foreground || !api.configured || disposed) return;
    stop();
    foreground = true;
    unawaited(refresh());
    unawaited(connect());
    pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(refresh());
      if (!{
        'applied',
        'executed',
        'failed',
        'expired',
      }.contains(lastCommandState['status'])) {
        unawaited(refreshCommandState());
      }
    });
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
      Map<String, dynamic> h;
      try {
        h = await api.call('GET', '/health', auth: false);
        if (gen != generation || disposed) return;
        health = h;
        backendOnline = {'ok', 'healthy'}.contains(h['status']);
        publish();
        if (backendOnline != true) throw ApiFailure('后端健康检测未通过');
      } catch (_) {
        if (gen == generation && !disposed) {
          backendOnline = false;
          health = {};
          publish();
        }
        rethrow;
      }
      final p = await api.call(
        'GET',
        '/api/v1/music/control/status',
        query: {'device_id': api.deviceId},
      );
      if (gen != generation || disposed) return;
      health = h;
      if (p['device_id'] != null &&
          !MusicContract.sameDevice(p['device_id'], api.deviceId)) {
        throw ApiFailure('后端返回的设备不匹配，未应用快照');
      }
      final validated = MusicContract.statusPatch(p);
      if (validated.isEmpty) throw ApiFailure('后端快照无有效状态，保留最后一次状态');
      playback = {...playback, ...validated};
      connection = '后端可达';
      verifyLog('HTTP_STATE_RECEIVED');
      statusReceivedAt = DateTime.now();
      final track = '${playback['current_track_id'] ?? ''}';
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
        try {
          final task = await api.call(
            'GET',
            '/tasks/${Uri.encodeComponent('${lastTask['task_id']}')}',
          );
          if (gen == generation) lastTask = task;
        } catch (e) {
          if (gen == generation) lastMessage = '任务状态暂未更新：$e';
        }
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
      verifyLog('WSS_CONNECTED');
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
    final id = api.trackId(track);
    knownTracks[id] = {...track, 'track_id': id};
    if (knownTracks.length > 200) knownTracks.remove(knownTracks.keys.first);
  }

  void acceptCommandState(Map<String, dynamic> data) {
    final id = '${data['command_id'] ?? ''}';
    if (!issuedCommands.containsKey(id) &&
        lastCommandState['command_id'] != id) {
      return;
    }
    if (data['device_id'] != null &&
        !MusicContract.sameDevice(data['device_id'], api.deviceId)) {
      return;
    }
    final status = data['lifecycle_status'] ?? data['status'];
    if (lastCommandState['command_id'] == id &&
        {
          'applied',
          'executed',
          'failed',
          'expired',
        }.contains(lastCommandState['status']) &&
        status != lastCommandState['status']) {
      return;
    }
    if (!{
      'queued',
      'sent',
      'received',
      'applied',
      'executed',
      'failed',
      'expired',
      'accepted',
    }.contains(status)) {
      return;
    }
    lastCommandState = {
      'command_id': id,
      'device_id': api.deviceId,
      'status': status,
      if (data['error_code'] != null) 'error_code': safeErrorCode(data),
    };
    if (status == 'failed') lastMessage = '车机回执失败：${safeErrorCode(data)}';
    verifyLog('COMMAND_STATE_RECEIVED');
    publish();
  }

  String get commandLabel => switch (lastCommandState['status']) {
    'queued' => '指令已排队，车机结果待回报',
    'sent' => '后端已投递，车机结果待回报',
    'received' => '车机已接收，尚未确认执行',
    'applied' || 'executed' => '车机回执：操作已应用（播放状态另行核对）',
    'failed' => '车机回执：执行失败',
    'expired' => '指令已过期，不会由手机自动重发',
    'accepted' => '后端已接收，执行结果待回报',
    'submitting' => '指令正在提交',
    'unknown' => '指令结果未知，请先核对车机状态',
    _ => '尚无指令执行回执',
  };
  Future<void> refreshCommandState() async {
    final id = lastCommandState['command_id'];
    if (id == null || !api.configured) return;
    final gen = generation;
    try {
      final value = await api.call(
        'GET',
        '/api/v1/music/control/command/${Uri.encodeComponent('$id')}',
      );
      if (gen == generation && !disposed && value['command_id'] == id) {
        acceptCommandState(value);
      }
    } catch (e) {
      if (gen == generation && !disposed) {
        lastMessage = '执行状态暂未更新：$e';
        publish();
      }
    }
  }

  void consumeRealtime(dynamic event) {
    try {
      final m = jsonDecode(event as String) as Map;
      if (m['type'] == 'pong') lastPongAt = DateTime.now();
      if (m['type'] == 'command_status') {
        acceptCommandState(MusicContract.envelope(m));
      }
      if (m['type'] == 'command_ack') {
        final ack = MusicContract.envelope(m);
        if (ack['device_id'] != null &&
            !MusicContract.sameDevice(ack['device_id'], api.deviceId)) {
          return;
        }
        final pending = pendingCommands.remove('${ack['command_id']}');
        if (pending != null) {
          if ({
            'ok',
            'accepted',
            'queued',
            'dispatched',
            'duplicate',
          }.contains(ack['status'])) {
            lastCommandReceipt = ack;
            acceptCommandState({
              ...ack,
              'status': ack['lifecycle_status'] ?? 'accepted',
            });
            pending.complete();
          } else {
            pending.completeError(ApiFailure('指令确认失败或状态未知，请核对车机'));
          }
        }
      }
      if (m['type'] == 'error') {
        final error = MusicContract.envelope(m);
        pendingCommands
            .remove('${error['command_id']}')
            ?.completeError(ApiFailure('后端拒绝指令：${safeErrorCode(error)}'));
      }
      if (m['type'] == 'status_snapshot' || m['type'] == 'status_update') {
        final data = MusicContract.statusPatch(MusicContract.envelope(m));
        if (data.isEmpty) return;
        if (data['device_id'] != null &&
            !MusicContract.sameDevice(data['device_id'], api.deviceId)) {
          return;
        }
        playback = {...playback, ...data};
        verifyLog('WSS_STATE_RECEIVED');
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

  Future<void> playTrack(Map<String, dynamic> track) async {
    if (preparingTrack || commandPending || awaitingExecution) {
      throw ApiFailure('已有选歌/指令正在检查或提交，请勿重复点击');
    }
    final origin = api.baseUrl, target = api.deviceId, credential = api.token;
    preparingTrack = true;
    lastTrackProbe = {};
    publish();
    try {
      if (api.trackSource(track) == 'netease') {
        lastTrackProbe = await api.ensureOnlinePlayable(track);
      }
      if (disposed ||
          !foreground ||
          api.baseUrl != origin ||
          api.deviceId != target ||
          api.token != credential) {
        throw ApiFailure('App已离开前台或配置已改变，未发送过期选歌指令');
      }
      await sendCommand('play_track', api.trackParams(track));
      rememberTrack(track);
    } catch (e) {
      lastTrackProbe = {
        'status': 'failed',
        'message': e is ApiFailure ? e.message : '选歌检查失败',
      };
      lastMessage = '${lastTrackProbe['message']}';
      rethrow;
    } finally {
      preparingTrack = false;
      publish();
    }
  }

  Future<void> sendCommand(
    String action, [
    Map<String, dynamic> params = const {},
    String? commandId,
  ]) async {
    if (!api.configured) throw ApiFailure('请先配置手机 Token');
    if (commandPending) throw ApiFailure('正在等待上一条指令确认，请勿重复提交');
    final validated = MusicContract.params(
      action,
      params,
      BackendApi.validateBase(api.baseUrl),
    );
    final id = commandId ?? requestId();
    final signature = jsonEncode({
      'action': action,
      'params': validated,
      'device_id': api.deviceId,
    });
    if (issuedCommands.containsKey(id)) {
      if (issuedCommands[id] != signature) {
        throw ApiFailure('同一 command_id 不得对应不同指令');
      }
      lastMessage = '该指令 ID 已提交过；未重复发送，执行结果仍以车机状态为准';
      publish();
      return;
    }
    issuedCommands[id] = signature;
    lastCommandState = {
      'command_id': id,
      'device_id': api.deviceId,
      'status': 'submitting',
    };
    if (issuedCommands.length > 1000) {
      issuedCommands.remove(issuedCommands.keys.first);
    }
    commandPending = true;
    publish();
    try {
      final ws = socket;
      if (ws != null && ws.readyState == WebSocket.open) {
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
                'params': validated,
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
        final response = await api.command(action, validated, id);
        if (response['command_id'] != null && response['command_id'] != id) {
          throw ApiFailure('后端确认指令 ID 不符，执行结果未知');
        }
        lastCommandReceipt = response;
        acceptCommandState({
          ...response,
          'command_id': id,
          'status': response['lifecycle_status'] ?? 'accepted',
        });
      }
      final duplicate =
          lastCommandReceipt['duplicate'] == true ||
          lastCommandReceipt['status'] == 'duplicate';
      lastMessage = duplicate ? '后端识别到已有指令，未当作新指令；执行结果以车机状态为准' : commandLabel;
    } catch (e) {
      if (!{
        'applied',
        'executed',
        'failed',
        'expired',
      }.contains(lastCommandState['status'])) {
        lastCommandState = {...lastCommandState, 'status': 'unknown'};
      }
      lastMessage = e.toString();
      rethrow;
    } finally {
      commandPending = false;
      publish();
    }
  }

  bool get playbackStale {
    final stamp = MusicContract.backendTimestamp(
      '${playback['updated_at'] ?? playback['last_heartbeat_at'] ?? ''}',
    );
    return !foreground ||
        stamp == null ||
        DateTime.now().toUtc().difference(stamp.toUtc()).inSeconds.abs() > 60;
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
    final h = MusicContract.backendTimestamp(playback['last_heartbeat_at']);
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
