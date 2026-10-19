// Test-only: style toggles, folder swipe, point dialog cancellation. No dispatch.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:myyaris_ios/main.dart' as app;
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/folder_row.dart';
import 'package:myyaris_ios/apple_map.dart';
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
  final end = DateTime.now().add(const Duration(seconds: 25));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('UI not ready');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> photo(String name) async {
  await Future<void>.delayed(const Duration(seconds: 1));
  await KeychainStore.channel.invokeMethod<void>('captureHome', name);
}

Future<void> main() async {
  app.main();
  final proof = <String, dynamic>{
    'version': '0.5.3+21',
    'navigation_sent': false,
    'music_sent': false,
    'completed': false,
  };
  final binding = GestureBinding.instance,
      oldResampling = GestureBinding.instance.resamplingEnabled;
  binding.resamplingEnabled = false;
  final clock = Stopwatch()..start();
  try {
    await Future<void>.delayed(const Duration(seconds: 7));
    GlassTabBar bar() =>
        tree().firstWhere((e) => e.widget is GlassTabBar).widget as GlassTabBar;
    final previous = bar().index;
    bar().onChanged(1);
    await Future<void>.delayed(const Duration(seconds: 1));
    final dynamic nav =
        (tree().firstWhere((e) => e.widget is NavigationPage)
                as StatefulElement)
            .state;
    final dynamic map =
        (tree().firstWhere((e) => e.widget is AppleMap) as StatefulElement)
            .state;
    await waitFor(() => map.ready == true);
    IconButton style() =>
        tree()
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('map-style-toggle'),
                )
                .widget
            as IconButton;
    final originalStyle = map.satellite == true;
    style().onPressed!.call();
    await waitFor(() => map.changingStyle == false);
    final native = await (map.channel as MethodChannel)
        .invokeMapMethod<String, dynamic>('diagnostics');
    proof['native_satellite_confirmed'] = native?['map_style'] == 'satellite';
    await photo('map-driving-device.png');
    style().onPressed!.call();
    await waitFor(() => map.changingStyle == false);
    final standard = await (map.channel as MethodChannel)
        .invokeMapMethod<String, dynamic>('diagnostics');
    proof['native_standard_restored'] = standard?['map_style'] == 'standard';
    final drawer = nav.drawer as DraggableScrollableController;
    final oldExtent = drawer.size;
    final handle = tree().firstWhere(
      (e) => e.widget.key == const ValueKey('favorites-handle'),
    );
    final handleBox = handle.findRenderObject()! as RenderBox;
    final startHandle = handleBox.localToGlobal(
      handleBox.size.center(Offset.zero),
    );
    binding.handlePointerEvent(
      PointerDownEvent(
        timeStamp: clock.elapsed,
        pointer: 94,
        position: startHandle,
      ),
    );
    for (var i = 1; i <= 8; i++) {
      binding.handlePointerEvent(
        PointerMoveEvent(
          timeStamp: clock.elapsed,
          pointer: 94,
          position: startHandle + Offset(0, -20.0 * i),
          delta: const Offset(0, -20),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    proof['drawer_moves_while_held'] = drawer.size > oldExtent + .05;
    binding.handlePointerEvent(
      PointerUpEvent(
        timeStamp: clock.elapsed,
        pointer: 94,
        position: startHandle + const Offset(0, -160),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await drawer.animateTo(
      .80,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    final folders = tree().where((e) => e.widget is FolderRow).toList();
    proof['folder_available'] = folders.isNotEmpty;
    if (folders.isNotEmpty) {
      final row = folders.first as StatefulElement;
      final dynamic state = row.state;
      final box = row.findRenderObject()! as RenderBox;
      final start = box.localToGlobal(box.size.center(Offset.zero));
      Future<void> swipe(Offset from, double dx, int pointer) async {
        binding.handlePointerEvent(
          PointerDownEvent(
            timeStamp: clock.elapsed,
            pointer: pointer,
            position: from,
          ),
        );
        for (var i = 1; i <= 6; i++) {
          binding.handlePointerEvent(
            PointerMoveEvent(
              timeStamp: clock.elapsed,
              pointer: pointer,
              position: from + Offset(dx * i / 6, 0),
              delta: Offset(dx / 6, 0),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        binding.handlePointerEvent(
          PointerUpEvent(
            timeStamp: clock.elapsed,
            pointer: pointer,
            position: from + Offset(dx, 0),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      await swipe(start, -120, 95);
      proof['left_swipe_reveals_actions'] = state.offset < -100;
      await photo('map-drawer-device.png');
      await swipe(start, 180, 96);
      proof['swipe_closed'] = state.offset == 0;
    }
    await drawer.animateTo(
      oldExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    // Explicit fixture selection to exercise actual dialog UI; never confirm send.
    (tree().firstWhere((e) => e.widget is AppleMap).widget as AppleMap)
        .onSelected(const MapSelection(34.4, 132.4, title: '仅UI验收选点（不发送）'));
    await waitFor(
      () => tree().any(
        (e) => e.widget.key == const ValueKey('map-point-confirmation'),
      ),
    );
    proof['point_dialog_opened'] = true;
    proof['selection_source'] = 'test-only Flutter selection callback';
    await photo('map-search-device.png');
    final dialog = tree().firstWhere(
      (e) => e.widget.key == const ValueKey('map-point-confirmation'),
    );
    Navigator.of(dialog).pop(false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    proof['cancel_dismissed_dialog'] = !tree().any(
      (e) => e.widget.key == const ValueKey('map-point-confirmation'),
    );
    proof['selection_panel_absent'] = !tree().any(
      (e) => e.widget.key == const ValueKey('destination-preview'),
    );
    if (originalStyle) {
      style().onPressed!.call();
      await waitFor(() => map.changingStyle == false);
    }
    bar().onChanged(previous);
    proof['completed'] =
        proof['native_satellite_confirmed'] == true &&
        proof['native_standard_restored'] == true &&
        proof['drawer_moves_while_held'] == true &&
        proof['point_dialog_opened'] == true &&
        proof['cancel_dismissed_dialog'] == true &&
        proof['selection_panel_absent'] == true &&
        (folders.isEmpty ||
            proof['left_swipe_reveals_actions'] == true &&
                proof['swipe_closed'] == true);
  } catch (_) {
    proof['blocked'] = true;
  } finally {
    binding.resamplingEnabled = oldResampling;
    await saveEvidence(
      'map-ui-proof.json',
      Uint8List.fromList(utf8.encode(jsonEncode(proof))),
    );
  }
}
