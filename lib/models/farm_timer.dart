/// Lifecycle state of a running timer, derived from the clock.
enum TimerStatus { growing, ready, overdue }

/// A timer for something the player planted. All instants are stored as
/// absolute UTC timestamps so they survive restarts and timezone changes.
class FarmTimer {
  FarmTimer({
    required this.id,
    required this.notificationId,
    required this.itemName,
    required this.category,
    required this.plantedAtUtc,
    required this.readyAtUtc,
    required this.growMinutes,
    double? regrowMinutes,
    this.label,
    this.quantity = 1,
    this.witherMinutes,
    this.totalCycles = 1,
    this.repeating = false,
    this.cycle = 1,
    this.preferredClimate = false,
    this.watered = false,
    this.farmhand = false,
    this.witherCustom = false,
  }) : regrowMinutes = regrowMinutes ?? growMinutes;

  final String id;

  /// 31-bit int id used for the platform notification.
  final int notificationId;
  final String itemName;

  /// Category group name (FarmCategory.name).
  final String category;
  final String? label;
  final int quantity;

  final DateTime plantedAtUtc;
  final DateTime readyAtUtc;

  /// Effective minutes used for the initial growth (after climate bonus or
  /// manual override).
  final double growMinutes;

  /// Minutes until the next harvest after harvesting (harvest interval).
  final double regrowMinutes;

  /// Minutes after ready until wither/death, if known (item data or the
  /// player's own value, see [witherCustom]).
  final double? witherMinutes;

  /// [witherMinutes] was entered by the player rather than taken from data.
  final bool witherCustom;

  /// Harvest limit (null = unlimited when [repeating]).
  final int? totalCycles;

  /// Whether the item can be harvested again after the first harvest.
  final bool repeating;

  /// Current harvest number, 1-based.
  final int cycle;

  final bool preferredClimate;

  /// Watered at planting (first growth shortened).
  final bool watered;

  /// Planted on a farmhand plot (first growth lengthened).
  final bool farmhand;

  DateTime? get witherAtUtc =>
      witherMinutes == null ? null : readyAtUtc.add(Duration(milliseconds: (witherMinutes! * 60000).round()));

  bool get hasMoreCycles {
    if (totalCycles != null && totalCycles! > 1) return cycle < totalCycles!;
    return repeating && totalCycles == null;
  }

  /// "2/3", "4/∞", or null for single-harvest items.
  String? get cycleLabel {
    if (totalCycles != null && totalCycles! > 1) return '$cycle/$totalCycles';
    if (repeating && totalCycles == null) return '$cycle/∞';
    return null;
  }

  static const _keep = Object();

  /// Copy with changes. Pass `label: null` to clear the farm name.
  FarmTimer copyWith({
    DateTime? plantedAtUtc,
    DateTime? readyAtUtc,
    int? cycle,
    int? notificationId,
    Object? label = _keep,
  }) => FarmTimer(
    id: id,
    notificationId: notificationId ?? this.notificationId,
    itemName: itemName,
    category: category,
    label: identical(label, _keep) ? this.label : label as String?,
    quantity: quantity,
    plantedAtUtc: plantedAtUtc ?? this.plantedAtUtc,
    readyAtUtc: readyAtUtc ?? this.readyAtUtc,
    growMinutes: growMinutes,
    regrowMinutes: regrowMinutes,
    witherMinutes: witherMinutes,
    totalCycles: totalCycles,
    repeating: repeating,
    cycle: cycle ?? this.cycle,
    preferredClimate: preferredClimate,
    watered: watered,
    farmhand: farmhand,
    witherCustom: witherCustom,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'notificationId': notificationId,
    'itemName': itemName,
    'category': category,
    'label': label,
    'quantity': quantity,
    'plantedAtUtc': plantedAtUtc.toUtc().toIso8601String(),
    'readyAtUtc': readyAtUtc.toUtc().toIso8601String(),
    'growMinutes': growMinutes,
    'regrowMinutes': regrowMinutes,
    'witherMinutes': witherMinutes,
    'totalCycles': totalCycles,
    'repeating': repeating,
    'cycle': cycle,
    'preferredClimate': preferredClimate,
    'watered': watered,
    'farmhand': farmhand,
    'witherCustom': witherCustom,
  };

  factory FarmTimer.fromJson(Map<String, dynamic> j) => FarmTimer(
    id: j['id'] as String,
    notificationId: (j['notificationId'] as num).toInt(),
    itemName: j['itemName'] as String,
    category: (j['category'] as String?) ?? 'other',
    label: j['label'] as String?,
    quantity: (j['quantity'] as num?)?.toInt() ?? 1,
    plantedAtUtc: DateTime.parse(j['plantedAtUtc'] as String).toUtc(),
    readyAtUtc: DateTime.parse(j['readyAtUtc'] as String).toUtc(),
    growMinutes: (j['growMinutes'] as num).toDouble(),
    regrowMinutes: (j['regrowMinutes'] as num?)?.toDouble(),
    witherMinutes: (j['witherMinutes'] as num?)?.toDouble(),
    totalCycles: j.containsKey('totalCycles') ? (j['totalCycles'] as num?)?.toInt() : 1,
    repeating: (j['repeating'] as bool?) ?? false,
    cycle: (j['cycle'] as num?)?.toInt() ?? 1,
    preferredClimate: (j['preferredClimate'] as bool?) ?? false,
    watered: (j['watered'] as bool?) ?? false,
    farmhand: (j['farmhand'] as bool?) ?? false,
    witherCustom: (j['witherCustom'] as bool?) ?? false,
  );
}
