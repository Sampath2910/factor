import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/home_sdui/home_cube_motion.dart';

void main() {
  test('cube stagger hash matches the web Home engine', () {
    // app_home_page.js computeCubeAnimOffset for id/index/count/speed.
    const id = 'ef-m-prime-card';
    var hash = 0;
    for (final code in id.codeUnits) {
      hash += code;
    }
    const speed = 16.0;
    const count = 11;
    const slot = 0;
    const segment = speed / 4;
    final indexSpread = (slot / count) * speed;
    final hashSpread = ((hash % 997) / 997) * speed * 0.88;
    final microSpread = ((hash % 17) / 17) * segment * 0.95;
    final saltSpread = ((hash % 43) / 43) * segment * 0.35;
    final expected =
        -((indexSpread + hashSpread + microSpread + saltSpread) % speed);

    expect(
      computeCubeAnimOffsetSeconds(
        id: id,
        index: 0,
        totalCount: 11,
        speedSec: 16,
      ),
      expected,
    );
  });

  test('different card ids get different stagger delays', () {
    final prime = computeCubeAnimOffsetSeconds(
      id: 'ef-m-prime-card',
      index: 0,
      totalCount: 11,
      speedSec: 16,
    );
    final mobile = computeCubeAnimOffsetSeconds(
      id: 'ef-m-mobile-card',
      index: 2,
      totalCount: 11,
      speedSec: 16,
    );
    expect(prime, isNot(mobile));
    expect(prime, lessThanOrEqualTo(0));
    expect(mobile, lessThanOrEqualTo(0));
  });

  test('web delay of 0 still produces a negative hash stagger', () {
    // app_home_page.js: phaseOffset 0 = auto stagger from tile id.
    final delay = computeCubeAnimOffsetSeconds(
      id: 'ef-m-deals-card',
      index: 3,
      totalCount: 11,
      speedSec: 16,
    );
    expect(delay, lessThan(0));
    expect(delay, greaterThanOrEqualTo(-16));
  });

  test('wall-clock elapsed wraps into a 0-1 cycle', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final cycle = cubeElapsedCycle(
      speedSec: 16,
      delaySec: -3.2,
      now: now,
    );
    expect(cycle, inInclusiveRange(0.0, 1.0));
  });
}
