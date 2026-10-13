import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'backend.dart';

class AuthenticationGate extends StatelessWidget {
  const AuthenticationGate({
    super.key,
    required this.session,
    required this.child,
  });
  final BackendSession session;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (_, _) {
      if (!session.authInitialized || session.restoringSession) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return session.userSignedIn ? child : LoginPage(session: session);
    },
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});
  final BackendSession session;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final base = TextEditingController(text: widget.session.api.baseUrl);
  final username = TextEditingController(),
      password = TextEditingController(),
      nickname = TextEditingController();
  bool register = false, busy = false;
  String message = '';
  @override
  void dispose() {
    base.dispose();
    username.dispose();
    password.dispose();
    nickname.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (register) {
        await widget.session.register(
          base.text,
          username.text,
          password.text,
          nickname.text,
        );
        if (mounted) {
          setState(() {
            register = false;
            message = '注册成功，请登录；普通账号须由管理员授权车机';
          });
        }
      } else {
        await widget.session.login(base.text, username.text, password.text);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is ApiFailure ? e.message : '无法安全完成登录，请保持手机解锁后重试',
        );
      }
    } finally {
      password.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 30),
          const Text(
            'MyYaris',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            register ? '注册普通账号' : '登录 MyYaris',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const ValueKey('login-base'),
            controller: base,
            enabled: !busy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'HTTPS 服务地址',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('login-username'),
            controller: username,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('login-password'),
            controller: password,
            enabled: !busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => submit(),
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
            ),
          ),
          if (register) ...[
            const SizedBox(height: 16),
            TextField(
              controller: nickname,
              enabled: !busy,
              maxLength: 64,
              decoration: const InputDecoration(labelText: '昵称（选填）'),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const ValueKey('login-submit'),
            onPressed: busy ? null : submit,
            child: Text(
              busy
                  ? '处理中…'
                  : register
                  ? '注册普通账号'
                  : '登录',
            ),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () {
                    password.clear();
                    setState(() {
                      register = !register;
                      message = '';
                    });
                  },
            child: Text(register ? '已有账号，返回登录' : '注册普通账号'),
          ),
          if (message.isNotEmpty)
            Text(message, style: const TextStyle(color: Colors.orangeAccent)),
          if (widget.session.authMessage.isNotEmpty)
            Text(
              widget.session.authMessage,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          TextButton(
            onPressed: busy ? null : widget.session.initialize,
            child: const Text('重试恢复已有会话'),
          ),
          const SizedBox(height: 16),
          const Text(
            '密码不会保存在App。会话安全保存在本机Keychain。\n注册只创建普通用户；车机权限由管理员授权。\n旧连接配置与收藏不自动迁移到新账号。',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

Widget accountAvatar(Map<String, dynamic> profile, String base) {
  final raw = profile['avatar_url'];
  Uri? uri = raw is String ? Uri.tryParse(raw) : null;
  if (uri != null &&
      !uri.hasScheme &&
      uri.path.startsWith('/api/v1/auth/avatar/')) {
    uri = Uri.parse(base).resolveUri(uri);
  }
  final safe = uri != null && uri.scheme == 'https' && uri.userInfo.isEmpty;
  return _PublicAvatar(uri: safe ? uri : null);
}

class _PublicAvatar extends StatefulWidget {
  const _PublicAvatar({required this.uri});
  final Uri? uri;
  @override
  State<_PublicAvatar> createState() => _PublicAvatarState();
}

class _PublicAvatarState extends State<_PublicAvatar> {
  late Future<Uint8List?> image = load();
  @override
  void didUpdateWidget(covariant _PublicAvatar old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) image = load();
  }

  Future<Uint8List?> load() async {
    final uri = widget.uri;
    if (uri == null) return null;
    final client = http.Client();
    try {
      final request = http.Request('GET', uri)..followRedirects = false;
      // Public avatar endpoint: never attach the API session or cookies.
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 ||
          !{'image/png', 'image/jpeg', 'image/webp'}.contains(
            (response.headers['content-type'] ?? '')
                .split(';')
                .first
                .toLowerCase(),
          )) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 10),
      )) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) return null;
        bytes.addAll(chunk);
      }
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 24,
    child: FutureBuilder<Uint8List?>(
      future: image,
      builder: (_, snapshot) {
        final bytes = snapshot.data;
        return bytes == null
            ? const Icon(Icons.person)
            : ClipOval(
                child: Image.memory(
                  bytes,
                  width: 48,
                  height: 48,
                  cacheWidth: 96,
                  cacheHeight: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.person),
                ),
              );
      },
    ),
  );
}
