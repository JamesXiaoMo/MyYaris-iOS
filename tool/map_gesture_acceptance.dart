// Read-only diagnostic entry: human pan/pinch, no synthesized native gestures.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/apple_map.dart';
import 'package:myyaris_ios/glass_tab_bar.dart';
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
    'version': '0.4.4+16',
    'business_commands_sent': false,
    'synthetic_native_gestures': false,
  };
  Timer? heartbeat;
  var ticks = 0;
  try {
    final bars = tree().where((e) => e.widget is GlassTabBar);
    if (bars.isEmpty) throw StateError('LOGIN_REQUIRED');
    (bars.first.widget as GlassTabBar).onChanged(1);
    await Future<void>.delayed(const Duration(seconds: 3));
    final dynamic map =
        (tree().firstWhere((e) => e.widget is AppleMap) as StatefulElement)
            .state;
    final end = DateTime.now().add(const Duration(seconds: 16));
    while (map.locating == true && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final channel = map.channel as dynamic;
    heartbeat = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => ticks++,
    );
    proof['before'] = await channel.invokeMapMethod<String, dynamic>(
      'diagnostics',
    );
    final context = tree().firstWhere((e) => e.widget is AppleMap);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('地图手势验收：请连续拖动、双指缩放约20秒；不点选目的地'),
        duration: Duration(seconds: 8),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      proof['sample_at_utc'] = DateTime.now().toUtc().toIso8601String();
      proof['samples'] = i + 1;
      proof['dart_heartbeat_ticks'] = ticks;
      try {
        proof['after'] = await channel
            .invokeMapMethod<String, dynamic>('diagnostics')
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        proof['native_diagnostic_timeout'] = true;
        break;
      }
      await saveEvidence(
        'map-gesture-proof.json',
        Uint8List.fromList(utf8.encode(jsonEncode(proof))),
      );
    }
    await KeychainStore.channel
        .invokeMethod<void>('captureHome', 'map-gesture-device.png')
        .timeout(const Duration(seconds: 3));
    proof['finished'] = true;
  } catch (_) {
    proof['blocked'] = '手机未能完成前台地图诊断，请核对解锁/登录/页面';
  } finally {
    heartbeat?.cancel();
    await saveEvidence(
      'map-gesture-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
