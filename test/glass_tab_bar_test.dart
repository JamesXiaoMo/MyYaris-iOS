import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/glass_tab_bar.dart';
import 'package:myyaris_ios/main.dart';
import 'package:myyaris_ios/api/driving_favorites_drawer.dart';
import 'package:myyaris_ios/api/music_home.dart' show VinylRecord;
import 'package:myyaris_ios/api/login_page.dart';
import 'widget_test.dart' show FixtureSession;

void main() {
  testWidgets(
    'glass pixels change with the layer underneath, without an opaque strip',
    (tester) async {
      final boundary = GlobalKey();
      var background = Colors.red;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  extendBody: true,
                  body: ColoredBox(
                    color: background,
                    child: const SizedBox.expand(),
                  ),
                  bottomNavigationBar: GlassTabBar(index: 0, onChanged: (_) {}),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byKey(const ValueKey('glass-tab-bar')));
      final point = Offset(bar.right - 18, bar.center.dy);
      Future<List<int>> pixel() async {
        return (await tester.runAsync(() async {
          final box =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await box.toImage(pixelRatio: 1);
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final offset =
              (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
          final bytes = data.buffer.asUint8List();
          final result = bytes.sublist(offset, offset + 4);
          image.dispose();
          return result;
        }))!;
      }

      final red = await pixel();
      update(() => background = Colors.blue);
      await tester.pumpAndSettle();
      final blue = await pixel();
      expect(red[0], greaterThan(red[2] + 50));
      expect(blue[2], greaterThan(blue[0] + 50));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'page paints behind glass; drawer scroll tail and record avoid overlay',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      final session = FixtureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: YarisShell(session: session, initializeSession: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).extendBody,
        true,
      );
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byKey(const ValueKey('glass-tab-bar')));
      final drawer = tester.getRect(find.byType(DrivingFavoritesDrawer));
      expect(drawer.bottom, greaterThan(bar.bottom));
      expect(drawer.top, lessThan(bar.top));
      final list = tester.widget<ListView>(
        find.descendant(
          of: find.byType(DrivingFavoritesDrawer),
          matching: find.byType(ListView),
        ),
      );
      expect(
        (list.padding! as EdgeInsets).bottom,
        greaterThan(bar.height + 34),
      );
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(VinylRecord)).bottom,
        lessThan(bar.top),
      );
      await tester.tap(find.byKey(const ValueKey('tab-3')));
      await tester.pumpAndSettle();
      final settingsList = tester.widget<ListView>(find.byType(ListView).first);
      expect(
        (settingsList.padding! as EdgeInsets).bottom,
        greaterThan(bar.height + 34),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'drag follows pointer, commits only once on release, cancel restores',
    (tester) async {
      var index = 0;
      final changes = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, set) => Scaffold(
              bottomNavigationBar: GlassTabBar(
                index: index,
                onChanged: (value) => set(() {
                  index = value;
                  changes.add(value);
                }),
              ),
            ),
          ),
        ),
      );
      final start = tester.getCenter(find.byKey(const ValueKey('tab-0')));
      final end = tester.getCenter(find.byKey(const ValueKey('tab-3')));
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(start + const Offset(25, 0));
      await gesture.moveTo(end);
      await tester.pump();
      expect(changes, isEmpty);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('glass-selection'))).dx,
        greaterThan(start.dx),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, [3]);
      final cancel = await tester.startGesture(end);
      await cancel.moveTo(start);
      await cancel.cancel();
      await tester.pumpAndSettle();
      expect(changes, [3]);
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      expect(changes, [3, 1]);
    },
  );

  testWidgets(
    'touch bounds, safe area, semantics and accessible solid fallback',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              padding: EdgeInsets.only(bottom: 34),
              disableAnimations: true,
              highContrast: true,
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              bottomNavigationBar: GlassTabBar(index: 1, onChanged: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        final size = tester.getSize(find.byKey(ValueKey('tab-$i')));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      }
      expect(
        tester.getBottomLeft(find.byKey(const ValueKey('glass-tab-bar'))).dy,
        lessThanOrEqualTo(534),
      );
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isFalse,
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('行驶')),
        matchesSemantics(
          label: '行驶',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'shell preserves input across click and drag; keyboard hides bar; login has no tabs',
    (tester) async {
      final session = FixtureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: YarisShell(session: session, initializeSession: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('destination-input-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('destination-input')),
        '34.4,132.4',
      );
      await tester.tap(find.text('取消'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-2')));
      await tester.pumpAndSettle();
      await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('tab-2'))),
        tester.getCenter(find.byKey(const ValueKey('tab-1'))) -
            tester.getCenter(find.byKey(const ValueKey('tab-2'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('destination-input-open')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('destination-input')))
            .controller!
            .text,
        '34.4,132.4',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('glass-tab-bar')), findsNothing);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('glass-tab-bar')), findsOneWidget);
      session.authInitialized = true;
      await tester.pumpWidget(
        MaterialApp(
          home: AuthenticationGate(
            session: session,
            child: const Text('hidden control pages'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('glass-tab-bar')), findsNothing);
    },
  );
}
