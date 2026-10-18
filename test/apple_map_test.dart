import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/apple_map.dart';

void main() {
  testWidgets(
    'MapKit channel validates coordinates; center is not navigation; dispose releases view',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger = tester.binding.defaultBinaryMessenger;
      String? name;
      bool denyLocation = false;
      final nativeCalls = <MethodCall>[], picked = <MapSelection>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'),
        (call) async {
          if (call.method == 'create') {
            name = 'io.myyaris/map/${(call.arguments as Map)['id']}';
            messenger.setMockMethodCallHandler(MethodChannel(name!), (c) async {
              nativeCalls.add(c);
              if (c.method == 'locate' && denyLocation) {
                throw PlatformException(
                  code: 'LOCATION_DENIED',
                  message: '定位未授权',
                );
              }
              return c.method == 'locate'
                  ? {'status': 'located', 'approximate': false}
                  : null;
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
      await tester.pumpWidget(
        MaterialApp(
          home: AppleMap(
            onSelected: picked.add,
            selection: const MapSelection(34.4, 132.4),
          ),
        ),
      );
      await tester.pump();
      expect(
        nativeCalls.map((c) => c.method),
        containsAll(['center', 'setActive', 'locate']),
      );
      expect(picked, isEmpty);
      denyLocation = true;
      await tester.tap(find.byKey(const ValueKey('map-locate')));
      await tester.pump();
      expect(find.text('定位未授权'), findsOneWidget);
      expect(picked, isEmpty);
      Future<void> event(String method, Object? value) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          name!,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, value),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await tester.pump();
      }

      await event('selected', {'latitude': 91, 'longitude': 132});
      expect(picked, isEmpty);
      await event('selected', {'latitude': 34.4, 'longitude': 132.4});
      expect(picked.single.latitude, 34.4);
      expect(picked.single.longitude, 132.4);
      await event('failed', null);
      expect(find.textContaining('地图加载失败'), findsOneWidget);
      await event('ready', null);
      expect(find.textContaining('地图加载失败'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(nativeCalls.last.method, 'dispose');
      debugDefaultTargetPlatformOverride = null;
      expect(
        nativeCalls.every(
          (c) =>
              {'center', 'setActive', 'locate', 'dispose'}.contains(c.method),
        ),
        true,
      );
    },
  );
}
