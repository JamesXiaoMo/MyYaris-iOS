import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'backend.dart';
import 'music_queue_browser.dart';
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
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                key: const ValueKey('netease-account-title'),
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                account.userIdLine,
                                key: const ValueKey('netease-account-uid'),
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
                      key: const ValueKey('vinyl-cover'),
                      size: widget.size * .64,
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

  void controls(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF151B27),
    builder: (_) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            const Text(
              '更多控制与状态',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 18),
            PlaybackPanel(session: session),
          ],
        ),
      ),
    ),
  );

  Future<void> lyrics(BuildContext context, String songId) async {
    final identity = '${session.api.baseUrl}\n${session.api.token}';
    final track = session.playback['current_track_id'];
    final future = session.api
        .call('GET', '/api/v1/music/netease/lyric', query: {'song_id': songId})
        .then<Map<String, dynamic>>(
          (value) => value,
          onError: (_) => <String, dynamic>{'_read_error': true},
        );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF151B27),
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Text(
                '歌词',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<Map<String, dynamic>>(
                  future: future,
                  builder: (context, snapshot) {
                    if (identity !=
                            '${session.api.baseUrl}\n${session.api.token}' ||
                        track != session.playback['current_track_id']) {
                      return const Center(child: Text('会话或曲目已切换，请关闭后重新打开'));
                    }
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return const Center(child: Text('歌词读取失败，请关闭后重试'));
                    }
                    final data = snapshot.data ?? {};
                    if (data['_read_error'] == true) {
                      return const Center(child: Text('歌词读取失败，请关闭后重试'));
                    }
                    final value = data['lrc'] is String
                        ? data['lrc']
                        : data['lrc'] is Map
                        ? (data['lrc'] as Map)['lyric']
                        : data['lyric'];
                    if (value is! String || value.trim().isEmpty) {
                      return const Center(child: Text('当前曲目暂无歌词'));
                    }
                    final text = value
                        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
                        .trim();
                    return SingleChildScrollView(
                      child: SelectableText(
                        text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          height: 2,
                          color: Colors.white70,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      final artwork = musicArtworkUrl(session.currentTrack['cover_url']);
      final songId =
          session.currentTrack['song_id'] ??
          (session.currentTrack['source'] == 'netease'
              ? session.currentTrack['id']
              : null);
      return Scaffold(
        backgroundColor: const Color(0xFF0B111E),
        body: Stack(
          children: [
            Positioned.fill(
              child: ClipRect(
                child: RepaintBoundary(
                  child: artwork == null || MediaQuery.highContrastOf(context)
                      ? const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFF263345),
                                Color(0xFF35282D),
                                Color(0xFF0B111E),
                              ],
                            ),
                          ),
                        )
                      : ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 45,
                            sigmaY: 45,
                          ),
                          child: Image.network(
                            artwork.toString(),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const ColoredBox(color: Color(0xFF182031)),
                          ),
                        ),
                ),
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x75101929),
                      Color(0xA6101420),
                      Color(0xF0080D15),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = math.min(
                    390.0,
                    math.max(
                      220.0,
                      math.min(
                        constraints.maxWidth - 48,
                        constraints.maxHeight * .4,
                      ),
                    ),
                  );
                  return SingleChildScrollView(
                    key: const ValueKey('immersive-player-scroll'),
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              key: const ValueKey('player-dismiss'),
                              tooltip: '返回音乐',
                              onPressed: () => Navigator.maybePop(context),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 30,
                              ),
                            ),
                            const Expanded(
                              child: Column(
                                children: [
                                  Text(
                                    'MY YARIS',
                                    style: TextStyle(
                                      fontSize: 12,
                                      letterSpacing: 5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: 5),
                                  Text(
                                    '正在播放',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuButton<int>(
                              key: const ValueKey('music-player-search'),
                              tooltip: '播放选项',
                              icon: const Icon(Icons.more_horiz),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 0, child: Text('搜索音乐')),
                                PopupMenuItem(value: 1, child: Text('更多控制与状态')),
                              ],
                              onSelected: (item) {
                                if (item == 0) {
                                  Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          MusicSearchPage(session: session),
                                    ),
                                  );
                                } else {
                                  controls(context);
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: size,
                          height: size + 18,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 12,
                                child: VinylRecord(
                                  session: session,
                                  size: size,
                                ),
                              ),
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: const _PlayerTonearmPainter(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        PlaybackPanel(
                          session: session,
                          immersive: true,
                          onSelectMusic: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  MusicQueueBrowser(session: session),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            TextButton.icon(
                              key: const ValueKey('player-lyrics'),
                              onPressed: songId == null
                                  ? null
                                  : () => lyrics(context, '$songId'),
                              icon: const Icon(Icons.music_note_outlined),
                              label: const Text('歌词'),
                            ),
                            Tooltip(
                              message: '当前车机未提供可切换音质',
                              child: TextButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.graphic_eq),
                                label: const Text('音质'),
                              ),
                            ),
                            TextButton.icon(
                              key: const ValueKey('player-more'),
                              onPressed: () => controls(context),
                              icon: const Icon(Icons.more_horiz),
                              label: const Text('更多'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PlayerTonearmPainter extends CustomPainter {
  const _PlayerTonearmPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final start = Offset(size.width * .91, 0);
    final bend = Offset(size.width * .89, size.height * .21);
    final tip = Offset(size.width * .82, size.height * .38);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(bend.dx, bend.dy)
      ..lineTo(tip.dx, tip.dy);
    canvas.drawPath(
      path.shift(const Offset(3, 3)),
      Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF626A77)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFC0C5CE)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(start, 8, Paint()..color = const Color(0xFF454C58));
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(.35);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-6, -8, 12, 24),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF242B37),
    );
    canvas.drawLine(
      const Offset(-5, 9),
      const Offset(5, 9),
      Paint()
        ..color = const Color(0xFF8ADBE9)
        ..strokeWidth = 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlayerTonearmPainter oldDelegate) => false;
}
