import 'dart:io';

import 'package:archeragefarmtimer/models/farm_item.dart';
import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_math.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

FarmItem _item(String cat, String name, {double grow = 100, String? climate}) =>
    FarmItem(name: name, category: FarmCategory.parse(cat), rawCategory: cat, growTimeMinutes: grow, climate: climate);

void main() {
  group('PlantKind.classify', () {
    final cases = <(String, String, PlantKind)>[
      ('crop', 'Potato Eyes', PlantKind.plant),
      ('seed_bundle', 'Rice Seed Bundle', PlantKind.bundle),
      ('mushroom', 'Mushroom Spore', PlantKind.plant),
      ('mushroom', 'Mushroom Spore Bundle', PlantKind.bundle),
      ('tree', 'Pine Sapling', PlantKind.sapling),
      ('fruit_tree', 'Apple Sapling', PlantKind.sapling),
      ('woodlot', 'Pine Woodlot', PlantKind.sapling),
      ('livestock', 'Goat', PlantKind.livestock),
      ('livestock_pen', 'Dairy Pen', PlantKind.livestock),
      ('greenhouse', 'Aloe Greenhouse', PlantKind.unknown),
      ('aquafarm', 'Pearl Oyster Bundle', PlantKind.unknown),
      ('special', 'Yellow Yam Seed Bundle', PlantKind.bundle),
      ('special', 'Wish Tree Sapling', PlantKind.sapling),
      ('special', 'Ruby Gembloom Seed', PlantKind.plant),
      ('special', 'Cornucopia Cow', PlantKind.livestock),
      ('special', 'Experia Pumpkin Patch', PlantKind.unknown),
    ];
    for (final (cat, name, kind) in cases) {
      test('$cat / $name -> $kind', () => expect(PlantKind.classify(cat, name), kind));
    }
  });

  group('multipliers', () {
    test('watered: plants & saplings -10%, bundles -20%, n/a otherwise', () {
      expect(_item('crop', 'Potato').wateredMultiplier, 0.9);
      expect(_item('tree', 'Pine Sapling').wateredMultiplier, 0.9);
      expect(_item('seed_bundle', 'Rice Seed Bundle').wateredMultiplier, 0.8);
      expect(_item('livestock', 'Goat').wateredMultiplier, isNull);
      expect(_item('greenhouse', 'Aloe Greenhouse').wateredMultiplier, isNull);
    });
    test('farmhand: plants +20%, bundles +10%, saplings/livestock unchanged', () {
      expect(_item('crop', 'Potato').farmhandMultiplier, 1.2);
      expect(_item('seed_bundle', 'Rice Seed Bundle').farmhandMultiplier, 1.1);
      expect(_item('fruit_tree', 'Apple Sapling').farmhandMultiplier, 1.0);
      expect(_item('livestock', 'Goat').farmhandMultiplier, 1.0);
      expect(_item('aquafarm', 'Kelp').farmhandMultiplier, isNull);
    });
  });

  group('effectiveGrowMinutes combinations (multiplicative)', () {
    final crop = _item('crop', 'Rice', climate: 'Tropical');
    final bundle = _item('seed_bundle', 'Rice Seed Bundle', climate: 'Tropical');
    final sapling = _item('tree', 'Pine Sapling');
    final goat = _item('livestock', 'Goat');

    test('single modifiers', () {
      expect(TimerMath.effectiveGrowMinutes(crop, watered: true), closeTo(90, 1e-9));
      expect(TimerMath.effectiveGrowMinutes(crop, farmhand: true), closeTo(120, 1e-9));
      expect(TimerMath.effectiveGrowMinutes(bundle, watered: true), closeTo(80, 1e-9));
      expect(TimerMath.effectiveGrowMinutes(bundle, farmhand: true), closeTo(110, 1e-9));
      expect(TimerMath.effectiveGrowMinutes(sapling, watered: true), closeTo(90, 1e-9));
      expect(TimerMath.effectiveGrowMinutes(sapling, farmhand: true), 100);
      expect(TimerMath.effectiveGrowMinutes(goat, watered: true, farmhand: true), 100);
    });
    test('climate x watered x farmhand', () {
      expect(
        TimerMath.effectiveGrowMinutes(crop, preferredClimate: true, watered: true, farmhand: true),
        closeTo(100 * 0.7 * 0.9 * 1.2, 1e-9),
      );
      expect(
        TimerMath.effectiveGrowMinutes(bundle, preferredClimate: true, watered: true, farmhand: true),
        closeTo(100 * 0.7 * 0.8 * 1.1, 1e-9),
      );
    });
    test('override ignores all modifiers', () {
      expect(TimerMath.effectiveGrowMinutes(crop, watered: true, farmhand: true, overrideMinutes: 33), 33);
    });
  });

  test('every bundled item has a classification; spot-check counts', () {
    final items = CatalogService.parse(File('assets/farm_items.json').readAsStringSync());
    final byKind = <PlantKind, int>{};
    for (final i in items) {
      byKind.update(i.plantKind, (v) => v + 1, ifAbsent: () => 1);
    }
    expect(byKind[PlantKind.bundle], greaterThanOrEqualTo(54));
    expect(byKind[PlantKind.livestock], greaterThanOrEqualTo(25));
    expect(byKind[PlantKind.unknown], greaterThanOrEqualTo(61)); // 40 greenhouses + 21 aquafarm
  });

  group('controller + persistence', () {
    setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());
    final now = DateTime.utc(2026, 10, 17, 9);
    TimerController make() =>
        TimerController(repository: TimerRepository(), notifications: NoopNotificationService(), clock: () => now);

    test('flags saved with each timer and only when they had an effect', () async {
      final c = make();
      await c.load();
      final a = await c.startTimer(_item('crop', 'Potato'), watered: true, farmhand: true);
      final b = await c.startTimer(_item('tree', 'Pine Sapling'), watered: true, farmhand: true);
      final g = await c.startTimer(_item('livestock', 'Goat'), watered: true, farmhand: true);
      expect(a.readyAtUtc, now.add(TimerMath.minutes(100 * 0.9 * 1.2)));
      expect((a.watered, a.farmhand), (true, true));
      expect((b.watered, b.farmhand), (true, false));
      expect((g.watered, g.farmhand), (false, false));

      final reloaded = await TimerRepository().loadAll();
      final pa = reloaded.firstWhere((t) => t.id == a.id);
      expect((pa.watered, pa.farmhand), (true, true));
      expect(pa.readyAtUtc, a.readyAtUtc);
    });

    test('harvest regrow is not affected by watered/farmhand', () async {
      final c = make();
      await c.load();
      const apple = FarmItem(
        name: 'Apple Sapling',
        category: FarmCategory.trees,
        rawCategory: 'fruit_tree',
        growTimeMinutes: 100,
        harvestCycles: null,
        harvestIntervalMinutes: 50,
      );
      final t = await c.startTimer(apple, watered: true);
      expect(t.readyAtUtc, now.add(const Duration(minutes: 90)));
      final next = (await c.harvest(t.id))!;
      expect(next.readyAtUtc, now.add(const Duration(minutes: 50)));
      expect(next.watered, isTrue); // tag stays for reference
    });

    test('old saved timers without the new fields still load', () {
      final t = FarmTimer.fromJson({
        'id': 'old',
        'notificationId': 1,
        'itemName': 'Rice',
        'category': 'crops',
        'plantedAtUtc': '2026-10-17T00:00:00.000Z',
        'readyAtUtc': '2026-10-17T01:00:00.000Z',
        'growMinutes': 60,
      });
      expect((t.watered, t.farmhand), (false, false));
    });
  });
}
