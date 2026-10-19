import 'package:flutter/material.dart';
import 'backend.dart';
import 'music_queue_contract.dart';

const playbackModeLabels = <String, String>{
  'list_loop': '喜欢歌单循环',
  'shuffle': '喜欢歌单随机',
  'intelligence': '网易云心动',
  'single_loop': '单曲循环',
};

String appliedPlaybackLabel(BackendSession session) {
  if (session.hasAppliedQueue &&
      session.playback['queue_source'] == 'single_track') {
    return session.appliedQueueMode == 'single_loop' ? '临时单曲 · 单曲循环' : '临时单曲';
  }
  return playbackModeLabels[session.appliedQueueMode] ?? '播放模式待确认';
}

Future<void> showQueueModes(
  BuildContext context,
  BackendSession session,
) async {
  final identity =
      '${session.api.baseUrl}\n${session.api.token}\n${session.api.deviceId}';
  final selected = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (context) => AnimatedBuilder(
      animation: session,
      builder: (context, _) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                '播放模式',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            if (!session.ownerQueueAllowed)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('当前账号无Owner喜欢歌单权限'),
              ),
            if (!session.queueV2Ready)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('车机尚未确认新版队列能力，未伪报模式已应用'),
              ),
            for (final item in playbackModeLabels.entries)
              ListTile(
                key: ValueKey('queue-mode-${item.key}'),
                enabled:
                    session.ownerQueueAllowed &&
                    session.canControlVehicle &&
                    session.queueV2Ready &&
                    !session.commandPending &&
                    !session.awaitingExecution,
                title: Text(item.value),
                trailing:
                    session.appliedQueueMode == item.key &&
                        (session.playback['queue_source'] != 'single_track' ||
                            item.key == 'single_loop')
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, item.key),
              ),
          ],
        ),
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  if (identity !=
      '${session.api.baseUrl}\n${session.api.token}\n${session.api.deviceId}') {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('会话已切换，请重新选择模式')));
    return;
  }
  try {
    await session.choosePlaybackMode(selected);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('模式请求已提交，等待车机实际应用')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiFailure ? e.message : '模式切换失败，未自动重试')),
      );
    }
  }
}

class QueueModeCaption extends StatelessWidget {
  const QueueModeCaption({super.key, required this.session});
  final BackendSession session;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      final actual = session.appliedQueueMode,
          requested = session.playback['requested_mode'];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            !session.hasAppliedQueue || actual == null
                ? '实际模式待确认 · 默认来源：我喜欢的音乐'
                : '已应用：${appliedPlaybackLabel(session)}',
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
          if (session.queueV2Ready &&
              requested != null &&
              requested != actual &&
              playbackModeLabels.containsKey(requested))
            Text(
              '待应用：${playbackModeLabels[requested]}',
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
          if (session.queueV2Ready && session.playback['error_code'] != null)
            Text(
              queueErrorMessages[session.playback['error_code']] ??
                  '车机回报执行异常，请刷新状态',
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
          TextButton(
            key: const ValueKey('queue-mode-menu'),
            onPressed: () => showQueueModes(context, session),
            child: const Text('选择播放模式'),
          ),
        ],
      );
    },
  );
}

class MusicQueueBrowser extends StatefulWidget {
  const MusicQueueBrowser({super.key, required this.session});
  final BackendSession session;
  @override
  State<MusicQueueBrowser> createState() => _MusicQueueBrowserState();
}

class _MusicQueueBrowserState extends State<MusicQueueBrowser> {
  MusicQueuePage? first;
  List<Map<String, dynamic>> tracks = [];
  MusicQueueAccumulator accumulator = MusicQueueAccumulator();
  bool busy = false, more = false;
  String? error;
  int generation = 0;
  late String identity;
  String get who =>
      '${widget.session.api.baseUrl}\n${widget.session.api.token}\n${widget.session.api.deviceId}\n${widget.session.userProfile['role']}';
  @override
  void initState() {
    super.initState();
    identity = who;
    widget.session.addListener(identityChanged);
    load(reset: true);
  }

  void identityChanged() {
    if (identity == who) return;
    identity = who;
    generation++;
    first = null;
    tracks = [];
    error = null;
    busy = false;
    more = false;
    accumulator = MusicQueueAccumulator();
    if (mounted) setState(() {});
    load(reset: true);
  }

  @override
  void dispose() {
    generation++;
    widget.session.removeListener(identityChanged);
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (busy) return;
    if (!widget.session.ownerQueueAllowed) {
      setState(() => error = '当前账号无Owner喜欢歌单权限');
      return;
    }
    final gen = ++generation, used = who;
    final api =
        BackendApi(
            client: widget.session.api.client,
            baseUrl: widget.session.api.baseUrl,
          )
          ..token = widget.session.api.token
          ..deviceId = widget.session.api.deviceId
          ..isUserSession = widget.session.api.isUserSession
          ..onSessionExpired = () async {
            if (used == who) await widget.session.api.onSessionExpired?.call();
          };
    setState(() {
      busy = true;
      error = null;
      if (reset) {
        first = null;
        tracks = [];
        more = false;
        accumulator = MusicQueueAccumulator();
      }
    });
    try {
      final page = await api.readMusicQueue(
        queueId: reset ? null : first?.id,
        version: reset ? null : first?.version,
        offset: reset ? 0 : tracks.length,
      );
      if (!mounted || gen != generation || used != who) return;
      accumulator.add(page);
      first ??= page;
      setState(() {
        tracks = accumulator.tracks;
        more = page.hasMore;
      });
    } catch (e) {
      if (mounted && gen == generation && used == who) {
        setState(() {
          error = e is ApiFailure && e.statusCode == 403
              ? '当前账号无Owner喜欢歌单权限'
              : e is ApiFailure
              ? e.message
              : '队列读取失败';
          if (e is ApiFailure && e.statusCode == 409) {
            first = null;
            tracks = [];
            more = false;
            accumulator = MusicQueueAccumulator();
          }
        });
      }
    } finally {
      if (mounted && gen == generation && used == who) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> select(Map<String, dynamic> track) async {
    try {
      if (first?.source != 'netease_favorite') {
        throw ApiFailure('请从我喜欢的音乐选择；当前队列点播路径尚未验收');
      }
      await widget.session.playFavoriteTrack(track);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('播放队列'),
      actions: [
        IconButton(
          tooltip: '刷新队列',
          onPressed: busy ? null : () => load(reset: true),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        QueueModeCaption(session: widget.session),
        Text(
          first?.source == 'netease_intelligence'
              ? '网易云心动'
              : first?.source == 'single_track'
              ? '临时单曲'
              : '我喜欢的音乐',
        ),
        if (first != null)
          Text(
            '已读取 ${tracks.length} / ${first!.total} 首 · ${accumulator.complete ? '元数据完整' : '尚未读完'}，读取不代表车机已应用',
          ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
        if (error != null)
          TextButton(
            onPressed: busy ? null : () => load(reset: true),
            child: const Text('重新读取队列'),
          ),
        if (busy) const Center(child: CircularProgressIndicator()),
        for (final track in tracks)
          ListTile(
            title: Text('${track['title'] ?? '曲名暂不可用'}'),
            subtitle: Text('${track['artist'] ?? ''}'),
            onTap:
                busy ||
                    widget.session.commandPending ||
                    widget.session.awaitingExecution
                ? null
                : () => select(track),
          ),
        if (more && error == null)
          TextButton(
            onPressed: busy ? null : () => load(),
            child: const Text('加载更多'),
          ),
        if (!busy && error == null && tracks.isEmpty) const Text('暂无队列曲目'),
      ],
    ),
  );
}
