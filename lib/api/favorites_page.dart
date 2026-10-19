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
    this.initialFolderId,
    this.onReconcile,
  });
  final FavoritesApi service;
  final Favorite? item;
  final MapSelection? initialSelection;
  final String? initialFolderId;
  final Future<void> Function()? onReconcile;
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
  final plusCode = TextEditingController();
  final referenceLatitude = TextEditingController();
  final referenceLongitude = TextEditingController();
  bool get shortCode =>
      plusCode.text.contains('+') && plusCode.text.indexOf('+') < 8;
  bool usePlusCode = false;
  bool busy = false,
      uncertain = false,
      folderChanged = false,
      foldersBusy = true;
  List<FavoriteFolder> folders = [];
  late String? folderId = widget.item?.folderId ?? widget.initialFolderId;
  String? error, folderError;
  @override
  void initState() {
    super.initState();
    loadFolders();
  }

  Future<void> loadFolders() async {
    setState(() {
      foldersBusy = true;
      folderError = null;
    });
    try {
      final value = await widget.service.allFolders();
      if (mounted) setState(() => folders = value);
    } catch (e) {
      if (mounted) setState(() => folderError = favoriteError(e));
    } finally {
      if (mounted) setState(() => foldersBusy = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    address.dispose();
    latitude.dispose();
    longitude.dispose();
    plusCode.dispose();
    referenceLatitude.dispose();
    referenceLongitude.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || uncertain) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (usePlusCode) {
        Map<String, double>? reference;
        if (shortCode) {
          final lat = double.tryParse(referenceLatitude.text.trim()),
              lon = double.tryParse(referenceLongitude.text.trim());
          if (lat == null ||
              lon == null ||
              !lat.isFinite ||
              !lon.isFinite ||
              lat.abs() > 90 ||
              lon.abs() > 180) {
            throw ApiFailure('请填写有效WGS84参考纬度和经度');
          }
          reference = {'latitude': lat, 'longitude': lon};
        }
        final point = await widget.service.resolvePlusCode(
          plusCode.text,
          reference: reference,
        );
        if (!mounted) return;
        if (shortCode) {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              key: const ValueKey('favorite-short-code-confirm'),
              title: const Text('确认短码解析位置'),
              content: Text(
                '参考：${reference!['latitude']}, ${reference['longitude']}\n解析位置：${point['latitude']}, ${point['longitude']}\n是否将此位置保存为收藏？',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('favorite-short-code-save'),
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('确认保存'),
                ),
              ],
            ),
          );
          if (confirmed != true || !mounted) return;
        }
        latitude.text = '${point['latitude']}';
        longitude.text = '${point['longitude']}';
      }
      final body = Favorite.validate(
        name.text,
        address.text,
        latitude.text,
        longitude.text,
      );
      if (folderChanged || widget.item == null) body['folder_id'] = folderId;
      await widget.service.save(body, id: widget.item?.id);
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
              decoration: const InputDecoration(labelText: '显示地址（选填）'),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('经纬度')),
                ButtonSegment(value: true, label: Text('Plus Code')),
              ],
              selected: {usePlusCode},
              onSelectionChanged: busy || uncertain
                  ? null
                  : (values) => setState(() => usePlusCode = values.single),
            ),
            if (usePlusCode) ...[
              TextField(
                key: const ValueKey('favorite-plus-code'),
                controller: plusCode,
                enabled: !busy && !uncertain,
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Plus Code',
                  hintText: '例如 849VCWC8+R9',
                ),
              ),
              if (shortCode) ...[
                const Text('短码参考位置（WGS84）'),
                TextField(
                  key: const ValueKey('favorite-reference-latitude'),
                  controller: referenceLatitude,
                  enabled: !busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(labelText: '参考纬度'),
                ),
                TextField(
                  key: const ValueKey('favorite-reference-longitude'),
                  controller: referenceLongitude,
                  enabled: !busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(labelText: '参考经度'),
                ),
                if (widget.initialSelection != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            referenceLatitude.text =
                                '${widget.initialSelection!.latitude}';
                            referenceLongitude.text =
                                '${widget.initialSelection!.longitude}';
                          }),
                    child: const Text('使用所选地图点作为参考'),
                  ),
              ],
            ] else ...[
              TextField(
                key: const ValueKey('favorite-latitude'),
                controller: latitude,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'WGS84 纬度（-90～90）',
                ),
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
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'favorite-folder-${folderId ?? 'none'}-${folders.length}',
              ),
              initialValue: folderId ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '所属分类'),
              items: [
                const DropdownMenuItem(value: '', child: Text('未分类')),
                if (folderId != null && !folders.any((v) => v.id == folderId))
                  DropdownMenuItem(
                    value: folderId,
                    child: Text(widget.item?.folderName ?? '当前分类'),
                  ),
                for (final folder in folders)
                  DropdownMenuItem(
                    value: folder.id,
                    child: Text(folder.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: busy || uncertain || foldersBusy || folderError != null
                  ? null
                  : (value) => setState(() {
                      folderId = value == '' ? null : value;
                      folderChanged = true;
                    }),
            ),
            if (foldersBusy) const LinearProgressIndicator(),
            if (folderError != null)
              TextButton(
                onPressed: loadFolders,
                child: Text('分类加载失败，点击重试：$folderError'),
              ),
            const Text('仅保存收藏，不发送导航'),
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
          key: const ValueKey('favorite-save'),
          onPressed: busy || uncertain ? null : save,
          child: Text(busy ? '保存中…' : '保存到后端'),
        ),
      ],
    ),
  );
}
