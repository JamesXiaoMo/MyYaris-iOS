import 'package:flutter/material.dart';
import 'backend.dart';
import '../apple_map.dart';
import 'favorites.dart';
import 'pages.dart' show confirmAction;

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key, required this.api});
  final BackendApi api;
  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  late final service = FavoritesApi(widget.api);
  List<Favorite> items = [];
  bool loading = true, mutating = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await service.list();
      if (mounted) setState(() => items = result);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> edit([Favorite? item]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FavoriteEditor(service: service, item: item),
    );
    if (saved == true && mounted) await load();
  }

  Future<void> remove(Favorite item) async {
    if (!await confirmAction(
      context,
      '删除收藏',
      '删除“${item.displayName}”？此操作不会触发导航。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      mutating = true;
      error = null;
    });
    try {
      await service.delete(item.id);
      if (mounted) await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('收藏夹'),
      actions: [
        IconButton(
          tooltip: '刷新收藏夹',
          onPressed: loading || mutating ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('favorite-add'),
              onPressed: loading || mutating ? null : () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('新增收藏'),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '保存到后端 · WGS84 纬度在前、经度在后\n选择收藏只填入目的地，发送仍需确认',
            style: TextStyle(color: Colors.white54),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              error!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!loading && error == null && items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: Text('暂无收藏，点击“新增收藏”添加地址与坐标')),
                  ),
                if (error != null && items.isEmpty)
                  TextButton(
                    onPressed: loading ? null : load,
                    child: const Text('重新加载'),
                  ),
                for (final item in items)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            item.displayName,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(item.address),
                          Text(
                            '${item.coordSystem.toUpperCase()} · 纬度 ${item.latitude}\n经度 ${item.longitude}',
                            style: const TextStyle(color: Colors.white60),
                          ),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed:
                                    loading ||
                                        mutating ||
                                        item.coordSystem != 'wgs84'
                                    ? null
                                    : () => edit(item),
                                child: const Text('编辑'),
                              ),
                              TextButton(
                                onPressed: loading || mutating
                                    ? null
                                    : () => remove(item),
                                child: const Text('删除'),
                              ),
                              FilledButton(
                                onPressed:
                                    loading ||
                                        mutating ||
                                        error != null ||
                                        item.coordSystem != 'wgs84'
                                    ? null
                                    : () => Navigator.pop(context, item),
                                child: const Text('选择目的地'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class FavoriteEditor extends StatefulWidget {
  const FavoriteEditor({
    super.key,
    required this.service,
    this.item,
    this.initialSelection,
  });
  final FavoritesApi service;
  final Favorite? item;
  final MapSelection? initialSelection;
  @override
  State<FavoriteEditor> createState() => _FavoriteEditorState();
}

class _FavoriteEditorState extends State<FavoriteEditor> {
  late final name = TextEditingController(
    text: widget.item?.name ?? widget.initialSelection?.title,
  );
  late final address = TextEditingController(
    text: widget.item?.address ?? widget.initialSelection?.address,
  );
  late final latitude = TextEditingController(
    text:
        widget.item?.latitude.toString() ??
        widget.initialSelection?.latitude.toString(),
  );
  late final longitude = TextEditingController(
    text:
        widget.item?.longitude.toString() ??
        widget.initialSelection?.longitude.toString(),
  );
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    address.dispose();
    latitude.dispose();
    longitude.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    try {
      final body = Favorite.validate(
        name.text,
        address.text,
        latitude.text,
        longitude.text,
      );
      setState(() {
        busy = true;
        error = null;
      });
      await widget.service.save(body, id: widget.item?.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.item == null ? '新增收藏' : '编辑收藏'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('favorite-name'),
              controller: name,
              enabled: !busy,
              decoration: const InputDecoration(labelText: '名称（选填）'),
            ),
            TextField(
              key: const ValueKey('favorite-address'),
              controller: address,
              enabled: !busy,
              decoration: const InputDecoration(labelText: '地址'),
              maxLines: 2,
            ),
            TextField(
              key: const ValueKey('favorite-latitude'),
              controller: latitude,
              enabled: !busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'WGS84 纬度（-90～90）'),
            ),
            TextField(
              key: const ValueKey('favorite-longitude'),
              controller: longitude,
              enabled: !busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: 'WGS84 经度（-180～180）',
              ),
            ),
            const SizedBox(height: 12),
            const Text('仅保存收藏，不解析或发送导航'),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? '保存中…' : '保存到后端'),
        ),
      ],
    ),
  );
}
