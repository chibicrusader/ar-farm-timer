import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/farm_item.dart';
import '../models/zone.dart';

/// Loads and queries the bundled item catalog (assets/farm_items.json).
class CatalogService {
  CatalogService({AssetBundle? bundle, this.assetPath = defaultAsset}) : _bundle = bundle ?? rootBundle;

  static const defaultAsset = 'assets/farm_items.json';

  final AssetBundle _bundle;
  final String assetPath;

  Future<List<FarmItem>> load() async => parse(await _bundle.loadString(assetPath));

  static const zonesAsset = 'assets/zones.json';

  /// Zone -> climate map; empty (zone picker hidden) if missing or invalid.
  Future<List<Zone>> loadZones() async {
    try {
      return Zone.parseList(await _bundle.loadString(zonesAsset));
    } catch (_) {
      return const [];
    }
  }

  /// Parses the JSON array, silently skipping malformed entries.
  static List<FarmItem> parse(String source) {
    final decoded = jsonDecode(source);
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['items'] is List ? decoded['items'] as List : const []);
    final items = <FarmItem>[];
    for (final e in list) {
      if (e is Map) {
        final item = FarmItem.tryFromJson(Map<String, dynamic>.from(e));
        if (item != null) items.add(item);
      }
    }
    items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return items;
  }

  /// Case-insensitive search over name, category, climate and notes.
  static List<FarmItem> search(List<FarmItem> items, String query) {
    final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty) return items;
    return items.where((i) {
      final hay = [
        i.name,
        i.rawCategory ?? '',
        i.categoryLabel,
        i.category.label,
        i.subcategory ?? '',
        i.climate ?? '',
      ].join(' ').toLowerCase();
      return terms.every(hay.contains);
    }).toList();
  }

  /// Groups items by category in a fixed display order (empty groups omitted).
  static Map<FarmCategory, List<FarmItem>> group(List<FarmItem> items) {
    final map = {for (final c in FarmCategory.values) c: <FarmItem>[]};
    for (final i in items) {
      map[i.category]!.add(i);
    }
    map.removeWhere((_, v) => v.isEmpty);
    return map;
  }
}
