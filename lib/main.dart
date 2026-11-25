import 'dart:async';
import 'dart:math' as math;
import 'car_model.dart';
import 'glass_tab_bar.dart';
import 'splash_screen.dart';
import 'yaris_theme.dart';
import 'verification/favorites_evidence.dart';
import 'verification/home_evidence.dart';
import 'verification/music_diagnostic.dart';
import 'api/backend.dart';
import 'api/music_home.dart' show MusicArtwork;
import 'api/music_queue_browser.dart';
import 'api/pages.dart';
import 'api/login_page.dart';
import 'api/vehicle_data_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _muted = YarisTheme.muted;
const _homeAccent = YarisTheme.blue;
const _homeSurface = YarisTheme.paper;
const _homeBorder = YarisTheme.line;
const _parkingGreen = Color(0xFF157A58);
const _parkingMint = Color(0xFFE6F6EE);
const _homeNativeChannel = MethodChannel('io.myyaris/share');

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
    unawaited(session.initialize().then((_) => session.hub.restoreLastTrack()));
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
      child: YarisSplashOverlay(
        session: session,
        child: AuthenticationGate(session: session, child: child!),
      ),
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
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final tileSize = ((constraints.maxWidth - 12) / 2)
                  .clamp(132.0, 210.0)
                  .toDouble();
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: tileSize),
                        child: _fuelRangeCard(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: tileSize),
                        child: _parkingNavCard(context),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _musicCard(),
        ],
      ),
    );
  }

  Future<void> _openParkingInGoogleMaps(BuildContext context) async {
    final parking = session.homeParking;
    final lat = parking?['latitude'];
    final lng = parking?['longitude'];
    if (lat is! num || lng is! num || !lat.isFinite || !lng.isFinite) {
      unawaited(session.refreshVehicleState(force: true));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂未记录到停车位置，待车机熄火上报后即可导航')),
        );
      }
      return;
    }
    try {
      final ok = await _homeNativeChannel.invokeMethod<bool>(
        'openGoogleMapsNavigation',
        {
          'lat': lat.toDouble(),
          'lng': lng.toDouble(),
          'mode': 'walking',
        },
      );
      if (ok != true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开 Google 地图，请确认系统浏览器或地图应用可用')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('唤起 Google 地图失败，请稍后重试')),
        );
      }
    }
  }

  String _formatParkedSubtitle(Map<String, dynamic>? parking) {
    if (parking == null) return '暂无停车记录';
    final rawTime = parking['parked_at']?.toString();
    final dt = rawTime != null ? DateTime.tryParse(rawTime)?.toLocal() : null;
    if (dt != null) {
      final now = DateTime.now();
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      final isToday =
          dt.year == now.year && dt.month == now.month && dt.day == now.day;
      if (isToday) return '$hh:$mm 停放';
      return '${dt.month}/${dt.day} $hh:$mm 停放';
    }
    final lat = parking['latitude'];
    final lng = parking['longitude'];
    if (lat is num && lng is num) return '已记录停车坐标';
    return '暂无停车记录';
  }

  Widget _fuelRangeCard(BuildContext context) {
    final pct = session.homeFuelPercent;
    final liters = session.homeFuelLiters;
    final rangeKm = session.homeEstimatedRangeKm;
    final kmPerL = session.homeAvgKmPerL;
    final lowFuel = pct != null && pct < 20.0;
    final ringColor = lowFuel ? YarisTheme.red : _homeAccent;
    final rangeText = rangeKm != null
        ? '剩余约 ${rangeKm.round()} km'
        : (liters != null ? '剩余 ${liters.toStringAsFixed(1)} L' : '油量待采集');
    final subText = kmPerL != null
        ? '${kmPerL.toStringAsFixed(1)} km/L'
        : '点击查看车况';

    return Material(
      color: _homeSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: _homeBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('home-fuel-card'),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => VehicleDataPage(session: session),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '油量与续航',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ringColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(
                    CupertinoIcons.chevron_right,
                    size: 13,
                    color: _muted,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Center(
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: CustomPaint(
                    painter: _FuelRingPainter(
                      fraction: pct != null ? (pct / 100.0) : null,
                      activeColor: ringColor,
                      trackColor: lowFuel
                          ? YarisTheme.rose
                          : YarisTheme.periwinkle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.local_gas_station_rounded,
                              size: 15,
                              color: ringColor,
                            ),
                            const SizedBox(height: 1),
                            Text(
                              pct != null ? '${pct.round()}%' : '--%',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: YarisTheme.ink,
                                height: 1.05,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                rangeText,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: YarisTheme.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subText,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _parkingNavCard(BuildContext context) {
    final parking = session.homeParking;
    final hasCoords =
        parking?['latitude'] is num && parking?['longitude'] is num;
    final subtitle = _formatParkedSubtitle(parking);

    return Material(
      color: _homeSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: _homeBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('home-parking-card'),
        onTap: () => _openParkingInGoogleMaps(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _parkingMint,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Icon(
                      Icons.local_parking_rounded,
                      size: 21,
                      color: _parkingGreen,
                    ),
                  ),
                  const Spacer(),
                  const Icon(
                    CupertinoIcons.arrow_up_right,
                    size: 15,
                    color: _muted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: hasCoords ? _parkingGreen : YarisTheme.neutral,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '最后停车点',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: hasCoords ? Colors.white : _muted,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                '导航寻车',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w800,
                  color: YarisTheme.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F1EA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.location_on_rounded,
                      size: 13,
                      color: _parkingGreen,
                    ),
                    SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Google 地图',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: YarisTheme.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _musicCard() => Material(
    color: _homeSurface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: const BorderSide(color: _homeBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onMusic,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: MusicArtwork(
                    url: session.homeMusicCoverUrl,
                    size: 52,
                    icon: CupertinoIcons.music_note,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.homeMusicState,
                        style: const TextStyle(
                          color: _homeAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        session.homeMusicTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: YarisTheme.ink,
                        ),
                      ),
                      if (session.homeMusicDetail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          session.homeMusicDetail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: _muted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 15,
                  color: _muted,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: _homeBorder),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
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
        ),
      ],
    ),
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

class _FuelRingPainter extends CustomPainter {
  const _FuelRingPainter({
    required this.fraction,
    required this.activeColor,
    required this.trackColor,
  });

  final double? fraction;
  final Color activeColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 7.5;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    if (fraction != null && fraction! > 0) {
      final activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round;
      final sweep = 2 * math.pi * fraction!.clamp(0.02, 1.0);
      canvas.drawArc(rect, -math.pi / 2, sweep, false, activePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FuelRingPainter old) =>
      old.fraction != fraction ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor;
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
