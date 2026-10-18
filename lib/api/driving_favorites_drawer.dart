import 'package:flutter/material.dart';
import '../apple_map.dart';
import 'backend.dart';
import 'favorites.dart';
import 'favorites_page.dart';
import 'favorite_library.dart';
import 'folder_row.dart';
import 'folder_editor.dart';

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
  late final library = FavoriteLibrary(widget.session);
  late String identity;
  @override
  void initState() {
    super.initState();
    identity = library.currentIdentity;
    library.addListener(changed);
    widget.controller.addListener(scrolled);
    library.refresh();
  }

  void changed() {
    if (!mounted) return;
    if (identity != library.currentIdentity) {
      identity = library.currentIdentity;
      search.clear();
    }
    setState(() {});
  }

  void scrolled() {
    if (widget.controller.hasClients &&
        widget.controller.position.extentAfter < 160 &&
        library.error == null) {
      library.more();
    }
  }

  @override
  void didUpdateWidget(covariant DrivingFavoritesDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(scrolled);
      widget.controller.addListener(scrolled);
    }
  }

  Future<void> edit([Favorite? item]) async {
    final who = identity;
    final service = FavoritesApi(widget.session.api);
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SessionBoundFavoriteDialog(
        session: widget.session,
        service: service,
        child: FavoriteEditor(
          service: service,
          onReconcile: library.refresh,
          item: item,
          initialSelection: widget.selection,
          initialFolderId: library.folderId == 'uncategorized'
              ? null
              : library.folderId,
        ),
      ),
    );
    if (mounted && who == library.currentIdentity) await library.refresh();
  }

  Future<void> editFolder([FavoriteFolder? folder]) async {
    final who = identity;
    final service = FavoritesApi(widget.session.api);
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SessionBoundFavoriteDialog(
        session: widget.session,
        service: service,
        child: FolderEditor(
          service: service,
          folder: folder,
          onReconcile: library.refresh,
        ),
      ),
    );
    if (mounted && who == library.currentIdentity) await library.refresh();
  }

  Future<bool> confirm(String title, String message) async {
    final service = FavoritesApi(widget.session.api);
    return await showDialog<bool>(
          context: context,
          builder: (context) => SessionBoundFavoriteDialog(
            session: widget.session,
            service: service,
            child: AlertDialog(
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
          ),
        ) ??
        false;
  }

  Future<void> removeFolder(FavoriteFolder folder) async {
    final who = identity;
    if (!await confirm('删除分类', '删除“${folder.name}”？所有地址都会保留并移回未分类，不会触发导航。') ||
        !mounted ||
        who != library.currentIdentity) {
      return;
    }
    await library.removeFolder(folder);
  }

  Future<void> remove(Favorite item) async {
    final who = identity;
    if (!await confirm('删除收藏', '删除“${item.displayName}”？不会触发导航。') ||
        !mounted ||
        who != library.currentIdentity) {
      return;
    }
    await library.remove(item);
  }

  Future<void> move(Favorite item) async {
    final who = identity;
    try {
      final service = FavoritesApi(widget.session.api);
      final folders = await service.allFolders();
      if (!mounted || who != library.currentIdentity) return;
      final target = await showDialog<String>(
        context: context,
        builder: (context) => SessionBoundFavoriteDialog(
          session: widget.session,
          service: service,
          child: SimpleDialog(
            title: const Text('移动收藏'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, ''),
                child: const Text('未分类'),
              ),
              for (final folder in folders)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, folder.id),
                  child: Text(folder.name),
                ),
            ],
          ),
        ),
      );
      if (target != null && mounted && who == library.currentIdentity) {
        await library.move(item, target.isEmpty ? null : target);
      }
    } catch (e) {
      if (mounted && who == library.currentIdentity) {
        setState(() => library.error = favoriteError(e));
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(scrolled);
    library.removeListener(changed);
    library.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = library.busy || library.mutating;
    final selected = library.folderId;
    final title = selected == null
        ? '全部收藏'
        : selected == 'uncategorized'
        ? '未分类'
        : library.folders.where((f) => f.id == selected).firstOrNull?.name ??
              '分类地址';
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
                  textInputAction: TextInputAction.search,
                  onSubmitted: library.query,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: '搜索收藏',
                      onPressed: () => library.query(search.text),
                      icon: const Icon(Icons.arrow_forward),
                    ),
                    hintText: selected == null ? '搜索收藏地址 / 分类' : '搜索此分类地址',
                    isDense: true,
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('driving-add'),
                tooltip: '新增地址或分类',
                enabled: !locked,
                icon: const Icon(Icons.add_circle_outline, size: 30),
                onSelected: (value) =>
                    value == 'address' ? edit() : editFolder(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'address', child: Text('新增收藏地址')),
                  PopupMenuItem(value: 'folder', child: Text('新增分类文件夹')),
                ],
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
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
                onPressed: locked ? null : library.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('favorites-all'),
                label: const Text('全部'),
                selected: selected == null,
                onSelected: locked ? null : (_) => library.filter(null),
              ),
              ChoiceChip(
                key: const ValueKey('favorites-uncategorized'),
                label: Text('未分类（${library.uncategorizedCount}）'),
                selected: selected == 'uncategorized',
                onSelected: locked
                    ? null
                    : (_) => library.filter('uncategorized'),
              ),
            ],
          ),
          widget.destinationPanel,
          if (locked) const LinearProgressIndicator(),
          if (library.error != null) ...[
            Text(
              library.error!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
            TextButton(
              onPressed: locked ? null : library.refresh,
              child: const Text('刷新核对收藏'),
            ),
          ],
          if (selected == null) ...[
            for (final folder in library.folders)
              FolderRow(
                key: ValueKey('folder-row-${folder.id}'),
                folder: folder,
                enabled: !locked,
                open: () => library.filter(folder.id),
                rename: () => editFolder(folder),
                remove: () => removeFolder(folder),
              ),
            if (library.foldersHaveMore)
              TextButton(
                onPressed: library.folderMoreBusy || locked
                    ? null
                    : () => library.more(groups: true),
                child: Text(library.folderMoreBusy ? '加载中…' : '更多分类'),
              ),
          ],
          if (!library.busy && library.error == null && library.items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(library.search.isEmpty ? '暂无收藏，点击＋添加地址' : '没有匹配的收藏'),
            ),
          for (final item in library.items)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(item.displayName),
              subtitle: Text(
                '${item.folderName == null ? '' : '${item.folderName} · '}${item.address}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: !locked && item.coordSystem == 'wgs84'
                  ? () => widget.onSelected(item)
                  : null,
              trailing: PopupMenuButton<String>(
                key: ValueKey('favorite-menu-${item.id}'),
                tooltip: '管理收藏地址',
                enabled: !locked,
                onSelected: (value) {
                  if (value == 'edit') edit(item);
                  if (value == 'move') move(item);
                  if (value == 'delete') remove(item);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'move', child: Text('移动到分类 / 未分类')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          if (library.hasMore)
            TextButton(
              key: const ValueKey('favorites-more'),
              onPressed: locked || library.moreBusy
                  ? null
                  : () => library.more(),
              child: Text(
                library.moreBusy
                    ? '加载中…'
                    : '加载更多地址（已加载${library.items.length} / ${library.total}）',
              ),
            ),
        ],
      ),
    );
  }
}
