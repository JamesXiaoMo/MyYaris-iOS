import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/music_home.dart';
import 'package:myyaris_ios/api/playback_hub.dart';
import 'local_playback_support.dart';

void main() {
  testWidgets(
    'player target choice and controls reach HTTP queues and the native player',
    (tester) async {
      final h = Harness.create();
      addTearDown(h.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: MusicPlayerPage(session: h.session),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('playback-target')), findsOneWidget);
      await tester.tap(find.text('本机'));
      await tester.pumpAndSettle();
      expect(h.session.hub.target, PlaybackTarget.phone);
      expect(h.world.phonePlaying, isFalse);
      expect(h.backend.posted, isEmpty);
      final toggle = find.byKey(const ValueKey('player-toggle'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(h.world.phonePlaying, isTrue);
      expect(h.session.hub.local.queue!.tracks.length, 137);
      expect(find.text('Song 1000'), findsOneWidget);
      expect(h.backend.posted, isEmpty);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(h.world.phonePlaying, isFalse);
      expect(h.native.of('pause'), isNotEmpty);
      await tester.ensureVisible(find.text('车机').first);
      await tester.tap(find.text('车机').first);
      await tester.pumpAndSettle();
      expect(h.session.hub.target, PlaybackTarget.car);
      expect(h.backend.posted.single['params']['autoplay'], isFalse);
      expect(h.world.doubleOutput, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
