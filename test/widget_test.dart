import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/main.dart';
import 'package:myyaris_ios/api/backend.dart';

class MemoryCredentials implements CredentialStore {
  String? data;
  @override
  Future<String?> load() async => data;
  @override
  Future<void> save(String value) async {
    data = value;
  }

  @override
  Future<void> clear() async {
    data = null;
  }
}

class FixtureSession extends BackendSession {
  FixtureSession({super.api})
    : super(store: MemoryCredentials(), requireUserLogin: false);
  @override
  void start() {}
}

void main() {
  testWidgets(
    'manual destination entry is removed; driving retains map and favorites',
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
      expect(
        find.byKey(const ValueKey('destination-input-open')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('destination-input')), findsNothing);
      expect(find.text('输入目的地'), findsNothing);
      expect(find.byKey(const ValueKey('map-search-open')), findsOneWidget);
      expect(find.byKey(const ValueKey('favorites-all')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932),
  ]) {
    testWidgets('unconfigured offline layout at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = FixtureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: YarisShell(session: session),
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
