import 'farm_item.dart';

/// A timer the player has set up in the start sheet but not started yet
/// (the "Add to list" queue). Times are counted from when the list is
/// started, exactly like a single "Start timer" tap.
class PendingTimer {
  const PendingTimer({
    required this.item,
    this.label,
    this.quantity = 1,
    this.preferredClimate = false,
    this.watered = false,
    this.farmhand = false,
    this.overrideGrowMinutes,
    this.witherMinutes,
    this.plantedAgo = Duration.zero,
    this.zone,
  });

  final FarmItem item;
  final String? label;
  final int quantity;
  final bool preferredClimate;
  final bool watered;
  final bool farmhand;
  final double? overrideGrowMinutes;
  final double? witherMinutes;
  final Duration plantedAgo;
  final String? zone;

  /// Farm name as it will be saved (trimmed, empty = none).
  String? get farm {
    final t = label?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}
