import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/apple_map.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'widget_test.dart' show FixtureSession;
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

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

      final one = await tester.startGesture(
        const Offset(100, 200),
        pointer: 21,
      );
      final two = await tester.startGesture(
        const Offset(180, 200),
        pointer: 22,
      );
      await one.moveBy(const Offset(-20, 20));
      await two.moveBy(const Offset(20, -20));
      await one.up();
      await event('selected', {'latitude': 34.4, 'longitude': 132.4});
      expect(picked, isEmpty, reason: 'Second pinch pointer is still down');
      expect(
        nativeCalls
            .where((c) => c.method == 'interaction')
            .map((c) => c.arguments),
        [true],
      );
      await two.cancel();
      await tester.pump();
      expect(
        nativeCalls
            .where((c) => c.method == 'interaction')
            .map((c) => c.arguments),
        [true, false],
      );
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
          (c) => {
            'center',
            'setActive',
            'locate',
            'dispose',
            'interaction',
          }.contains(c.method),
        ),
        true,
      );
    },
  );
  testWidgets(
    'map viewport and platform identity stay stable while multi-touch overlaps drawer resize',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger = tester.binding.defaultBinaryMessenger;
      final channels = <MethodChannel>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform_views'),
        (call) async {
          if (call.method == 'create') {
            final channel = MethodChannel(
              'io.myyaris/map/${(call.arguments as Map)['id']}',
            );
            channels.add(channel);
            messenger.setMockMethodCallHandler(
              channel,
              (call) async =>
                  call.method == 'locate' ? {'status': 'located'} : null,
            );
          }
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('flutter/platform_views'),
          null,
        );
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      final session = FixtureSession(
        api: BackendApi(
          client: MockClient(
            (_) async => http.Response(
              '{"items":[],"total":0,"has_more":false,"uncategorized_count":0}',
              200,
            ),
          ),
        )..token = 'unit',
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NavigationPage(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.getSize(find.byType(UiKitView));
      final one = await tester.startGesture(
        const Offset(120, 160),
        pointer: 21,
      );
      final two = await tester.startGesture(
        const Offset(220, 160),
        pointer: 22,
      );
      await tester.pump();
      final dynamic navigation = tester.state(find.byType(NavigationPage));
      final drawer = navigation.drawer as DraggableScrollableController;
      drawer.jumpTo(.70);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(UiKitView)), before);
      expect(channels.length, 1);
      await one.up();
      await tester.pump();
      expect(tester.getSize(find.byType(UiKitView)), before);
      await two.cancel();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(UiKitView)).height,
        lessThan(before.height),
      );
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
