import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'backend.dart';
import 'netease_account_view.dart';
import 'liked_music_page.dart';
import 'pages.dart' show MusicSearchPage, PlaybackPanel, AccountPage;

Uri? musicArtworkUrl(Object? value) {
  var url = Uri.tryParse(value is String ? value : '');
  if (url?.scheme == 'http' &&
      (url!.host == 'music.126.net' || url.host.endsWith('.music.126.net'))) {
    url = url.replace(scheme: 'https');
  }
  if (url == null ||
      url.scheme != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    return null;
  }
  return url;
}

class MusicArtwork extends StatelessWidget {
  const MusicArtwork({
    super.key,
    this.url,
    this.size = 56,
    this.icon = Icons.music_note,
  });
  final Object? url;
  final double size;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final uri = musicArtworkUrl(url);
    final fallback = ColoredBox(
      color: const Color(0xFF263040),
      child: Center(
        child: Icon(icon, size: size * .45, color: Colors.white60),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: uri == null
          ? fallback
          : Image.network(
              uri.toString(),
              fit: BoxFit.cover,
              cacheWidth: (size * 3).round(),
              errorBuilder: (_, _, _) => fallback,
              frameBuilder: (_, child, frame, _) =>
                  frame == null ? fallback : child,
            ),
    );
  }
}

class ScopedMusicRoute extends StatelessWidget {
  const ScopedMusicRoute({
    super.key,
    required this.session,
    required this.identity,
    required this.child,
  });
  final BackendSession session;
  final String identity;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) =>
        identity ==
                '${session.api.baseUrl}\n${session.api.token}\n${session.userProfile['role']}' &&
            session.userSignedIn
        ? child
        : Scaffold(
            appBar: AppBar(title: const Text('会话已切换')),
            body: const Center(child: Text('请返回音乐页后重新打开')),
          ),
  );
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key, required this.session, this.active = true});
  final BackendSession session;
  final bool active;
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  late final account = NeteaseAccountView(widget.session);
  @override
  void initState() {
    super.initState();
    account.refresh();
  }

  @override
  void didUpdateWidget(covariant MusicPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) account.refresh();
  }

  @override
  void dispose() {
    account.dispose();
    super.dispose();
  }

  Future<void> open(Widget child, {bool accountChanged = false}) async {
    final who = account.identity;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ScopedMusicRoute(
          session: widget.session,
          identity: who,
          child: child,
        ),
      ),
    );
    if (mounted && who == account.identity && accountChanged) {
      await account.refresh();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([account, widget.session]),
    builder: (context, _) => Stack(
      children: [
        RefreshIndicator(
          onRefresh: account.refresh,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              22,
              8,
              22,
              184 + MediaQuery.paddingOf(context).bottom,
            ),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '音乐',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('music-search-open'),
                    tooltip: '搜索音乐',
                    onPressed: () =>
                        open(MusicSearchPage(session: widget.session)),
                    icon: const Icon(Icons.search),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xB31B2230),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ClipOval(
                          child: MusicArtwork(
                            url: account.profile['avatar_url'],
                            icon: Icons.person_outline,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                account.headline,
                                key: const ValueKey('netease-account-title'),
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                account.membership,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        TextButton(
                          key: const ValueKey('netease-account-open'),
                          onPressed: account.manager
                              ? () => open(
                                  AccountPage(session: widget.session),
                                  accountChanged: true,
                                )
                              : null,
                          child: Text(
                            account.manager
                                ? account.profile['logged_in'] == true
                                      ? '切换账号'
                                      : '登录'
                                : '仅管理员',
                          ),
                        ),
                      ],
                    ),
                    if (account.busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (account.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                account.error!,
                                style: const TextStyle(
                                  color: Colors.orangeAccent,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: account.busy ? null : account.refresh,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Card(
                color: const Color(0xFF151D29),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Colors.white10),
                ),
                child: ListTile(
                  key: const ValueKey('liked-music-entry'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  leading: const Icon(
                    Icons.folder_outlined,
                    color: Color(0xFFE07892),
                    size: 32,
                  ),
                  title: const Text(
                    '网易云收藏音乐',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text('我喜欢的音乐'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(LikedMusicPage(session: widget.session)),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: 24,
          bottom: 20 + MediaQuery.paddingOf(context).bottom,
          child: VinylRecord(
            key: const ValueKey('music-record-open'),
            session: widget.session,
            active: widget.active,
            onTap: () => open(MusicPlayerPage(session: widget.session)),
          ),
        ),
      ],
    ),
  );
}

class VinylRecord extends StatefulWidget {
  const VinylRecord({
    super.key,
    required this.session,
    this.size = 124,
    this.active = true,
    this.onTap,
  });
  final BackendSession session;
  final double size;
  final bool active;
  final VoidCallback? onTap;
  @override
  State<VinylRecord> createState() => _VinylRecordState();
}

class _VinylRecordState extends State<VinylRecord>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );
  bool foreground = true;
  bool get shouldSpin =>
      widget.active &&
      foreground &&
      widget.session.foreground &&
      widget.session.playing &&
      widget.session.heartbeatFresh &&
      !widget.session.playbackStale &&
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;
  void sync() {
    if (!mounted) return;
    if (shouldSpin) {
      if (!rotation.isAnimating) rotation.repeat();
    } else {
      rotation.stop(canceled: false);
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(sync);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(covariant VinylRecord oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session != oldWidget.session) {
      oldWidget.session.removeListener(sync);
      widget.session.addListener(sync);
    }
    sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    sync();
  }

  @override
  void dispose() {
    widget.session.removeListener(sync);
    WidgetsBinding.instance.removeObserver(this);
    rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final known =
        widget.session.heartbeatFresh && !widget.session.playbackStale;
    final state = known ? (widget.session.playing ? '播放中' : '未在播放') : '播放状态未知';
    return Semantics(
      button: widget.onTap != null,
      label: '打开播放页面，$state',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        elevation: 8,
        child: InkResponse(
          onTap: widget.onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: RotationTransition(
              key: const ValueKey('vinyl-rotation'),
              turns: rotation,
              child: CustomPaint(
                painter: const _VinylPainter(),
                child: Center(
                  child: ClipOval(
                    child: MusicArtwork(
                      url: widget.session.currentTrack['cover_url'],
                      size: widget.size * .42,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VinylPainter extends CustomPainter {
  const _VinylPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero), r = size.shortestSide / 2;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF15171D), Color(0xFF2C303B), Color(0xFF08090D)],
        ).createShader(Offset.zero & size),
    );
    for (var i = 0; i < 9; i++) {
      canvas.drawCircle(
        center,
        r * (.5 + i * .052),
        Paint()
          ..color = const Color(0xFF3A3F4C).withValues(alpha: .48)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7,
      );
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r * .91),
      -math.pi * .22,
      math.pi * .25,
      false,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(
      center,
      r - 1,
      Paint()
        ..color = Colors.white12
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_VinylPainter oldDelegate) => false;
}

class MusicPlayerPage extends StatelessWidget {
  const MusicPlayerPage({super.key, required this.session});
  final BackendSession session;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('正在播放'),
      actions: [
        IconButton(
          key: const ValueKey('music-player-search'),
          tooltip: '搜索音乐',
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => MusicSearchPage(session: session),
            ),
          ),
          icon: const Icon(Icons.search),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Center(child: VinylRecord(session: session, size: 240)),
          const SizedBox(height: 24),
          PlaybackPanel(session: session),
        ],
      ),
    ),
  );
}
