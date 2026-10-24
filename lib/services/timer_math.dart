import 'dart:math' as math;

import '../models/farm_item.dart';
import '../models/farm_timer.dart';

/// Pure, clock-injected timer calculations (unit tested).
class TimerMath {
  const TimerMath._();

  static Duration minutes(double m) => Duration(milliseconds: (m * 60000).round());

  /// First-growth minutes for a planting. A manual override wins outright.
  /// Otherwise the data value (ArcheRage time, non-native climate,
  /// unwatered, normal farm) is multiplied by each applicable modifier:
  ///
  ///   grow x climate(0.7) x watered(0.9 | 0.8) x farmhand(1.2 | 1.1 | 1.0)
  ///
  /// Modifiers that don't apply to the item (see [FarmItem]) are ignored.
  /// Repeat-harvest intervals are never modified.
  static double effectiveGrowMinutes(
    FarmItem item, {
    bool preferredClimate = false,
    bool watered = false,
    bool farmhand = false,
    double? overrideMinutes,
  }) {
    if (overrideMinutes != null && overrideMinutes > 0) return overrideMinutes;
    var m = item.growTimeMinutes;
    if (preferredClimate && item.hasClimateBonus) m *= FarmItem.preferredClimateMultiplier;
    if (watered && item.wateredMultiplier != null) m *= item.wateredMultiplier!;
    if (farmhand && item.farmhandMultiplier != null) m *= item.farmhandMultiplier!;
    return m;
  }

  static DateTime readyAt(DateTime plantedAt, double growMinutes) => plantedAt.toUtc().add(minutes(growMinutes));

  static TimerStatus status(FarmTimer t, DateTime now) {
    final n = now.toUtc();
    final wither = t.witherAtUtc;
    if (wither != null && !n.isBefore(wither)) return TimerStatus.overdue;
    if (!n.isBefore(t.readyAtUtc)) return TimerStatus.ready;
    return TimerStatus.growing;
  }

  /// Time until ready (negative once ready).
  static Duration remaining(FarmTimer t, DateTime now) => t.readyAtUtc.difference(now.toUtc());

  /// Time until wither/death, or null when the item has no wither data.
  static Duration? untilWither(FarmTimer t, DateTime now) => t.witherAtUtc?.difference(now.toUtc());

  /// When the "about to wither" warning fires: [leadMinutes] before the
  /// wither/death deadline, but never earlier than halfway between ready and
  /// the deadline (so a short wither window still gets a useful warning
  /// after the "ready" alert). null when off or the deadline is unknown.
  static DateTime? witherWarningAt(FarmTimer t, int leadMinutes) {
    final wither = t.witherAtUtc;
    final window = t.witherMinutes;
    if (leadMinutes <= 0 || wither == null || window == null || window <= 0) return null;
    final lead = math.min(leadMinutes.toDouble(), window / 2);
    return wither.subtract(minutes(lead));
  }

  /// Minutes between the warning and the deadline (for alert text).
  static int witherWarningLead(FarmTimer t, int leadMinutes) {
    final w = t.witherMinutes;
    if (w == null) return leadMinutes;
    return math.min(leadMinutes.toDouble(), w / 2).round();
  }

  /// Notification id for a timer's wither warning (distinct from the ready
  /// alert's id, still a positive 31-bit int).
  static int warningNotificationId(int readyId) {
    final w = readyId ^ 0x40000000;
    return w == 0 ? 0x7FFFFFFF : w;
  }

  /// Growth progress in [0, 1].
  static double progress(FarmTimer t, DateTime now) {
    final total = t.readyAtUtc.difference(t.plantedAtUtc).inMilliseconds;
    if (total <= 0) return 1;
    final done = now.toUtc().difference(t.plantedAtUtc).inMilliseconds;
    return (done / total).clamp(0.0, 1.0).toDouble();
  }

  /// Harvest a timer. Returns the restarted timer for the next cycle (ready
  /// after the harvest interval from [now]) or null when the item is finished
  /// and should be removed.
  static FarmTimer? harvest(FarmTimer t, DateTime now, {int? newNotificationId}) {
    if (!t.hasMoreCycles) return null;
    final planted = now.toUtc();
    return t.copyWith(
      plantedAtUtc: planted,
      readyAtUtc: readyAt(planted, t.regrowMinutes),
      cycle: t.cycle + 1,
      notificationId: newNotificationId,
    );
  }

  /// Soonest-ready first; ties broken by item name.
  static List<FarmTimer> sortBySoonest(Iterable<FarmTimer> timers) {
    final list = timers.toList();
    list.sort((a, b) {
      final c = a.readyAtUtc.compareTo(b.readyAtUtc);
      return c != 0 ? c : a.itemName.compareTo(b.itemName);
    });
    return list;
  }

  /// Compact countdown text, e.g. "2d 3h", "1h 05m", "4m 09s", "12s".
  static String formatDuration(Duration d) {
    var s = d.inSeconds.abs();
    final days = s ~/ 86400;
    s %= 86400;
    final h = s ~/ 3600;
    s %= 3600;
    final m = s ~/ 60;
    s %= 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (days > 0) return '${days}d ${h}h';
    if (h > 0) return '${h}h ${two(m)}m';
    if (m > 0) return '${m}m ${two(s)}s';
    return '${s}s';
  }

  /// Human grow time for the catalog, e.g. 90 -> "1h 30m", 0.5 -> "30s".
  static String formatMinutes(double m) {
    final d = minutes(m);
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    final total = d.inMinutes;
    final days = total ~/ 1440;
    final h = (total % 1440) ~/ 60;
    final mins = total % 60;
    final parts = <String>[if (days > 0) '${days}d', if (h > 0) '${h}h', if (mins > 0) '${mins}m'];
    return parts.isEmpty ? '0m' : parts.join(' ');
  }

  static final _rng = math.Random();

  /// Positive 31-bit id, safe for all notification backends.
  static int newNotificationId() => _rng.nextInt(0x7FFFFFFF - 1) + 1;
}
