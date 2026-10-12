import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../api/backend.dart';
import '../api/favorites.dart';
import '../api/favorites_page.dart';

final evidenceBoundary = GlobalKey();
Future<void> saveEvidence(String name, Uint8List bytes) => KeychainStore.channel
    .invokeMethod<void>('saveEvidence', {'name': name, 'bytes': bytes});
Future<void> captureEvidence(String name) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  await WidgetsBinding.instance.endOfFrame;
  final boundary =
      evidenceBoundary.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
  if (boundary == null) throw StateError('No screenshot boundary');
  final image = await boundary.toImage(pixelRatio: 3);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Screenshot unavailable');
    await saveEvidence(name, data.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

/// Explicit compile-time acceptance mode only; never navigates or plays media.
Future<void> verifyFavoritesOnDevice(
  BackendApi api,
  BuildContext context,
  VoidCallback showDriving,
) async {
  final proof = <String, dynamic>{
    'configured': api.configured,
    'created': false,
    'fresh_read': false,
    'edited': false,
    'reopened_list': false,
    'deleted': false,
    'cleanup': false,
    'navigation_sent': false,
  };
  String? id;
  try {
    showDriving();
    await captureEvidence('driving-device.png');
    if (!api.configured) throw ApiFailure('MISSING_CONFIGURATION');
    final service = FavoritesApi(api);
    await service.list();
    final label = 'iOS接口验收测试-${DateTime.now().microsecondsSinceEpoch}';
    final created = await service.save(
      Favorite.validate(label, '接口验收测试地址（请勿导航）', '34.4', '132.4'),
    );
    id = created.id;
    proof['created'] = true;
    proof['test_id'] = id;
    final freshApi = BackendApi()
      ..baseUrl = api.baseUrl
      ..token = api.token
      ..deviceId = api.deviceId;
    try {
      final fresh = FavoritesApi(freshApi);
      final read = await fresh.get(id);
      proof['fresh_read'] =
          read.name == label &&
          read.address == created.address &&
          read.latitude == 34.4 &&
          read.longitude == 132.4;
      await service.save(
        Favorite.validate('$label（修改）', '接口验收修改地址（请勿导航）', '34.41', '132.41'),
        id: id,
      );
      final reread = await fresh.get(id);
      proof['edited'] =
          reread.latitude == 34.41 && reread.address == '接口验收修改地址（请勿导航）';
      proof['reopened_list'] = (await FavoritesApi(
        freshApi,
      ).list()).any((item) => item.id == id && item.latitude == 34.41);
      if (!context.mounted) return;
      final route = MaterialPageRoute<Favorite>(
        builder: (_) => FavoritesPage(api: api),
      );
      final completion = Navigator.of(context).push(route);
      await captureEvidence('favorites-device.png');
      if (context.mounted && route.isCurrent) Navigator.of(context).pop();
      await completion;
    } finally {
      freshApi.client.close();
    }
    await service.delete(id);
    proof['deleted'] = !(await FavoritesApi(
      api,
    ).list()).any((item) => item.id == id);
    proof['cleanup'] = proof['deleted'];
    id = null;
  } catch (e) {
    proof['error'] = e is ApiFailure ? e.message : '本机验收步骤失败';
  } finally {
    if (id != null) {
      try {
        await FavoritesApi(api).delete(id);
        proof['cleanup'] = true;
      } catch (_) {
        proof['cleanup'] = false;
      }
    }
    await saveEvidence(
      'favorites-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
