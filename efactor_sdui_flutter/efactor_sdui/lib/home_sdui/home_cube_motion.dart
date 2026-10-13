/// Web Home cube timing helpers. Keep these aligned with
/// `app_home_page.js` (`computeCubeAnimOffset`, `getCubeElapsedSeconds`).
double computeCubeAnimOffsetSeconds({
  required String id,
  required int index,
  required int totalCount,
  required double speedSec,
  int faceCount = 4,
}) {
  final speed = speedSec <= 0 ? 16.0 : speedSec;
  final count = totalCount < 1 ? 1 : totalCount;
  final slot = index < 0 ? 0 : index;
  var hash = 0;
  for (final code in id.codeUnits) {
    hash += code;
  }
  final faces = faceCount < 1 ? 4 : faceCount;
  final segment = speed / faces;
  final indexSpread = (slot / count) * speed;
  final hashSpread = ((hash % 997) / 997) * speed * 0.88;
  final microSpread = ((hash % 17) / 17) * segment * 0.95;
  final saltSpread = ((hash % 43) / 43) * segment * 0.35;
  return -((indexSpread + hashSpread + microSpread + saltSpread) % speed);
}

double cubeElapsedCycle({
  required double speedSec,
  required double delaySec,
  DateTime? now,
}) {
  final speed = speedSec <= 0 ? 16.0 : speedSec;
  final clock = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000.0;
  var elapsed = (clock - delaySec) % speed;
  if (elapsed < 0) elapsed += speed;
  return elapsed / speed;
}
