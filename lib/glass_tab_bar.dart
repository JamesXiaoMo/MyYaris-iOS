import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Flutter-drawn glass styling, not Apple's native Liquid Glass material.
class GlassTabBar extends StatefulWidget {
  const GlassTabBar({super.key, required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  @override
  State<GlassTabBar> createState() => _GlassTabBarState();
}

class _GlassTabBarState extends State<GlassTabBar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _channel = MethodChannel('io.myyaris/credentials');
  static const _labels = ['首页', '行驶', '音乐', '设置'];
  static const _icons = [
    CupertinoIcons.house_fill,
    CupertinoIcons.location_north_fill,
    CupertinoIcons.music_note,
    CupertinoIcons.gear_solid,
  ];
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.index.toDouble(),
  );
  bool _dragging = false;
  bool _cancelled = false;
  bool _reduceTransparency = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readAccessibility();
  }

  Future<void> _readAccessibility() async {
    try {
      final flags = await _channel.invokeMapMethod<String, bool>(
        'accessibilityFlags',
      );
      if (!mounted || flags == null) return;
      setState(() {
        _reduceTransparency = flags['reduceTransparency'] ?? false;
        _reduceMotion = flags['reduceMotion'] ?? false;
      });
    } on MissingPluginException {
      // Other platforms and widget tests use MediaQuery's accessibility flags.
    } on PlatformException {
      // Never make navigation depend on a native preference query.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _readAccessibility();
  }

  bool get _motionOff =>
      _reduceMotion || MediaQuery.disableAnimationsOf(context);

  void _snap(int index) {
    if (_motionOff) {
      _position.value = index.toDouble();
    } else {
      _position.animateTo(
        index.toDouble(),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutBack,
      );
    }
  }

  void _select(int index) {
    _snap(index);
    if (index != widget.index) widget.onChanged(index);
  }

  @override
  void didUpdateWidget(covariant GlassTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.index != widget.index) _snap(widget.index);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final solid =
        _reduceTransparency ||
        MediaQuery.highContrastOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final height =
        72.0 + (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(0, 24);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(36),
            child: BackdropFilter(
              enabled: !solid,
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: solid
                      ? const Color(0xFF202631)
                      : const Color(0x18202631),
                  borderRadius: BorderRadius.circular(36),
                  border: Border.all(color: const Color(0x35FFFFFF)),
                  gradient: solid
                      ? null
                      : const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0x303F4B5F), Color(0x10161C27)],
                        ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cell = (constraints.maxWidth - 8) / 4;
                    void track(double dx) {
                      _position.value = ((dx - 4) / cell - .5).clamp(0, 3);
                    }

                    return Listener(
                      onPointerCancel: (_) => _cancelled = true,
                      child: GestureDetector(
                        key: const ValueKey('glass-tab-bar'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (event) {
                          _dragging = true;
                          _cancelled = false;
                          _position.stop();
                          track(event.localPosition.dx);
                        },
                        onHorizontalDragUpdate: (event) =>
                            track(event.localPosition.dx),
                        onHorizontalDragEnd: (_) {
                          _dragging = false;
                          if (_cancelled) {
                            _snap(widget.index);
                          } else {
                            _select(_position.value.round().clamp(0, 3));
                          }
                        },
                        onHorizontalDragCancel: () {
                          _dragging = false;
                          _snap(widget.index);
                        },
                        child: SizedBox(
                          height: height,
                          child: Stack(
                            children: [
                              AnimatedBuilder(
                                animation: _position,
                                builder: (_, _) => Positioned(
                                  key: const ValueKey('glass-selection'),
                                  left: 4 + cell * _position.value,
                                  top: 5,
                                  bottom: 5,
                                  width: cell,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(31),
                                      border: Border.all(
                                        color: const Color(0x55FFFFFF),
                                      ),
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: solid
                                            ? const [
                                                Color(0xFF4A5669),
                                                Color(0xFF4A5669),
                                              ]
                                            : const [
                                                Color(0x409DB8D8),
                                                Color(0x184F6889),
                                              ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Row(
                                  children: List.generate(
                                    4,
                                    (index) => Expanded(
                                      child: Semantics(
                                        label: _labels[index],
                                        button: true,
                                        selected: widget.index == index,
                                        onTap: () => _select(index),
                                        child: ExcludeSemantics(
                                          child: GestureDetector(
                                            key: ValueKey('tab-$index'),
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () => _select(index),
                                            child: SizedBox(
                                              height: height,
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    _icons[index],
                                                    size: 23,
                                                    color: widget.index == index
                                                        ? Colors.white
                                                        : const Color(
                                                            0xFFADB9CB,
                                                          ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    child: Text(
                                                      _labels[index],
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            widget.index ==
                                                                index
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                        color:
                                                            widget.index ==
                                                                index
                                                            ? Colors.white
                                                            : const Color(
                                                                0xFFADB9CB,
                                                              ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
