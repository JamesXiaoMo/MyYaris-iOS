import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/car_model.dart';

void main() {
  testWidgets(
    'single horizontal rotation; vertical scroll and two fingers never rotate',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      String? name;
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'),
        (call) async {
          if (call.method == 'create') {
            name = 'io.myyaris/model/${(call.arguments as Map)['id']}';
            messenger.setMockMethodCallHandler(MethodChannel(name!), (
              call,
            ) async {
              calls.add(call);
              return null;
            });
          }
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('flutter/platform_views'),
          null,
        );
        if (name != null) {
          messenger.setMockMethodCallHandler(MethodChannel(name!), null);
        }
      });
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: const Column(
                children: [
                  SizedBox(height: 230, child: CarModel()),
                  SizedBox(height: 1200),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(name, isNotNull);
      expect(
        find.byType(Image),
        findsNothing,
      ); // No static poster while loading.
      final done = Completer<void>();
      messenger.handlePlatformMessage(
        name!,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('loaded'),
        ),
        (_) => done.complete(),
      );
      await done.future;
      await tester.pump();
      await tester.drag(find.byType(CarModel), const Offset(100, 0));
      expect(calls.where((c) => c.method == 'yaw'), isNotEmpty);
      expect(find.byType(Image), findsNothing);
      final before = calls.where((c) => c.method == 'yaw').length;
      await tester.drag(find.byType(CarModel), const Offset(0, -90));
      expect(scroll.offset, greaterThan(0));
      expect(calls.where((c) => c.method == 'yaw').length, before);
      scroll.jumpTo(0);
      await tester.pump();
      final point = tester.getCenter(find.byType(CarModel));
      final a = await tester.startGesture(point, pointer: 1);
      final b = await tester.startGesture(
        point + const Offset(40, 0),
        pointer: 2,
      );
      await a.moveBy(const Offset(-70, 0));
      await b.moveBy(const Offset(70, 0));
      await a.up();
      await b.up();
      expect(calls.where((c) => c.method == 'yaw').length, before);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.any((c) => c.method == 'dispose'), isTrue);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
