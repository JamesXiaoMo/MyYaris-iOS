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
const _purple = Color(0xFFC77DFF);

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
                            Color(0xFF08132F),
                            Color(0xFF252439),
                            Color(0xFFCE9877),
                            Color(0xFF333640),
                            _background,
                          ]
                        : const [Color(0xFF08132F), _background],
                    stops: _index == 0 ? const [0, .35, .58, .68, 1] : null,
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
                    repeat: session.hub.phoneTarget
                        ? session.hub.local.queue?.mode == 'list_loop'
                        : session.playback['loop_mode'] == 'all',
                    onPlay: () =>
                        _command(session.playing ? 'pause' : 'resume'),
                    onRepeat: () => showQueueModes(context, session),
                    onDemo: (label) =>
                        _command(label == '上一曲' ? 'prev' : 'next'),
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
    required this.repeat,
    required this.onPlay,
    required this.onRepeat,
    required this.onDemo,
  });
  final BackendSession session;
  final bool playing, repeat;
  final VoidCallback onPlay, onRepeat;
  final ValueChanged<String> onDemo;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('home-scroll'),
    padding: EdgeInsets.fromLTRB(
      20,
      12,
      20,
      24 + MediaQuery.paddingOf(context).bottom,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 18,
          runSpacing: 10,
          children: [
            const Text(
              'Toyota Yaris',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            _badge(
              session.homeConnectionLabel,
              switch (session.homeConnectionState) {
                HomeConnectionState.backendOffline => const Color(0xFFFF6370),
                HomeConnectionState.carOffline => const Color(0xFFFFCC66),
                HomeConnectionState.online => const Color(0xFF48D882),
                HomeConnectionState.checking => _muted,
              },
              icon: Icons.circle,
              iconSize: 8,
            ),
          ],
        ),
        const SizedBox(height: 20),
        const SizedBox(height: 280, child: CarModel()),
        const SizedBox(height: 30),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _control(
              '上一曲',
              CupertinoIcons.backward_end_fill,
              () => onDemo('上一曲'),
            ),
            _control(
              '播放/暂停',
              playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
              onPlay,
              highlighted: true,
            ),
            _control(
              '下一曲',
              CupertinoIcons.forward_end_fill,
              () => onDemo('下一曲'),
            ),
            _control(
              appliedPlaybackLabel(session),
              session.appliedQueueMode == 'shuffle'
                  ? CupertinoIcons.shuffle
                  : session.appliedQueueMode == 'intelligence'
                  ? CupertinoIcons.heart
                  : session.appliedQueueMode == 'single_loop'
                  ? CupertinoIcons.repeat_1
                  : CupertinoIcons.repeat,
              onRepeat,
            ),
          ],
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final stackCards =
                constraints.maxWidth < 340 ||
                MediaQuery.textScalerOf(context).scale(14) > 19;
            final cards = [
              _featureCard(context, navigation: true),
              _featureCard(context, navigation: false),
            ];
            if (stackCards) {
              return Column(
                children: [cards[0], const SizedBox(height: 12), cards[1]],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cards[0]),
                const SizedBox(width: 12),
                Expanded(child: cards[1]),
              ],
            );
          },
        ),
      ],
    ),
  );

  Widget _control(
    String label,
    IconData icon,
    VoidCallback callback, {
    bool highlighted = false,
  }) => Expanded(
    child: Column(
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: highlighted
                  ? const [Color(0xFF4A4E58), Color(0xFF2C3038)]
                  : const [Color(0xFF333740), Color(0xFF242830)],
            ),
            border: Border.all(color: const Color(0xFF4A4E56)),
          ),
          child: IconButton(
            onPressed: callback,
            tooltip: label,
            icon: Icon(icon, size: 23),
            padding: const EdgeInsets.all(15),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
      ],
    ),
  );

  Widget _featureCard(BuildContext context, {required bool navigation}) {
    final color = navigation ? _blue : _purple;
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  navigation
                      ? CupertinoIcons.location_north_fill
                      : CupertinoIcons.music_note,
                  color: color,
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  navigation ? 'CAR NAVITIME' : '车机播放器',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 10, color: _muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            navigation ? session.homeDestinationTitle : session.homeMusicTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            navigation
                ? session.homeDestinationDetail
                : session.homeMusicDetail.isEmpty
                ? '车机上报曲目'
                : session.homeMusicDetail,
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 9),
          _badge(
            navigation
                ? session.lastTask.isNotEmpty && !session.navigationVerified
                      ? '状态待核对'
                      : session.taskLabel
                : session.homeMusicState,
            color,
            icon: navigation ? Icons.circle : CupertinoIcons.music_note,
            iconSize: 9,
          ),
        ],
      ),
    );
  }
}

Widget _panel({required Widget child}) => Container(
  width: double.infinity,
  padding: const EdgeInsets.all(14),
  decoration: BoxDecoration(
    color: const Color(0xFF10141C),
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: const Color(0xFF222630)),
  ),
  child: child,
);

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
