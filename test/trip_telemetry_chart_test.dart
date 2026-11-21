import 'package:flutter_test/flutter_test.dart';
import 'package:myyaris_ios/api/trips_page.dart';

void main() {
  test('TripTelemetrySeries computes speed and acceleration from trip points', () {
    final series = TripTelemetrySeries.fromPoints([
      {
        'latitude': 35.6812,
        'longitude': 139.7671,
        'speed_kmh': 0.0,
        'recorded_at': '2026-11-22T00:00:00Z',
      },
      {
        'latitude': 35.6815,
        'longitude': 139.7671,
        'speed_kmh': 36.0,
        'recorded_at': '2026-11-22T00:00:10Z',
      },
      {
        'latitude': 35.6820,
        'longitude': 139.7671,
        'speed_kmh': 18.0,
        'recorded_at': '2026-11-22T00:00:20Z',
      },
    ]);

    expect(series.speedsKmh.length, 3);
    expect(series.maxSpeedKmh, 36.0);
    expect(series.avgSpeedKmh, 18.0);
    expect(series.accelsMs2.length, 2);
    // 0 -> 36 km/h (+10 m/s) in 10s = +1.0 m/s^2
    expect(series.accelsMs2[0].value, closeTo(1.0, 0.01));
    // 36 -> 18 km/h (-5 m/s) in 10s = -0.5 m/s^2
    expect(series.accelsMs2[1].value, closeTo(-0.5, 0.01));
    expect(series.maxAccelMs2, closeTo(1.0, 0.01));
    expect(series.minAccelMs2, closeTo(-0.5, 0.01));
  });
}
