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

class MyYarisApp extends StatelessWidget {
  const MyYarisApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MyYaris',
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
    home: const YarisShell(),
  );
}

class YarisShell extends StatefulWidget {
  const YarisShell({super.key});

  @override
  State<YarisShell> createState() => _YarisShellState();
}

class _YarisShellState extends State<YarisShell> {
  int _index = 0;
  bool _playing = false;
  bool _repeat = true;

  void _demo(String action) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$action · 本地演示，未接入车机或后端')));
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light,
    child: Scaffold(
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
                  playing: _playing,
                  repeat: _repeat,
                  onPlay: () {
                    setState(() => _playing = !_playing);
                    _demo('播放状态已切换');
                  },
                  onRepeat: () {
                    setState(() => _repeat = !_repeat);
                    _demo('循环模式已切换');
                  },
                  onDemo: _demo,
                  onNavigate: () => setState(() => _index = 1),
                  onMusic: () => setState(() => _index = 2),
                ),
                const _InputPage(isMusic: false),
                const _InputPage(isMusic: true),
                const _SettingsPage(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFF0D1017),
          border: Border(top: BorderSide(color: Color(0xFF20232A))),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              _tab(0, '首页', CupertinoIcons.house_fill),
              _tab(1, '导航', CupertinoIcons.location_north_fill),
              _tab(2, '音乐', CupertinoIcons.music_note),
              _tab(3, '设置', CupertinoIcons.gear_solid),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _tab(int index, String label, IconData icon) => Expanded(
    child: Semantics(
      selected: _index == index,
      child: InkWell(
        key: ValueKey('tab-$index'),
        onTap: () => setState(() => _index = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 24,
                color: _index == index ? Colors.white : _muted,
              ),
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: _index == index ? Colors.white : _muted,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.playing,
    required this.repeat,
    required this.onPlay,
    required this.onRepeat,
    required this.onDemo,
    required this.onNavigate,
    required this.onMusic,
  });
  final bool playing, repeat;
  final VoidCallback onPlay, onRepeat, onNavigate, onMusic;
  final ValueChanged<String> onDemo;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('home-scroll'),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
              'Toyota Yaris ⌄',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            _badge(
              'Tailscale · 演示',
              const Color(0xFF48D882),
              icon: Icons.circle,
              iconSize: 8,
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          '已连接',
          style: TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          '演示状态 · Tailscale HTTPS 专网\nR9000P 与车机尚未接入',
          style: TextStyle(color: _muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 185,
          width: double.infinity,
          child: Semantics(
            label: '红色 Toyota Yaris 车辆展示',
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0, .18, .85, 1],
              ).createShader(bounds),
              child: Image.asset(
                'assets/images/yaris.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
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
              '列表循环',
              repeat ? CupertinoIcons.repeat : CupertinoIcons.repeat_1,
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
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _quick('快速发送目的地', CupertinoIcons.map_pin_ellipse, onNavigate),
            _quick('搜索点播歌曲 / 歌单', CupertinoIcons.search, onMusic),
          ],
        ),
        const SizedBox(height: 14),
        _panel(
          child: Column(
            children: [
              _device('R9000P 远端后端', '未接入 · 演示', CupertinoIcons.cloud_fill),
              const Divider(color: Color(0xFF242830), height: 22),
              _device(
                'Ottocast P3 Pro 车机',
                '未接入 · 演示',
                CupertinoIcons.device_phone_portrait,
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
            navigation ? '广岛和平公园' : 'Lemon',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            navigation ? '最近导航任务（演示）' : '米津玄师 · 演示曲目',
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 9),
          _badge(
            navigation
                ? '已请求打开 · 演示'
                : '${playing ? "播放中" : "已暂停"} · 02:45 / 04:15',
            color,
            icon: navigation ? Icons.circle : CupertinoIcons.music_note,
            iconSize: 9,
          ),
        ],
      ),
    );
  }

  Widget _quick(String label, IconData icon, VoidCallback onTap) =>
      OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color(0xFF202227),
          side: const BorderSide(color: Color(0xFF32353B)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        ),
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      );
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

Widget _device(String title, String status, IconData icon) => Row(
  children: [
    Icon(icon, size: 19, color: _muted),
    const SizedBox(width: 9),
    Expanded(
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    const SizedBox(width: 6),
    Text(status, style: const TextStyle(color: _muted, fontSize: 10)),
  ],
);

class _InputPage extends StatefulWidget {
  const _InputPage({required this.isMusic});
  final bool isMusic;
  @override
  State<_InputPage> createState() => _InputPageState();
}

class _InputPageState extends State<_InputPage> {
  final _input = TextEditingController();
  String? _preview;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
    children: [
      Text(
        widget.isMusic ? '音乐' : '导航',
        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        widget.isMusic ? '想听的音乐，随手找到。' : '下一站，想去哪里？',
        style: const TextStyle(color: _muted, fontSize: 16),
      ),
      const SizedBox(height: 28),
      _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isMusic ? '歌曲 / 歌单' : '目的地',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 15),
            TextField(
              key: ValueKey(
                widget.isMusic ? 'music-input' : 'destination-input',
              ),
              controller: _input,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: widget.isMusic
                    ? '输入歌曲名、歌单或音乐链接'
                    : '输入坐标、Plus Code 或地图链接',
                border: const OutlineInputBorder(),
                hintStyle: const TextStyle(fontSize: 14, color: _muted),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: ValueKey(
                widget.isMusic ? 'music-preview' : 'destination-preview',
              ),
              onPressed: () {
                FocusScope.of(context).unfocus();
                setState(
                  () => _preview = _input.text.trim().isEmpty
                      ? '请先输入内容'
                      : '本地预览：${_input.text.trim()}\n未发送，未接入后端或车机。',
                );
              },
              icon: Icon(
                widget.isMusic
                    ? CupertinoIcons.search
                    : CupertinoIcons.paperplane,
              ),
              label: Text(widget.isMusic ? '预览搜索（演示）' : '预览发送（演示）'),
            ),
            if (_preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 15),
                child: Text(
                  _preview!,
                  style: const TextStyle(color: _blue, height: 1.5),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _panel(
        child: Text(
          widget.isMusic
              ? '尚未接入网易云或车机播放器。\n所有操作只在本机展示，不会播放音乐。'
              : '尚未接入地图解析或车机下发。\n真实路线需以后在车机端确认。',
          style: const TextStyle(color: _muted, height: 1.7),
        ),
      ),
    ],
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage();
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      const Text(
        '设置',
        style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 24),
      _panel(
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MyYaris',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text('0.1.0 · 页面演示版', style: TextStyle(color: _muted)),
            SizedBox(height: 20),
            Text('网络与凭据', style: TextStyle(fontSize: 17)),
            SizedBox(height: 8),
            Text(
              '未配置后端地址；未保存或读取 token。\nTailscale 状态与车机信息均为演示。',
              style: TextStyle(color: _muted, height: 1.7),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _panel(
        child: const Text(
          '此版本仅用于页面与安装验证。\n导航、音乐和设备状态尚未接入。',
          style: TextStyle(color: _muted, height: 1.7),
        ),
      ),
    ],
  );
}
