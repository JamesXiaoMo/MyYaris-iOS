import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'backend.dart';

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
      const SizedBox(height: 8),
      Text(subtitle, style: const TextStyle(color: _muted)),
    ],
  ),
);

class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key, required this.session});
  final BackendSession session;
  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  final input = TextEditingController();
  Map<String, dynamic>? resolved, query;
  String? error;
  bool busy = false;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> resolve() async {
    if (input.text.trim().isEmpty) {
      setState(() => error = '请输入目的地');
      return;
    }
    if (!widget.session.api.configured) {
      setState(() => error = '请先在设置中配置手机 Token');
      return;
    }
    if (!await confirmAction(
      context,
      '提交目的地',
      '后端对明确坐标或链接可能直接生成导航任务。确认将以下输入提交给车机？\n${input.text.trim()}',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
      resolved = null;
      query = null;
    });
    try {
      Map<String, dynamic> r;
      if (widget.session.api.deviceId == 'car_p3pro') {
        r = await widget.session.api.call(
          'POST',
          '/api/v1/destinations/resolve',
          body: {'raw_input': input.text.trim(), 'source': 'ios_share'},
        );
      } else {
        // V1 resolve has no target-device field and may auto-dispatch to the default car.
        final q = await widget.session.api.call(
          'POST',
          '/destinations',
          body: {
            'input_type': 'auto',
            'text': input.text.trim(),
            'target_device_id': widget.session.api.deviceId,
            'idempotency_key': requestId(),
          },
        );
        r = {
          'destination_id': q['request_id'],
          'name': input.text.trim(),
          'confidence': 0.5,
        };
      }
      if (!mounted) return;
      setState(() => resolved = r);
      await loadResolved();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> uploadVoice() async {
    if (busy) return;
    if (!widget.session.api.configured) {
      setState(() => error = '请先配置手机 Token');
      return;
    }
    try {
      final selected = await KeychainStore.channel
          .invokeMapMethod<String, dynamic>('pickAudio');
      if (selected == null || !mounted) return;
      final bytes = selected['bytes'] as Uint8List;
      if (!await confirmAction(
        context,
        '上传音频',
        '将 ${selected['name']} 发往你的私网后端转写和解析目的地，可能生成导航任务。是否继续？',
      )) {
        return;
      }
      if (!mounted) return;
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
    final q = await widget.session.api.call(
      'GET',
      '/destinations/${Uri.encodeComponent('${resolved!['destination_id']}')}',
    );
    if (mounted) setState(() => query = q);
    if (q['task_id'] != null) {
      final task = await widget.session.api.call(
        'GET',
        '/tasks/${Uri.encodeComponent('${q['task_id']}')}',
      );
      widget.session.lastTask = task;
      widget.session.publish();
    }
  }

  Future<void> send([String? candidate]) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final id = resolved!['destination_id'];
      final result = candidate == null
          ? await widget.session.api.call(
              'POST',
              '/api/v1/tasks/destination',
              body: {
                'destination_id': id,
                'expires_in_seconds': 3600,
                'target_device_id': widget.session.api.deviceId,
              },
            )
          : await widget.session.api.call(
              'POST',
              '/destinations/${Uri.encodeComponent('$id')}/confirm',
              body: {
                'candidate_id': candidate,
                'target_device_id': widget.session.api.deviceId,
              },
            );
      widget.session.lastTask = result;
      widget.session.publish();
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
    final candidates = (query?['candidates'] as List?) ?? [];
    final confidence = (resolved?['confidence'] as num?)?.toDouble() ?? 0;
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        heading('导航', '提交前确认输入，歧义地点再选择候选。'),
        card([
          TextField(
            key: const ValueKey('destination-input'),
            controller: input,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '坐标 / Plus Code / 地图链接 / 地址',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('destination-preview'),
            onPressed: busy || resolved != null ? null : resolve,
            icon: const Icon(Icons.place_outlined),
            label: Text(busy ? '处理中…' : '提交目的地'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
        ]),
        TextButton.icon(
          onPressed: busy || resolved != null ? null : uploadVoice,
          icon: const Icon(Icons.audio_file_outlined),
          label: const Text('选择短音频并上传解析'),
        ),
        const Text(
          '使用已有音频文件，不申请麦克风权限；上传前会确认。',
          style: TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (resolved != null)
          card([
            const Text(
              '解析结果与派发状态',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            if (query?['task_id'] != null)
              const Text('后端已生成任务，不会再次派发。请查看下方回执。')
            else if (query == null)
              const Text('解析请求已提交，但未能查询派发状态。请重新查询，不要重复提交。')
            else if (candidates.isNotEmpty)
              ...candidates.map(
                (c) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${c['title']}'),
                  subtitle: Text(
                    '${c['address'] ?? ''}\n${c['latitude']}, ${c['longitude']}',
                  ),
                  trailing: const Icon(Icons.send),
                  onTap: busy
                      ? null
                      : () => send(
                          candidates.length == 1
                              ? null
                              : '${c['candidate_id']}',
                        ),
                ),
              )
            else ...[
              Text(
                '${resolved!['name']}\n${resolved!['latitude']}, ${resolved!['longitude']}',
              ),
              const SizedBox(height: 12),
              if (confidence >= .7)
                FilledButton(
                  onPressed: busy ? null : () => send(),
                  child: const Text('确认并发送到车机'),
                )
              else
                const Text(
                  '未得到可靠候选，请换用完整坐标或更明确的地址。不会派发占位坐标。',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
            ],
          ]),
        if (resolved != null)
          Wrap(
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await loadResolved();
                        } catch (e) {
                          if (mounted) setState(() => error = e.toString());
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      },
                child: const Text('重新查询解析 / 派发状态'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        resolved = null;
                        query = null;
                        error = null;
                      }),
                child: const Text('准备新的目的地'),
              ),
            ],
          ),
        AnimatedBuilder(
          animation: widget.session,
          builder: (context, _) => card([
            Text(
              '任务：${widget.session.taskLabel}',
              style: const TextStyle(fontSize: 18),
            ),
            if (widget.session.lastTask.isNotEmpty)
              Text(
                '${widget.session.lastTask['title'] ?? ''}\n${widget.session.lastTask['task_id'] ?? ''}',
              ),
            const SizedBox(height: 8),
            const Text(
              '“已请求打开”不代表导航已经开始。路线需在车机端确认。',
              style: TextStyle(color: _muted),
            ),
            TextButton(
              onPressed: () => widget.session.refresh(),
              child: const Text('刷新任务回执'),
            ),
          ]),
        ),
      ],
    );
  }
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key, required this.session});
  final BackendSession session;
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  final keyword = TextEditingController();
  String source = 'netease';
  int page = 1, total = 0;
  bool busy = false;
  String? error;
  List<Map<String, dynamic>> tracks = [];
  @override
  void dispose() {
    keyword.dispose();
    super.dispose();
  }

  Future<void> search({bool next = false}) async {
    setState(() {
      busy = true;
      error = null;
      if (!next) page = 1;
    });
    try {
      final online = source == 'netease';
      if (online && keyword.text.trim().isEmpty) {
        throw ApiFailure('请输入网易云搜索关键词');
      }
      final response = await widget.session.api.call(
        'GET',
        online ? '/api/v1/music/netease/search' : '/api/v1/music/tracks',
        query: {
          if (keyword.text.trim().isNotEmpty) 'keyword': keyword.text.trim(),
          'page': '$page',
          'limit': '20',
          if (!online) 'source': source,
        },
      );
      final items = ((response[online ? 'songs' : 'tracks'] as List?) ?? [])
          .map((x) => Map<String, dynamic>.from(x as Map))
          .toList();
      if (mounted) {
        setState(() {
          tracks = next ? [...tracks, ...items] : items;
          total = (response['total'] as num?)?.toInt() ?? tracks.length;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
      if (next) page--;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> play(Map<String, dynamic> track) async {
    try {
      await widget.session.api.playTrack(track);
      widget.session.rememberTrack(track);
      widget.session.lastMessage = '播放指令已提交，等待车机回报';
      widget.session.publish();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('播放指令已提交，并不代表已经起播')));
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
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      heading('音乐', '搜索曲库，选择歌曲发送到车机播放。'),
      PlaybackPanel(session: widget.session),
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
        Text('共 $total 首', style: const TextStyle(color: _muted)),
      ]),
      ...tracks.map(
        (track) => card([
          Text(
            '${track['title'] ?? track['track_id']}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Text(
            '${track['artist'] ?? ''} · ${track['album'] ?? ''}',
            style: const TextStyle(color: _muted),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => play(track),
                icon: const Icon(Icons.play_arrow),
                label: const Text('车机播放'),
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
  );
}

class PlaybackPanel extends StatelessWidget {
  const PlaybackPanel({super.key, required this.session});
  final BackendSession session;
  void command(
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
      final duration = (p['duration_ms'] as num?)?.toDouble() ?? 0;
      final position = ((p['position_ms'] as num?)?.toDouble() ?? 0)
          .clamp(0, duration > 0 ? duration : 1)
          .toDouble();
      final volume = ((p['software_volume'] as num?)?.toDouble() ?? 1)
          .clamp(0, 1)
          .toDouble();
      final mode = ['all', 'one', 'off'].contains(p['loop_mode'])
          ? '${p['loop_mode']}'
          : 'all';
      return card([
        Text(
          '${session.currentTrack['title'] ?? p['current_track_id'] ?? '暂无播放曲目'}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          '车机回报：${p['playback_state'] ?? '尚未收到'} · ${session.realtime}',
          style: const TextStyle(color: _muted),
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
              onPressed: () => command(context, 'prev'),
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              tooltip: '播放/暂停',
              onPressed: () =>
                  command(context, session.playing ? 'pause' : 'resume'),
              icon: Icon(session.playing ? Icons.pause : Icons.play_arrow),
            ),
            IconButton(
              tooltip: '下一曲',
              onPressed: () => command(context, 'next'),
              icon: const Icon(Icons.skip_next),
            ),
            IconButton(
              tooltip: '刷新播放状态',
              onPressed: () => session.refresh(),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (duration > 0) ...[
          Text('${(position / 1000).floor()} / ${(duration / 1000).floor()} 秒'),
          Slider(
            value: position,
            max: duration,
            onChanged: (_) {},
            onChangeEnd: (v) =>
                command(context, 'seek', {'seek_ms': v.round()}),
          ),
        ],
        const Text('车机软件音量'),
        Slider(
          value: volume,
          onChanged: (_) {},
          onChangeEnd: (v) => command(context, 'set_volume', {'volume': v}),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey(mode),
          initialValue: mode,
          decoration: const InputDecoration(labelText: '循环模式'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('列表循环')),
            DropdownMenuItem(value: 'one', child: Text('单曲循环')),
            DropdownMenuItem(value: 'off', child: Text('不循环')),
          ],
          onChanged: (v) => command(context, 'set_loop', {'loop_mode': v}),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('随机播放'),
          value: p['shuffle_enabled'] == true,
          onChanged: (v) => command(context, 'set_shuffle', {'shuffle': v}),
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
  late final base = TextEditingController(text: widget.session.api.baseUrl),
      device = TextEditingController(text: widget.session.api.deviceId);
  final token = TextEditingController();
  bool busy = false;
  bool editing = false;
  String message = '';
  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
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
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      heading('设置', '连接私网后端，手机 Token 仅保存在本机 Keychain。'),
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
        TextField(
          controller: token,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: widget.session.api.configured
                ? '新手机 Token（留空保持当前）'
                : '手机 Token',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await widget.session.configure(
                      base.text,
                      token.text.trim().isEmpty
                          ? widget.session.api.token
                          : token.text,
                      device.text,
                      tokenProvided: token.text.trim().isNotEmpty,
                    );
                    token.clear();
                    if (mounted) setState(() => message = '配置已保存；正在核对连接');
                  } catch (e) {
                    if (mounted) {
                      setState(
                        () => message = e is ApiFailure
                            ? e.message
                            : 'Keychain 保存失败，请保持设备解锁并重试',
                      );
                    }
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: const Text('保存并连接'),
        ),
        if (message.isNotEmpty) Text(message),
        TextButton(
          onPressed: () async {
            try {
              BackendApi.validateBase(base.text);
              final probe = BackendApi()..baseUrl = base.text;
              try {
                await showApiResult(
                  context,
                  '后端健康',
                  () => probe.call('GET', '/health', auth: false),
                );
              } finally {
                probe.close();
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(e.toString())));
              }
            }
          },
          child: const Text('检查地址健康（不发送 Token）'),
        ),
        TextButton(
          onPressed: () async {
            if (await confirmAction(
              context,
              '清除手机配置',
              '只删除本 App 的连接凭据，不注销网易云。',
            )) {
              try {
                await widget.session.clear();
                token.clear();
                editing = false;
                if (mounted) setState(() => message = '已清除');
              } catch (_) {
                if (mounted) setState(() => message = '清除失败，请重试');
              }
            }
          },
          child: const Text('清除本机连接配置'),
        ),
      ]),
      card([
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
      const SizedBox(height: 20),
      const Text(
        'App 不伪造车机 ACK，不调用车机专用拉取 / 上报接口。进入后台会停止连接，回前台重新同步。',
        style: TextStyle(color: _muted),
      ),
    ],
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
