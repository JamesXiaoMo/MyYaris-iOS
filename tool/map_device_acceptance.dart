// Read-only real app UI acceptance. No business command or account bypass.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/apple_map.dart';
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/api/pages.dart';
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

Future<void> main() async {
  app.main();
  await Future<void>.delayed(const Duration(seconds: 6));
  final proof = <String, dynamic>{
    'version': '0.4.0+12',
    'business_commands_sent': false,
    'folders_backend_connected': false,
    'completed': false,
  };
  try {
    final bars = tree().where((e) => e.widget is GlassTabBar);
    if (bars.isEmpty) {
      proof['blocked'] = '需用户在手机登录，未绕过';
      return;
    }
    final original = (bars.first.widget as GlassTabBar).index;
    (bars.first.widget as GlassTabBar).onChanged(1);
    await Future<void>.delayed(const Duration(seconds: 2));
    final element =
        tree().firstWhere((e) => e.widget is AppleMap) as StatefulElement;
    final dynamic map = element.state;
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (map.ready != true && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    proof['mapkit_rendered'] = map.ready == true;
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'map-driving-device.png',
    );
    final dynamic navigation =
        (tree().firstWhere((e) => e.widget is NavigationPage)
                as StatefulElement)
            .state;
    final drawer = navigation.drawer as DraggableScrollableController;
    await drawer.animateTo(
      .70,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await KeychainStore.channel.invokeMethod<void>(
      'captureHome',
      'map-drawer-device.png',
    );
    proof['drawer_expanded'] = drawer.size > .65;
    proof['completed'] = true;
    await drawer.animateTo(
      .34,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    (tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar)
        .onChanged(original);
  } catch (_) {
    proof['error'] = '真机地图/抽屉验收未完成';
  } finally {
    await saveEvidence(
      'map-ui-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
