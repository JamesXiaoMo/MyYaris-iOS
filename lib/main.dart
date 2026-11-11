import 'dart:async';
import 'car_model.dart';
import 'glass_tab_bar.dart';
import 'yaris_theme.dart';
import 'verification/favorites_evidence.dart';
import 'verification/home_evidence.dart';
import 'verification/music_diagnostic.dart';
import 'api/backend.dart';
import 'api/music_queue_browser.dart';
import 'api/pages.dart';
import 'api/login_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _muted = YarisTheme.muted;
const _homeAccent = YarisTheme.blue;
const _homeSurface = YarisTheme.paper;
const _homeBorder = YarisTheme.line;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
  runApp(const MyYarisApp());
}

class MyYarisApp extends StatefulWidget {
  const MyYarisApp({super.key});
  @override
  State<MyYarisApp> createState() => _MyYarisAppState();
}

class _MyYarisAppState extends State<MyYarisApp> {
  final session = BackendSession();
  @override
  void initState() {
    super.initState();
    unawaited(session.initialize());
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MyYaris',
    builder: (context, child) => RepaintBoundary(
      key: evidenceBoundary,
      child: AuthenticationGate(session: session, child: child!),
    ),
    debugShowCheckedModeBanner: false,
    theme: YarisTheme.light,
    home: YarisShell(session: session, initializeSession: false),
  );
}

class YarisShell extends StatefulWidget {
  const YarisShell({super.key, this.session, this.initializeSession = true});
  final bool initializeSession;
  final BackendSession? session;

  @override
  State<YarisShell> createState() => _YarisShellState();
}

class _YarisShellState extends State<YarisShell> with WidgetsBindingObserver {
  int _index = 0;
  late final BackendSession session;
  @override
  void initState() {
    super.initState();
    session = widget.session ?? BackendSession();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initializeSession) {
      unawaited(
        session.initialize().then((_) async {
          if (const bool.fromEnvironment('MY_YARIS_MUSIC_DIAGNOSTIC') &&
              mounted) {
            setState(() => _index = 2);
            await diagnoseOnlineMusic(session);
          }
          if (const bool.fromEnvironment('MY_YARIS_HOME_VERIFY') && mounted) {
            await verifyHomeOnDevice(session);
          }
          if (const bool.fromEnvironment('MY_YARIS_FAVORITES_VERIFY') &&
              mounted) {
            await verifyFavoritesOnDevice(session.api, context, () {
              if (mounted) setState(() => _index = 1);
            });
          }
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    session.lifecycle(state);
    session.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.session == null) session.dispose();
    super.dispose();
  }

  Future<void> _command(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      await session.hub.command(action, params);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(session.hub.phoneTarget ? '本机控制已应用' : '指令已提交，等待车机回报'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        extendBody: true,
        backgroundColor: YarisTheme.canvas,
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _index,
                children: [
                  _HomePage(
                    session: session,
                    playing: session.playing,
                    onPlay: () =>
                        _command(session.playing ? 'pause' : 'resume'),
                    onRepeat: () => showQueueModes(context, session),
                    onPrevious: () => _command('prev'),
                    onNext: () => _command('next'),
                    onDriving: () => setState(() => _index = 1),
                    onMusic: () => setState(() => _index = 2),
                    onSettings: () => setState(() => _index = 3),
                  ),
                  NavigationPage(session: session, active: _index == 1),
                  MusicPage(session: session, active: _index == 2),
                  SettingsPage(session: session),
                ],
              ),
            ),
          ],
        ),
        // The page paints behind the floating glass. Scroll views consume the
        // Scaffold-provided bottom inset as trailing space, not a black strip.
        // Hide consistently while typing; the body keyboard inset stays active.
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? const SizedBox.shrink()
            : GlassTabBar(
                index: _index,
                lightAppearance:
                    Theme.of(context).colorScheme.primary == YarisTheme.blue,
                onChanged: (index) => setState(() => _index = index),
              ),
      ),
    ),
  );
}

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.session,
    required this.playing,
    required this.onPlay,
    required this.onRepeat,
    required this.onPrevious,
    required this.onNext,
    required this.onDriving,
    required this.onMusic,
    required this.onSettings,
  });

  final BackendSession session;
  final bool playing;
  final VoidCallback onPlay,
      onRepeat,
      onPrevious,
      onNext,
      onDriving,
      onMusic,
      onSettings;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).colorScheme.primary == YarisTheme.blue;
    final connectionColor = switch (session.homeConnectionState) {
      HomeConnectionState.backendOffline =>
        light ? YarisTheme.red : const Color(0xFFFF6370),
      HomeConnectionState.carOffline =>
        light ? const Color(0xFF805700) : const Color(0xFFFFCC66),
      HomeConnectionState.online =>
        light ? const Color(0xFF155D46) : const Color(0xFF48D882),
      HomeConnectionState.checking => light ? _muted : const Color(0xFF9398A6),
    };
    return SingleChildScrollView(
      key: const ValueKey('home-scroll'),
      padding: EdgeInsets.fromLTRB(
        22,
        16,
        22,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '我的车',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: YarisTheme.ink,
                  ),
                ),
              ),
              IconButton.filledTonal(
                tooltip: '打开设置',
                onPressed: onSettings,
                icon: const Icon(CupertinoIcons.gear_alt),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: YarisTheme.periwinkle,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'HYBRID',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: YarisTheme.blue,
                        ),
                      ),
                      _badge(
                        session.homeConnectionLabel,
                        connectionColor,
                        icon: Icons.circle,
                        iconSize: 6,
                      ),
                    ],
                  ),
                  const Text(
                    'YARIS',
                    style: TextStyle(
                      fontSize: 66,
                      height: 1,
                      letterSpacing: -4,
                      fontWeight: FontWeight.w900,
                      color: YarisTheme.blue,
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) => SizedBox(
                      height: (constraints.maxWidth * .59)
                          .clamp(150.0, 230.0)
                          .toDouble(),
                      child: const CarModel(),
                    ),
                  ),
                  const Text(
                    'Toyota Yaris',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: YarisTheme.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onDriving,
                icon: const Icon(CupertinoIcons.location_north_fill),
                label: const Text('找目的地'),
              ),
              FilledButton.tonalIcon(
                onPressed: onMusic,
                icon: const Icon(CupertinoIcons.music_note),
                label: const Text('打开音乐'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _musicCard(),
          const SizedBox(height: 12),
          _destinationCard(),
        ],
      ),
    );
  }

  BoxDecoration get _card => BoxDecoration(
    color: _homeSurface,
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: _homeBorder),
  );

  Widget _musicCard() => DecoratedBox(
    decoration: _card,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _sectionIcon(CupertinoIcons.music_note),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.homeMusicState,
                      style: const TextStyle(
                        color: _homeAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      session.homeMusicTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (session.homeMusicDetail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        session.homeMusicDetail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: _homeBorder),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _control('上一曲', CupertinoIcons.backward_end_fill, onPrevious),
              _control(
                '播放/暂停',
                playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
                onPlay,
                primary: true,
              ),
              _control('下一曲', CupertinoIcons.forward_end_fill, onNext),
              _control(
                appliedPlaybackLabel(session),
                switch (session.appliedQueueMode) {
                  'shuffle' => CupertinoIcons.shuffle,
                  'intelligence' => CupertinoIcons.heart,
                  'single_loop' => CupertinoIcons.repeat_1,
                  _ => CupertinoIcons.repeat,
                },
                onRepeat,
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _destinationCard() => Material(
    color: _homeSurface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: const BorderSide(color: _homeBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onDriving,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _sectionIcon(CupertinoIcons.location_north_fill),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '目的地',
                    style: TextStyle(
                      color: _homeAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    session.homeDestinationTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: YarisTheme.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    session.lastTask.isNotEmpty && !session.navigationVerified
                        ? '状态待核对 · ${session.homeDestinationDetail}'
                        : session.lastTask.isEmpty
                        ? session.homeDestinationDetail
                        : '${session.taskLabel} · ${session.homeDestinationDetail}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(CupertinoIcons.chevron_right, size: 15, color: _muted),
          ],
        ),
      ),
    ),
  );

  Widget _sectionIcon(IconData icon) => Container(
    width: 44,
    height: 44,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: YarisTheme.periwinkle,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Icon(icon, size: 19, color: _homeAccent),
  );

  Widget _control(
    String label,
    IconData icon,
    VoidCallback callback, {
    bool primary = false,
  }) => IconButton(
    onPressed: callback,
    tooltip: label,
    icon: Icon(icon, size: primary ? 21 : 19),
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: primary ? Colors.white : YarisTheme.ink,
      backgroundColor: primary ? _homeAccent : Colors.transparent,
    ),
  );
}

Widget _badge(
  String label,
  Color color, {
  required IconData icon,
  double iconSize = 12,
}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .10),
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: color.withValues(alpha: .18)),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: iconSize, color: color),
      const SizedBox(width: 5),
      Flexible(
        child: Text(label, style: TextStyle(color: color, fontSize: 10)),
      ),
    ],
  ),
);
