// Explicit read-only acceptance entry. Uses the actual signed-in app UI/session.
// Never requests passwords/cookies, bypasses login, probes or plays songs.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as production;
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/liked_music.dart';
import 'package:myyaris_ios/api/liked_music_page.dart';
import 'package:myyaris_ios/verification/favorites_evidence.dart'
    show saveEvidence;

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

Future<void> until(bool Function() ready, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) throw StateError('等待页面/接口超时');
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

Future<void> photo(String name) async {
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await KeychainStore.channel.invokeMethod<void>('captureHome', name);
}

Future<void> main() async {
  production.main();
  await Future<void>.delayed(const Duration(seconds: 5));
  final proof = <String, dynamic>{
    'version': '0.3.2+10',
    'started_at_utc': DateTime.now().toUtc().toIso8601String(),
    'input': 'actual app UI callbacks and scroll controller on real iPhone',
    'business_commands_sent': false,
    'audio_probes_sent': false,
    'playlist_details_saved_in_proof': false,
    'completed': false,
  };
  BuildContext? routeContext;
  try {
    final bars = tree().where((e) => e.widget is GlassTabBar);
    if (bars.isEmpty) {
      proof['blocked'] = '需要用户在手机自行登录，未绕过登录';
      await photo('liked-login-device.png');
      return;
    }
    (bars.first.widget as GlassTabBar).onChanged(2);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await photo('liked-music-device.png');
    final button =
        tree()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('liked-music-entry'),
                )
                .widget
            as OutlinedButton;
    button.onPressed!();
    await until(() => tree().any((e) => e.widget is LikedMusicPage));
    final element =
        tree().firstWhere((e) => e.widget is LikedMusicPage) as StatefulElement;
    routeContext = element;
    final dynamic state = element.state;
    final model = state.model as LikedMusicController;
    await until(() => !model.busy);
    proof['administrator_access'] = model.allowed;
    if (!model.allowed || model.error != null) {
      proof['blocked'] = model.error ?? '需要Owner管理员身份';
      await photo('liked-playlist-device.png');
      return;
    }
    final firstIds = model.tracks.map((t) => t['song_id']).toList();
    proof['first_page_count'] = model.tracks.length;
    proof['total'] = model.total;
    proof['first_has_more'] = model.hasMore;
    proof['first_next_offset'] = model.nextOffset;
    proof['schema_validated'] = model.loaded;
    await photo('liked-playlist-device.png');
    if (model.hasMore) {
      final scroll = state.scroll as ScrollController;
      await scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOut,
      );
      await until(
        () => !model.busy && (model.nextOffset > 30 || model.error != null),
      );
      if (model.error != null) throw StateError(model.error!);
      proof['second_page_count'] = model.tracks.length;
      proof['second_next_offset'] = model.nextOffset;
      proof['second_has_more'] = model.hasMore;
      proof['no_duplicate_song_ids'] =
          model.tracks.map((t) => t['song_id']).toSet().length ==
          model.tracks.length;
      await photo('liked-playlist-more-device.png');
    }
    final refresh =
        tree()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('liked-refresh'),
                )
                .widget
            as IconButton;
    refresh.onPressed!();
    await until(() => !model.busy);
    if (model.error != null) throw StateError(model.error!);
    proof['refresh_first_page_count'] = model.tracks.length;
    proof['refresh_order_stable'] =
        jsonEncode(model.tracks.map((t) => t['song_id']).toList()) ==
        jsonEncode(firstIds);
    proof['completed'] = true;
  } catch (e) {
    proof['error'] = e is StateError ? e.message : '真机列表验收未完成';
  } finally {
    if (routeContext != null && routeContext.mounted) {
      Navigator.of(routeContext).pop();
    }
    await saveEvidence(
      'liked-playlist-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
