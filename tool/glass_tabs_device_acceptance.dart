// Explicit test entry point only. Real iPhone window captures; automated Flutter
// pointer events, not an assertion that a human physically dragged the screen.
// No login bypass, business command, navigation, registration or preference save.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as production;
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

Future<void> photo(String name) async {
  await Future<void>.delayed(const Duration(milliseconds: 550));
  await KeychainStore.channel.invokeMethod<void>('captureHome', name);
}

Future<void> main() async {
  production.main();
  // Synthetic events need real timestamps and bypass engine resampling; this
  // test-only adjustment is restored before returning, never used by main.dart.
  final binding = GestureBinding.instance;
  final originalResampling = binding.resamplingEnabled;
  binding.resamplingEnabled = false;
  final clock = Stopwatch()..start();
  await Future<void>.delayed(const Duration(seconds: 7));
  final proof = <String, dynamic>{
    'version': '0.3.1+9',
    'started_at_utc': DateTime.now().toUtc().toIso8601String(),
    'input': 'automated Flutter pointer events on actual iPhone',
    'capture': 'full native application window including WKWebView',
    'business_commands_sent': false,
    'completed': false,
  };
  try {
    final bars = tree().where((e) => e.widget is GlassTabBar);
    if (bars.isEmpty) {
      proof['blocked'] = '登录门禁或会话恢复未完成；没有绕过';
      await photo('glass-login-device.png');
      return;
    }
    GlassTabBar bar() =>
        tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar;
    Offset center(int index) {
      final e = tree().firstWhere(
        (e) => e.widget.key == ValueKey('tab-$index'),
      );
      final box = e.findRenderObject()! as RenderBox;
      return box.localToGlobal(box.size.center(Offset.zero));
    }

    Future<void> tap(int index) async {
      final point = center(index);
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          timeStamp: clock.elapsed,
          pointer: 90,
          position: point,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(timeStamp: clock.elapsed, pointer: 90, position: point),
      );
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (bar().index != index) throw StateError('点击未切到目标页');
    }

    final original = bar().index;
    proof['initial_index'] = original;
    await tap(0);
    await photo('glass-home-device.png');
    proof['home_capture_index'] = bar().index;
    if (bar().index != 0) throw StateError('截图期间页面改变');
    final start = center(0), end = center(3);
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(timeStamp: clock.elapsed, pointer: 91, position: start),
    );
    var previous = start;
    for (var i = 1; i <= 8; i++) {
      final point = Offset.lerp(start, end, i / 8)!;
      GestureBinding.instance.handlePointerEvent(
        PointerMoveEvent(
          timeStamp: clock.elapsed,
          pointer: 91,
          position: point,
          delta: point - previous,
        ),
      );
      previous = point;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (i == 4) await photo('glass-drag-device.png');
    }
    proof['index_during_drag'] = bar().index;
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(timeStamp: clock.elapsed, pointer: 91, position: end),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    proof['index_after_release'] = bar().index;
    proof['drag_commit_once'] =
        proof['index_during_drag'] == 0 && bar().index == 3;
    if (proof['drag_commit_once'] != true) throw StateError('拖动验收不通过');
    await photo('glass-settings-device.png');
    await tap(1);
    await photo('glass-driving-device.png');
    await tap(2);
    await photo('glass-music-device.png');
    await tap(original);
    proof['all_four_tabs_opened'] = true;
    proof['completed'] = true;
  } catch (e) {
    proof['failure_step'] = e is StateError ? e.message : 'UI验收异常';
    proof['error'] = '设备页面验收未完成，请核对截图与设备状态';
  } finally {
    binding.resamplingEnabled = originalResampling;
    await saveEvidence(
      'glass-tabs-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
