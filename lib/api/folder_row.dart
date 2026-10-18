import 'package:flutter/material.dart';
import 'favorites.dart';

/// Right swipe reveals management actions without dismissing or deleting a row.
class FolderRow extends StatefulWidget {
  const FolderRow({
    super.key,
    required this.folder,
    required this.open,
    required this.rename,
    required this.remove,
    this.enabled = true,
  });
  final FavoriteFolder folder;
  final VoidCallback open, rename, remove;
  final bool enabled;
  @override
  State<FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<FolderRow> {
  double offset = 0;
  @override
  Widget build(BuildContext context) => ClipRect(
    child: SizedBox(
      height: 72,
      child: Stack(
        children: [
          Positioned.fill(
            child: Row(
              children: [
                SizedBox(
                  width: 66,
                  child: IconButton(
                    tooltip: '重命名分类',
                    onPressed: widget.enabled ? widget.rename : null,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
                SizedBox(
                  width: 66,
                  child: IconButton(
                    tooltip: '删除分类，保留地址',
                    onPressed: widget.enabled ? widget.remove : null,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onHorizontalDragUpdate: widget.enabled
                ? (details) => setState(
                    () => offset = (offset + details.delta.dx).clamp(0, 132),
                  )
                : null,
            onHorizontalDragEnd: (_) =>
                setState(() => offset = offset > 44 ? 132 : 0),
            onHorizontalDragCancel: () => setState(() => offset = 0),
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              transform: Matrix4.translationValues(offset, 0, 0),
              child: Material(
                color: const Color(0xFF141B26),
                child: ListTile(
                  key: ValueKey('folder-${widget.folder.id}'),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(widget.folder.name),
                  subtitle: Text('${widget.folder.count} 个地址 · 右滑管理'),
                  onTap: widget.enabled ? widget.open : null,
                  trailing: PopupMenuButton<String>(
                    tooltip: '管理分类',
                    enabled: widget.enabled,
                    onSelected: (value) =>
                        value == 'rename' ? widget.rename() : widget.remove(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名分类')),
                      PopupMenuItem(value: 'delete', child: Text('删除分类')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
