import '../models/farm_item.dart';
import '../services/timer_math.dart';

/// "5 harvests, every 2h" / "unlimited harvests, every 12h".
String harvestText(FarmItem item) {
  final count = item.harvestCycles == null ? 'unlimited harvests' : '${item.harvestCycles} harvests';
  final every = item.harvestIntervalMinutes == null
      ? ''
      : ', every ${TimerMath.formatMinutes(item.harvestIntervalMinutes!)}';
  return '$count$every';
}
