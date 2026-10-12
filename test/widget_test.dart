import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/main.dart';

void main() {
  testWidgets('four tabs and local destination preview work', (tester) async {
    await tester.pumpWidget(const MyYarisApp());
    await tester.pumpAndSettle();
    expect(find.text('Toyota Yaris ⌄'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('destination-input')),
      '34.39,132.45',
    );
    await tester.tap(find.byKey(const ValueKey('destination-preview')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未发送，未接入'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-input')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-3')));
    await tester.pumpAndSettle();
    expect(find.text('0.1.0 · 页面演示版'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tab-0')));
    await tester.pumpAndSettle();
    expect(find.text('Toyota Yaris ⌄'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932),
  ]) {
    testWidgets('portrait layout fits $size with larger text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: const YarisShell(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('home-scroll')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (var i = 1; i < 4; i++) {
        await tester.tap(find.byKey(ValueKey('tab-$i')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
