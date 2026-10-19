// Read-only real UI acceptance; never sends navigation/music or account writes.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/api/music_home.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/verification/favorites_evidence.dart'
    show saveEvidence;

List<Element> elements() {
  final result = <Element>[];
  void visit(Element e) {
    result.add(e);
    e.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return result;
}

Future<void> main() async {
  app.main();
  final proof = <String, dynamic>{
    'version': '0.5.5+23',
    'business_writes_sent': false,
    'completed': false,
  };
  try {
    await Future<void>.delayed(const Duration(seconds: 8));
    final bar =
        elements().firstWhere((e) => e.widget is GlassTabBar).widget
            as GlassTabBar;
    bar.onChanged(2);
    await Future<void>.delayed(const Duration(seconds: 1));
    final dynamic home =
        (elements().firstWhere((e) => e.widget is MusicPage) as StatefulElement)
            .state;
    final until = DateTime.now().add(const Duration(seconds: 25));
    while (home.account.busy == true) {
      if (DateTime.now().isAfter(until)) throw StateError('account timeout');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final title =
        elements()
                .firstWhere(
                  (e) =>
                      e.widget.key == const ValueKey('netease-account-title'),
                )
                .widget
            as Text;
    final uid =
        elements()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('netease-account-uid'),
                )
                .widget
            as Text;
    final record =
        elements()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-record-open'),
                )
                .widget
            as VinylRecord;
    final cover =
        elements()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('vinyl-cover'),
                )
                .widget
            as MusicArtwork;
    proof['profile_loaded'] = home.account.loaded;
    proof['nickname_first_line'] =
        home.account.loaded &&
        home.account.profile['logged_in'] == true &&
        home.account.manager &&
        (home.account.profile['nickname'] as String? ?? '').trim().isNotEmpty &&
        title.data == (home.account.profile['nickname'] as String).trim();
    proof['uid_second_line'] =
        home.account.loaded &&
        home.account.manager &&
        home.account.profile['user_id'] != null &&
        uid.data == 'UID：${home.account.profile['user_id']}';
    proof['cover_ratio_064'] = cover.size == record.size * .64;
    await Future<void>.delayed(const Duration(seconds: 1));
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'music-home-v2-device.png',
    );
    proof['completed'] =
        proof['nickname_first_line'] == true &&
        proof['uid_second_line'] == true &&
        proof['cover_ratio_064'] == true;
  } catch (_) {
    proof['blocked'] = true;
  } finally {
    await saveEvidence(
      'music-layout-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
