import 'package:flutter/material.dart';
import 'backend.dart';
import 'liked_music.dart';
import 'liked_music_store.dart';

class LikedMusicPage extends StatefulWidget {
  const LikedMusicPage({super.key, required this.session, this.store});
  final BackendSession session;
  final LikedMusicStore? store;
  @override
  State<LikedMusicPage> createState() => _LikedMusicPageState();
}

class _LikedMusicPageState extends State<LikedMusicPage> {
  late final model = LikedMusicController(widget.session, store: widget.store);
  final scroll = ScrollController();
  bool selecting = false;
  @override
  void initState() {
    super.initState();
    model.addListener(_refreshUI);
    model.open();
  }

  void _refreshUI() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    scroll.dispose();
    model.dispose();
    super.dispose();
  }

  Future<void> play(Map<String, dynamic> track) async {
    if (selecting || !model.allowed) return;
    final who = model.identity;
    setState(() => selecting = true);
    try {
      await widget.session.hub.playFavorite(track);
      if (mounted && who == model.identity) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.session.hub.phoneTarget
                  ? '本机已准备播放，请到音乐页查看'
                  : '已发送播放请求，请到音乐页确认车机是否开始播放',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted && who == model.identity) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiFailure ? e.message : '选歌失败，未确认播放成功')),
        );
      }
    } finally {
      if (mounted) setState(() => selecting = false);
    }
  }

  Widget cover(Map<String, dynamic> track) {
    var url = Uri.tryParse('${track['cover_url'] ?? ''}');
    // Upstream artwork may use HTTP; only upgrade recognized NetEase artwork
    // hosts, still requiring successful TLS. Other insecure URLs use fallback.
    if (url?.scheme == 'http' &&
        (url!.host == 'music.126.net' || url.host.endsWith('.music.126.net'))) {
      url = url.replace(scheme: 'https');
    }
    const fallback = SizedBox(
      width: 48,
      height: 48,
      child: Icon(Icons.album_outlined),
    );
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      return fallback;
    }
    // Public artwork only: never attach the private backend session to a CDN.
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url.toString(),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        cacheWidth: 144,
        frameBuilder: (_, child, frame, _) => frame == null ? fallback : child,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('我喜欢的音乐'),
      actions: [
        IconButton(
          key: const ValueKey('liked-refresh'),
          tooltip: '刷新歌单',
          onPressed: model.busy ? null : model.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: Listenable.merge([model, widget.session]),
        builder: (context, _) => RefreshIndicator(
          onRefresh: model.refresh,
          child: ListView.builder(
            key: const ValueKey('liked-list'),
            controller: scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: model.tracks.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('这是服务器管理员的网易云喜欢歌单，仅管理员账号可以查看。'),
                      const SizedBox(height: 8),
                      const Text('部分歌曲可能因版权或会员限制只能试听。'),
                      if (model.loaded)
                        Text(
                          model.statusLine,
                          key: const ValueKey('liked-status'),
                        ),
                      if (model.syncError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            model.syncError!,
                            key: const ValueKey('liked-sync-error'),
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                    ],
                  ),
                );
              }
              if (index == model.tracks.length + 1) {
                return Column(
                  children: [
                    if (model.loadingFirst || (model.syncing && model.hasMore))
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(),
                      ),
                    if (model.error != null) ...[
                      Text(
                        model.error!,
                        key: const ValueKey('liked-error'),
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                      if (model.allowed)
                        TextButton(
                          onPressed: model.busy ? null : model.refresh,
                          child: const Text('重试'),
                        ),
                    ] else if (model.syncError != null && !model.busy)
                      TextButton(
                        key: const ValueKey('liked-sync-retry'),
                        onPressed: model.refresh,
                        child: const Text('重新检查更新'),
                      )
                    else if (model.loaded &&
                        model.tracks.isEmpty &&
                        !model.fromCache)
                      const Text('歌单读取成功，暂无喜欢的音乐')
                    else if (model.loaded && !model.busy)
                      const Text('已到歌单末尾'),
                  ],
                );
              }
              final track = model.tracks[index - 1];
              final duration = track['duration_ms'] as int;
              final unavailable = track['playable'] == false;
              final disabled =
                  unavailable ||
                  selecting ||
                  !model.allowed ||
                  !widget.session.hub.controlsReady ||
                  (!widget.session.hub.phoneTarget &&
                      !widget.session.canControlVehicle);
              return Card(
                child: ListTile(
                  leading: cover(track),
                  title: Text(track['title'] as String),
                  subtitle: Text(
                    '${track['artist']} · ${track['album'] ?? ''}\n${duration ~/ 60000}:${((duration ~/ 1000) % 60).toString().padLeft(2, '0')} · ${unavailable
                        ? '暂不可播放（版权或地区限制）'
                        : (track['fee'] as num? ?? 0) > 0
                        ? '可能需要会员，点击后确认'
                        : '点击发送到车机'}',
                  ),
                  isThreeLine: true,
                  trailing: Icon(disabled ? Icons.block : Icons.play_arrow),
                  onTap: disabled ? null : () => play(track),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}
