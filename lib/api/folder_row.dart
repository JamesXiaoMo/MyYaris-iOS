import '../yaris_theme.dart';
import 'package:flutter/material.dart';
import 'favorites.dart';

/// Harmonious Apple Maps-friendly palette for saved-place folders.
const List<Color> kFolderPalette = [
  Color(0xFFD6323F), // Crimson
  Color(0xFF2F6BFF), // Sapphire
  Color(0xFF16A34A), // Emerald
  Color(0xFFEA8C00), // Amber
  Color(0xFF8B5CF6), // Violet
  Color(0xFF0891B2), // Teal
  Color(0xFFE11D74), // Rose
  Color(0xFF4F46E5), // Indigo
];

const Color kUncategorizedFolderColor = Color(0xFF64748B);

/// Returns a deterministic, visually distinct color for any folder ID.
Color folderColorFor(String? folderId) {
  if (folderId == null || folderId.isEmpty || folderId == 'uncategorized') {
    return kUncategorizedFolderColor;
  }
  var hash = 0;
  for (final code in folderId.codeUnits) {
    hash = (hash * 31 + code) & 0x7FFFFFFF;
  }
  return kFolderPalette[hash % kFolderPalette.length];
}

/// Returns `#RRGGBB` hex string for native iOS MapKit marker tinting.
String folderColorHexFor(String? folderId) {
  final c = folderColorFor(folderId);
  final r = (c.r * 255).round().toRadixString(16).padLeft(2, '0');
  final g = (c.g * 255).round().toRadixString(16).padLeft(2, '0');
  final b = (c.b * 255).round().toRadixString(16).padLeft(2, '0');
  return '#$r$g$b'.toUpperCase();
}

/// Left swipe reveals management actions without dismissing or deleting a row.
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
              mainAxisAlignment: MainAxisAlignment.end,
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
                    () => offset = (offset + details.delta.dx).clamp(-132, 0),
                  )
                : null,
            onHorizontalDragEnd: (_) =>
                setState(() => offset = offset < -44 ? -132 : 0),
            onHorizontalDragCancel: () => setState(() => offset = 0),
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              transform: Matrix4.translationValues(offset, 0, 0),
              child: Material(
                color: YarisTheme.paper,
                child: ListTile(
                  key: ValueKey('folder-${widget.folder.id}'),
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: folderColorFor(widget.folder.id)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.folder_rounded,
                      color: folderColorFor(widget.folder.id),
                      size: 20,
                    ),
                  ),
                  title: Text(widget.folder.name),
                  subtitle: Text('${widget.folder.count} 个地址'),
                  onTap: widget.enabled ? widget.open : null,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
