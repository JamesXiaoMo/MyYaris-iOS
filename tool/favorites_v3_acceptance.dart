// Explicit production acceptance: creates/deletes only a unique temporary favorite.
// Does not dispatch navigation, play music or alter existing user records.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/favorites.dart';
import 'package:myyaris_ios/api/favorites_page.dart';
import 'package:myyaris_ios/api/driving_favorites_drawer.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/verification/favorites_evidence.dart'
    show saveEvidence;

List<Element> tree() {
  final list = <Element>[];
  void visit(Element e) {
    list.add(e);
    e.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return list;
}

Future<void> waitFor(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('acceptance timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

T keyed<T extends Widget>(String key) =>
    tree().firstWhere((e) => e.widget.key == ValueKey(key)).widget as T;
Future<void> main() async {
  app.main();
  final label = 'iOS-PlusCode-临时验收-${DateTime.now().microsecondsSinceEpoch}';
  final proof = <String, dynamic>{
    'version': '0.5.4+22',
    'navigation_sent': false,
    'music_sent': false,
    'completed': false,
    'cleaned': false,
  };
  FavoritesApi? service;
  String? createdId, folderId;
  final ownedIds = <String>{};
  try {
    proof['phase'] = 'startup';
    await Future<void>.delayed(const Duration(seconds: 8));
    GlassTabBar bar() =>
        tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar;
    final previous = bar().index;
    bar().onChanged(1);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final nav =
        tree().firstWhere((e) => e.widget is NavigationPage).widget
            as NavigationPage;
    final s = nav.session;
    if (!s.userSignedIn) throw StateError('user login required');
    proof['phase'] = 'health_schema';
    final health = await s.api.call('GET', '/health', auth: false);
    if (!{'ok', 'healthy'}.contains(health['status'])) {
      throw StateError('backend not healthy');
    }
    final spec = await s.api.call('GET', '/openapi.json', auth: false);
    final schema =
        (spec['components'] as Map?)?['schemas']?['FavoriteCreateRequest']
            as Map?;
    proof['backend_address_optional'] =
        schema != null &&
        !((schema['required'] as List?) ?? []).contains('address');
    if (proof['backend_address_optional'] != true) {
      throw StateError('deployed optional address schema not ready');
    }
    proof['backend_short_reference_supported'] =
        (spec['components']
            as Map?)?['schemas']?['DestinationResolveRequest']?['properties']?['reference_coordinate'] !=
        null;
    if (proof['backend_short_reference_supported'] != true) {
      throw StateError('short reference contract not deployed');
    }
    service = FavoritesApi(s.api);
    final dynamic drawer =
        (tree().firstWhere((e) => e.widget is DrivingFavoritesDrawer)
                as StatefulElement)
            .state;
    await drawer.library.filter(null);
    proof['root_only_uncategorized'] = drawer.library.items.every(
      (Favorite v) => v.folderId == null,
    );
    proof['manual_entry_absent'] = !tree().any(
      (e) => e.widget.key == const ValueKey('destination-input-open'),
    );
    proof['phase'] = 'editor';
    unawaited(drawer.edit() as Future<void>);
    await waitFor(() => tree().any((e) => e.widget is FavoriteEditor));
    keyed<TextField>('favorite-name').controller!.text = label;
    keyed<TextField>('favorite-address').controller!.clear();
    final segment = tree()
        .map((e) => e.widget)
        .whereType<SegmentedButton<bool>>()
        .single;
    segment.onSelectionChanged!({true});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    keyed<TextField>('favorite-plus-code').controller!.text = '849VCWC8+R9';
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'folder-address-device.png',
    );
    keyed<FilledButton>('favorite-save').onPressed!();
    await waitFor(() => !tree().any((e) => e.widget is FavoriteEditor));
    proof['saved_via_ui'] = true;
    proof['phase'] = 'full_reread';
    final rows = (await service.page(
      folderId: 'uncategorized',
      search: label,
    )).items.where((v) => v.name == label).toList();
    if (rows.length != 1) {
      throw StateError('temporary favorite not uniquely found');
    }
    final saved = rows.single;
    createdId = saved.id;
    ownedIds.add(saved.id);
    proof['full_code_favorite_id'] = saved.id;
    proof['blank_address_persisted'] = saved.address.isEmpty;
    final reread = await FavoritesApi(s.api).get(createdId);
    proof['fresh_reread_matches'] =
        reread.address.isEmpty &&
        reread.latitude == saved.latitude &&
        reread.longitude == saved.longitude &&
        reread.name == label;
    proof['decoded_coordinates_valid'] =
        saved.latitude > 37 &&
        saved.latitude < 38 &&
        saved.longitude < -122 &&
        saved.longitude > -123;
    await drawer.library.refresh();
    proof['root_shows_saved_uncategorized'] = drawer.library.items.any(
      (Favorite v) => v.id == createdId,
    );
    proof['phase'] = 'patch_semantics';
    // Test only our own IDs: PATCH omitted fields retain values; explicit null clears.
    final ownPath = '${FavoritesApi.path}/${Uri.encodeComponent(createdId)}';
    await service.call('PATCH', ownPath, body: {'address': '临时验收地址'});
    await service.call('PATCH', ownPath, body: {'name': label});
    proof['patch_omitted_address_retained'] =
        (await service.get(createdId)).address == '临时验收地址';
    await service.call('PATCH', ownPath, body: {'address': null});
    proof['patch_null_address_cleared'] = (await service.get(
      createdId,
    )).address.isEmpty;
    await service.call('PATCH', ownPath, body: {'address': '   '});
    proof['patch_blank_address_cleared'] = (await service.get(
      createdId,
    )).address.isEmpty;
    proof['phase'] = 'short_cancel';
    // A short code only decodes; cancellation must not create any favorite.
    unawaited(drawer.edit() as Future<void>);
    await waitFor(() => tree().any((e) => e.widget is FavoriteEditor));
    keyed<TextField>('favorite-name').controller!.text = label;
    keyed<TextField>('favorite-address').controller!.clear();
    tree()
        .map((e) => e.widget)
        .whereType<SegmentedButton<bool>>()
        .single
        .onSelectionChanged!({true});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final codeField = keyed<TextField>('favorite-plus-code');
    codeField.controller!.text = 'CWC8+R9';
    codeField.onChanged!('CWC8+R9');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    keyed<TextField>('favorite-reference-latitude').controller!.text = '37.42';
    keyed<TextField>('favorite-reference-longitude').controller!.text =
        '-122.08';
    keyed<FilledButton>('favorite-save').onPressed!();
    await waitFor(
      () => tree().any(
        (e) => e.widget.key == const ValueKey('favorite-short-code-confirm'),
      ),
    );
    proof['short_position_confirmation_opened'] = true;
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'map-search-device.png',
    );
    final shortDialog = tree().firstWhere(
      (e) => e.widget.key == const ValueKey('favorite-short-code-confirm'),
    );
    Navigator.of(shortDialog).pop(false);
    final editorElement =
        tree().firstWhere((e) => e.widget is FavoriteEditor) as StatefulElement;
    final dynamic editorState = editorElement.state;
    await waitFor(() => editorState.busy == false);
    proof['short_cancel_no_favorite'] =
        (await service.page(
          folderId: 'uncategorized',
          search: label,
        )).items.where((v) => v.name == label).length ==
        1;
    proof['phase'] = 'short_save';
    // Confirm the same short code explicitly, now saving our second temporary item.
    keyed<TextField>('favorite-name').controller!.text = '$label-short';
    keyed<FilledButton>('favorite-save').onPressed!();
    await waitFor(
      () => tree().any(
        (e) => e.widget.key == const ValueKey('favorite-short-code-confirm'),
      ),
    );
    final confirmedDialog = tree().firstWhere(
      (e) => e.widget.key == const ValueKey('favorite-short-code-confirm'),
    );
    Navigator.of(confirmedDialog).pop(true);
    await waitFor(() => !tree().any((e) => e.widget is FavoriteEditor));
    final shortRows = (await service.page(
      folderId: 'uncategorized',
      search: '$label-short',
    )).items.where((v) => v.name == '$label-short').toList();
    if (shortRows.length != 1) {
      throw StateError('confirmed short favorite not uniquely found');
    }
    ownedIds.add(shortRows.single.id);
    proof['short_code_favorite_id'] = shortRows.single.id;
    proof['short_confirm_saved_and_reread'] = (await service.get(
      shortRows.single.id,
    )).address.isEmpty;
    proof['phase'] = 'pagination';
    // Force actual has_more/offset traversal on exactly our two test items.
    final pagedIds = <String>{};
    var pageOffset = 0;
    var sawMore = false;
    while (true) {
      final page = await service.call(
        'GET',
        FavoritesApi.path,
        query: {
          'limit': '1',
          'offset': '$pageOffset',
          'search': label,
          'folder_id': 'uncategorized',
          'sort_by': 'created_at',
          'order': 'desc',
        },
      );
      final entries = page['items'] as List;
      for (final entry in entries) {
        pagedIds.add(entry['id'] as String);
      }
      if (page['has_more'] != true) break;
      sawMore = true;
      if (entries.isEmpty || pageOffset > 10) {
        throw StateError('pagination invalid');
      }
      pageOffset += entries.length;
    }
    proof['uncategorized_real_pagination'] =
        sawMore && pagedIds.length == 2 && pagedIds.containsAll(ownedIds);
    proof['phase'] = 'folder';
    final folder = await service.saveFolder(label);
    folderId = folder.id;
    proof['temporary_folder_id'] = folder.id;
    await service.move(createdId, folderId);
    await service.call('PATCH', ownPath, body: {'name': label});
    proof['patch_omitted_folder_retained'] =
        (await service.get(createdId)).folderId == folderId;
    await drawer.library.query(label);
    await drawer.library.filter(null);
    proof['root_folder_and_uncategorized'] =
        drawer.library.folders.any((FavoriteFolder f) => f.id == folderId) &&
        drawer.library.items.any((Favorite f) => f.id == shortRows.single.id) &&
        !drawer.library.items.any((Favorite f) => f.id == createdId);
    final folderItems = await service.page(folderId: folderId, search: label);
    proof['folder_member_search'] = folderItems.items.any(
      (v) => v.id == createdId,
    );
    await service.move(createdId, null);
    proof['patch_null_folder_cleared'] =
        (await service.get(createdId)).folderId == null;
    await service.call('PATCH', ownPath, body: {'name': null, 'address': null});
    final empty = await service.get(createdId);
    proof['empty_name_address_coordinate_fallback'] =
        empty.name.isEmpty &&
        empty.address.isEmpty &&
        empty.displayName == empty.coordinates;
    proof['phase'] = 'cleanup';
    for (final id in ownedIds) {
      await service.delete(id);
      try {
        await service.get(id);
        throw StateError('deleted item still exists');
      } on ApiFailure catch (e) {
        if (e.statusCode != 404) rethrow;
      }
    }
    await service.deleteFolder(folderId);
    try {
      await service.getFolder(folderId);
      throw StateError('deleted folder still exists');
    } on ApiFailure catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    proof['deleted_ids_404'] = true;
    folderId = null;
    ownedIds.clear();
    createdId = null;
    proof['cleaned'] = (await service.page(
      search: label,
    )).items.where((v) => v.name == label || v.name == '$label-short').isEmpty;
    await drawer.library.query('');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'map-drawer-device.png',
    );
    bar().onChanged(previous);
    proof['completed'] =
        proof['blank_address_persisted'] == true &&
        proof['fresh_reread_matches'] == true &&
        proof['decoded_coordinates_valid'] == true &&
        proof['root_only_uncategorized'] == true &&
        proof['manual_entry_absent'] == true &&
        proof['short_cancel_no_favorite'] == true &&
        proof['cleaned'] == true &&
        [
          'patch_omitted_address_retained',
          'patch_null_address_cleared',
          'patch_blank_address_cleared',
          'short_confirm_saved_and_reread',
          'uncategorized_real_pagination',
          'patch_omitted_folder_retained',
          'root_folder_and_uncategorized',
          'folder_member_search',
          'patch_null_folder_cleared',
          'empty_name_address_coordinate_fallback',
          'deleted_ids_404',
        ].every((key) => proof[key] == true);
  } catch (_) {
    proof['blocked'] = true;
  } finally {
    // A timed-out create is never retried. Reconcile only the exact unique test label.
    if (service != null && proof['cleaned'] != true) {
      try {
        for (final id in ownedIds) {
          await service.delete(id);
        }
        if (folderId != null) await service.deleteFolder(folderId);
        final own =
            (await service.page(folderId: 'uncategorized', search: label)).items
                .where((v) => v.name == label || v.name == '$label-short')
                .toList();
        for (final item in own) {
          await service.delete(item.id);
        }
        final ownFolders = (await service.folders(
          search: label,
        )).items.where((f) => f.name == label);
        for (final folder in ownFolders) {
          await service.deleteFolder(folder.id);
        }
        proof['cleaned'] = (await service.page(
          folderId: 'uncategorized',
          search: label,
        )).items.where((v) => v.name == label).isEmpty;
      } catch (_) {
        proof['cleanup_unconfirmed'] = true;
      }
    }
    await saveEvidence(
      'favorites-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
