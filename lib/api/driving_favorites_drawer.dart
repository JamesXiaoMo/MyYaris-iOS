import 'package:flutter/material.dart';
import '../apple_map.dart';
import 'backend.dart';
import 'favorites.dart';
import 'favorites_page.dart';
import 'pages.dart' show confirmAction;

class DrivingFavoritesDrawer extends StatefulWidget {
  const DrivingFavoritesDrawer({
    super.key,
    required this.session,
    required this.controller,
    required this.onSelected,
    required this.onInput,
    this.selection,
    required this.destinationPanel,
  });
  final BackendSession session;
  final ScrollController controller;
  final ValueChanged<Favorite> onSelected;
  final VoidCallback onInput;
  final MapSelection? selection;
  final Widget destinationPanel;
  @override
  State<DrivingFavoritesDrawer> createState() => _DrivingFavoritesDrawerState();
}

class _DrivingFavoritesDrawerState extends State<DrivingFavoritesDrawer> {
  final search = TextEditingController();
  List<Favorite> items = [];
  bool busy = false;
  String? error;
  int epoch = 0;
  late String identity;
  String get currentIdentity =>
      '${widget.session.api.baseUrl}\n${widget.session.api.token}';
  @override
  void initState() {
    super.initState();
    identity = currentIdentity;
    widget.session.addListener(accountChanged);
    load();
  }

  void accountChanged() {
    if (currentIdentity == identity) return;
    identity = currentIdentity;
    epoch++;
    if (!mounted) return;
    setState(() {
      items = [];
      busy = false;
      error = null;
      search.clear();
    });
    if (widget.session.userSignedIn) load();
  }

  Future<void> load() async {
    if (busy) return;
    final gen = ++epoch, who = identity;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await FavoritesApi(widget.session.api).list();
      if (mounted && gen == epoch && who == currentIdentity) {
        setState(() => items = result);
      }
    } catch (e) {
      if (mounted && gen == epoch && who == currentIdentity) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && gen == epoch && who == currentIdentity) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> edit([Favorite? item]) async {
    final who = identity;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FavoriteEditor(
        service: FavoritesApi(widget.session.api),
        item: item,
        initialSelection: widget.selection,
      ),
    );
    if (saved == true && mounted && who == currentIdentity) await load();
  }

  Future<void> remove(Favorite item) async {
    final who = identity;
    if (!await confirmAction(
          context,
          '删除收藏',
          '删除“${item.displayName}”？不会触发导航。',
        ) ||
        !mounted ||
        who != currentIdentity) {
      return;
    }
    try {
      await FavoritesApi(widget.session.api).delete(item.id);
      if (mounted && who == currentIdentity) await load();
    } catch (e) {
      if (mounted && who == currentIdentity) setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    epoch++;
    widget.session.removeListener(accountChanged);
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyword = search.text.trim().toLowerCase();
    final visible = items
        .where(
          (x) =>
              '${x.displayName} ${x.address}'.toLowerCase().contains(keyword),
        )
        .toList();
    return Material(
      color: const Color(0xFF141B26),
      elevation: 0,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        controller: widget.controller,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Center(
            child: Container(
              key: const ValueKey('favorites-handle'),
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white38,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('favorite-search'),
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索收藏地址 / 分类',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('driving-add'),
                tooltip: '新增地址或分类',
                icon: const Icon(Icons.add_circle_outline, size: 30),
                onSelected: (value) {
                  if (value == 'address') edit();
                  if (value == 'folder') {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('分类须保存后端；正在等待分类接口，不会仅保存在本机'),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'address', child: Text('新增收藏地址')),
                  PopupMenuItem(
                    value: 'folder',
                    child: Text('新增分类文件夹 · 待后端接入'),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '收藏地址',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('destination-input-open'),
                onPressed: widget.onInput,
                icon: const Icon(Icons.edit_location_alt_outlined),
                label: const Text('输入目的地'),
              ),
              IconButton(
                tooltip: '刷新收藏',
                onPressed: busy ? null : load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          widget.destinationPanel,
          if (busy) const LinearProgressIndicator(),
          if (error != null) ...[
            Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
            TextButton(
              onPressed: busy ? null : load,
              child: const Text('重试加载收藏'),
            ),
          ],
          if (!busy && error == null && visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(keyword.isEmpty ? '暂无收藏，点击＋添加地址' : '没有匹配的收藏'),
            ),
          for (final item in visible)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(item.displayName),
              subtitle: Text(
                item.address,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: item.coordSystem == 'wgs84'
                  ? () => widget.onSelected(item)
                  : null,
              trailing: PopupMenuButton<String>(
                key: ValueKey('favorite-menu-${item.id}'),
                tooltip: '管理收藏地址',
                onSelected: (value) =>
                    value == 'edit' ? edit(item) : remove(item),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              '分类文件夹等待后端同步接口；现有地址仍从后端读取和保存。',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
