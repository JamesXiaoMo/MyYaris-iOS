import 'contracts.dart';
import 'user_auth.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const defaultBackend = String.fromEnvironment(
  'MY_YARIS_BACKEND',
  defaultValue: '',
);
const verifyMode = bool.fromEnvironment('MY_YARIS_VERIFY_LOGS');
void verifyLog(String event) {
  if (verifyMode) debugPrint('[MyYarisVerify] $event');
}

String requestId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

enum DestinationPurpose {
  favoritePreview('favorite_preview'),
  navigation('navigation');

  const DestinationPurpose(this.value);
  final String value;
}

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
  ApiFailure(this.message, {this.statusCode});
  final int? statusCode;
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

enum HomeConnectionState { checking, backendOffline, carOffline, online }

class BackendApi {
  BackendApi({http.Client? client, String? baseUrl})
    : client = client ?? http.Client(),
      baseUrl = baseUrl ?? defaultBackend;
  final http.Client client;
  String baseUrl;
  String token = '';
  String deviceId = 'car_p3pro';
  bool isUserSession = false;
  Future<void> Function()? onSessionExpired;
  void Function(String)? onDeviceForbidden;
  Map<String, String> get sessionHeaders => {'Authorization': 'Bearer $token'};
  Future<void> checkAuthStatus(
    int status,
    String path,
    String usedToken,
  ) async {
    if (!isUserSession || usedToken != token) return;
    if (status == 401) await onSessionExpired?.call();
    if (status == 403 &&
        (path.contains('/music/control') ||
            path.startsWith('/tasks') ||
            path.startsWith('/destinations') ||
            path.contains('/tasks/destination'))) {
      onDeviceForbidden?.call(path);
    }
  }

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
    if (auth && !configured) throw ApiFailure('请先登录 MyYaris');
    final usedToken = token;
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
      if (auth) await checkAuthStatus(response.statusCode, path, usedToken);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiFailure(
          response.statusCode == 401
              ? (path.endsWith('/auth/login') ? '用户名或密码不正确' : '登录会话已失效，请重新登录')
              : response.statusCode == 403
              ? (path.endsWith('/auth/register')
                    ? '后端未开放普通注册'
                    : '账号未获此操作或当前车机权限，请联系管理员授权')
              : response.statusCode == 429
              ? '请求暂时受限或账户冷却中，请稍后重试'
              : {404, 405, 501}.contains(response.statusCode) &&
                    path.endsWith('/auth/register')
              ? '当前后端未开放普通注册或版本尚未支持'
              : response.statusCode == 400 && path.endsWith('/auth/register')
              ? '注册失败：用户名不可用或不符合后端规则'
              : '接口返回 HTTP ${response.statusCode}，请重试或核对后端',
          statusCode: response.statusCode,
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
    String key, {
    required DestinationPurpose purpose,
    Map<String, double>? reference,
  }) async {
    await ensureResolveOnlyContract();
    final result = await call(
      'POST',
      '/api/v1/destinations/resolve',
      body: {
        'raw_input': input,
        'purpose': purpose.value,
        'source': 'ios_share',
        if (reference != null)
          'reference_coordinate': {...reference, 'coord_system': 'wgs84'},
      },
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
    final usedToken = token;
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
      await checkAuthStatus(response.statusCode, '/voice', usedToken);
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
    final usedToken = token;
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      endpoint(streamPath(track)),
      abortTrigger: abort.future,
    )..followRedirects = false;
    request.headers.addAll({
      ...sessionHeaders,
      'Range': 'bytes=0-1023',
      'Accept': 'audio/*',
    });
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      await checkAuthStatus(response.statusCode, streamPath(track), usedToken);
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
  BackendSession({
    BackendApi? api,
    CredentialStore? store,
    CredentialStore? authStore,
    CredentialStore? settingsStore,
    CredentialStore? navigationStore,
    this.requireUserLogin = true,
    this.webSocketConnector,
  }) : api = api ?? BackendApi(),
       store = store ?? KeychainStore(),
       authStore = authStore ?? ScopedKeychainStore('UserSession'),
       settingsStore = settingsStore ?? ScopedKeychainStore('Connection'),
       navigationStore = navigationStore ?? ScopedKeychainStore('Navigation') {
    this.api.onSessionExpired = expireSession;
    this.api.onDeviceForbidden = (path) {
      if (path.endsWith('/music/control/command') &&
          lastCommandState['status'] == 'submitting') {
        lastCommandState = {
          ...lastCommandState,
          'status': 'denied',
          'error_code': 'FORBIDDEN',
        };
      }
      deviceDenied = true;
      stop();
      lastMessage = '当前账号未授权车机 ${this.api.deviceId}，请联系管理员；登录会话仍有效';
      publish();
    };
  }
  final bool requireUserLogin;
  final Future<WebSocket> Function(Uri, Map<String, String>)?
  webSocketConnector;
  final CredentialStore authStore, settingsStore, navigationStore;
  bool authInitialized = false,
      restoringSession = false,
      authBusy = false,
      authenticated = false,
      deviceDenied = false;
  Map<String, dynamic> userProfile = {};
  String authMessage = '';
  DateTime? sessionExpires;
  Timer? sessionExpiryTimer;
  bool get canControlVehicle =>
      !requireUserLogin ||
      authenticated &&
          userProfile['has_device_control'] == true &&
          !deviceDenied &&
          !authBusy;
  bool get userSignedIn => !requireUserLogin || authenticated;
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
  HomeConnectionState get homeConnectionState {
    if (displayedBackendOnline == null) return HomeConnectionState.checking;
    if (displayedBackendOnline == false) {
      return HomeConnectionState.backendOffline;
    }
    final reportedDevice = playback['device_id'];
    return heartbeatFresh &&
            !deviceDenied &&
            (reportedDevice == null || reportedDevice == api.deviceId)
        ? HomeConnectionState.online
        : HomeConnectionState.carOffline;
  }

  String get homeConnectionLabel => switch (homeConnectionState) {
    HomeConnectionState.checking => '检测中',
    HomeConnectionState.backendOffline => '后端未连接',
    HomeConnectionState.carOffline => '车机未连接',
    HomeConnectionState.online => '在线',
  };
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
    if (!requireUserLogin) {
      authInitialized = true;
      publish();
      return;
    }
    restoringSession = true;
    publish();
    try {
      final rawSettings = await settingsStore.load();
      final legacy = rawSettings == null ? await store.load() : null;
      final config = rawSettings ?? legacy;
      if (config != null) {
        final data = jsonDecode(config) as Map;
        api.baseUrl = BackendApi.validateBase('${data['base']}').origin;
        api.deviceId = '${data['device'] ?? 'car_p3pro'}';
      }
      final saved = await authStore.load();
      if (saved != null) {
        final data = jsonDecode(saved) as Map;
        if (BackendApi.validateBase('${data['base']}').origin != api.baseUrl) {
          authMessage = '服务域名已改变，请重新登录';
        } else {
          final expiry = MusicContract.backendTimestamp(data['expires_at']);
          if (expiry == null || !expiry.isAfter(DateTime.now().toUtc())) {
            await expireSession();
          } else {
            final secret = data['session_id'];
            if (secret is! String ||
                secret.length < 32 ||
                RegExp(r'\s').hasMatch(secret)) {
              await expireSession();
              return;
            }
            api.token = secret;
            api.isUserSession = true;
            sessionExpires = expiry;
            await refreshUserProfile();
            if (!expiry.isAfter(DateTime.now().toUtc())) {
              await expireSession();
              return;
            }
            authenticated = true;
            scheduleSessionExpiry();
          }
        }
      }
      if (authenticated) {
        await restoreNavigation();
        start();
      }
    } catch (e) {
      authenticated = false;
      authMessage = e is ApiFailure ? e.message : '无法恢复会话，请保持手机解锁并重试';
    } finally {
      restoringSession = false;
      authInitialized = true;
      publish();
    }
  }

  void scheduleSessionExpiry() {
    sessionExpiryTimer?.cancel();
    final expires = sessionExpires;
    if (expires != null) {
      sessionExpiryTimer = Timer(
        expires.difference(DateTime.now().toUtc()),
        () => unawaited(expireSession()),
      );
    }
  }

  Future<void> expireSession() async {
    stop();
    sessionExpiryTimer?.cancel();
    api.token = '';
    api.isUserSession = false;
    authenticated = false;
    userProfile = {};
    resetAccountCaches();
    authMessage = '登录会话已失效，请重新登录';
    try {
      await authStore.clear();
    } catch (_) {
      authMessage = '会话已失效，本机清理未完成；请保持设备解锁后重试';
    }
    publish();
  }

  void resetAccountCaches() {
    commandPending = false;
    preparingTrack = false;
    deviceDenied = false;
    playback = {};
    lastTask = {};
    navigationDisplayTitle = null;
    navigationVerified = false;
    _metadataRequest = null;
    _metadataRequestKey = null;
    _metadataFailedId = null;
    _metadataRetryAt = null;
    currentTrack = {};
    knownTracks.clear();
    issuedCommands.clear();
    lastCommandState = {};
    lastCommandReceipt = {};
    lastTrackProbe = {};
    musicDiagnostic = {};
    statusReceivedAt = null;
    health = {};
    backendOnline = null;
  }

  Future<void> refreshUserProfile({bool resetDeviceDenied = false}) async {
    final usedToken = api.token;
    final profile = accountProfile(await api.call('GET', '/api/v1/auth/me'));
    if (api.token != usedToken || disposed) return;
    userProfile = profile;
    if (resetDeviceDenied) deviceDenied = false;
    publish();
  }

  Future<void> saveConnection(String base, String device) async {
    final origin = BackendApi.validateBase(base).origin;
    if (device.trim().isEmpty) throw ApiFailure('请输入车机设备ID');
    if (api.baseUrl != origin && authenticated) {
      throw ApiFailure('请先退出当前账号，再更换服务域名');
    }
    await settingsStore.save(
      jsonEncode({'base': origin, 'device': device.trim()}),
    );
    if (api.baseUrl != origin) {
      api.token = '';
      api.isUserSession = false;
      authenticated = false;
    }
    if (api.deviceId != device.trim()) {
      stop();
      resetAccountCaches();
    }
    api.baseUrl = origin;
    api.deviceId = device.trim();
    deviceDenied = false;
    if (authenticated) start();
    publish();
  }

  Future<void> login(String base, String username, String password) async {
    if (authBusy) return;
    if (username.trim().isEmpty || password.isEmpty) {
      throw ApiFailure('请输入用户名和密码');
    }
    final origin = BackendApi.validateBase(base).origin;
    authBusy = true;
    authMessage = '';
    stop();
    publish();
    // Tests use the injected HTTP transport; no production credentials leave this client.
    final transport = BackendApi(client: api.client)..baseUrl = origin;
    UserSessionRecord? record;
    try {
      record = UserSessionRecord.fromLogin(
        await transport.call(
          'POST',
          '/api/v1/auth/login',
          auth: false,
          body: {'username': username.trim(), 'password': password},
        ),
      );
      await settingsStore.save(
        jsonEncode({'base': origin, 'device': api.deviceId}),
      );
      await authStore.save(record.encode(origin, api.deviceId));
      resetAccountCaches();
      api.baseUrl = origin;
      api.token = record.secret;
      api.isUserSession = true;
      userProfile = record.profile;
      sessionExpires = record.expires;
      authenticated = true;
      deviceDenied = false;
      await restoreNavigation();
      scheduleSessionExpiry();
    } catch (e) {
      if (record != null) {
        final cleanup = BackendApi(client: api.client)
          ..baseUrl = origin
          ..token = record.secret
          ..isUserSession = true;
        try {
          await cleanup.call('POST', '/api/v1/auth/logout');
        } catch (_) {}
      }
      rethrow;
    } finally {
      authBusy = false;
      if (authenticated) start();
      publish();
    }
  }

  Future<void> register(
    String base,
    String username,
    String password,
    String nickname,
  ) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{3,32}$').hasMatch(username.trim()) ||
        password.length < 8 ||
        password.length > 128 ||
        nickname.length > 64) {
      throw ApiFailure('用户名须3～32位字母/数字/_/-，密码8～128位，昵称最多64字');
    }
    final transport = BackendApi(client: api.client)
      ..baseUrl = BackendApi.validateBase(base).origin;
    await transport.call(
      'POST',
      '/api/v1/auth/register',
      auth: false,
      body: {
        'username': username.trim(),
        'password': password,
        if (nickname.trim().isNotEmpty) 'nickname': nickname.trim(),
      },
    );
  }

  Future<void> updateNickname(String nickname) async {
    if (nickname.length > 64) throw ApiFailure('昵称最多64字');
    userProfile = accountProfile(
      await api.call(
        'PATCH',
        '/api/v1/auth/profile',
        body: {'nickname': nickname.trim()},
      ),
    );
    publish();
  }

  Future<void> logout() async {
    if (authBusy) return;
    authBusy = true;
    stop();
    sessionExpiryTimer?.cancel();
    publish();
    var revoked = true, localCleared = true;
    try {
      if (api.isUserSession && api.configured) {
        await api.call('POST', '/api/v1/auth/logout');
      }
    } catch (e) {
      revoked = e is ApiFailure && e.statusCode == 401;
    } finally {
      try {
        await authStore.clear();
      } catch (_) {
        localCleared = false;
      }
      api.token = '';
      api.isUserSession = false;
      authenticated = false;
      userProfile = {};
      resetAccountCaches();
      authBusy = false;
      authMessage = !localCleared
          ? '已停止本机会话，但Keychain清理失败，请保持手机解锁后重试'
          : revoked
          ? '已退出登录'
          : '已退出本机；服务端注销未确认，请联网后处理';
      publish();
    }
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
    navigationDisplayTitle = null;
    navigationVerified = false;
    _metadataRequest = null;
    _metadataRequestKey = null;
    _metadataFailedId = null;
    _metadataRetryAt = null;
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
    if (requireUserLogin) {
      await logout();
      return;
    }
    await store.clear();
    stop();
    api.token = '';
    knownTracks.clear();
    issuedCommands.clear();
    lastCommandReceipt = {};
    lastCommandState = {};
    playback = {};
    lastTask = {};
    navigationDisplayTitle = null;
    navigationVerified = false;
    _metadataRequest = null;
    _metadataRequestKey = null;
    _metadataFailedId = null;
    _metadataRetryAt = null;
    currentTrack = {};
    health = {};
    statusReceivedAt = null;
    backendOnline = null;
    connection = '未配置';
    publish();
  }

  void start() {
    if (requireUserLogin &&
        sessionExpires != null &&
        !sessionExpires!.isAfter(DateTime.now().toUtc())) {
      unawaited(expireSession());
      return;
    }
    if (!foreground ||
        !api.configured ||
        disposed ||
        requireUserLogin && !authenticated) {
      return;
    }
    if (!canControlVehicle) {
      unawaited(checkHealthOnly());
      stop();
      lastMessage = '账号已登录，尚未授权当前车机；请联系管理员绑定';
      publish();
      return;
    }
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

  Future<void> checkHealthOnly() async {
    try {
      final h = await api.call('GET', '/health', auth: false);
      health = h;
      backendOnline = {'ok', 'healthy'}.contains(h['status']);
    } catch (_) {
      backendOnline = false;
    }
    publish();
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

  String get _navigationOwner =>
      requireUserLogin ? '${userProfile['id'] ?? ''}' : 'legacy-device';
  String? navigationDisplayTitle;
  bool navigationVerified = false;
  String? _metadataRequest;
  String? _metadataFailedId;
  DateTime? _metadataRetryAt;

  Future<void> acceptNavigationTask(
    Map<String, dynamic> task, {
    String? displayTitle,
  }) async {
    if (task['task_id'] is! String ||
        task['device_id'] != null &&
            !MusicContract.sameDevice(task['device_id'], api.deviceId)) {
      return;
    }
    lastTask = Map.of(task);
    navigationDisplayTitle = displayTitle?.trim().isNotEmpty == true
        ? displayTitle!.trim()
        : null;
    navigationVerified = true;
    publish();
    final owner = _navigationOwner;
    if (owner.isEmpty) return;
    try {
      await navigationStore.save(
        jsonEncode({
          'base': api.baseUrl,
          'device': api.deviceId,
          'owner': owner,
          'task_id': task['task_id'],
          'display_title': navigationDisplayTitle,
        }),
      );
    } catch (_) {
      lastMessage = '目的地已提交，本机任务引用未能保存；重启后可能无法恢复';
      publish();
    }
  }

  Future<void> restoreNavigation() async {
    final gen = generation,
        owner = _navigationOwner,
        base = api.baseUrl,
        device = api.deviceId;
    try {
      final raw = await navigationStore.load();
      if (raw == null ||
          gen != generation ||
          owner != _navigationOwner ||
          base != api.baseUrl ||
          device != api.deviceId) {
        return;
      }
      final record = jsonDecode(raw) as Map;
      if (record['owner'] != owner ||
          record['base'] != base ||
          record['device'] != device ||
          record['task_id'] is! String) {
        return;
      }
      lastTask = {'task_id': record['task_id']};
      navigationDisplayTitle = record['display_title'] is String
          ? record['display_title']
          : null;
      navigationVerified = false;
      await refreshNavigationTask();
    } catch (_) {
      // A missing private reference never prevents login or resets credentials.
    }
  }

  Future<void> refreshNavigationTask() async {
    final id = lastTask['task_id'];
    if (id == null) return;
    final gen = generation,
        token = api.token,
        base = api.baseUrl,
        device = api.deviceId;
    try {
      final task = await api.call(
        'GET',
        '/tasks/${Uri.encodeComponent('$id')}',
      );
      if (gen != generation ||
          token != api.token ||
          base != api.baseUrl ||
          device != api.deviceId ||
          lastTask['task_id'] != id) {
        return;
      }
      if (task['task_id'] != id ||
          task['device_id'] != null &&
              !MusicContract.sameDevice(task['device_id'], device)) {
        return;
      }
      lastTask = task;
      navigationVerified = true;
    } catch (e) {
      if (gen != generation ||
          token != api.token ||
          base != api.baseUrl ||
          device != api.deviceId) {
        return;
      }
      navigationVerified = false;
      if (e is ApiFailure && {403, 404}.contains(e.statusCode)) {
        lastTask = {};
        navigationDisplayTitle = null;
      }
      lastMessage = '任务状态暂未更新，请刷新后核对';
    }
    publish();
  }

  Future<void> syncCurrentTrack() async {
    final id = '${playback['current_track_id'] ?? ''}';
    if (id.isEmpty) {
      currentTrack = {};
      return;
    }
    if (knownTracks.containsKey(id)) {
      currentTrack = knownTracks[id]!;
      return;
    }
    if (currentTrack['track_id'] != id) currentTrack = {'track_id': id};
    if (currentTrack['metadata_loaded'] == true ||
        _metadataRequest == id ||
        _metadataFailedId == id &&
            _metadataRetryAt != null &&
            DateTime.now().isBefore(_metadataRetryAt!)) {
      return;
    }
    final gen = generation,
        token = api.token,
        base = api.baseUrl,
        device = api.deviceId;
    final request = '$gen|$id|${DateTime.now().microsecondsSinceEpoch}';
    _metadataRequest = id;
    _metadataRequestKey = request;
    try {
      final data = await api.call(
        'GET',
        '/api/v1/music/tracks/${Uri.encodeComponent(id)}',
      );
      if (gen != generation ||
          token != api.token ||
          base != api.baseUrl ||
          device != api.deviceId ||
          playback['current_track_id'] != id) {
        return;
      }
      if (data['track_id'] != id) throw ApiFailure('曲目信息与车机状态不匹配');
      currentTrack = {...data, 'metadata_loaded': true};
      _metadataFailedId = null;
      _metadataRetryAt = null;
    } catch (_) {
      if (gen == generation &&
          token == api.token &&
          base == api.baseUrl &&
          device == api.deviceId &&
          playback['current_track_id'] == id) {
        currentTrack = {'track_id': id};
        _metadataFailedId = id;
        _metadataRetryAt = DateTime.now().add(const Duration(seconds: 15));
      }
    } finally {
      if (_metadataRequestKey == request) {
        _metadataRequest = null;
        _metadataRequestKey = null;
      }
      if (!disposed) publish();
    }
  }

  String? _metadataRequestKey;

  String get homeDestinationTitle => lastTask.isEmpty
      ? '暂无目的地'
      : navigationDisplayTitle ?? _nonempty(lastTask['title']) ?? '目的地名称待同步';
  String get homeDestinationDetail => lastTask.isEmpty
      ? '尚无本机确认的导航任务'
      : _nonempty(lastTask['address']) ?? '上次确认发送的目的地';
  String get homeMusicTitle =>
      _nonempty(currentTrack['title']) ??
      (playback['current_track_id'] == null ||
              playback['current_track_id'] == ''
          ? '暂无曲目'
          : '曲名暂不可用');
  String get homeMusicDetail => [
    if (_nonempty(currentTrack['artist']) != null)
      _nonempty(currentTrack['artist'])!,
    if (playback['position_ms'] is num) _clock(playback['position_ms']),
    if (playback['duration_ms'] is num && (playback['duration_ms'] as num) > 0)
      '/ ${_clock(playback['duration_ms'])}',
  ].join(' ').trim();
  String get homeMusicState => !heartbeatFresh || playbackStale
      ? '状态待更新'
      : switch (playback['playback_state']) {
          'playing' => '正在播放',
          'paused' => '已暂停',
          'stopped' => '已停止',
          'buffering' => '缓冲中',
          _ => '状态未知',
        };
  static String? _nonempty(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
  static String _clock(dynamic value) {
    final seconds = ((value as num).toInt().clamp(0, 1 << 40) ~/ 1000);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
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
      await syncCurrentTrack();
    } catch (e) {
      if (gen == generation) {
        connection = '连接异常';
        lastMessage = e.toString();
      }
    } finally {
      if (gen == generation && backendOnline == true && !disposed) {
        await refreshNavigationTask();
      }
      refreshing = false;
      publish();
    }
  }

  Future<void> connect() async {
    if (disposed || !foreground || !api.configured || !canControlVehicle) {
      return;
    }
    final gen = generation;
    try {
      if (api.isUserSession) {
        await refreshUserProfile();
        if (!canControlVehicle || gen != generation) return;
      }
      final uri = api
          .endpoint('/api/v1/ws/music', {
            'client_type': 'phone',
            'device_id': api.deviceId,
          })
          .replace(scheme: 'wss');
      final ws =
          await (webSocketConnector?.call(uri, api.sessionHeaders) ??
                  WebSocket.connect(
                    uri.toString(),
                    headers: api.sessionHeaders,
                  ))
              .timeout(const Duration(seconds: 12));
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
        onDone: () {
          if (ws.closeCode == 4401) {
            unawaited(expireSession());
          } else if (ws.closeCode == 4403 || ws.closeCode == 1008) {
            unawaited(recheckWebSocketAuth(gen));
          } else {
            disconnected(gen);
          }
        },
        onError: (_) => disconnected(gen),
        cancelOnError: true,
      );
    } catch (e) {
      if (api.isUserSession &&
          e is WebSocketException &&
          RegExp(r'\b(401|403)\b').hasMatch(e.message)) {
        await recheckWebSocketAuth(gen);
      } else {
        disconnected(gen);
      }
    }
  }

  Future<void> recheckWebSocketAuth(int gen) async {
    try {
      await refreshUserProfile();
      if (gen != generation) return;
      deviceDenied = true;
      stop();
      lastMessage = '实时通道未授权当前车机；登录仍有效，请联系管理员';
      publish();
    } catch (e) {
      if (e is! ApiFailure || e.statusCode != 401) disconnected(gen);
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
    'denied' => '后端拒绝当前账号控车权限，未当作车机执行结果',
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
        unawaited(syncCurrentTrack());
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
      if (api.token != credential) rethrow;
      lastTrackProbe = {
        'status': 'failed',
        'message': e is ApiFailure ? e.message : '选歌检查失败',
      };
      lastMessage = '${lastTrackProbe['message']}';
      rethrow;
    } finally {
      if (api.token == credential) {
        preparingTrack = false;
        publish();
      }
    }
  }

  Future<void> sendCommand(
    String action, [
    Map<String, dynamic> params = const {},
    String? commandId,
  ]) async {
    if (!api.configured) throw ApiFailure('请先登录 MyYaris');
    if (!canControlVehicle) {
      throw ApiFailure('当前账号未授权车机 ${api.deviceId}，请联系管理员');
    }
    if (commandPending) throw ApiFailure('正在等待上一条指令确认，请勿重复提交');
    final validated = MusicContract.params(
      action,
      params,
      BackendApi.validateBase(api.baseUrl),
    );
    final requestGeneration = generation, requestCredential = api.token;
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
        if (requestGeneration != generation || requestCredential != api.token) {
          throw ApiFailure('会话已改变，不接受旧指令回执');
        }
        lastCommandReceipt = response;
        acceptCommandState({
          ...response,
          'command_id': id,
          'status': response['lifecycle_status'] ?? 'accepted',
        });
      }
      if (requestGeneration != generation || requestCredential != api.token) {
        return;
      }
      final duplicate =
          lastCommandReceipt['duplicate'] == true ||
          lastCommandReceipt['status'] == 'duplicate';
      lastMessage = duplicate ? '后端识别到已有指令，未当作新指令；执行结果以车机状态为准' : commandLabel;
    } catch (e) {
      if (requestGeneration != generation || requestCredential != api.token) {
        rethrow;
      }
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
      if (requestGeneration == generation && requestCredential == api.token) {
        commandPending = false;
        publish();
      }
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
    sessionExpiryTimer?.cancel();
    stop();
    api.close();
    super.dispose();
  }
}
