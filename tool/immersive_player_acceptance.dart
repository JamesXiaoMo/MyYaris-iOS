// Read-only real UI acceptance; never sends navigation/music or account writes.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/music_home.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/verification/favorites_evidence.dart'
    show saveEvidence;

List<Element> elements([Element? scope]) {
  final result = <Element>[];
  void visit(Element e) {
    result.add(e);
    e.visitChildElements(visit);
  }

  final root = scope ?? WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return result;
}

Future<void> main() async {
  app.main();
  final proof = <String, dynamic>{
    'version': '0.5.7+25',
    'business_writes_sent': false,
    'completed': false,
  };
  try {
    await Future<void>.delayed(const Duration(seconds: 8));
    (elements().firstWhere((e) => e.widget is GlassTabBar).widget
            as GlassTabBar)
        .onChanged(2);
    await Future<void>.delayed(const Duration(seconds: 1));
    (elements()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-record-open'),
                )
                .widget
            as VinylRecord)
        .onTap!();
    await Future<void>.delayed(const Duration(seconds: 2));
    final pageElement = elements().firstWhere(
      (e) => e.widget is MusicPlayerPage,
    );
    final page = pageElement.widget as MusicPlayerPage;
    final widgets = elements(pageElement).map((e) => e.widget).toList();
    final panel = widgets.whereType<PlaybackPanel>().single;
    proof['immersive_controls'] = panel.immersive;
    proof['large_record'] = widgets.whereType<VinylRecord>().single.size >= 220;
    proof['unknown_or_stale_disables_toggle'] =
        page.session.heartbeatFresh && !page.session.playbackStale ||
        (widgets
                .whereType<FilledButton>()
                .firstWhere((w) => w.key == const ValueKey('player-toggle'))
                .onPressed ==
            null);
    proof['real_cover_available'] =
        musicArtworkUrl(page.session.currentTrack['cover_url']) != null;
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'music-player-v2-device.png',
    );
    final scroll = elements(pageElement)
        .whereType<StatefulElement>()
        .map((e) => e.state)
        .whereType<ScrollableState>()
        .first;
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await Future<void>.delayed(const Duration(seconds: 1));
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'music-search-v2-device.png',
    );
    final more =
        elements(pageElement)
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('player-more'),
                )
                .widget
            as TextButton;
    more.onPressed!();
    await Future<void>.delayed(const Duration(seconds: 1));
    proof['more_controls_opened'] = elements().any(
      (e) => e.widget is Text && (e.widget as Text).data == '更多控制与状态',
    );
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'music-home-v2-device.png',
    );
    Navigator.of(
      elements().firstWhere(
        (e) =>
            e.widget is PlaybackPanel && !(e.widget as PlaybackPanel).immersive,
      ),
    ).pop();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    (elements(pageElement)
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('player-dismiss'),
                )
                .widget
            as IconButton)
        .onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    proof['return_to_music'] = !elements().any(
      (e) => e.widget is MusicPlayerPage,
    );
    proof['completed'] = [
      'immersive_controls',
      'large_record',
      'unknown_or_stale_disables_toggle',
      'more_controls_opened',
      'return_to_music',
    ].every((k) => proof[k] == true);
  } catch (_) {
    proof['blocked'] = true;
  } finally {
    await saveEvidence(
      'music-layout-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
