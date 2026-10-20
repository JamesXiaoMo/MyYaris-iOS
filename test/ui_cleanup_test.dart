import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/pages.dart';

import 'widget_test.dart' show FixtureSession;

void main() {
  testWidgets(
    'track detail keeps normal quality/lyrics but exposes no probe or raw ids',
    (tester) async {
      final session = FixtureSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TrackPage(
            session: session,
            track: {
              'id': 123,
              'song_id': 123,
              'track_id': 'netease_123',
              'title': '测试歌曲',
              'artist': '测试歌手',
              'album': '测试专辑',
              'source': 'netease',
            },
            onPlay: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('发送到车机播放'), findsOneWidget);
      expect(find.text('音质'), findsOneWidget);
      expect(find.text('查看歌词'), findsOneWidget);
      for (final removed in [
        '读取曲目详情',
        '检查流媒体首块',
        'CDN',
        'song_id',
        'HTTP',
        'Range',
      ]) {
        expect(find.textContaining(removed), findsNothing);
      }
    },
  );

  testWidgets(
    'search page ignores verification diagnostics and does not print source/raw ids',
    (tester) async {
      final session = FixtureSession()
        ..musicDiagnostic = {
          'search': 'fixture',
          'total': 3,
          'error': 'fixture diagnostic',
        };
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(home: MusicSearchPage(session: session)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('只读诊断'), findsNothing);
      expect(find.textContaining('fixture diagnostic'), findsNothing);
      expect(find.textContaining('来源：'), findsNothing);
      expect(find.textContaining('song_id'), findsNothing);
    },
  );

  testWidgets(
    'api result dialog shows a short structured summary, never the raw JSON',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showApiResult(
                context,
                '缓存状态',
                () async => {
                  'cache_dir': '/private/example/cache',
                  'total_files': 12,
                  'total_bytes': 1024 * 1024,
                  'max_bytes': 4 * 1024 * 1024,
                  'usage_percentage': 25.0,
                },
              ),
              child: const Text('打开结果'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开结果'));
      await tester.pumpAndSettle();
      expect(find.textContaining('缓存文件：12'), findsOneWidget);
      expect(find.textContaining('使用率：25.0%'), findsOneWidget);
      expect(find.textContaining('cache_dir'), findsNothing);
      expect(find.textContaining('/private/example'), findsNothing);
      expect(find.textContaining('{'), findsNothing);
    },
  );
}
