// Explicit test-only entry. Exact unique test records; never navigation/music.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/favorites.dart';
import 'package:myyaris_ios/api/driving_favorites_drawer.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/verification/favorites_evidence.dart'
    show saveEvidence;

const label = 'iOS分类验收20261018_2233';
List<Element> tree() {
  final nodes = <Element>[];
  void visit(Element e) {
    nodes.add(e);
    e.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return nodes;
}

T keyed<T extends Widget>(String key) =>
    tree().firstWhere((e) => e.widget.key == ValueKey(key)).widget as T;
Future<void> waitFor(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 35));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw ApiFailure('验收等待超时');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> capture(String name) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await KeychainStore.channel.invokeMethod<void>('captureHome', name);
}

Future<void> fill(String key, String value) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  keyed<TextField>(key).controller!.text = value;
}

Future<void> main() async {
  app.main();
  await Future<void>.delayed(const Duration(seconds: 7));
  final proof = <String, dynamic>{
    'version': '0.4.2+14',
    'backend_source': '20a2dff',
    'navigation_sent': false,
    'music_sent': false,
    'completed': false,
  };
  var evidence = 'folder-sync-proof.json';
  String? folderId, favoriteId;
  FavoritesApi? service;
  var retainForRestart = false;
  try {
    final bars = tree().where((e) => e.widget is GlassTabBar);
    if (bars.isEmpty) throw ApiFailure('需用户手机登录或解锁，未绕过');
    (bars.first.widget as GlassTabBar).onChanged(1);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final navWidget =
        tree().firstWhere((e) => e.widget is NavigationPage).widget
            as NavigationPage;
    final session = navWidget.session;
    // Health and schema must be available over existing strict HTTPS before writes.
    await session.api.call('GET', '/health', auth: false);
    final spec = await session.api.call('GET', '/openapi.json', auth: false);
    if ((spec['paths'] as Map?)?.containsKey(FavoritesApi.foldersPath) != true) {
      throw ApiFailure('生产分类接口尚未就绪');
    }
    proof['health_checked_at_utc'] = DateTime.now().toUtc().toIso8601String();
    service = FavoritesApi(session.api);
    final dynamic drawer =
        (tree().firstWhere((e) => e.widget is DrivingFavoritesDrawer)
                as StatefulElement)
            .state;
    final dynamic nav =
        (tree().firstWhere((e) => e.widget is NavigationPage)
                as StatefulElement)
            .state;
    final controller = nav.drawer as DraggableScrollableController;
    await controller.animateTo(
      .70,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
    );
    await waitFor(() => drawer.library.busy == false);
    final existing = (await service.folders(
      search: label,
    )).items.where((f) => f.name == label).toList();
    final addresses = (await service.page(
      search: label,
    )).items.where((f) => f.name == label).toList();
    if (existing.isEmpty && addresses.isEmpty) {
      evidence = 'folder-sync-created.json';
      unawaited(drawer.editFolder() as Future<void>);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await fill('folder-name-input', label);
      keyed<FilledButton>('folder-save').onPressed!.call();
      await waitFor(
        () => !tree().any(
          (e) => e.widget.key == const ValueKey('folder-name-input'),
        ),
      );
      await waitFor(() => drawer.library.busy == false);
      final created = (await service.folders(
        search: label,
      )).items.singleWhere((f) => f.name == label);
      folderId = created.id;
      proof['folder_id'] = folderId;
      proof['folder_created_via_ui'] = true;
      await capture('folder-overview-device.png');
      await drawer.library.filter(folderId);
      unawaited(drawer.edit() as Future<void>);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await fill('favorite-name', label);
      await fill('favorite-address', 'iOS同步验证临时地址（勿导航）');
      await fill('favorite-latitude', '34.4');
      await fill('favorite-longitude', '132.4');
      keyed<FilledButton>('favorite-save').onPressed!.call();
      await waitFor(
        () =>
            !tree().any((e) => e.widget.key == const ValueKey('favorite-save')),
      );
      await waitFor(() => drawer.library.busy == false);
      final saved = (await service.page(
        folderId: folderId,
        search: label,
      )).items.singleWhere((f) => f.name == label);
      favoriteId = saved.id;
      proof['favorite_id'] = favoriteId;
      proof['assigned_via_ui'] = saved.folderId == folderId;
      proof['fresh_read'] =
          (await service.get(favoriteId)).folderId == folderId;
      proof['folder_count'] = (await service.getFolder(folderId)).count;
      await capture('folder-address-device.png');
      proof['awaiting_process_restart'] = true;
      retainForRestart = true;
    } else {
      if (existing.length != 1 || addresses.length != 1) {
        throw ApiFailure('临时记录不完整；未创建重复项，请核对清理');
      }
      folderId = existing.single.id;
      favoriteId = addresses.single.id;
      proof['folder_id'] = folderId;
      proof['favorite_id'] = favoriteId;
      final persisted = await service.get(favoriteId);
      if (persisted.name != label || persisted.folderId != folderId) {
        throw ApiFailure('重启后归类不一致');
      }
      proof['persisted_across_process_restart'] = true;
      unawaited(drawer.editFolder(existing.single) as Future<void>);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await fill('folder-name-input', '${label}_已改名');
      keyed<FilledButton>('folder-save').onPressed!.call();
      await waitFor(
        () => !tree().any(
          (e) => e.widget.key == const ValueKey('folder-name-input'),
        ),
      );
      await waitFor(() => drawer.library.busy == false);
      final renamed = await service.getFolder(folderId);
      proof['renamed_via_ui'] = renamed.name == '${label}_已改名';
      await drawer.library.filter(folderId);
      unawaited(drawer.removeFolder(renamed) as Future<void>);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await capture('folder-delete-device.png');
      final confirm =
          tree()
                  .where(
                    (e) =>
                        e.widget is FilledButton &&
                        (e.widget as FilledButton).child is Text &&
                        ((e.widget as FilledButton).child as Text).data == '确认',
                  )
                  .single
                  .widget
              as FilledButton;
      confirm.onPressed!.call();
      await waitFor(
        () =>
            drawer.library.mutating == false &&
            drawer.library.folderId == 'uncategorized',
      );
      final retained = await service.get(favoriteId);
      proof['folder_deleted_address_preserved'] =
          retained.folderId == null && retained.name == label;
      proof['selected_uncategorized'] =
          drawer.library.folderId == 'uncategorized';
      proof['uncategorized_visible'] = (await service.page(
        folderId: 'uncategorized',
        search: label,
      )).items.any((f) => f.id == favoriteId);
      await capture('folder-uncategorized-device.png');
      proof['completed'] =
          proof['folder_deleted_address_preserved'] == true &&
          proof['renamed_via_ui'] == true;
    }
  } catch (e) {
    proof['error'] = e is ApiFailure ? favoriteError(e) : '真机分类验收未完成';
  } finally {
    if (!retainForRestart && service != null) {
      try {
        final ownFavorites = (await service.page(search: label)).items.where((item) => item.name == label);
        for (final item in ownFavorites) { await service.delete(item.id); }
        if (favoriteId != null) await service.delete(favoriteId);
        if (folderId != null) await service.deleteFolder(folderId);
        proof['temporary_records_cleaned'] = !(await service.page(search: label)).items.any((item) => item.name == label) && !(await service.folders(search: label)).items.any((item) => item.name == label || item.name == '${label}_已改名');
        final element = tree()
            .where((e) => e.widget is DrivingFavoritesDrawer)
            .firstOrNull;
        if (element is StatefulElement) {
          final dynamic state = element.state;
          await state.library.refresh();
        }
      } catch (_) {
        proof['temporary_records_cleaned'] = false;
      }
    }
    await saveEvidence(
      evidence,
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
