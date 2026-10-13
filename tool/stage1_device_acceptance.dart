// One-shot test target. Runs the existing app/pages on the real iPhone.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:myyaris_ios/main.dart' as production;
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/pages.dart';
import 'package:myyaris_ios/verification/favorites_evidence.dart'
    show saveEvidence;

List<Element> tree([Element? root]) {
  final nodes = <Element>[];
  void visit(Element e) {
    nodes.add(e);
    e.visitChildElements(visit);
  }

  final start = root ?? WidgetsBinding.instance.rootElement;
  if (start != null) visit(start);
  return nodes;
}

Future<void> until(bool Function() condition, {int seconds = 20}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('页面/车机回报等待超时');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  await WidgetsBinding.instance.endOfFrame;
}

Map<String, dynamic> snapshot(BackendSession session) => {
  for (final key in [
    'device_id',
    'current_track_id',
    'playback_state',
    'position_ms',
    'duration_ms',
    'software_volume',
    'loop_mode',
    'last_heartbeat_at',
    'updated_at',
  ])
    if (session.playback.containsKey(key)) key: session.playback[key],
};
Future<void> main() async {
  production.main();
  await Future<void>.delayed(const Duration(seconds: 2));
  final claimed = await KeychainStore.channel.invokeMethod<bool>(
    'claimStage1Run',
    'real_phone_1357375695_20261013_2',
  );
  if (claimed != true) return;
  final proof = <String, dynamic>{
    'mode': 'real_iPhone_existing_page_callbacks',
    'started_at_utc': DateTime.now().toUtc().toIso8601String(),
    'song_id': 1357375695,
    'user_confirmed_idle': true,
    'audio_audibility': 'user_confirmation_required',
    'commands': <Map<String, dynamic>>[],
    'completed': false,
    'running': true,
  };
  BackendSession? session;
  dynamic panel;
  double? originalGain;
  String? originalLoop;
  bool touched = false;
  Future<void> save() => saveEvidence(
    'stage1-live-proof.json',
    Uint8List.fromList(utf8.encode(jsonEncode(proof))),
  );
  Future<void> photo(String name) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await KeychainStore.channel.invokeMethod<void>('captureHome', name);
  }

  Future<void> command(
    String label,
    void Function() callback,
    bool Function(Map p) expected,
  ) async {
    final s = session!;
    final old = s.lastCommandState['command_id'];
    callback();
    await until(
      () => s.lastCommandState['command_id'] != old && !s.commandPending,
      seconds: 30,
    );
    final id = s.lastCommandState['command_id'];
    final record = <String, dynamic>{'step': label, 'command_id': id};
    (proof['commands'] as List).add(record);
    proof['phase'] = label;
    await save();
    final deadline = DateTime.now().add(const Duration(seconds: 16));
    while (DateTime.now().isBefore(deadline)) {
      await s.refreshCommandState();
      await s.refresh();
      final state = s.lastCommandState['status'];
      record['lifecycle'] = state;
      record['car_status'] = snapshot(s);
      if (state == 'failed' || state == 'expired') {
        record['error_code'] = s.lastCommandState['error_code'];
        await save();
        throw StateError('$label 车机回执$state');
      }
      if ((state == 'applied' || state == 'executed') &&
          expected(s.playback) &&
          s.heartbeatFresh) {
        record['state_readback_passed'] = true;
        await save();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    await save();
    throw StateError('$label 未获得终态及匹配的真实状态');
  }

  try {
    await until(
      () => tree().any(
        (e) => e is StatefulElement && e.widget is production.YarisShell,
      ),
    );
    final shell =
        tree().firstWhere(
              (e) => e is StatefulElement && e.widget is production.YarisShell,
            )
            as StatefulElement;
    session = (shell.state as dynamic).session as BackendSession;
    await until(() => session!.api.configured);
    final tab =
        tree().firstWhere((e) => e.widget.key == const ValueKey('tab-2')).widget
            as InkWell;
    tab.onTap!();
    await Future<void>.delayed(const Duration(seconds: 1));
    final musicElement =
        tree().firstWhere((e) => e is StatefulElement && e.widget is MusicPage)
            as StatefulElement;
    final dynamic music = musicElement.state;
    await until(() => !session!.refreshing);
    await session.refresh();
    final initial = snapshot(session);
    proof['initial_car_status'] = initial;
    if (!session.heartbeatFresh) throw StateError('车机心跳未知/陈旧，未开始播控');
    if (['playing', 'buffering'].contains(initial['playback_state']) &&
        initial['current_track_id'] != 'netease_1357375695') {
      throw StateError('正在播放非待测曲目，未触碰');
    }
    final gain = initial['software_volume'];
    if (gain is! num || !gain.isFinite || gain < 0 || gain > 1) {
      throw StateError('原增益未知，不采用默认值');
    }
    originalGain = gain.toDouble();
    originalLoop = initial['loop_mode'] as String?;
    final earlyPanel =
        tree(musicElement).firstWhere(
              (e) => e is StatefulElement && e.widget is PlaybackPanel,
            )
            as StatefulElement;
    panel = earlyPanel.state;
    if (['playing', 'buffering'].contains(initial['playback_state'])) {
      await command(
        'prepare_pause_existing_test_song',
        () => panel.command(panel.context, 'pause'),
        (p) => p['playback_state'] == 'paused',
      );
    }
    final input =
        tree(musicElement)
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-input'),
                )
                .widget
            as TextField;
    input.controller!.text = '海阔天空';
    final search =
        tree(musicElement)
                .firstWhere(
                  (e) => e.widget.key == const ValueKey('music-preview'),
                )
                .widget
            as FilledButton;
    search.onPressed!();
    await until(() => music.busy == false, seconds: 40);
    if (music.error != null) throw StateError('手机页面搜索失败');
    final tracks = List<Map<String, dynamic>>.from(music.tracks as List);
    final chosen = tracks
        .where((t) => session!.api.songId(t) == 1357375695)
        .toList();
    if (chosen.isEmpty) throw StateError('手机实际搜索结果本页未找到指定ID，未用直接URL替代');
    proof['search'] = {
      'keyword': '海阔天空',
      'total': music.total,
      'selected_song': {
        'song_id': session.api.songId(chosen.first),
        'source': chosen.first['source'],
        'title': chosen.first['title'],
      },
    };
    proof['phase'] = 'search_complete';
    await save();
    final panelElement =
        tree(musicElement).firstWhere(
              (e) => e is StatefulElement && e.widget is PlaybackPanel,
            )
            as StatefulElement;
    panel = panelElement.state;
    touched = true;
    await command(
      'gain_0.15_before_play',
      () => panel.command(panel.context, 'set_volume', {'volume': .15}),
      (p) =>
          p['software_volume'] is num &&
          ((p['software_volume'] as num) - .15).abs() < .01,
    );
    touched = true;
    Element? caption;
    for (var i = 0; i < 25 && caption == null; i++) {
      final matches = tree(musicElement)
          .where(
            (e) =>
                e.widget is Text &&
                ((e.widget as Text).data ?? '').contains('song_id：1357375695'),
          )
          .toList();
      if (matches.isNotEmpty) {
        caption = matches.first;
        break;
      }
      final scroll =
          tree(musicElement).firstWhere(
                (e) => e is StatefulElement && e.widget is Scrollable,
              )
              as StatefulElement;
      final state = scroll.state as ScrollableState;
      state.position.jumpTo(
        (state.position.pixels + 300).clamp(0, state.position.maxScrollExtent),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (caption == null) throw StateError('搜索结果按钮未渲染，未直接绕过选歌页面');
    await Scrollable.ensureVisible(
      caption,
      alignment: .25,
      duration: const Duration(milliseconds: 200),
    );
    await photo('stage1-phone-search.png');
    Element? card;
    caption.visitAncestorElements((e) {
      if (e.widget is Material) {
        card = e;
        return false;
      }
      return true;
    });
    if (card == null) throw StateError('真实搜索结果卡片不存在');
    final button =
        tree(card).firstWhere((e) => e.widget is FilledButton).widget
            as FilledButton;
    await command(
      'play_search_result_1357375695',
      () => button.onPressed!(),
      (p) =>
          p['current_track_id'] == 'netease_1357375695' &&
          p['playback_state'] == 'playing',
    );
    proof['stream_probe'] = session.lastTrackProbe;
    final before = snapshot(session);
    await Future<void>.delayed(const Duration(seconds: 3));
    await session.refresh();
    final after = snapshot(session);
    proof['natural_progress'] = {
      'before': before,
      'after': after,
      'delta_ms':
          (after['position_ms'] as num) - (before['position_ms'] as num),
    };
    if (after['current_track_id'] != 'netease_1357375695' ||
        after['playback_state'] != 'playing' ||
        ((after['position_ms'] as num) - (before['position_ms'] as num)) <
            1000) {
      throw StateError('position未自然增长或播放器未保持playing');
    }
    await Scrollable.ensureVisible(
      panelElement,
      duration: const Duration(milliseconds: 200),
    );
    await photo('stage1-phone-playing.png');
    proof['phase'] = 'natural_progress_passed';
    await save();
    void volume(double v) {
      final slider =
          tree(panelElement).where((e) => e.widget is Slider).last.widget
              as Slider;
      slider.onChanged!(v);
      slider.onChangeEnd!(v);
    }

    await command(
      'gain_0.20',
      () => volume(.20),
      (p) =>
          p['software_volume'] is num &&
          ((p['software_volume'] as num) - .20).abs() < .01,
    );
    void seek(double v) {
      final slider =
          tree(panelElement).firstWhere((e) => e.widget is Slider).widget
              as Slider;
      slider.onChanged!(v);
      slider.onChangeEnd!(v);
    }

    for (final ms in [10000, 30000]) {
      await command(
        'seek_$ms',
        () => seek(ms.toDouble()),
        (p) =>
            p['position_ms'] is num &&
            ((p['position_ms'] as num) - ms).abs() < 8000,
      );
    }
    for (final mode in ['one', 'all', 'off']) {
      await command('loop_$mode', () {
        final dropdown =
            tree(panelElement)
                    .firstWhere(
                      (e) => e.widget is DropdownButtonFormField<String>,
                    )
                    .widget
                as DropdownButtonFormField<String>;
        dropdown.onChanged!(mode);
      }, (p) => p['loop_mode'] == mode);
    }
    await photo('stage1-phone-controls.png');
    proof['completed'] = true;
  } catch (e) {
    proof['failure'] = e is ApiFailure ? e.message : e.toString();
  } finally {
    if (touched && session != null && panel != null) {
      try {
        await command(
          'cleanup_pause',
          () => panel.command(panel.context, 'pause'),
          (p) => p['playback_state'] == 'paused',
        );
        proof['pause_cleanup'] = true;
      } catch (e) {
        proof['pause_cleanup'] = false;
        proof['pause_error'] = e.toString();
      }
      try {
        await command(
          'restore_gain',
          () => panel.command(panel.context, 'set_volume', {
            'volume': originalGain,
          }),
          (p) =>
              p['software_volume'] is num &&
              ((p['software_volume'] as num) - originalGain!).abs() < .01,
        );
        proof['gain_restored'] = true;
      } catch (e) {
        proof['gain_restored'] = false;
        proof['gain_restore_error'] = e.toString();
      }
      if (['one', 'all', 'off'].contains(originalLoop)) {
        try {
          await command(
            'restore_loop',
            () => panel.command(panel.context, 'set_loop', {
              'loop_mode': originalLoop,
            }),
            (p) => p['loop_mode'] == originalLoop,
          );
          proof['loop_restored'] = true;
        } catch (e) {
          proof['loop_restored'] = false;
        }
      }
    }
    proof['finished_at_utc'] = DateTime.now().toUtc().toIso8601String();
    proof['running'] = false;
    await save();
    try {
      await photo('stage1-phone-completed.png');
    } catch (_) {}
  }
}
