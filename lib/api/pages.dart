import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'backend.dart';
import 'music_queue_browser.dart';
import 'login_page.dart';
export 'music_home.dart' show MusicPage, MusicPlayerPage;
import '../apple_map.dart';
import '../map_search_page.dart';
import 'driving_favorites_drawer.dart';

const _muted = Color(0xFF9398A6);

Future<void> showApiResult(
  BuildContext context,
  String title,
  Future<Map<String, dynamic>> Function() action,
) async {
  try {
    final result = await action();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(redact(result)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

Object? redact(Object? value) {
  if (value is Map) {
    return value.map(
      (k, v) => MapEntry(
        '$k',
        RegExp(
              'cookie|token|music_u|authorization',
              caseSensitive: false,
            ).hasMatch('$k')
            ? '[已隐藏]'
            : redact(v),
      ),
    );
  }
  if (value is List) return value.map(redact).toList();
  return value;
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
Widget card(List<Widget> children) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: Material(
    color: const Color(0xFF11151D),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xFF252B35)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  ),
);
Widget heading(String title, String subtitle) => Padding(
  padding: const EdgeInsets.only(bottom: 24),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
      ),
      if (subtitle.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(subtitle, style: const TextStyle(color: _muted)),
      ],
    ],
  ),
);

class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key, required this.session, this.active = true});
  final bool active;
  final BackendSession session;
  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  final input = TextEditingController();
  Map<String, dynamic>? resolved, query;
  String? error;
  bool busy = false;
  bool pointPromptOpen = false;
  String? resolveKey, dispatchKey, resolveInput;
  MapSelection? mapSelection;
  final mapController = AppleMapController();
  final drawer = DraggableScrollableController();
  double drawerExtent = .34, heldDrawerExtent = .34;
  double _sheetHeight = 0;
  double _snapFraction = -1;
  List<double> _drawerSnapSizes = const [.22, .34, .70, .86];
  double get _barFraction => _sheetHeight <= 0
      ? 0
      : (MediaQuery.paddingOf(context).bottom / _sheetHeight).clamp(0, .5);
  double _sheetSize(double visibleExtent) =>
      (_barFraction + (1 - _barFraction) * visibleExtent).clamp(0, 1);
  double _visibleSize(double sheetExtent) =>
      ((sheetExtent - _barFraction) / (1 - _barFraction)).clamp(0, 1);

  bool mapInteracting = false;
  void mapInteractionChanged(bool active) {
    if (!mounted || mapInteracting == active) return;
    setState(() {
      if (active) heldDrawerExtent = drawerExtent;
      mapInteracting = active;
    });
  }

  @override
  void didUpdateWidget(covariant NavigationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) mapInteracting = false;
  }

  @override
  void initState() {
    super.initState();
    drawer.addListener(() {
      if (mounted &&
          drawer.isAttached &&
          (_visibleSize(drawer.size) - drawerExtent).abs() > .005) {
        setState(() => drawerExtent = _visibleSize(drawer.size));
      }
    });
  }

  bool _samePoint(Map value, MapSelection point) =>
      value['latitude'] is num &&
      value['longitude'] is num &&
      ((value['latitude'] as num) - point.latitude).abs() < .000001 &&
      ((value['longitude'] as num) - point.longitude).abs() < .000001;

  Future<void> selectPoint(MapSelection point) async {
    if (busy ||
        pointPromptOpen ||
        !point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude.abs() > 90 ||
        point.longitude.abs() > 180) {
      return;
    }
    pointPromptOpen = true;
    final messenger = ScaffoldMessenger.of(context);
    final reuseResolution =
        input.text == '${point.latitude}, ${point.longitude}' &&
        resolved != null &&
        query != null;
    final token = widget.session.api.token,
        origin = widget.session.api.baseUrl,
        device = widget.session.api.deviceId;
    bool sameIdentity() =>
        mounted &&
        token == widget.session.api.token &&
        origin == widget.session.api.baseUrl &&
        device == widget.session.api.deviceId;
    setState(() {
      mapSelection = point;
      input.text = '${point.latitude}, ${point.longitude}';
      error = null;
      if (!reuseResolution) {
        resolved = null;
        query = null;
        resolveKey = dispatchKey = resolveInput = null;
      }
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: const ValueKey('map-point-confirmation'),
          title: const Text('发送目的地到车机？'),
          content: Text(
            '${point.title}\nWGS84 纬度 ${point.latitude.toStringAsFixed(6)} · 经度 ${point.longitude.toStringAsFixed(6)}\n目标：$device',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('map-point-send'),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('发送到车机'),
            ),
          ],
        ),
      );
      if (confirmed != true || !sameIdentity()) return;
      if (!reuseResolution) await resolve();
      if (!sameIdentity()) return;
      if (query?['task_id'] != null) {
        await loadResolved();
        if (sameIdentity()) {
          messenger.showSnackBar(
            const SnackBar(content: Text('该目的地已提交，已查询回执，未重复派发')),
          );
        }
        return;
      }
      if (error == null) {
        final candidates = ((query?['candidates'] as List?) ?? [])
            .whereType<Map>()
            .where((c) => _samePoint(c, point))
            .toList();
        if (resolved?['needs_confirmation'] != true &&
            resolved?['status'] != 'needs_clarification' &&
            query?['needs_confirmation'] != true &&
            query?['status'] != 'needs_clarification' &&
            ((query?['candidates'] as List?) ?? []).length == 1 &&
            candidates.length == 1 &&
            candidates.single['candidate_id'] is String &&
            query?['task_id'] == null) {
          await _sendPointCandidate(
            candidates.single['candidate_id'] as String,
            point,
          );
        } else {
          error = '解析结果与确认的选点不一致或尚未完成，未派发。请重新选择目的地';
        }
      }
      if (sameIdentity()) {
        messenger.showSnackBar(
          SnackBar(content: Text(error ?? '目的地已提交，等待车机回执')),
        );
      }
    } catch (e) {
      if (sameIdentity()) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(e is ApiFailure ? e.message : '目的地处理失败，未自动重试，请核对回执'),
          ),
        );
      }
    } finally {
      pointPromptOpen = false;
    }
  }

  Future<void> searchMap() async {
    final token = widget.session.api.token;
    final origin = widget.session.api.baseUrl;
    final point = await Navigator.push<MapSelection>(
      context,
      MaterialPageRoute(
        builder: (_) => MapSearchPage(controller: mapController),
      ),
    );
    if (!mounted ||
        token != widget.session.api.token ||
        origin != widget.session.api.baseUrl) {
      return;
    }
    if (point != null) selectPoint(point);
  }

  @override
  void dispose() {
    drawer.dispose();
    input.dispose();
    super.dispose();
  }

  Future<void> resolve() async {
    if (input.text.trim().isEmpty) {
      setState(() => error = '请输入目的地');
      return;
    }
    if (!widget.session.api.configured || !widget.session.canControlVehicle) {
      setState(
        () => error = widget.session.userSignedIn
            ? '当前账号未授权车机，请联系管理员'
            : '请先登录 MyYaris',
      );
      return;
    }
    if (busy) return;
    if (resolveInput != input.text.trim()) {
      resolveKey = null;
      dispatchKey = null;
      resolveInput = input.text.trim();
    }
    resolveKey ??= requestId();
    dispatchKey ??= requestId();
    setState(() {
      busy = true;
      error = null;
      resolved = null;
      query = null;
    });
    try {
      final token = widget.session.api.token,
          origin = widget.session.api.baseUrl,
          device = widget.session.api.deviceId;
      final r = await widget.session.api.resolveDestination(
        input.text.trim(),
        resolveKey!,
        purpose: DestinationPurpose.navigation,
      );
      if (!mounted ||
          token != widget.session.api.token ||
          origin != widget.session.api.baseUrl ||
          device != widget.session.api.deviceId) {
        return;
      }
      setState(() {
        resolved = r;
        query = r['candidates'] is List ? r : null;
      });
      if (query == null) await loadResolved();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> uploadVoice() async {
    if (busy) return;
    if (!widget.session.api.configured) {
      setState(() => error = '请先登录 MyYaris');
      return;
    }
    try {
      await widget.session.api.ensureVoiceProvider();
      final selected = await KeychainStore.channel
          .invokeMapMethod<String, dynamic>('pickAudio');
      if (selected == null || !mounted) return;
      final bytes = selected['bytes'] as Uint8List;
      if (!await confirmAction(
        context,
        '上传音频',
        '将 ${selected['name']} 发往你的私网后端转写和解析目的地，随后由你确认候选，不在上传时派发。是否继续？',
      )) {
        return;
      }
      if (!mounted) return;
      resolveKey ??= requestId();
      dispatchKey ??= requestId();
      setState(() {
        busy = true;
        error = null;
        query = null;
        resolved = null;
      });
      final r = await widget.session.api.uploadAudio(
        bytes,
        '${selected['name']}',
      );
      if (!mounted) return;
      setState(
        () => resolved = {
          'destination_id': r['request_id'],
          'name': '音频目的地',
          'confidence': .5,
        },
      );
      await loadResolved();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiFailure
              ? e.message
              : '文件选择或上传失败，请在 iPhone 上选择短音频重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loadResolved() async {
    if (resolved == null) return;
    final token = widget.session.api.token,
        origin = widget.session.api.baseUrl,
        device = widget.session.api.deviceId;
    final q = await widget.session.api.call(
      'GET',
      '/destinations/${Uri.encodeComponent('${resolved!['destination_id'] ?? resolved!['request_id']}')}',
    );
    if (!mounted ||
        token != widget.session.api.token ||
        origin != widget.session.api.baseUrl ||
        device != widget.session.api.deviceId) {
      return;
    }
    if (mounted) {
      setState(() {
        query = q;
        if (q['status'] == 'failed' || q['status'] == 'unavailable') {
          error = '解析未完成/能力不可用，请核对真实 provider；不会派发';
        }
      });
    }
    if (q['task_id'] != null) {
      final task = await widget.session.api.call(
        'GET',
        '/tasks/${Uri.encodeComponent('${q['task_id']}')}',
      );
      if (mounted &&
          token == widget.session.api.token &&
          origin == widget.session.api.baseUrl &&
          device == widget.session.api.deviceId) {
        await widget.session.acceptNavigationTask(task);
      }
    }
  }

  Future<void> _sendPointCandidate(
    String candidate,
    MapSelection confirmedPoint,
  ) async {
    if (busy) return;
    if (!((query?['candidates'] as List?) ?? []).whereType<Map>().any(
      (c) => c['candidate_id'] == candidate && _samePoint(c, confirmedPoint),
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final token = widget.session.api.token;
      final origin = widget.session.api.baseUrl;
      final device = widget.session.api.deviceId;
      final id = '${resolved!['destination_id'] ?? resolved!['request_id']}';
      final result = await widget.session.api.dispatchDestination(
        id,
        candidate,
        dispatchKey ??= requestId(),
        singleCandidate: ((query?['candidates'] as List?) ?? []).length == 1,
      );
      if (!mounted ||
          token != widget.session.api.token ||
          origin != widget.session.api.baseUrl ||
          device != widget.session.api.deviceId) {
        return;
      }
      final point = mapSelection;
      final matchesPoint =
          point != null &&
          input.text.trim() == '${point.latitude}, ${point.longitude}' &&
          result['latitude'] is num &&
          result['longitude'] is num &&
          ((result['latitude'] as num) - point.latitude).abs() < .00001 &&
          ((result['longitude'] as num) - point.longitude).abs() < .00001 &&
          point.title != '地图选点';
      await widget.session.acceptNavigationTask(
        result,
        displayTitle: matchesPoint ? point.title : null,
      );
      if (mounted) {
        setState(() {
          resolved = null;
          query = null;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '行驶',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                key: const ValueKey('map-search-open'),
                tooltip: '搜索地图地点',
                onPressed: busy ? null : searchMap,
                icon: const Icon(Icons.search),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _sheetHeight = constraints.maxHeight;
              // Flutter compares snapSizes by list identity. A new list on
              // every drag tick forces goBallistic(0) and cancels the drag.
              if (_snapFraction != _barFraction) {
                _snapFraction = _barFraction;
                _drawerSnapSizes = [
                  .22,
                  .34,
                  .70,
                  .86,
                ].map(_sheetSize).toList();
              }
              return Stack(
                children: [
                  Positioned.fill(
                    bottom:
                        (constraints.maxHeight *
                                    _sheetSize(
                                      mapInteracting
                                          ? heldDrawerExtent
                                          : drawerExtent,
                                    ) -
                                24)
                            .clamp(0.0, constraints.maxHeight),
                    child: AppleMap(
                      controller: mapController,
                      onInteractionChanged: mapInteractionChanged,
                      active: widget.active,
                      selection: mapSelection,
                      onSelected: selectPoint,
                    ),
                  ),
                  DraggableScrollableSheet(
                    controller: drawer,
                    minChildSize: _sheetSize(.22),
                    initialChildSize: _sheetSize(.34),
                    maxChildSize: _sheetSize(.86),
                    snap: true,
                    snapSizes: _drawerSnapSizes,
                    builder: (context, scroll) => DrivingFavoritesDrawer(
                      session: widget.session,
                      controller: scroll,
                      selection: mapSelection,
                      onSelected: (favorite) => selectPoint(
                        MapSelection(
                          favorite.latitude,
                          favorite.longitude,
                          title: favorite.displayName,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class MusicSearchPage extends StatefulWidget {
  const MusicSearchPage({super.key, required this.session});
  final BackendSession session;
  @override
  State<MusicSearchPage> createState() => _MusicSearchPageState();
}

class _MusicSearchPageState extends State<MusicSearchPage> {
  final keyword = TextEditingController();
  String get identity =>
      '${widget.session.api.baseUrl}\n${widget.session.api.token}';
  late String owner;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    owner = identity;
    widget.session.addListener(accountChanged);
  }

  void accountChanged() {
    if (identity == owner) return;
    owner = identity;
    epoch++;
    if (mounted) {
      setState(() {
        tracks = [];
        total = 0;
        searched = busy = selecting = false;
        error = null;
        keyword.clear();
      });
    }
  }

  String source = 'netease';
  int page = 1, total = 0;
  bool busy = false, searched = false, selecting = false;
  String? error;
  List<Map<String, dynamic>> tracks = [];
  @override
  void dispose() {
    epoch++;
    widget.session.removeListener(accountChanged);
    keyword.dispose();
    super.dispose();
  }

  Future<void> search({bool next = false}) async {
    if (busy) return;
    final gen = ++epoch, who = identity, queryText = keyword.text.trim();
    final transport = BackendApi(client: widget.session.api.client)
      ..baseUrl = widget.session.api.baseUrl
      ..token = widget.session.api.token
      ..isUserSession = widget.session.api.isUserSession
      ..onSessionExpired = () async {
        if (who == identity) await widget.session.api.onSessionExpired?.call();
      };
    setState(() {
      busy = true;
      error = null;
      if (!next) {
        page = 1;
        tracks = [];
        total = 0;
        searched = false;
      }
    });
    try {
      final online = source == 'netease';
      if (online && keyword.text.trim().isEmpty) {
        throw ApiFailure('请输入网易云搜索关键词');
      }
      final response = online
          ? await transport.searchOnline(queryText, page: page)
          : await transport.call(
              'GET',
              '/api/v1/music/tracks',
              query: {
                if (keyword.text.trim().isNotEmpty)
                  'keyword': keyword.text.trim(),
                'page': '$page',
                'limit': '20',
                if (!online) 'source': source,
              },
            );
      final items = ((response[online ? 'songs' : 'tracks'] as List?) ?? [])
          .map(
            (x) => {
              ...Map<String, dynamic>.from(x as Map),
              'source': online ? 'netease' : source,
            },
          )
          .toList();
      if (mounted &&
          gen == epoch &&
          who == identity &&
          queryText == keyword.text.trim()) {
        setState(() {
          tracks = next ? [...tracks, ...items] : items;
          total = (response['total'] as num?)?.toInt() ?? tracks.length;
          searched = true;
        });
      }
    } catch (e) {
      if (mounted && gen == epoch && who == identity) {
        setState(() => error = e.toString());
        if (next) page--;
      }
    } finally {
      if (mounted && gen == epoch && who == identity) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> play(Map<String, dynamic> track) async {
    if (selecting) return;
    final who = identity;
    setState(() => selecting = true);
    try {
      await widget.session.playTrack(track, singleTrack: true);
      if (mounted && who == identity) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('播放指令已提交，并不代表已经起播')));
      }
    } catch (e) {
      if (mounted && who == identity) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted && who == identity) setState(() => selecting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('搜索音乐')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          if (!widget.session.canControlVehicle)
            const Text(
              '账号已登录，但未授权当前车机；请联系管理员绑定后再播放。',
              style: TextStyle(color: Colors.orangeAccent),
            ),
          if (widget.session.musicDiagnostic.isNotEmpty)
            card([
              Text(
                '只读诊断：${widget.session.musicDiagnostic['search']} · 搜索数量 ${widget.session.musicDiagnostic['total'] ?? '未知'}',
              ),
              if (widget.session.musicDiagnostic['error'] != null)
                Text(
                  '${widget.session.musicDiagnostic['error']}',
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              const Text('未发送播放/音量/导航指令，实际起播尚未验收'),
            ]),
          card([
            DropdownButtonFormField<String>(
              initialValue: source,
              items: const [
                DropdownMenuItem(value: 'netease', child: Text('网易云在线')),
                DropdownMenuItem(value: 'local_repo', child: Text('本地曲库')),
                DropdownMenuItem(value: 'netease_cache', child: Text('网易云缓存')),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      source = v!;
                      tracks = [];
                      total = 0;
                    }),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('music-input'),
              controller: keyword,
              decoration: const InputDecoration(
                labelText: '歌曲 / 艺术家 / 专辑',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => search(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('music-preview'),
              onPressed: busy ? null : () => search(),
              child: Text(busy ? '搜索中…' : '搜索曲库'),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
            if (error != null)
              const Text('搜索失败，未将错误当作空结果')
            else if (searched && tracks.isEmpty)
              const Text('搜索返回成功，暂无结果；旧后端若吞掉上游错误，需后端诊断确认')
            else if (searched)
              Text('共 $total 首', style: const TextStyle(color: _muted)),
          ]),
          ...tracks.map(
            (track) => card([
              Text(
                '${track['title'] ?? track['track_id']}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${track['artist'] ?? ''} · ${track['album'] ?? ''}',
                style: const TextStyle(color: _muted),
              ),
              Text(
                '来源：${track['source']} · song_id：${track['song_id'] ?? track['id'] ?? '非在线曲目'} · 可播性待检查',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed:
                        selecting ||
                            widget.session.commandPending ||
                            widget.session.awaitingExecution
                        ? null
                        : () => play(track),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(selecting ? '检查可播性…' : '检查并车机播放'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => TrackPage(
                          session: widget.session,
                          track: track,
                          onPlay: play,
                        ),
                      ),
                    ),
                    child: const Text('详情 / 歌词'),
                  ),
                ],
              ),
            ]),
          ),
          if (tracks.length < total)
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      page++;
                      search(next: true);
                    },
              child: const Text('加载下一页'),
            ),
        ],
      ),
    ),
  );
}

class PlaybackPanel extends StatefulWidget {
  const PlaybackPanel({
    super.key,
    required this.session,
    this.immersive = false,
    this.onSelectMusic,
  });
  final BackendSession session;
  final bool immersive;
  final VoidCallback? onSelectMusic;
  @override
  State<PlaybackPanel> createState() => _PlaybackPanelState();
}

class _PlaybackPanelState extends State<PlaybackPanel> {
  BackendSession get session => widget.session;
  double? seekDraft, volumeDraft;
  Future<void> command(
    BuildContext context,
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      await session.sendCommand(action, params);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('指令已提交，等待车机状态回报')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      final p = session.playback;
      final ready =
          (session.queueV2Ready && session.ownerQueueAllowed) ||
          !session.playbackStale &&
              session.heartbeatFresh &&
              p['current_track_id'] is String &&
              (p['current_track_id'] as String).isNotEmpty;
      final locked =
          session.commandPending ||
          session.preparingTrack ||
          session.awaitingExecution;
      final duration = (p['duration_ms'] as num?)?.toDouble() ?? 0;
      final seekKnown = ready && p['position_ms'] is num && duration > 0;
      final position = ((p['position_ms'] as num?)?.toDouble() ?? 0)
          .clamp(0, duration > 0 ? duration : 1)
          .toDouble();
      final rawVolume = p['software_volume'];
      final volume =
          rawVolume is num &&
              rawVolume.isFinite &&
              rawVolume >= 0 &&
              rawVolume <= 1
          ? rawVolume.toDouble()
          : null;
      if (widget.immersive) {
        String clock(double ms) {
          final seconds = ms ~/ 1000;
          return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
        }

        final enabled = ready && !locked;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.homeMusicTitle,
                        key: const ValueKey('player-track-title'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${session.currentTrack['artist'] ?? '歌手信息暂不可用'}',
                        style: const TextStyle(
                          fontSize: 17,
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ),
                const Tooltip(
                  message: '喜欢操作暂未接入',
                  child: IconButton(
                    onPressed: null,
                    icon: Icon(Icons.favorite_border, color: Colors.white30),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(
                  Icons.directions_car_outlined,
                  size: 18,
                  color: Colors.white54,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '车机 · ${session.homeMusicState}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ],
            ),
            QueueModeCaption(session: session),
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                key: const ValueKey('player-seek'),
                value: seekKnown
                    ? (seekDraft ?? position).clamp(0, duration).toDouble()
                    : 0,
                max: seekKnown ? duration : 1,
                activeColor: const Color(0xFF8ADBE9),
                inactiveColor: Colors.white24,
                onChanged: !seekKnown || locked
                    ? null
                    : (v) => setState(() => seekDraft = v),
                onChangeEnd: !seekKnown || locked
                    ? null
                    : (v) async {
                        await command(context, 'seek', {'seek_ms': v.round()});
                        if (mounted) setState(() => seekDraft = null);
                      },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  seekKnown ? clock(seekDraft ?? position) : '--:--',
                  style: const TextStyle(color: Colors.white54),
                ),
                Text(
                  seekKnown ? clock(duration) : '--:--',
                  style: const TextStyle(color: Colors.white54),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  key: const ValueKey('player-loop'),
                  tooltip: '选择播放模式',
                  onPressed: () => showQueueModes(context, session),
                  icon: const Icon(Icons.repeat),
                  iconSize: 25,
                ),
                IconButton(
                  tooltip: '上一曲',
                  onPressed: enabled ? () => command(context, 'prev') : null,
                  icon: const Icon(Icons.skip_previous_rounded),
                  iconSize: 32,
                ),
                SizedBox(
                  width: 76,
                  height: 76,
                  child: FilledButton(
                    key: const ValueKey('player-toggle'),
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      backgroundColor: const Color(0xFFFFF2E0),
                      foregroundColor: const Color(0xFF19202E),
                    ),
                    onPressed: enabled
                        ? () => command(
                            context,
                            session.playing ? 'pause' : 'resume',
                          )
                        : null,
                    child: Icon(
                      session.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 42,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一曲',
                  onPressed: enabled ? () => command(context, 'next') : null,
                  icon: const Icon(Icons.skip_next_rounded),
                  iconSize: 32,
                ),
                IconButton(
                  tooltip: '选择音乐',
                  onPressed: widget.onSelectMusic,
                  icon: const Icon(Icons.queue_music),
                  iconSize: 25,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('车机音量', style: TextStyle(color: Colors.white54)),
                Text(
                  ready && volume != null
                      ? '${((volumeDraft ?? volume) * 100).round()}%'
                      : '未知',
                  style: const TextStyle(color: Colors.white54),
                ),
              ],
            ),
            Row(
              children: [
                const Icon(
                  Icons.volume_mute_outlined,
                  size: 23,
                  color: Colors.white60,
                ),
                Expanded(
                  child: Slider(
                    key: const ValueKey('player-volume'),
                    value: ready && volume != null ? volumeDraft ?? volume : 0,
                    activeColor: const Color(0xFF8ADBE9),
                    inactiveColor: Colors.white24,
                    onChanged: !enabled || volume == null
                        ? null
                        : (v) => setState(() => volumeDraft = v),
                    onChangeEnd: !enabled || volume == null
                        ? null
                        : (v) async {
                            await command(context, 'set_volume', {'volume': v});
                            if (mounted) setState(() => volumeDraft = null);
                          },
                  ),
                ),
                const Icon(
                  Icons.volume_up_outlined,
                  size: 23,
                  color: Colors.white60,
                ),
              ],
            ),
            if (locked || session.lastCommandState.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  session.preparingTrack ? '正在检查资源可播性…' : session.commandLabel,
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
          ],
        );
      }
      return card([
        Text(
          '${session.currentTrack['title'] ?? p['current_track_id'] ?? '暂无播放曲目'}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          '${session.playbackStale ? '过期/尚未收到的快照' : '服务器转发的状态快照'}：${p['playback_state'] ?? '未知'} · ${session.realtime}',
          style: const TextStyle(color: _muted),
        ),
        Text(
          '车机心跳：${p['last_heartbeat_at'] ?? '未知'} · 60秒内心跳才启用播控',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        Text(
          '快照时间（后端提供）：${p['updated_at'] ?? '未知'}',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        Wrap(
          alignment: WrapAlignment.spaceAround,
          children: [
            IconButton(
              tooltip: '上一曲',
              onPressed: !ready || locked
                  ? null
                  : () => command(context, 'prev'),
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              tooltip: '播放/暂停',
              onPressed: !ready || locked
                  ? null
                  : () =>
                        command(context, session.playing ? 'pause' : 'resume'),
              icon: Icon(session.playing ? Icons.pause : Icons.play_arrow),
            ),
            IconButton(
              tooltip: '下一曲',
              onPressed: !ready || locked
                  ? null
                  : () => command(context, 'next'),
              icon: const Icon(Icons.skip_next),
            ),
            IconButton(
              tooltip: '停止',
              onPressed: !ready || locked
                  ? null
                  : () => command(context, 'stop'),
              icon: const Icon(Icons.stop),
            ),
            IconButton(
              tooltip: '刷新播放状态',
              onPressed: () => session.refresh(),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (seekKnown) ...[
          Text('${(position / 1000).floor()} / ${(duration / 1000).floor()} 秒'),
          Slider(
            value: (seekDraft ?? position).clamp(0, duration).toDouble(),
            max: duration,
            onChanged: locked ? null : (v) => setState(() => seekDraft = v),
            onChangeEnd: (v) async {
              await command(context, 'seek', {'seek_ms': v.round()});
              if (mounted) setState(() => seekDraft = null);
            },
          ),
        ] else
          const Text('进度：未知/不可用，等待车机有效状态'),
        const Text('车机软件音量'),
        if (ready && volume != null)
          Slider(
            value: volumeDraft ?? volume,
            onChanged: locked ? null : (v) => setState(() => volumeDraft = v),
            onChangeEnd: (v) async {
              await command(context, 'set_volume', {'volume': v});
              if (mounted) setState(() => volumeDraft = null);
            },
          )
        else
          const Text('音量：未知/不可用，未采用默认值'),
        QueueModeCaption(session: session),
        Text(
          '目标：${session.api.deviceId} · command_id：${session.lastCommandState['command_id'] ?? '无'}',
        ),
        Text(session.commandLabel),
        if (session.preparingTrack) const Text('正在检查资源与音频首段，尚未发出播放指令'),
        if (session.lastTrackProbe.isNotEmpty)
          Text(
            session.lastTrackProbe['status'] == 'failed'
                ? '选歌检查失败：${session.lastTrackProbe['message']}'
                : '首段检查：HTTP ${session.lastTrackProbe['http_status']} · ${session.lastTrackProbe['content_type']} · Range ${session.lastTrackProbe['range_supported']}（不等于完整权限或已播放）',
          ),
        if (session.lastCommandState['error_code'] != null)
          Text('车机错误：${session.lastCommandState['error_code']}'),
        TextButton(
          onPressed: session.refreshCommandState,
          child: const Text('查询指令执行结果'),
        ),
        const Text(
          '控件以车机回报为准；HTTP / WebSocket 已送达不等于执行成功。',
          style: TextStyle(color: _muted, fontSize: 12),
        ),
      ]);
    },
  );
}

class TrackPage extends StatefulWidget {
  const TrackPage({
    super.key,
    required this.session,
    required this.track,
    required this.onPlay,
  });
  final BackendSession session;
  final Map<String, dynamic> track;
  final Future<void> Function(Map<String, dynamic>) onPlay;
  @override
  State<TrackPage> createState() => _TrackPageState();
}

class _TrackPageState extends State<TrackPage> {
  String quality = 'standard';
  List<Map<String, dynamic>> recommendations = [];
  @override
  Widget build(BuildContext context) {
    final online = widget.track['id'] != null;
    final id = '${widget.track['id']}';
    return Scaffold(
      appBar: AppBar(title: const Text('歌曲详情')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          heading(
            '${widget.track['title'] ?? ''}',
            '${widget.track['artist'] ?? ''} · ${widget.track['album'] ?? ''}',
          ),
          FilledButton(
            onPressed: () => widget.onPlay(widget.track),
            child: const Text('发送到车机播放'),
          ),
          const SizedBox(height: 12),
          if (!online)
            TextButton(
              onPressed: () => showApiResult(
                context,
                '曲目元数据',
                () => widget.session.api.call(
                  'GET',
                  '/api/v1/music/tracks/${Uri.encodeComponent('${widget.track['track_id']}')}',
                ),
              ),
              child: const Text('读取曲目详情'),
            ),
          TextButton(
            onPressed: () => showApiResult(
              context,
              '流媒体响应',
              () => widget.session.api.probeStream(widget.track),
            ),
            child: const Text('检查流媒体首块（在线歌曲会触发缓存）'),
          ),
          if (online) ...[
            DropdownButtonFormField<String>(
              initialValue: quality,
              items: [
                'standard',
                'exhigh',
                'lossless',
                'hires',
              ].map((q) => DropdownMenuItem(value: q, child: Text(q))).toList(),
              onChanged: (v) => setState(() => quality = v!),
            ),
            TextButton(
              onPressed: () => showApiResult(
                context,
                '音质 / CDN 信息',
                () => widget.session.api.call(
                  'GET',
                  '/api/v1/music/netease/song_url',
                  query: {'song_id': id, 'level': quality},
                ),
              ),
              child: const Text('获取音质信息（不直接播放 CDN）'),
            ),
            TextButton(
              onPressed: () => showApiResult(
                context,
                '歌词 / 翻译',
                () => widget.session.api.call(
                  'GET',
                  '/api/v1/music/netease/lyric',
                  query: {'song_id': id},
                ),
              ),
              child: const Text('歌词与翻译'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  final r = await widget.session.api.call(
                    'POST',
                    '/api/v1/music/netease/intelligence',
                    body: {'seed_song_id': widget.track['id'], 'count': 30},
                  );
                  if (mounted) {
                    setState(
                      () => recommendations = ((r['songs'] as List?) ?? [])
                          .map((x) => Map<String, dynamic>.from(x as Map))
                          .toList(),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              },
              child: const Text('获取心动推荐队列'),
            ),
            ...recommendations.map(
              (t) => ListTile(
                title: Text('${t['title']}'),
                subtitle: Text('${t['artist'] ?? ''}'),
                trailing: const Icon(Icons.play_arrow),
                onTap: () => widget.onPlay(t),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.session});
  final BackendSession session;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<void> accountMenu() async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('settings-account-menu'),
        title: const Text('账号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'nickname'),
              child: const Text('修改昵称'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'refresh'),
              child: const Text('刷新个人资料/权限'),
            ),
            TextButton(
              onPressed: widget.session.authBusy
                  ? null
                  : () => Navigator.pop(dialog, 'logout'),
              child: const Text('退出 MyYaris 登录'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'nickname') {
      await editNickname();
    } else if (action == 'refresh') {
      try {
        await widget.session.refreshUserProfile(resetDeviceDenied: true);
        widget.session.start();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.toString())));
        }
      }
    } else if (action == 'logout') {
      if (await confirmAction(context, '退出登录', '注销本机会话，保留服务域名、旧配置和服务器收藏。')) {
        await widget.session.logout();
      }
    }
  }

  Future<void> editNickname() async {
    var nickname = '${widget.session.userProfile['nickname'] ?? ''}';
    var saving = false;
    String? failure;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: const Text('修改昵称'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: nickname,
                maxLength: 64,
                enabled: !saving,
                onChanged: (value) => nickname = value,
              ),
              if (failure != null) Text(failure!),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      update(() {
                        saving = true;
                        failure = null;
                      });
                      try {
                        await widget.session.updateNickname(nickname);
                        if (dialog.mounted) Navigator.pop(dialog);
                      } catch (e) {
                        if (dialog.mounted) {
                          update(() {
                            failure = e.toString();
                            saving = false;
                          });
                        }
                      }
                    },
              child: Text(saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.fromLTRB(
      22,
      22,
      22,
      22 + MediaQuery.paddingOf(context).bottom,
    ),
    children: [
      heading('设置', ''),
      card([
        ListTile(
          key: const ValueKey('settings-user-open'),
          contentPadding: EdgeInsets.zero,
          leading: accountAvatar(
            widget.session.userProfile,
            widget.session.api.baseUrl,
          ),
          title: Text(
            '${widget.session.userProfile['nickname'] ?? widget.session.userProfile['username'] ?? '已登录用户'}',
            style: const TextStyle(fontSize: 20),
          ),
          subtitle: Text(
            '用户名：${widget.session.userProfile['username'] ?? ''}\n${widget.session.canControlVehicle ? '车机权限已获授权' : '当前账号未授权车机，请联系管理员'}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: accountMenu,
        ),
      ]),
      card([
        ListTile(
          key: const ValueKey('settings-connection-open'),
          title: const Text('连接设置'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => ConnectionSettingsPage(session: widget.session),
            ),
          ),
        ),
        ListTile(
          title: const Text('网易云账号'),
          subtitle: const Text('扫码 / Cookie 导入 / 保活 / 退出'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => AccountPage(session: widget.session),
            ),
          ),
        ),
        ListTile(
          title: const Text('媒体库与缓存'),
          subtitle: const Text('扫描索引 / 缓存用量 / LRU 清理'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => MediaAdminPage(session: widget.session),
            ),
          ),
        ),
      ]),
      AnimatedBuilder(
        animation: widget.session,
        builder: (context, _) => Text(
          '${widget.session.connection}\n${widget.session.realtime}\n${widget.session.lastMessage}',
          style: const TextStyle(color: _muted),
        ),
      ),
    ],
  );
}

class ConnectionSettingsPage extends StatefulWidget {
  const ConnectionSettingsPage({super.key, required this.session});
  final BackendSession session;
  @override
  State<ConnectionSettingsPage> createState() => _ConnectionSettingsPageState();
}

class _ConnectionSettingsPageState extends State<ConnectionSettingsPage> {
  late final base = TextEditingController(text: widget.session.api.baseUrl),
      device = TextEditingController(text: widget.session.api.deviceId);
  bool busy = false;
  bool editing = false;
  String message = '';
  @override
  void didUpdateWidget(covariant ConnectionSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!editing) {
      base.text = widget.session.api.baseUrl;
      device.text = widget.session.api.deviceId;
    }
  }

  @override
  void dispose() {
    base.dispose();
    device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('连接设置')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        card([
          TextField(
            controller: base,
            onChanged: (_) => editing = true,
            decoration: const InputDecoration(labelText: 'HTTPS 后端地址'),
            autocorrect: false,
          ),
          TextField(
            controller: device,
            onChanged: (_) => editing = true,
            decoration: const InputDecoration(labelText: '车机设备 ID'),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await widget.session.saveConnection(
                        base.text,
                        device.text,
                      );
                      if (mounted) setState(() => message = '连接设置已保存');
                    } catch (e) {
                      if (mounted) setState(() => message = e.toString());
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('保存并连接'),
          ),
          if (message.isNotEmpty) Text(message),
        ]),
      ],
    ),
  );
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.session});
  final BackendSession session;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> with WidgetsBindingObserver {
  final cookie = TextEditingController();
  Map<String, dynamic> account = {};
  String? key, qrImage;
  String message = '未查询';
  Timer? timer;
  bool checking = false, busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(loadStatus());
  }

  @override
  void dispose() {
    timer?.cancel();
    cookie.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      timer?.cancel();
    } else if (key != null) {
      startPolling();
    }
  }

  Future<void> loadStatus() async {
    try {
      final a = await widget.session.api.call(
        'GET',
        '/api/v1/music/netease/login/status',
      );
      if (mounted) setState(() => account = a);
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    }
  }

  void startPolling() {
    timer?.cancel();
    timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(checkQr()),
    );
  }

  Future<void> checkQr() async {
    if (checking || key == null) return;
    checking = true;
    try {
      final r = await widget.session.api.call(
        'GET',
        '/api/v1/music/netease/login/qr/check',
        query: {'key': key!},
      );
      if (!mounted) return;
      setState(
        () => message = switch (r['code']) {
          800 => '二维码已过期，请重新生成',
          801 => '等待扫码',
          802 => '已扫码，请在网易云确认',
          803 => '授权成功',
          _ => '未知扫码状态',
        },
      );
      if (r['code'] == 800 || r['code'] == 803) {
        timer?.cancel();
        key = null;
        if (r['code'] == 803) await loadStatus();
      }
    } catch (e) {
      timer?.cancel();
      if (mounted) setState(() => message = e.toString());
    } finally {
      checking = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('网易云账号')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        card([
          Text(
            account['logged_in'] == true
                ? '已登录：${account['nickname'] ?? ''}'
                : '未登录',
            style: const TextStyle(fontSize: 20),
          ),
          TextButton(onPressed: loadStatus, child: const Text('刷新登录状态')),
        ]),
        card([
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    timer?.cancel();
                    try {
                      final k = await widget.session.api.call(
                        'GET',
                        '/api/v1/music/netease/login/qr/key',
                      );
                      final r = await widget.session.api.call(
                        'GET',
                        '/api/v1/music/netease/login/qr/create',
                        query: {'key': '${k['unikey']}'},
                      );
                      if (!mounted) return;
                      setState(() {
                        key = '${k['unikey']}';
                        qrImage = '${r['qrimg']}';
                        message = '等待扫码';
                      });
                      startPolling();
                    } catch (e) {
                      if (mounted) setState(() => message = e.toString());
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('生成登录二维码'),
          ),
          if (qrImage != null) QrImage(data: qrImage!),
          Text(message),
          const Text(
            '使用另一设备的网易云 App 扫码并确认；Cookie 由后端保存。',
            style: TextStyle(color: _muted),
          ),
        ]),
        card([
          TextField(
            controller: cookie,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Cookie / MUSIC_U（仅本次输入）',
            ),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    if (cookie.text.trim().isEmpty) return;
                    if (!await confirmAction(
                      context,
                      '导入网易云凭据',
                      '将你输入的 Cookie 经 HTTPS 发往已配置的私网后端，用于网易云授权。',
                    )) {
                      return;
                    }
                    setState(() => busy = true);
                    try {
                      await widget.session.api.call(
                        'POST',
                        '/api/v1/music/netease/login/cookie',
                        body: {'cookie': cookie.text.trim()},
                      );
                      cookie.clear();
                      await loadStatus();
                      if (mounted) setState(() => message = '导入完成');
                    } catch (e) {
                      cookie.clear();
                      if (mounted) setState(() => message = e.toString());
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('导入到后端（不在手机保存）'),
          ),
          TextButton(
            onPressed: () => showApiResult(
              context,
              '刷新保活',
              () => widget.session.api.call(
                'POST',
                '/api/v1/music/netease/login/refresh',
              ),
            ),
            child: const Text('刷新网易云凭证'),
          ),
          TextButton(
            onPressed: () async {
              if (await confirmAction(
                context,
                '退出网易云',
                '这会清除后端保存的网易云会话，并影响车机在线音乐。',
              )) {
                if (!context.mounted) return;
                await showApiResult(
                  context,
                  '退出登录',
                  () => widget.session.api.call(
                    'POST',
                    '/api/v1/music/netease/login/logout',
                  ),
                );
                await loadStatus();
              }
            },
            child: const Text('退出网易云登录'),
          ),
        ]),
      ],
    ),
  );
}

class QrImage extends StatelessWidget {
  const QrImage({super.key, required this.data});
  final String data;
  @override
  Widget build(BuildContext context) {
    try {
      if (!data.startsWith('data:image/')) return const Text('二维码格式异常');
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Image.memory(
          base64Decode(data.split(',').last),
          width: 220,
          height: 220,
          errorBuilder: (_, _, _) => const Text('二维码加载失败'),
        ),
      );
    } catch (_) {
      return const Text('二维码解码失败');
    }
  }
}

class MediaAdminPage extends StatelessWidget {
  const MediaAdminPage({super.key, required this.session});
  final BackendSession session;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('媒体库与缓存')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        card([
          TextButton(
            onPressed: () => showApiResult(
              context,
              '缓存状态',
              () => session.api.call('GET', '/api/v1/music/cache/stats'),
            ),
            child: const Text('查询缓存用量'),
          ),
          TextButton(
            onPressed: () async {
              if (await confirmAction(
                context,
                '扫描音乐库',
                '扫描后端默认音乐目录并更新索引，不更改扫描目录。',
              )) {
                if (context.mounted) {
                  await showApiResult(
                    context,
                    '扫描结果',
                    () => session.api.call('POST', '/api/v1/music/scan'),
                  );
                }
              }
            },
            child: const Text('扫描默认音乐库'),
          ),
          TextButton(
            onPressed: () async {
              if (await confirmAction(
                context,
                '按配额清理缓存',
                '后端会按 LRU 删除超出配额的缓存文件，不是清空全部歌曲。',
              )) {
                if (context.mounted) {
                  await showApiResult(
                    context,
                    '清理结果',
                    () => session.api.call('POST', '/api/v1/music/cache/clean'),
                  );
                }
              }
            },
            child: const Text('按后端配额执行 LRU 清理'),
          ),
          const Text(
            '不开放任意服务器目录输入，也不自动扫描或清理。',
            style: TextStyle(color: _muted),
          ),
        ]),
      ],
    ),
  );
}
