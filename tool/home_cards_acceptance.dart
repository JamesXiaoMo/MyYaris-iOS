// Explicit read-only real-device entry; no playback, navigation or account writes.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/glass_tab_bar.dart';
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

Future<void> main() async {
  app.main();
  final proof = <String, dynamic>{
    'version': '0.5.1+18',
    'business_writes_sent': false,
    'completed': false,
  };
  try {
    await Future<void>.delayed(const Duration(seconds: 8));
    final page =
        tree().firstWhere((e) => e.widget is NavigationPage).widget
            as NavigationPage;
    final s = page.session;
    final bar =
        tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar;
    final previous = bar.index;
    bar.onChanged(0);
    await s.refresh();
    await Future<void>.delayed(const Duration(seconds: 2));
    final labels = tree()
        .map((e) => e.widget)
        .whereType<Text>()
        .map((w) => w.data)
        .toSet();
    proof.addAll({
      'session_available': s.userSignedIn,
      'backend_healthy': s.backendOnline,
      'destination_reference_available': s.lastTask['task_id'] != null,
      'destination_verified': s.navigationVerified,
      'music_state_fresh': s.heartbeatFresh && !s.playbackStale,
      'music_metadata_available': s.currentTrack['title'] is String,
      'home_title_matches_session':
          labels.contains(s.homeMusicTitle) &&
          labels.contains(s.homeDestinationTitle),
      'home_state_matches_session': labels.contains(s.homeMusicState),
    });
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'home-device.png',
    );
    (tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar)
        .onChanged(2);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    (tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar)
        .onChanged(previous);
    proof['completed'] = true;
  } catch (_) {
    proof['blocked'] = true;
  }
  await saveEvidence(
    'home-proof.json',
    Uint8List.fromList(utf8.encode(jsonEncode(proof))),
  );
}
