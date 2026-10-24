/// Catalog groups shown in the UI. Raw data categories (e.g. `seed_bundle`,
/// `fruit_tree`, `livestock_pen`) are folded into these four groups; the raw
/// value is kept on [FarmItem.rawCategory] for display.
enum FarmCategory {
  crops('Crops'),
  trees('Trees'),
  livestock('Livestock'),
  other('Other');

  const FarmCategory(this.label);
  final String label;

  static FarmCategory parse(Object? raw) {
    final s = (raw ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    const crops = {
      'crop',
      'crops',
      'seed',
      'seeds',
      'seed_bundle',
      'seed_bundles',
      'greenhouse',
      'greenhouses',
      'mushroom',
      'mushrooms',
      'vegetable',
      'herb',
      'herbs',
      'grain',
    };
    const trees = {'tree', 'trees', 'fruit_tree', 'fruit_trees', 'woodlot', 'woodlots', 'sapling', 'saplings'};
    const livestock = {
      'livestock',
      'livestock_pen',
      'livestock_pens',
      'pen',
      'pens',
      'coop',
      'coops',
      'beehive',
      'animal',
      'animals',
    };
    if (crops.contains(s)) return FarmCategory.crops;
    if (trees.contains(s)) return FarmCategory.trees;
    if (livestock.contains(s)) return FarmCategory.livestock;
    if (s.startsWith('crop') || s.startsWith('seed')) return FarmCategory.crops;
    if (s.contains('tree') || s.startsWith('woodlot') || s.startsWith('sapling')) return FarmCategory.trees;
    if (s.startsWith('livestock') || s.startsWith('animal') || s.contains('pen') || s.contains('coop')) {
      return FarmCategory.livestock;
    }
    return FarmCategory.other; // aquafarm, special/event, unknown
  }
}

/// "seed_bundle" -> "Seed bundle".
String prettyCategory(String raw) {
  final s = raw.replaceAll('_', ' ').trim();
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// What kind of thing an item is, for watering / farmhand modifiers
/// (see data/RESEARCH.md "Watering" and "Farmhands" rows).
enum PlantKind {
  /// Single seed/spore planted on a farm.
  plant,

  /// Seed (or spore) bundle.
  bundle,

  /// Sapling / tree / woodlot.
  sapling,

  /// Livestock and pens/coops/cages.
  livestock,

  /// Greenhouses, aquafarm items, Experia patches, etc.: no data on whether
  /// watering/farmhand apply, so both are hidden.
  unknown;

  static PlantKind classify(String? rawCategory, String name) {
    final c = (rawCategory ?? '').trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    final n = name.toLowerCase();
    final isBundle = n.contains('bundle');
    switch (c) {
      case 'seed_bundle':
        return PlantKind.bundle;
      case 'crop':
      case 'crops':
      case 'mushroom':
      case 'mushrooms':
        return isBundle ? PlantKind.bundle : PlantKind.plant;
      case 'tree':
      case 'fruit_tree':
      case 'woodlot':
        return PlantKind.sapling;
      case 'livestock':
      case 'livestock_pen':
        return PlantKind.livestock;
      case 'greenhouse':
      case 'aquafarm':
        return PlantKind.unknown;
    }
    // special / event / unrecognised categories: infer from the name.
    if (isBundle) return PlantKind.bundle;
    if (n.contains('sapling') || n.contains('tree') || n.contains('woodlot')) return PlantKind.sapling;
    if (n.contains('seed') || n.contains('spore') || n.contains('crop')) return PlantKind.plant;
    if (RegExp(r'\b(cow|sheep|goat|chick|chicken|duck|goose|pig|yata|bear|pen|coop|cage)\b').hasMatch(n)) {
      return PlantKind.livestock;
    }
    return PlantKind.unknown;
  }
}

/// One plantable/raisable item loaded from assets/farm_items.json.
///
/// Parsing is lenient: numbers may be strings, `source` may be a string or a
/// list, unknown extra fields are ignored, and most fields may be null.
class FarmItem {
  const FarmItem({
    required this.name,
    required this.category,
    required this.growTimeMinutes,
    this.rawCategory,
    this.subcategory,
    this.itemId,
    this.baseGrowTimeMinutes,
    this.harvestCycles = 1,
    this.harvestIntervalMinutes,
    this.witherOrDeathMinutes,
    this.climate,
    this.notes,
    this.sources = const [],
    this.archerageConfirmed,
  });

  /// Multiplier for planting in the preferred/native climate (~30% faster).
  /// Source: ArcheAge community guides; NOT verified on ArcheRage.
  static const preferredClimateMultiplier = 0.7;

  final String name;
  final FarmCategory category;
  final String? rawCategory;
  final String? subcategory;
  final int? itemId;

  /// Minutes from planting until ready (ArcheRage effective value,
  /// non-native climate, unwatered).
  final double growTimeMinutes;

  /// Vanilla/client value before ArcheRage's faster growth, if known.
  final double? baseGrowTimeMinutes;

  /// Harvest limit: 1 = single harvest, N = N harvests, null = unlimited
  /// repeating harvests (when [harvestIntervalMinutes] is set).
  final int? harvestCycles;

  /// Minutes between repeat harvests (fruit, milk, etc.), if repeating.
  final double? harvestIntervalMinutes;

  /// Minutes after ready before it withers/dies (often unknown -> null).
  final double? witherOrDeathMinutes;

  /// Raw climate text, e.g. "Temperate", "Any", "Zone-locked: Ahnimar".
  final String? climate;
  final String? notes;
  final List<String> sources;
  final bool? archerageConfirmed;

  /// Repeats after the first harvest.
  bool get isRepeating => harvestIntervalMinutes != null || (harvestCycles != null && harvestCycles! > 1);

  bool get isMultiHarvest => isRepeating;

  /// Minutes until the next harvest after harvesting.
  double get regrowMinutes => harvestIntervalMinutes ?? growTimeMinutes;

  /// True when a specific climate gives a growth bonus (not "Any"/"None"
  /// and not a zone-lock).
  bool get hasClimateBonus {
    final c = climate?.trim().toLowerCase();
    if (c == null || c.isEmpty) return false;
    if (const {'any', 'all', 'none', 'n/a', '-'}.contains(c)) return false;
    return !c.startsWith('zone');
  }

  PlantKind get plantKind => PlantKind.classify(rawCategory, name);

  /// First-growth multiplier when watered, or null if watering doesn't apply.
  /// Official ArcheAge values (single plants/saplings -10%, seed bundles
  /// -20%), unverified on ArcheRage.
  double? get wateredMultiplier => switch (plantKind) {
    PlantKind.plant || PlantKind.sapling => 0.9,
    PlantKind.bundle => 0.8,
    PlantKind.livestock || PlantKind.unknown => null,
  };

  /// First-growth multiplier on a farmhand plot, or null if unknown.
  /// ArcheRage-confirmed: plants +20%, bundles +10%, saplings/livestock 1.0.
  double? get farmhandMultiplier => switch (plantKind) {
    PlantKind.plant => 1.2,
    PlantKind.bundle => 1.1,
    PlantKind.sapling || PlantKind.livestock => 1.0,
    PlantKind.unknown => null,
  };

  bool get isExampleData => (notes ?? '').toUpperCase().contains('EXAMPLE DATA');

  String get categoryLabel => rawCategory == null ? category.label : prettyCategory(rawCategory!);

  static double? _num(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  static bool? _bool(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    if (s == 'true' || s == 'yes' || s == '1') return true;
    if (s == 'false' || s == 'no' || s == '0') return false;
    return null;
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is List) {
      final parts = v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty);
      return parts.isEmpty ? null : parts.join(', ');
    }
    final s = v.toString().trim();
    return s.isEmpty || s.toLowerCase() == 'null' ? null : s;
  }

  static List<String> _list(Object? v) {
    if (v == null) return const [];
    if (v is List) return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList(growable: false);
    final s = v.toString().trim();
    return s.isEmpty ? const [] : [s];
  }

  /// Returns null if the entry is unusable (no name or grow time), so one
  /// bad row never crashes the app.
  static FarmItem? tryFromJson(Map<String, dynamic> json) {
    final name = _str(json['name']);
    final grow = _num(json['growTimeMinutes']);
    if (name == null || grow == null || grow <= 0) return null;
    final cycles = _num(json['harvestCycles']);
    final interval = _num(json['harvestIntervalMinutes']);
    final wither = _num(json['witherOrDeathMinutes']);
    return FarmItem(
      name: name,
      category: FarmCategory.parse(json['category']),
      rawCategory: _str(json['category']),
      subcategory: _str(json['subcategory']),
      itemId: _num(json['itemId'])?.toInt(),
      growTimeMinutes: grow,
      baseGrowTimeMinutes: _num(json['baseGrowTimeMinutes']),
      // Missing/null cycles: unlimited if repeating, otherwise single.
      harvestCycles: cycles == null || cycles < 1 ? (interval != null ? null : 1) : cycles.round(),
      harvestIntervalMinutes: interval == null || interval <= 0 ? null : interval,
      witherOrDeathMinutes: wither == null || wither <= 0 ? null : wither,
      climate: _str(json['climate']),
      notes: _str(json['notes']),
      sources: _list(json['source']),
      archerageConfirmed: _bool(json['archerageConfirmed']),
    );
  }
}
