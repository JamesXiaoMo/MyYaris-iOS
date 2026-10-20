import 'package:flutter/material.dart';
import 'favorites.dart';
import 'backend.dart';

class FolderEditor extends StatefulWidget {
  const FolderEditor({
    super.key,
    required this.service,
    this.folder,
    this.onReconcile,
  });
  final FavoritesApi service;
  final FavoriteFolder? folder;
  final Future<void> Function()? onReconcile;
  @override
  State<FolderEditor> createState() => _FolderEditorState();
}

class _FolderEditorState extends State<FolderEditor> {
  late final name = TextEditingController(text: widget.folder?.name);
  bool busy = false, uncertain = false;
  String? error;
  Future<void> save() async {
    if (busy || uncertain) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.service.saveFolder(name.text, id: widget.folder?.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (e is FavoriteWriteUncertain ||
          e is ApiFailure && {404, 409}.contains(e.statusCode)) {
        await widget.onReconcile?.call();
      }
      if (mounted) {
        setState(() {
          error = favoriteError(e);
          uncertain = e is FavoriteWriteUncertain;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.folder == null ? '新增分类文件夹' : '重命名分类'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('folder-name-input'),
            controller: name,
            enabled: !busy && !uncertain,
            maxLength: 64,
            decoration: const InputDecoration(labelText: '分类名称'),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('folder-save'),
          onPressed: busy || uncertain ? null : save,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

/// Prevent an open editor exposing previous-account data or saving after logout.
class SessionBoundFavoriteDialog extends StatelessWidget {
  const SessionBoundFavoriteDialog({
    super.key,
    required this.session,
    required this.service,
    required this.child,
  });
  final BackendSession session;
  final FavoritesApi service;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) => service.current
        ? child
        : AlertDialog(
            title: const Text('会话已切换'),
            content: const Text('请关闭并在当前账号重新打开收藏'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
  );
}
