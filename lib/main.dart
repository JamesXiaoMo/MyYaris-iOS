import 'dart:async';
import 'car_model.dart';
import 'glass_tab_bar.dart';
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

const _background = Color(0xFF090B10);
const _muted = Color(0xFF9398A6);
const _blue = Color(0xFF44C5FF);
const _homeAccent = Color(0xFF91D8D0);
const _homeSurface = Color(0xFF131C21);
const _homeBorder = Color(0xFF273438);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
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
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _background,
      colorScheme: const ColorScheme.dark(
        primary: _blue,
        surface: Color(0xFF11151D),
      ),
      fontFamily: '.SF Pro Text',
      useMaterial3: true,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    ),
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
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        extendBody: true,
        body: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 540,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: _index == 0
                        ? const [
                            Color(0xFF101A20),
                            Color(0xFF183039),
                            Color(0xFF10191E),
                            _background,
                          ]
                        : const [Color(0xFF08132F), _background],
                    stops: _index == 0 ? const [0, .37, .72, 1] : null,
                  ),
                ),
              ),
            ),
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
  });

  final BackendSession session;
  final bool playing;
  final VoidCallback onPlay, onRepeat, onPrevious, onNext, onDriving;

  @override
  Widget build(BuildContext context) {
    final connectionColor = switch (session.homeConnectionState) {
      HomeConnectionState.backendOffline => const Color(0xFFFF6370),
      HomeConnectionState.carOffline => const Color(0xFFFFCC66),
      HomeConnectionState.online => const Color(0xFF48D882),
      HomeConnectionState.checking => _muted,
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
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'MyYaris',
                style: TextStyle(
                  color: _homeAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .45,
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
          const SizedBox(height: 10),
          const Text(
            'Toyota Yaris',
            style: TextStyle(
              fontSize: 39,
              height: 1.08,
              letterSpacing: -1.6,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: (constraints.maxWidth * .72)
                  .clamp(192.0, 278.0)
                  .toDouble(),
              child: const CarModel(),
            ),
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
      color: const Color(0xFF203136),
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
      foregroundColor: primary ? const Color(0xFF0C2725) : Colors.white,
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
