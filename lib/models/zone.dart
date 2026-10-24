import 'dart:convert';

import 'farm_item.dart';

/// A map zone and its farming climate(s) (assets/zones.json).
class Zone {
  const Zone({
    required this.name,
    required this.continent,
    this.climates = const [],
    this.note,
    this.sources = const [],
    this.pvp,
  });

  final String name;
  final String continent;

  /// Normalised climate names ("Temperate", "Arid", "Tropical", "Subarctic").
  /// Empty when no reliable source gives the climate.
  final List<String> climates;
  final String? note;
  final List<String> sources;
  final bool? pvp;

  bool get climateKnown => climates.isNotEmpty;
  String get climateLabel => climates.isEmpty ? 'climate unknown' : climates.join(' + ');

  static String normalizeClimate(String raw) {
    final c = raw.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
    if (c == 'subarctic' || c == 'arctic') return 'Subarctic';
    if (c.isEmpty) return '';
    return c[0].toUpperCase() + c.substring(1);
  }

  /// Whether planting [item] here gets the preferred-climate bonus.
  /// null = can't tell (the item has no climate bonus, or the zone's climate is unknown).
  bool? matches(FarmItem item) {
    if (!item.hasClimateBonus) return null;
    final c = normalizeClimate(item.climate!);
    // "Auroria" items grow best anywhere on the Auroria continent.
    if (c == 'Auroria') return continent == 'Auroria';
    if (!climateKnown) return null;
    return climates.contains(c);
  }

  /// Zone a zone-locked item must be planted in ("Zone-locked: Silent Forest").
  static String? lockedZone(FarmItem item) {
    final c = item.climate?.trim();
    if (c == null || !c.toLowerCase().startsWith('zone-locked')) return null;
    final i = c.indexOf(':');
    return i < 0 ? null : c.substring(i + 1).trim();
  }

  static Zone? tryFromJson(Map<String, dynamic> j) {
    final name = j['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final rawClimates = j['climates'] ?? j['climate'];
    final parts = <String>[
      if (rawClimates is List)
        for (final c in rawClimates)
          if (c is String) c,
      if (rawClimates is String) ...rawClimates.split(RegExp(r'[/,+]')),
    ];
    final climates = [
      for (final c in parts)
        if (c.trim().isNotEmpty) normalizeClimate(c),
    ];
    return Zone(
      name: name.trim(),
      continent: (j['continent'] as String?)?.trim() ?? 'Other',
      climates: climates,
      note: j['note'] as String?,
      sources: [
        if (j['sources'] is List)
          for (final s in j['sources'] as List)
            if (s is String) s,
      ],
      pvp: j['pvp'] as bool?,
    );
  }

  /// Tolerant parser: accepts `{"zones": [...]}` or a bare list and skips bad entries.
  static List<Zone> parseList(String source) {
    final decoded = jsonDecode(source);
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['zones'] is List ? decoded['zones'] as List : const []);
    return [
      for (final e in list)
        if (e is Map) ?Zone.tryFromJson(Map<String, dynamic>.from(e)),
    ];
  }
}
