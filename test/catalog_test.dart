import 'dart:io';

import 'package:archeragefarmtimer/models/farm_item.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('category mapping folds data categories into 4 groups', () {
    expect(FarmCategory.parse('crop'), FarmCategory.crops);
    expect(FarmCategory.parse('seed_bundle'), FarmCategory.crops);
    expect(FarmCategory.parse('greenhouse'), FarmCategory.crops);
    expect(FarmCategory.parse('mushroom'), FarmCategory.crops);
    expect(FarmCategory.parse('fruit_tree'), FarmCategory.trees);
    expect(FarmCategory.parse('woodlot'), FarmCategory.trees);
    expect(FarmCategory.parse('livestock_pen'), FarmCategory.livestock);
    expect(FarmCategory.parse('Livestock'), FarmCategory.livestock);
    expect(FarmCategory.parse('aquafarm'), FarmCategory.other);
    expect(FarmCategory.parse('special'), FarmCategory.other);
    expect(FarmCategory.parse(null), FarmCategory.other);
  });

  test('parses real-schema entry with extra fields and source array', () {
    final items = CatalogService.parse('''[
      {"name":"Apple Tree","category":"fruit_tree","subcategory":null,"itemId":123,
       "growTimeMinutes":"360","baseGrowTimeMinutes":720,"harvestCycles":null,
       "harvestIntervalMinutes":120,"baseHarvestIntervalMinutes":240,
       "witherOrDeathMinutes":null,"climate":"Temperate","notes":"n",
       "source":["https://a","https://b"],"archerageConfirmed":false},
      {"name":"","growTimeMinutes":5},
      {"name":"No time"},
      "garbage"
    ]''');
    expect(items, hasLength(1));
    final a = items.single;
    expect(a.category, FarmCategory.trees);
    expect(a.categoryLabel, 'Fruit tree');
    expect(a.itemId, 123);
    expect(a.growTimeMinutes, 360);
    expect(a.harvestCycles, isNull);
    expect(a.isRepeating, isTrue);
    expect(a.regrowMinutes, 120);
    expect(a.witherOrDeathMinutes, isNull);
    expect(a.sources, ['https://a', 'https://b']);
    expect(a.archerageConfirmed, isFalse);
    expect(a.hasClimateBonus, isTrue);
  });

  test('single-harvest defaults', () {
    final i = FarmItem.tryFromJson({'name': 'Potato', 'growTimeMinutes': 30, 'climate': 'Any'})!;
    expect(i.harvestCycles, 1);
    expect(i.isRepeating, isFalse);
    expect(i.hasClimateBonus, isFalse);
  });

  test('search and group', () {
    final items = CatalogService.parse(File('test/fixtures/example_farm_items.json').readAsStringSync());
    expect(items.every((i) => i.isExampleData), isTrue);
    expect(CatalogService.search(items, 'apple').map((i) => i.name), ['Example Apple Tree']);
    expect(CatalogService.search(items, 'ARID').map((i) => i.name), ['Example Thunderstruck Sapling']);
    expect(CatalogService.search(items, '  '), items);
    final groups = CatalogService.group(items);
    expect(groups.keys, FarmCategory.values);
  });

  test('bundled asset parses without dropping entries', () {
    final raw = File('assets/farm_items.json').readAsStringSync();
    final items = CatalogService.parse(raw);
    expect(items, isNotEmpty);
    expect(RegExp(r'"name"').allMatches(raw).length, items.length);
  });
}
