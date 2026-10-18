import 'package:flutter/foundation.dart';
import 'backend.dart';

/// In-memory, redacted display data. Never stores NetEase cookies or credentials.
class NeteaseAccountView extends ChangeNotifier {
  NeteaseAccountView(this.session) {
    owner = identity;
    session.addListener(accountChanged);
  }
  final BackendSession session;
  late String owner;
  String get identity =>
      '${session.api.baseUrl}\n${session.api.token}\n${session.userProfile['role']}';
  bool get manager =>
      session.userSignedIn && session.userProfile['role'] == 'admin';
  Map<String, dynamic> profile = {};
  bool busy = false, loaded = false, disposed = false;
  int epoch = 0;
  String? error;
  void accountChanged() {
    if (owner == identity) return;
    owner = identity;
    epoch++;
    profile = {};
    busy = loaded = false;
    error = null;
    notifyListeners();
    if (session.userSignedIn) refresh();
  }

  Future<void> refresh() async {
    if (busy || disposed) return;
    final gen = ++epoch, who = identity, token = session.api.token;
    final transport = BackendApi(client: session.api.client)
      ..baseUrl = session.api.baseUrl
      ..token = token
      ..isUserSession = session.api.isUserSession
      ..onSessionExpired = () async {
        if (who == identity) await session.api.onSessionExpired?.call();
      };
    busy = true;
    error = null;
    notifyListeners();
    try {
      final value = await transport.call(
        'GET',
        '/api/v1/music/netease/login/status',
      );
      if (disposed || gen != epoch || who != identity) return;
      if (value['logged_in'] is! bool) throw ApiFailure('网易云账号状态格式不符');
      profile = {
        'logged_in': value['logged_in'],
        if (manager) ...{
          for (final key in ['nickname', 'avatar_url'])
            if (value[key] is String) key: value[key],
          for (final key in ['user_id', 'vip_type'])
            if (value[key] is int) key: value[key],
        },
      };
      loaded = true;
    } catch (e) {
      if (!disposed && gen == epoch && who == identity) {
        profile = {};
        loaded = false;
        error = e is ApiFailure ? e.message : '网易云账号状态暂不可用';
      }
    } finally {
      if (!disposed && gen == epoch && who == identity) {
        busy = false;
        notifyListeners();
      }
    }
  }

  String get headline {
    if (!loaded) return busy ? '正在读取网易云账号' : '网易云账号状态未知';
    if (profile['logged_in'] != true) return '网易云未登录';
    if (!manager) return '网易云已连接';
    return profile['user_id'] == null
        ? '${profile['nickname'] ?? '网易云账号'}'
        : '网易云 ID：${profile['user_id']}';
  }

  String get membership {
    if (!loaded || profile['logged_in'] != true) return '会员信息：未知';
    if (!manager) return '账号资料仅管理员可见';
    final type = profile['vip_type'];
    return '${type == null
        ? '会员类型：未知'
        : type == 0
        ? '普通账号'
        : '会员类型：$type'} · 剩余天数：未提供';
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    session.removeListener(accountChanged);
    super.dispose();
  }
}
