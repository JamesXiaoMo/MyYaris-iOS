import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/music_queue_contract.dart';

Map<String, dynamic> fixture(
  int offset,
  int count, {
  int version = 1,
  bool established = true,
}) => {
  'queue_id': 'fixture-queue',
  'queue_version': version,
  'source': 'netease_favorite',
  'total': 65,
  'is_complete': established,
  'offset': offset,
  'limit': 50,
  'has_more': offset + count < 65,
  'tracks': List.generate(
    count,
    (i) => {
      'id': offset + i + 1,
      'track_id': 'netease_${offset + i + 1}',
      'queue_index': offset + i,
      'stream_url': 'http://127.0.0.1/example',
    },
  ),
};
void main() {
  test(
    'metadata queue consumes beyond first thirty, no direct stream forwarding',
    () {
      final queue = MusicQueueAccumulator();
      queue.add(MusicQueuePage.fromJson(fixture(0, 50)));
      expect(queue.complete, false);
      queue.add(MusicQueuePage.fromJson(fixture(50, 15)));
      expect(queue.complete, true);
      expect(queue.tracks.length, 65);
      expect(queue.tracks.last['queue_index'], 64);
      expect(queue.tracks.any((t) => t.containsKey('stream_url')), false);
    },
  );
  test('different versions cannot mix even when ID is unchanged', () {
    final queue = MusicQueueAccumulator()
      ..add(MusicQueuePage.fromJson(fixture(0, 50)));
    expect(
      () => queue.add(MusicQueuePage.fromJson(fixture(50, 15, version: 2))),
      throwsA(isA<ApiFailure>()),
    );
    expect(queue.tracks.length, 50);
    expect(queue.complete, false);
  });
  test('unestablished full list is not presented as complete', () {
    final queue = MusicQueueAccumulator()
      ..add(MusicQueuePage.fromJson(fixture(0, 50, established: false)))
      ..add(MusicQueuePage.fromJson(fixture(50, 15, established: false)));
    expect(queue.complete, false);
  });
  test(
    'bad has_more, gaps, unknown sources and empty nonterminal pages fail closed',
    () {
      final gap = fixture(0, 1);
      (gap['tracks'] as List).first['queue_index'] = 3;
      for (final bad in [
        gap,
        {...fixture(0, 1), 'has_more': false},
        {...fixture(0, 1), 'source': 'local_samples'},
        fixture(0, 0),
      ]) {
        expect(() => MusicQueuePage.fromJson(bad), throwsA(isA<ApiFailure>()));
      }
    },
  );
}
