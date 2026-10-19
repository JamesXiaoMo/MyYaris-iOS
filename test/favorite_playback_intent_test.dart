import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/backend.dart';
import 'package:myyaris_ios/api/favorite_playback_intent.dart';

void main() {
  test(
    'true intelligence preserves upstream order and removes repeated song IDs',
    () {
      final tracks = requireTrueIntelligence({
        'mode': 'intelligence',
        'songs': [
          {'id': 101, 'title': '推荐A'},
          {'id': 102},
          {'id': 101},
        ],
      });
      expect(tracks.map((t) => t['id']), [101, 102]);
    },
  );
  test(
    'similar-song fallback and empty response cannot masquerade as intelligence',
    () {
      for (final mode in ['simi_fallback', 'empty', null]) {
        expect(
          () => requireTrueIntelligence({
            'mode': mode,
            'songs': [
              {'id': 101},
            ],
          }),
          throwsA(isA<ApiFailure>()),
        );
      }
    },
  );
  test(
    'malformed and oversized recommendation batches stop before any queue dispatch',
    () {
      for (final songs in [
        [],
        [
          {'id': 0},
        ],
        [
          {'id': '101'},
        ],
        [{}],
        ['invalid'],
        List.generate(101, (i) => {'id': i + 1}),
      ]) {
        expect(
          () =>
              requireTrueIntelligence({'mode': 'intelligence', 'songs': songs}),
          throwsA(isA<ApiFailure>()),
        );
      }
    },
  );
}
