import 'dart:async';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/local_audio.dart';
import 'package:myyaris_ios/api/local_player.dart';
import 'local_playback_support.dart';

Map<String, dynamic> track(int song) => {
  'track_id': 'netease_$song',
  'song_id': song,
  'title': 'Song $song',
  'artist': 'A',
  'duration_ms': 200000,
};

LocalQueue favorite(
  int n, {
  String mode = 'list_loop',
  int index = 0,
  int seed = 1,
}) => LocalQueue(
  source: 'netease_favorite',
  queueId: 'q_fav',
  version: 3,
  tracks: [for (var i = 0; i < n; i++) track(1000 + i)],
  mode: mode,
  index: index,
  random: Random(seed),
);

LocalPlayer playerFor(
  FakeNativeAudio native, {
  Future<HeartBatch> Function(LocalQueue)? heart,
  Uri Function(int song)? url,
}) => LocalPlayer(
  engine: NativeLocalAudioEngine(),
  resolveMedia: (t) => LocalMedia(
    url?.call(t['song_id'] as int) ??
        Uri.parse('$origin/api/v1/music/netease/stream/${t['song_id']}'),
    {'Authorization': 'Bearer fixture-token'},
  ),
  continueHeart: heart,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeWorld world;
  late FakeNativeAudio native;
  late LocalPlayer player;
  setUp(() {
    world = FakeWorld();
    native = FakeNativeAudio(world)..install();
    player = playerFor(native);
  });
  tearDown(() {
    player.dispose();
    native.uninstall();
  });

  group('queue cursor rules', () {
    test('list loop wraps and previous wraps back', () {
      final q = favorite(3);
      expect([q.advance(), q.advance(), q.advance()], [1, 2, 0]);
      expect(q.retreat(), 2);
    });

    test(
      'shuffle covers the whole favorite list once, starts at the current song, then reshuffles',
      () {
        final q = favorite(137, mode: 'shuffle', index: 40);
        expect(q.index, 40);
        final seen = <int>{40};
        for (var i = 1; i < 137; i++) {
          final next = q.advance()!;
          expect(
            seen.add(next),
            isTrue,
            reason: 'no repeat inside one full pass',
          );
        }
        expect(seen.length, 137);
        expect(q.advance(), isNotNull);
      },
    );

    test(
      'single track stops at the end; single loop repeats; heart ends at its last track',
      () {
        final single = LocalQueue.single(track(7));
        expect(single.advance(), isNull);
        single.mode = 'single_loop';
        expect(single.advance(), 0);
        final heart = LocalQueue(
          source: 'netease_intelligence',
          queueId: 'q_intel',
          version: 1,
          tracks: [track(1), track(2)],
          mode: 'intelligence',
        );
        expect(heart.advance(), 1);
        expect(heart.advance(), isNull);
      },
    );

    test('loop and shuffle only apply to a complete favorite queue', () {
      final heart = LocalQueue(
        source: 'netease_intelligence',
        queueId: 'h',
        version: 1,
        tracks: [track(1)],
        mode: 'intelligence',
      );
      expect(heart.setMode('shuffle'), isFalse);
      expect(LocalQueue.single(track(1)).setMode('list_loop'), isFalse);
      expect(favorite(3).setMode('intelligence'), isFalse);
      expect(favorite(3).setMode('shuffle'), isTrue);
    });
  });

  group('phone player over the native channel', () {
    test(
      'creating the player and the queue produces no native call and no sound',
      () async {
        final q = favorite(5);
        await settle();
        expect(native.calls, isEmpty);
        expect(world.phonePlaying, isFalse);
        expect(player.phase, LocalPhase.idle);
        expect(q.index, 0);
      },
    );

    test(
      'cold start prepares silently, play/pause/resume keep the position, authenticated https stream',
      () async {
        await player.start(
          favorite(5),
          index: 2,
          positionMs: 61000,
          autoplay: false,
        );
        expect(world.phonePlaying, isFalse);
        expect(player.phase, LocalPhase.paused);
        expect(player.positionMs, 61000);
        expect(
          native.lastUrl.toString(),
          '$origin/api/v1/music/netease/stream/1002',
        );
        expect(native.lastHeaders['Authorization'], 'Bearer fixture-token');
        await player.play();
        expect(world.phonePlaying, isTrue);
        expect(player.isPlaying, isTrue);
        await native.emit({
          'type': 'state',
          'state': 'playing',
          'positionMs': 63000,
          'durationMs': 200000,
        });
        expect(player.phase, LocalPhase.playing);
        await player.pause();
        expect(world.phonePlaying, isFalse);
        await native.emit({
          'type': 'state',
          'state': 'paused',
          'positionMs': 64000,
          'durationMs': 200000,
        });
        expect(player.positionMs, 64000);
        expect(player.phase, LocalPhase.paused);
        expect(
          native.of('load').length,
          1,
          reason: 'pause/resume never reload',
        );
        await player.play();
        expect(native.of('load').length, 1);
        await player.seek(120000);
        expect(native.positionMs, 120000);
        expect(player.positionMs, 120000);
        await player.setVolume(.4);
        expect(native.of('volume').last.arguments, {'volume': .4});
      },
    );

    test(
      'natural completion advances exactly once even if the event repeats; late events of an old item are ignored',
      () async {
        await player.start(favorite(5), autoplay: true);
        final firstEpoch = native.epoch;
        await native.emit({
          'type': 'completed',
          'epoch': firstEpoch,
          'positionMs': 200000,
        });
        await native.emit({
          'type': 'completed',
          'epoch': firstEpoch,
          'positionMs': 200000,
        });
        await settle();
        expect(player.queue!.index, 1);
        expect(native.of('load').length, 2);
        expect(world.phonePlaying, isTrue);
        await native.emit({
          'type': 'completed',
          'epoch': firstEpoch,
          'positionMs': 200000,
        });
        await native.emit({
          'type': 'state',
          'epoch': firstEpoch,
          'state': 'paused',
          'positionMs': 1,
        });
        await settle();
        expect(
          player.queue!.index,
          1,
          reason: 'a late event from the previous item changes nothing',
        );
        expect(player.phase, LocalPhase.playing);
      },
    );

    test(
      'full shuffle plays every favorite once through completions',
      () async {
        await player.start(
          favorite(12, mode: 'shuffle', index: 3, seed: 9),
          index: 3,
          autoplay: true,
        );
        final heard = <int>[3];
        for (var i = 0; i < 11; i++) {
          await native.emit({'type': 'completed', 'positionMs': 200000});
          await settle();
          heard.add(player.queue!.index);
        }
        expect(heard.toSet().length, 12);
      },
    );

    test(
      'single track ends in stopped and releases the audio session',
      () async {
        await player.start(LocalQueue.single(track(77)), autoplay: true);
        await native.emit({'type': 'completed', 'positionMs': 200000});
        await settle();
        expect(player.phase, LocalPhase.stopped);
        expect(player.notice, '播放完毕');
        expect(world.phonePlaying, isFalse);
        expect(native.of('stop'), isNotEmpty);
        expect(native.of('load').length, 1);
      },
    );

    test(
      'three unplayable songs stop with a visible reason; a single bad song is skipped',
      () async {
        native.failSongs = {1001};
        await player.start(favorite(5), autoplay: true);
        await native.emit({'type': 'completed', 'positionMs': 1});
        await settle();
        expect(
          player.queue!.index,
          2,
          reason: 'one unplayable song is skipped',
        );
        expect(player.phase, LocalPhase.playing);
        native.failSongs = {1003, 1004, 1000};
        await native.emit({'type': 'completed', 'positionMs': 1});
        await settle();
        expect(player.phase, LocalPhase.stopped);
        expect(player.error, contains('连续三首'));
        expect(world.phonePlaying, isFalse);
      },
    );

    test('a failed explicit pick restores the song that was playing', () async {
      await player.start(
        favorite(5),
        index: 1,
        positionMs: 30000,
        autoplay: true,
      );
      native.failSongs = {1004};
      await expectLater(
        player.start(favorite(5), index: 4, autoplay: true),
        throwsA(isA<LocalFailure>()),
      );
      await settle();
      expect(player.queue!.index, 1);
      expect(player.positionMs, 30000);
      expect(world.phonePlaying, isTrue);
      expect(player.notice, contains('回到原来'));
    });

    test(
      'an untrusted http media address is rejected before any sound',
      () async {
        final bad = playerFor(
          native,
          url: (s) => Uri.parse('http://insecure.example.test/$s'),
        );
        addTearDown(bad.dispose);
        await expectLater(
          bad.start(favorite(2), autoplay: true),
          throwsA(isA<LocalFailure>()),
        );
        expect(world.phonePlaying, isFalse);
        expect(bad.phase, LocalPhase.idle);
        expect(bad.hasMedia, isFalse);
      },
    );

    test(
      'audio interruption pauses; it resumes only if it was playing and the system says so',
      () async {
        await player.start(favorite(3), autoplay: true);
        await native.emit({'type': 'interruption', 'phase': 'began'});
        expect(player.phase, LocalPhase.paused);
        expect(player.isPlaying, isFalse);
        await native.emit({
          'type': 'interruption',
          'phase': 'ended',
          'shouldResume': false,
        });
        await settle();
        expect(player.isPlaying, isFalse);
        expect(world.phonePlaying, isFalse);
        await player.play();
        await native.emit({'type': 'interruption', 'phase': 'began'});
        await native.emit({
          'type': 'interruption',
          'phase': 'ended',
          'shouldResume': true,
        });
        await settle();
        expect(player.isPlaying, isTrue);
        // an interruption that began while paused must not start anything afterwards
        await player.pause();
        await native.emit({'type': 'interruption', 'phase': 'began'});
        await native.emit({
          'type': 'interruption',
          'phase': 'ended',
          'shouldResume': true,
        });
        await settle();
        expect(player.isPlaying, isFalse);
        expect(world.phonePlaying, isFalse);
      },
    );

    test(
      'headphones unplugged pauses and is not resumed automatically',
      () async {
        await player.start(favorite(3), autoplay: true);
        await native.emit({'type': 'routeLost'});
        expect(player.isPlaying, isFalse);
        expect(player.notice, contains('已暂停'));
      },
    );

    test(
      'a stray native playing event never creates sound the phone did not ask for',
      () async {
        await player.start(favorite(3), autoplay: false);
        await native.emit({
          'type': 'state',
          'state': 'playing',
          'positionMs': 5,
        });
        expect(player.phase, LocalPhase.paused);
        expect(player.isPlaying, isFalse);
      },
    );

    test(
      'heart continuation is requested once near the end, appended with stable prefix, and exhaustion stops',
      () async {
        var calls = 0;
        final heartPlayer = playerFor(
          native,
          heart: (queue) async {
            calls++;
            return HeartBatch(
              tracks: [...queue.tracks, track(9100), track(9101)],
              version: queue.version + 1,
              batchIndex: queue.batchIndex + 1,
            );
          },
        );
        addTearDown(heartPlayer.dispose);
        final heart = LocalQueue(
          source: 'netease_intelligence',
          queueId: 'q_intel',
          version: 10,
          tracks: [for (var i = 0; i < 4; i++) track(9000 + i)],
          complete: false,
          mode: 'intelligence',
        );
        await heartPlayer.start(heart, autoplay: true);
        await settle();
        expect(calls, 1);
        expect(heart.tracks.length, 6);
        expect(heart.version, 11);
        expect(heart.batchIndex, 1);
        heart.batchIndex = 5; // no further batches
        for (var i = 0; i < 6; i++) {
          await native.emit({'type': 'completed', 'positionMs': 1});
          await settle();
        }
        expect(heartPlayer.phase, LocalPhase.stopped);
        expect(heartPlayer.error, contains('心动'));
        expect(calls, 1);
      },
    );

    test('release silences, clears the queue and the audio session', () async {
      await player.start(favorite(3), autoplay: true);
      await player.release();
      expect(world.phonePlaying, isFalse);
      expect(player.queue, isNull);
      expect(player.phase, LocalPhase.idle);
      expect(native.of('stop'), isNotEmpty);
      await native.emit({'type': 'completed', 'positionMs': 1});
      await settle();
      expect(
        native.of('load').length,
        1,
        reason: 'a late completion cannot revive playback',
      );
    });

    test(
      'a release issued while a load is still pending ends silent with no queue',
      () async {
        native.holdLoad = Completer<void>();
        final first = player.start(favorite(3), index: 0, autoplay: true);
        await settle();
        final released = player.release();
        native.holdLoad!.complete();
        await first.catchError((Object _) {});
        await released;
        expect(world.phonePlaying, isFalse);
        expect(player.queue, isNull);
        expect(player.phase, LocalPhase.idle);
        expect(native.calls.last.method, 'stop');
      },
    );
  });
}
