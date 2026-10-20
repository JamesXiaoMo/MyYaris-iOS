import 'dart:convert';
import 'backend.dart';
import 'contracts.dart';

class ScopedKeychainStore implements CredentialStore {
  ScopedKeychainStore(this.scope);
  final String scope;
  @override
  Future<String?> load() =>
      KeychainStore.channel.invokeMethod<String>('load$scope');
  @override
  Future<void> save(String value) =>
      KeychainStore.channel.invokeMethod<void>('save$scope', value);
  @override
  Future<void> clear() =>
      KeychainStore.channel.invokeMethod<void>('clear$scope');
}

Map<String, dynamic> accountProfile(Map value) {
  if (value['id'] is! String ||
      value['username'] is! String ||
      !{'user', 'admin'}.contains(value['role']) ||
      value['is_active'] != true ||
      value['has_device_control'] is! bool ||
      (value['nickname'] != null && value['nickname'] is! String) ||
      (value['avatar_url'] != null && value['avatar_url'] is! String)) {
    throw ApiFailure('账户响应无效，不使用旧固定凭据登录');
  }
  return {
    for (final key in [
      'id',
      'username',
      'nickname',
      'avatar_url',
      'role',
      'is_active',
      'has_device_control',
    ])
      if (value.containsKey(key)) key: value[key],
  };
}

class UserSessionRecord {
  UserSessionRecord({
    required this.secret,
    required this.expires,
    required this.profile,
  });
  final String secret;
  final DateTime expires;
  final Map<String, dynamic> profile;
  factory UserSessionRecord.fromLogin(Map data) {
    final token = data['session_id'];
    final expires = MusicContract.backendTimestamp(data['expires_at']);
    if (token is! String ||
        token.length < 32 ||
        RegExp(r'\s').hasMatch(token) ||
        data['token_type'] != 'bearer' ||
        expires == null ||
        !expires.isAfter(DateTime.now().toUtc()) ||
        data['user'] is! Map) {
      throw ApiFailure('登录响应异常，请稍后重试');
    }
    return UserSessionRecord(
      secret: token,
      expires: expires,
      profile: accountProfile(data['user']),
    );
  }
  String encode(String base, String device) => jsonEncode({
    'version': 1,
    'base': base,
    'device': device,
    'session_id': secret,
    'expires_at': expires.toIso8601String(),
    'user': profile,
  });
}
