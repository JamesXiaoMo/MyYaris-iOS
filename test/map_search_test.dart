import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/apple_map.dart';
import 'package:myyaris_ios/map_search_page.dart';

class FakeMap extends AppleMapController {
  Future<List<MapSelection>> Function() result = () async => [];
  @override
  Future<List<MapSelection>> search(String query) => result();
  @override
  Future<void> cancelSearch() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'search validates and deduplicates native results without navigation',
    () async {
      final controller = AppleMapController()
        ..channel = const MethodChannel('test/map-search');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Object? response = {
        'results': [
          for (var i = 0; i < 2; i++)
            {
              'title': '麦当劳',
              'address': '日本',
              'latitude': 34.4,
              'longitude': 132.4,
            },
        ],
      };
      messenger.setMockMethodCallHandler(
        controller.channel!,
        (_) async => response,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(controller.channel!, null),
      );
      expect((await controller.search('麦当劳')).length, 1);
      response = {
        'results': [
          {'title': 'bad', 'address': '', 'latitude': 91, 'longitude': 0},
        ],
      };
      await expectLater(controller.search('test'), throwsFormatException);
      await expectLater(controller.search('  '), throwsFormatException);
    },
  );
  testWidgets('empty, error, late response and selection remain distinct', (
    tester,
  ) async {
    final map = FakeMap();
    await tester.pumpWidget(MaterialApp(home: MapSearchPage(controller: map)));
    await tester.enterText(
      find.byKey(const ValueKey('map-search-query')),
      '麦当劳',
    );
    await tester.tap(find.byKey(const ValueKey('map-search-submit')));
    await tester.pump();
    expect(find.textContaining('未找到地点'), findsOneWidget);
    map.result = () async =>
        throw PlatformException(code: 'SEARCH_FAILED', message: '网络不可用');
    await tester.tap(find.byKey(const ValueKey('map-search-submit')));
    await tester.pump();
    expect(find.text('网络不可用'), findsOneWidget);
    expect(find.textContaining('未找到地点'), findsNothing);
    final delayed = Completer<List<MapSelection>>();
    map.result = () => delayed.future;
    await tester.tap(find.byKey(const ValueKey('map-search-submit')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('map-search-query')),
      '新查询',
    );
    delayed.complete([const MapSelection(34, 132, title: '过期结果')]);
    await tester.pump();
    expect(find.text('过期结果'), findsNothing);
    map.result = () async => [
      const MapSelection(34, 132, title: '麦当劳', address: '测试地址'),
    ];
    await tester.tap(find.byKey(const ValueKey('map-search-submit')));
    await tester.pump();
    expect(find.text('麦当劳'), findsOneWidget);
    expect(find.text('测试地址'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
