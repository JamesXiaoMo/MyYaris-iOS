import '../yaris_theme.dart';
import 'package:flutter/material.dart';
import 'favorites.dart';

/// High-contrast 12-color Apple Maps-friendly palette for saved-place folders.
const List<Color> kFolderPalette = [
  Color(0xFFD6323F), // 0: Crimson Red
  Color(0xFF2563EB), // 1: Royal Blue
  Color(0xFF16A34A), // 2: Emerald Green
  Color(0xFFEA8C00), // 3: Vivid Amber
  Color(0xFF9333EA), // 4: Vivid Purple
  Color(0xFF0891B2), // 5: Cyan Teal
  Color(0xFFE11D74), // 6: Hot Rose
  Color(0xFF65A30D), // 7: Lime Olive
  Color(0xFFDC6803), // 8: Burnt Orange
  Color(0xFF4F46E5), // 9: Deep Indigo
  Color(0xFF0D9488), // 10: Seafoam Teal
  Color(0xFFBE123C), // 11: Berry Wine
];

const Color kUncategorizedFolderColor = Color(0xFF64748B);

final Map<String, Color> _assignedFolderColors = <String, Color>{};

/// Assigns guaranteed-distinct colors to every folder ID (collision-free up to 12 folders)
/// in deterministic sorted order so colors remain stable across restarts.
void syncFolderColorPalette(Iterable<String> folderIds) {
  final unique = folderIds
      .where((id) => id.isNotEmpty && id != 'uncategorized')
      .toSet()
      .toList()
    ..sort();
  if (unique.isEmpty) return;
  for (var i = 0; i < unique.length; i++) {
    _assignedFolderColors[unique[i]] =
        kFolderPalette[i % kFolderPalette.length];
  }
}

/// Returns a guaranteed-distinct color for any registered folder ID.
Color folderColorFor(String? folderId) {
  if (folderId == null || folderId.isEmpty || folderId == 'uncategorized') {
    return kUncategorizedFolderColor;
  }
  final assigned = _assignedFolderColors[folderId];
  if (assigned != null) return assigned;
  // Fallback before folder list loads: assign next unused palette color
  final used = _assignedFolderColors.values.toSet();
  for (final candidate in kFolderPalette) {
    if (!used.contains(candidate)) {
      _assignedFolderColors[folderId] = candidate;
      return candidate;
    }
  }
  final idx = _assignedFolderColors.length % kFolderPalette.length;
  final fallback = kFolderPalette[idx];
  _assignedFolderColors[folderId] = fallback;
  return fallback;
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
