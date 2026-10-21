import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/local_player.dart';
import 'package:myyaris_ios/api/playback_hub.dart';
import 'local_playback_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late PlaybackHub hub;
  setUp(() {
    h = Harness.create();
    hub = h.session.hub;
    hub.pollInterval = const Duration(milliseconds: 1);
    hub.commandTimeout = const Duration(milliseconds: 25);
    hub.statusTimeout = const Duration(milliseconds: 25);
  });
  tearDown(() async {
    expect(h.world.doubleOutput, isFalse, reason: h.world.timeline.join(', '));
    await hub.local.release();
    h.dispose();
  });
  Map<String, dynamic> song(int id) => h.backend.trackJson(id, id - 1000);
  Future<void> onPhone() => hub.selectTarget(PlaybackTarget.phone);
  void car({bool playing = true, String mode = 'shuffle'}) {
    h.backend.carShows(
      state: playing ? 'playing' : 'paused',
      song: 1090,
      queueId: 'q_fav_car',
      version: 41,
      source: 'netease_favorite',
      index: 90,
      position: 61000,
      mode: mode,
    );
  }

  test(
    'opening, lifecycle and websocket status produce no playback command or audio',
    () async {
      expect(hub.target, PlaybackTarget.car);
      await h.session.refresh();
      h.session.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'data': {...h.backend.car, 'status_seq': 200},
        }),
      );
      hub.onLifecycle(AppLifecycleState.paused);
      hub.onLifecycle(AppLifecycleState.resumed);
      expect(h.native.calls, isEmpty);
      expect(h.backend.posted, isEmpty);
    },
  );

  test(
    'phone cold play traverses all 137 tracks over HTTP then the real native channel',
    () async {
      await onPhone();
      await hub.command('resume');
      expect(hub.local.queue!.tracks.length, 137);
      expect(h.backend.log.where((v) => v.contains('/local/queue')).length, 3);
      expect(h.backend.posted, isEmpty);
      expect(
        h.native.lastUrl.toString(),
        '$origin/api/v1/music/netease/stream/1000',
      );
      expect(h.native.lastHeaders['Authorization'], 'Bearer fixture-token');
      expect(h.world.phonePlaying, isTrue);
      final loads = h.native.of('load').length;
      await hub.command('seek', {'seek_ms': 61000});
      await hub.command('pause');
      await hub.chooseMode('shuffle');
      expect(hub.local.queue!.shuffleOrder.length, 137);
      expect(hub.view.positionMs, 61000);
      expect(h.native.of('load').length, loads);
      expect(h.world.phonePlaying, isFalse);
    },
  );

  for (final playing in [true, false]) {
    test(
      'car to phone preserves full queue, song, cursor, progress and ${playing ? 'playing' : 'paused'} state',
      () async {
        car(playing: playing);
        await onPhone();
        expect(hub.target, PlaybackTarget.phone);
        expect(hub.handoff!.status, HandoffStatus.done);
        expect(hub.local.queue!.source, 'netease_favorite');
        expect(hub.local.queue!.tracks.length, 137);
        expect(hub.local.queue!.index, 90);
        expect(hub.local.queue!.mode, 'shuffle');
        expect(hub.view.songId, 1090);
        expect(hub.view.positionMs, 61000);
        expect(h.world.phonePlaying, playing);
        expect(h.world.carPlaying, isFalse);
        expect(h.native.of('load').single.arguments['autoplay'], isFalse);
        expect(h.backend.commandActions, ['pause']);
        if (playing) {
          expect(
            h.world.timeline.indexOf('car:silent'),
            lessThan(h.world.timeline.indexOf('phone:sound')),
          );
        }
      },
    );

    test(
      'phone to car preserves queue/source/mode/progress and ${playing ? 'playing' : 'paused'} state',
      () async {
        await onPhone();
        await hub.playFavorite(song(1090));
        await hub.chooseMode('shuffle');
        await hub.command('seek', {'seek_ms': 61000});
        if (!playing) await hub.command('pause');
        await hub.selectTarget(PlaybackTarget.car);
        expect(hub.handoff!.status, HandoffStatus.done);
        expect(hub.target, PlaybackTarget.car);
        expect(hub.local.queue, isNull);
        expect(h.backend.car['queue_source'], 'netease_favorite');
        expect(h.backend.car['current_index'], 90);
        expect(h.backend.car['applied_mode'], 'shuffle');
        expect(h.backend.car['position_ms'], 61000);
        expect(h.backend.carQueues.values.last.length, 137);
        expect(h.backend.posted.first['params']['autoplay'], isFalse);
        expect(
          h.backend.commandActions,
          playing ? ['play_track', 'resume'] : ['play_track'],
        );
        expect(h.world.carPlaying, playing);
        if (playing) {
          expect(
            h.world.timeline.indexOf('phone:silent'),
            lessThan(h.world.timeline.indexOf('car:sound')),
          );
        }
      },
    );
  }

  test(
    'round trip keeps the immutable favorite snapshot even when catalog has changed',
    () async {
      car();
      await onPhone();
      h.backend.favoriteCount = 50;
      await hub.selectTarget(PlaybackTarget.car);
      expect(h.backend.car['current_track_id'], 'netease_1090');
      expect(h.backend.carQueues.values.any((q) => q.length == 137), isTrue);
      expect(h.backend.posted.last['action'], 'resume');
    },
  );

  test(
    'car websocket pushes cannot overwrite phone actual state, progress, mode or pending',
    () async {
      await onPhone();
      await hub.playFavorite(song(1090));
      await hub.command('seek', {'seek_ms': 61000});
      car(playing: false, mode: 'list_loop');
      h.session.consumeRealtime(
        jsonEncode({
          'type': 'status_update',
          'data': {
            ...h.backend.car,
            'current_track_id': 'netease_1001',
            'position_ms': 123,
            'status_seq': 900,
          },
        }),
      );
      expect(hub.view.songId, 1090);
      expect(hub.view.positionMs, 61000);
      expect(hub.local.queue!.mode, 'list_loop');
      expect(h.session.playback['position_ms'], 123);
      // Simulating an external car start is outside a handoff; silence it before the next phone play.
      await hub.command('pause');
      await hub.command('resume');
      expect(h.world.carPlaying, isFalse);
    },
  );

  test(
    'legacy queue_v2 car is refused before a silent prepare can accidentally make sound',
    () async {
      await onPhone();
      await hub.playFavorite(song(1090));
      h.backend.car['capabilities'] = ['queue_v2'];
      await hub.selectTarget(PlaybackTarget.car);
      expect(hub.handoff!.status, HandoffStatus.failed);
      expect(hub.handoff!.message, contains('更新车机'));
      expect(h.backend.posted, isEmpty);
      expect(h.world.phonePlaying, isTrue);
    },
  );

  test(
    'prepare failure preserves phone song and sound without sending resume',
    () async {
      await onPhone();
      await hub.playFavorite(song(1090));
      h.backend.policies['play_track'] = CommandPolicy.fail;
      await hub.selectTarget(PlaybackTarget.car);
      expect(hub.handoff!.status, HandoffStatus.failed);
      expect(h.world.phonePlaying, isTrue);
      expect(hub.view.songId, 1090);
      expect(h.backend.commandActions, ['play_track']);
    },
  );

  test(
    'unknown prepare retries the same command id and does not create another prepare',
    () async {
      await onPhone();
      await hub.playFavorite(song(1090));
      h.backend.policies['play_track'] = CommandPolicy.hang;
      await hub.selectTarget(PlaybackTarget.car);
      final id = hub.handoff!.commandId('prepare');
      expect(hub.handoff!.status, HandoffStatus.needsConfirmation);
      expect(h.world.phonePlaying, isTrue);
      await h.native.emit({'type': 'position', 'positionMs': 64000});
      h.backend.lateAck(id);
      await hub.retryHandoff();
      expect(h.backend.commands.keys.where((k) => k.contains('prepare')), [id]);
      expect(hub.target, PlaybackTarget.car);
    },
  );

  test(
    'unknown car start leaves phone silent, retry observes a late ACK idempotently',
    () async {
      await onPhone();
      await hub.playFavorite(song(1090));
      h.backend.policies['resume'] = CommandPolicy.hang;
      await hub.selectTarget(PlaybackTarget.car);
      final id = hub.handoff!.commandId('start');
      expect(hub.handoff!.status, HandoffStatus.needsConfirmation);
      expect(h.world.phonePlaying, isFalse);
      await expectLater(hub.command('resume'), throwsA(isA<ApiFailure>()));
      h.backend.lateAck(id);
      await hub.retryHandoff();
      expect(hub.target, PlaybackTarget.car);
      expect(h.backend.commands.keys.where((k) => k.contains('start')), [id]);
      expect(h.world.phonePlaying, isFalse);
    },
  );

  test(
    'cancel with an unresolved car resume cannot re-enable phone sound',
    () async {
      await onPhone();
      await hub.playFavorite(song(1090));
      h.backend.policies['resume'] = CommandPolicy.hang;
      await hub.selectTarget(PlaybackTarget.car);
      final id = hub.handoff!.commandId('start');
      await hub.cancelHandoff();
      await expectLater(hub.command('resume'), throwsA(isA<ApiFailure>()));
      expect(h.world.phonePlaying, isFalse);
      h.backend.lateAck(id);
      await hub.command('resume');
      expect(h.world.carPlaying, isFalse);
      expect(h.world.phonePlaying, isTrue);
    },
  );

  for (final policy in [CommandPolicy.fail, CommandPolicy.hang]) {
    test('car pause ${policy.name} never starts the prepared phone', () async {
      car();
      h.backend.policies['pause'] = policy;
      await onPhone();
      expect(hub.target, PlaybackTarget.car);
      expect(h.world.phonePlaying, isFalse);
      expect(h.world.carPlaying, isTrue);
      if (policy == CommandPolicy.hang) {
        final id = hub.handoff!.commandId('pause');
        h.backend.lateAck(id);
        await hub.retryHandoff();
        expect(hub.target, PlaybackTarget.phone);
        expect(h.world.phonePlaying, isTrue);
      }
    });
  }

  test('phone preparation failure leaves the car unchanged', () async {
    car();
    h.native.failAllLoads = true;
    await onPhone();
    expect(hub.handoff!.status, HandoffStatus.failed);
    expect(h.world.carPlaying, isTrue);
    expect(h.backend.posted, isEmpty);
  });

  test(
    'failed snapshot import preserves source and never degrades to a single track',
    () async {
      car();
      h.backend.adoptFails = true;
      await onPhone();
      expect(hub.handoff!.status, HandoffStatus.failed);
      expect(h.world.carPlaying, isTrue);
      expect(hub.local.queue, isNull);
    },
  );

  test(
    'mismatched paginated version fails before native load or command',
    () async {
      await onPhone();
      h.backend.corruptPage = true;
      await expectLater(
        hub.playFavorite(song(1090)),
        throwsA(isA<ApiFailure>()),
      );
      expect(h.native.of('load'), isEmpty);
      expect(h.backend.posted, isEmpty);
    },
  );

  test(
    'search single ends stopped; explicitly selecting shuffle returns to the full favorites',
    () async {
      await onPhone();
      await hub.playSingle(song(9999));
      expect(hub.local.queue!.source, 'single_track');
      await h.native.emit({'type': 'completed'});
      await settle();
      expect(hub.local.phase, LocalPhase.stopped);
      expect(h.world.phonePlaying, isFalse);
      await hub.chooseMode('shuffle');
      expect(hub.local.queue!.tracks.length, 137);
      expect(hub.local.queue!.isFavorite, isTrue);
      expect(h.world.phonePlaying, isFalse);
    },
  );

  test(
    'true heart uses the local HTTP scope; upstream failure preserves the previous queue',
    () async {
      await onPhone();
      await hub.playFavorite(song(1000));
      final previous = hub.local.queue;
      h.backend.rejectHeart = true;
      await expectLater(
        hub.chooseMode('intelligence'),
        throwsA(isA<ApiFailure>()),
      );
      expect(hub.local.queue, same(previous));
      expect(h.world.phonePlaying, isTrue);
      h.backend.rejectHeart = false;
      await hub.chooseMode('intelligence');
      expect(hub.local.queue!.isHeart, isTrue);
      expect(hub.local.queue!.mode, 'intelligence');
      expect(h.backend.posted, isEmpty);
      await hub.selectTarget(PlaybackTarget.car);
      expect(h.backend.car['queue_source'], 'netease_intelligence');
      expect(h.backend.car['applied_mode'], 'intelligence');
    },
  );

  test(
    'standard user may search a single but cannot read Owner favorites or heart',
    () async {
      h.session.userProfile = {'role': 'user', 'has_device_control': true};
      await onPhone();
      await expectLater(
        hub.playFavorite(song(1090)),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        hub.chooseMode('intelligence'),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        h.backend.log.where(
          (r) =>
              r.contains('/local/queue') || r.contains('/local/intelligence'),
        ),
        isEmpty,
      );
      await hub.playSingle(song(1234));
      expect(h.world.phonePlaying, isTrue);
    },
  );

  test(
    'native buffering is displayed as buffering until actual playback arrives',
    () async {
      await onPhone();
      h.native.buffering = true;
      await hub.playSingle(song(1234));
      expect(hub.view.stateLabel, '缓冲中');
      expect(hub.view.playing, isFalse);
      expect(h.world.phonePlaying, isFalse);
      h.native.buffering = false;
      h.world.setPhonePlaying(true);
      await h.native.emit({'type': 'state', 'state': 'playing'});
      expect(hub.view.playing, isTrue);
    },
  );

  test(
    'account reset fences delayed HTTP queue pages before loading audio',
    () async {
      await onPhone();
      h.backend.holdQueue = Completer<void>();
      final result = hub.playFavorite(song(1090));
      final assertion = expectLater(result, throwsA(isA<ApiFailure>()));
      await settle();
      final old = hub.sessionId;
      h.session.resetAccountCaches();
      h.session.api.token = 'next-account';
      h.backend.holdQueue!.complete();
      await assertion;
      await settle();
      expect(hub.sessionId, isNot(old));
      expect(hub.local.queue, isNull);
      expect(h.world.phonePlaying, isFalse);
      expect(h.native.of('load'), isEmpty);
    },
  );

  test(
    'account reset cancels a native load immediately and ignores late completion',
    () async {
      await onPhone();
      h.native.holdLoad = Completer<void>();
      final result = hub.playSingle(song(1090));
      final assertion = expectLater(result, throwsA(anything));
      await settle();
      h.session.resetAccountCaches();
      expect(h.world.phonePlaying, isFalse);
      h.native.holdLoad!.complete();
      await assertion;
      await settle();
      expect(hub.local.queue, isNull);
      expect(h.world.phonePlaying, isFalse);
      await h.native.emit({'type': 'completed'});
      await settle();
      expect(h.native.of('load').length, 1);
    },
  );
  test(
    'saved backend origin change clears phone media with the same device id',
    () async {
      await onPhone();
      await hub.playSingle(song(1234));
      final old = hub.sessionId;
      await h.session.saveConnection(
        'https://other.example.test',
        h.session.api.deviceId,
      );
      await settle();
      expect(hub.local.queue, isNull);
      expect(hub.sessionId, isNot(old));
      expect(h.world.phonePlaying, isFalse);
      expect(h.session.api.baseUrl, 'https://other.example.test');
    },
  );
}
