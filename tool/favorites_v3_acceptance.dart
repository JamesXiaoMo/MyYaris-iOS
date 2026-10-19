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
  String? createdId;
  try {
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
    final rows = (await service.page(
      folderId: 'uncategorized',
      search: label,
    )).items.where((v) => v.name == label).toList();
    if (rows.length != 1) {
      throw StateError('temporary favorite not uniquely found');
    }
    final saved = rows.single;
    createdId = saved.id;
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
    await service.delete(createdId);
    createdId = null;
    proof['cleaned'] = (await service.page(
      folderId: 'uncategorized',
      search: label,
    )).items.where((v) => v.name == label).isEmpty;
    await drawer.library.refresh();
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
    proof['short_cancel_no_favorite'] = (await service.page(
      folderId: 'uncategorized',
      search: label,
    )).items.where((v) => v.name == label).isEmpty;
    Navigator.of(editorElement).pop(false);
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
        proof['cleaned'] == true;
  } catch (_) {
    proof['blocked'] = true;
  } finally {
    // A timed-out create is never retried. Reconcile only the exact unique test label.
    if (service != null && proof['cleaned'] != true) {
      try {
        final own = (await service.page(
          folderId: 'uncategorized',
          search: label,
        )).items.where((v) => v.name == label).toList();
        for (final item in own) {
          await service.delete(item.id);
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
