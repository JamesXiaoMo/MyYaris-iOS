import 'dart:async';
import 'package:flutter/material.dart';
import 'api/backend.dart';
import 'yaris_theme.dart';

/// Branded dark-obsidian Yaris Hybrid launch splash overlay.
/// Plays a smooth entrance animation while the app connects to the backend
/// in parallel, then fades out cleanly once connected (or after a short cap).
class YarisSplashOverlay extends StatefulWidget {
  const YarisSplashOverlay({
    super.key,
    required this.session,
    required this.child,
  });

  final BackendSession session;
  final Widget child;

  @override
  State<YarisSplashOverlay> createState() => _YarisSplashOverlayState();
}

class _YarisSplashOverlayState extends State<YarisSplashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeInAnim;
  bool _minHoldDone = false;
  bool _dismissing = false;
  bool _removed = false;
  Timer? _minTimer;
  Timer? _maxTimer;
  Timer? _removeTimer;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 820),
    );
    _scaleAnim = Tween<double>(begin: 0.90, end: 1.0).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );
    _fadeInAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOut),
    );
    _anim.forward();

    widget.session.addListener(_checkDismiss);

    // Minimum branded animation hold (1.15s) so splash feels intentional, never flickery
    _minTimer = Timer(const Duration(milliseconds: 1150), () {
      _minHoldDone = true;
      _checkDismiss();
    });

    // Safety cap (2.5s) so offline/slow network never stalls app entry
    _maxTimer = Timer(const Duration(milliseconds: 2500), () {
      _startDismiss();
    });
  }

  void _checkDismiss() {
    if (!_minHoldDone || _dismissing || _removed) return;
    final s = widget.session;
    if (s.authInitialized && !s.restoringSession) {
      _startDismiss();
    }
  }

  void _startDismiss() {
    if (_dismissing || _removed || !mounted) return;
    setState(() => _dismissing = true);
    _removeTimer = Timer(const Duration(milliseconds: 420), () {
      if (mounted) {
        setState(() => _removed = true);
      }
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_checkDismiss);
    _minTimer?.cancel();
    _maxTimer?.cancel();
    _removeTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_removed) return widget.child;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          ignoring: _dismissing,
          child: AnimatedOpacity(
            opacity: _dismissing ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOut,
            child: AnimatedBuilder(
              animation: widget.session,
              builder: (context, _) {
                final s = widget.session;
                final connected = s.authInitialized &&
                    !s.restoringSession &&
                    s.userSignedIn &&
                    s.api.configured;
                final statusText = connected
                    ? '已连接 Yaris 云端'
                    : (!s.authInitialized || s.restoringSession
                        ? '正在连接 Yaris 云端…'
                        : '正在同步车机与歌单…');

                return Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF0D121F),
                        Color(0xFF151D30),
                        Color(0xFF0B0F1A),
                      ],
                    ),
                  ),
                  child: SafeArea(
                    child: FadeTransition(
                      opacity: _fadeInAnim,
                      child: ScaleTransition(
                        scale: _scaleAnim,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Spacer(flex: 3),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFFD6323F), Color(0xFFA82F36)],
                                ),
                                borderRadius: BorderRadius.circular(999),
                                boxShadow: [
                                  BoxShadow(
                                    color: YarisTheme.red.withValues(alpha: 0.4),
                                    blurRadius: 18,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Text(
                                'YARIS HYBRID',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.8,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 22),
                            SizedBox(
                              width: 240,
                              height: 128,
                              child: Image.asset(
                                'assets/images/yaris.png',
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.directions_car_rounded,
                                  size: 72,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            const Text(
                              'MyYaris',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '智能混动车联 · 轨迹 · 语音 · 音乐',
                              style: TextStyle(
                                color: Color(0xFF8D9CB8),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.6,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            const Spacer(flex: 3),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (connected)
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    color: Color(0xFF19B36B),
                                    size: 16,
                                  )
                                else
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFD6323F),
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                Text(
                                  statusText,
                                  style: TextStyle(
                                    color: connected
                                        ? const Color(0xFF19B36B)
                                        : const Color(0xFFA0AEC9),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 36),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
