// Headless Flutter UI audit. Does not launch an iOS simulator or contact APIs.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/main.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  final errors = <String>[];
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
    stderr.writeln(details.exceptionAsString());
  };
  final font = FontLoader('.SF Pro Text');
  font.addFont(
    Future.value(
      ByteData.sublistView(
        await File(
          '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        ).readAsBytes(),
      ),
    ),
  );
  await font.load();
  final controller = LiveWidgetController(binding);
  final boundaryKey = GlobalKey();
  for (final size in [
    const Size(390, 844),
    const Size(320, 568),
    const Size(430, 932),
  ]) {
    runApp(
      Center(
        child: OverflowBox(
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: size.height,
          maxHeight: size.height,
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox.fromSize(
              size: size,
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  devicePixelRatio: 1,
                  padding: const EdgeInsets.only(top: 47, bottom: 34),
                  viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
                  textScaler: TextScaler.linear(size.width == 320 ? 1.4 : 1),
                ),
                child: MyYarisApp(key: ValueKey(size.width)),
              ),
            ),
          ),
        ),
      ),
    );
    await controller.pump(const Duration(milliseconds: 100));
    binding.renderViews.first.configuration = ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size),
      devicePixelRatio: 1,
    );
    await controller.pump(const Duration(milliseconds: 300));
    await controller.pump(const Duration(milliseconds: 300));
    Future<void> capture(String name) async {
      final render =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'docs/assets/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    await capture('home-api-${size.width.toInt()}');
    await controller.drag(
      find.byKey(const ValueKey('home-scroll')),
      const Offset(0, -500),
    );
    await controller.pump(const Duration(milliseconds: 300));
    if (size.width == 390) {
      await capture('home-details-api-390');
    }
    for (var tab = 1; tab < 4; tab++) {
      await controller.tap(find.byKey(ValueKey('tab-$tab')));
      await controller.pump(const Duration(milliseconds: 200));
      await controller.pump(const Duration(milliseconds: 200));
      final page = ['home', 'navigation', 'music', 'settings'][tab];
      if (size.width == 390) {
        await capture('$page-api-390');
      }
    }
    await controller.tap(find.byKey(const ValueKey('tab-1')));
    await controller.pump(const Duration(milliseconds: 100));
    final input = controller.widget<TextField>(
      find.byKey(const ValueKey('destination-input')),
    );
    input.controller!.text = '34.39,132.45';
    await controller.tap(find.byKey(const ValueKey('destination-preview')));
    await controller.pump(const Duration(milliseconds: 100));
    if (find.textContaining('请先在设置中配置手机 Token').evaluate().length != 1) {
      errors.add(
        'unconfigured request must be rejected before network for $size',
      );
    }
    stdout.writeln('layout and four tabs verified: $size');
  }
  stdout.writeln('Flutter UI audit errors: ${errors.length}');
  exit(errors.isEmpty ? 0 : 1);
}
