import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:ploggr/features/spots/spot_map.dart';

void main() {
  test('a stationary or empty track keeps the close-up camera', () {
    const fix = (latitude: 17.0, longitude: 78.0);
    expect(routeBounds([]), isNull);
    expect(routeBounds([fix, fix]), isNull);
  });

  test('the route view includes intermediate fixes across the dateline', () {
    final bounds = routeBounds([
      (latitude: 2, longitude: 179.8),
      (latitude: 2.1, longitude: -179.95),
      (latitude: 1.9, longitude: 179.9),
    ])!;
    expect(bounds.contains(const LatLng(2.1, -179.95)), isTrue);
    expect(bounds.contains(const LatLng(1.9, 179.9)), isTrue);
    expect(bounds.contains(const LatLng(2, 0)), isFalse);
  });
}
