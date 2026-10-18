// Read-only real UI verification: no audio probe, login, playback or navigation.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/music_home.dart' show VinylRecord;
import 'package:myyaris_ios/api/backend.dart';
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

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 25));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('timeout');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> photo(String name) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await Future<void>.delayed(const Duration(seconds: 1));
  await KeychainStore.channel.invokeMethod<void>('captureHome', name);
}

Future<void> main() async {
  app.main();
  await Future<void>.delayed(const Duration(seconds: 6));
  final proof = <String, dynamic>{
    'version': '0.5.0+17',
    'business_writes_sent': false,
    'audio_probe_sent': false,
    'completed': false,
  };
  try {
    final bars = tree().where((e) => e.widget is GlassTabBar);
    if (bars.isEmpty) throw StateError('login required');
    final previous = (bars.first.widget as GlassTabBar).index;
    (bars.first.widget as GlassTabBar).onChanged(2);
    await Future<void>.delayed(const Duration(seconds: 1));
    final dynamic home =
        (tree().firstWhere((e) => e.widget is MusicPage) as StatefulElement)
            .state;
    await until(() => home.account.busy == false);
    proof['account_status_loaded'] = home.account.loaded;
    proof['account_manager'] = home.account.manager;
    proof['account_error_present'] = home.account.error != null;
    proof['remaining_days_available'] = false;
    proof['homepage_has_playback_panel'] = tree().any(
      (e) => e.widget is PlaybackPanel,
    );
    await photo('music-home-v2-device.png');
    final search =
        tree()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-search-open'),
                )
                .widget
            as IconButton;
    search.onPressed!();
    await until(() => tree().any((e) => e.widget is MusicSearchPage));
    final searchElement =
        tree().firstWhere((e) => e.widget is MusicSearchPage)
            as StatefulElement;
    final dynamic state = searchElement.state;
    final field =
        tree()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-input'),
                )
                .widget
            as TextField;
    field.controller!.text = '海阔天空';
    final submit =
        tree()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-preview'),
                )
                .widget
            as FilledButton;
    submit.onPressed!();
    await until(() => state.busy == false);
    proof['real_search_count'] = state.tracks.length;
    proof['search_error_present'] = state.error != null;
    await photo('music-search-v2-device.png');
    Navigator.of(searchElement).pop();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final record =
        tree()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-record-open'),
                )
                .widget
            as VinylRecord;
    record.onTap!();
    await until(() => tree().any((e) => e.widget is MusicPlayerPage));
    proof['player_panel_opened'] = tree().any((e) => e.widget is PlaybackPanel);
    await photo('music-player-v2-device.png');
    final player = tree().firstWhere((e) => e.widget is MusicPlayerPage);
    Navigator.of(player).pop();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    (tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar)
        .onChanged(previous);
    proof['completed'] = true;
  } catch (_) {
    proof['blocked'] = '音乐页面只读真机验收未完成，需核对手机解锁/会话/服务';
  } finally {
    await saveEvidence(
      'music-layout-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
