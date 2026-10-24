import 'dart:convert';
import 'dart:io';

import 'package:archeragefarmtimer/app.dart';
import 'package:archeragefarmtimer/models/farm_item.dart';
import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/models/zone.dart';
import 'package:archeragefarmtimer/services/alert_settings.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:archeragefarmtimer/services/farm_store.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/push_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_math.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes.dart';

FarmTimer _timer({double? wither, String? label, int id = 42, DateTime? ready}) => FarmTimer(
  id: 't$id',
  notificationId: id,
  itemName: 'Ruby Gembloom Seed',
  category: 'crops',
  label: label,
  plantedAtUtc: DateTime.utc(2026, 10, 17, 8),
  readyAtUtc: ready ?? DateTime.utc(2026, 10, 17, 10),
  growMinutes: 120,
  witherMinutes: wither,
);

const _temperateItem = FarmItem(
  name: 'Lily Seed',
  category: FarmCategory.crops,
  growTimeMinutes: 86,
  climate: 'Temperate',
);
const _aridItem = FarmItem(name: 'Aloe Seed', category: FarmCategory.crops, growTimeMinutes: 100, climate: 'Arid');
const _anyItem = FarmItem(name: 'Potato Eyes', category: FarmCategory.crops, growTimeMinutes: 5, climate: 'Any');
const _auroriaItem = FarmItem(
  name: 'Silver Lily Seed',
  category: FarmCategory.crops,
  growTimeMinutes: 780,
  climate: 'Auroria',
);
const _lockedItem = FarmItem(
  name: 'Amaranth Seed',
  category: FarmCategory.crops,
  growTimeMinutes: 900,
  climate: 'Zone-locked: Silent Forest',
);

const _zonesJson = '''
{"zones":[
 {"name":"Two Crowns","continent":"Nuia","climates":["Temperate"]},
 {"name":"Solis Headlands","continent":"Haranya","climates":["Arid"]},
 {"name":"Heedmar","continent":"Auroria","climates":["Temperate","SubArctic"]},
 {"name":"Exeloch","continent":"Auroria","climates":[]},
 {"continent":"broken"},
 {"name":"Old Format","climate":"Tropical/Arid"}
]}''';

void main() {
  group('wither warning math', () {
    test('lead before deadline, capped at half the wither window', () {
      final t = _timer(wither: 1440);
      expect(t.witherAtUtc, DateTime.utc(2026, 10, 18, 10));
      expect(TimerMath.witherWarningAt(t, 30), DateTime.utc(2026, 10, 18, 9, 30));
      final short = _timer(wither: 20);
      expect(TimerMath.witherWarningAt(short, 30), DateTime.utc(2026, 10, 17, 10, 10));
      expect(TimerMath.witherWarningLead(short, 30), 10);
    });

    test('no warning without wither data or when off', () {
      expect(TimerMath.witherWarningAt(_timer(), 30), isNull);
      expect(TimerMath.witherWarningAt(_timer(wither: 60), 0), isNull);
    });

    test('warning notification id differs and stays a positive 31-bit int', () {
      for (final id in [1, 42, 0x3FFFFFFF, 0x40000000, 0x7FFFFFFE]) {
        final w = TimerMath.warningNotificationId(id);
        expect(w, isNot(id));
        expect(w, greaterThan(0));
        expect(w, lessThanOrEqualTo(0x7FFFFFFF));
      }
    });

    test('push service sends ready + warning alerts, honours the lead', () {
      var lead = 30;
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      final p = PushAlertService(prefs: SharedPreferencesAsync(), witherLead: () => lead);
      final now = DateTime.utc(2026, 10, 17, 9);
      final t = _timer(wither: 1440, label: 'Home');
      final alerts = p.alertsFor(t, now);
      expect(alerts.map((a) => a['id']), ['t42:42', 't42:42:wither']);
      expect(alerts[1]['fireAt'], '2026-10-18T09:30:00.000Z');
      expect(alerts[1]['title'], 'Ruby Gembloom Seed will wither soon!');
      expect(alerts[1]['body'], contains('at Home within 30m'));
      lead = 0;
      expect(p.alertsFor(t, now).length, 1);
      // Ready already passed: only the (future) warning remains.
      lead = 30;
      expect(p.alertsFor(t, DateTime.utc(2026, 10, 17, 11)).single['id'], 't42:42:wither');
    }, skip: false);
  });

  group('zones', () {
    final zones = Zone.parseList(_zonesJson);
    Zone z(String n) => zones.firstWhere((e) => e.name == n);

    test('tolerant parse, normalised climates', () {
      expect(zones.map((e) => e.name), ['Two Crowns', 'Solis Headlands', 'Heedmar', 'Exeloch', 'Old Format']);
      expect(z('Heedmar').climates, ['Temperate', 'Subarctic']);
      expect(z('Old Format').climates, ['Tropical', 'Arid']);
      expect(z('Exeloch').climateLabel, 'climate unknown');
    });

    test('climate matching', () {
      expect(z('Two Crowns').matches(_temperateItem), isTrue);
      expect(z('Solis Headlands').matches(_temperateItem), isFalse);
      expect(z('Solis Headlands').matches(_aridItem), isTrue);
      expect(z('Heedmar').matches(_temperateItem), isTrue); // dual climate
      expect(z('Exeloch').matches(_temperateItem), isNull); // unknown climate
      expect(z('Two Crowns').matches(_anyItem), isNull); // no bonus
      expect(z('Heedmar').matches(_auroriaItem), isTrue);
      expect(z('Two Crowns').matches(_auroriaItem), isFalse);
      expect(Zone.lockedZone(_lockedItem), 'Silent Forest');
      expect(Zone.lockedZone(_temperateItem), isNull);
    });

    test('bundled assets/zones.json is valid and covers item climates', () {
      final zones = Zone.parseList(File('assets/zones.json').readAsStringSync());
      expect(zones.length, greaterThanOrEqualTo(35));
      const allowed = {'Temperate', 'Arid', 'Tropical', 'Subarctic'};
      for (final zone in zones) {
        expect(allowed.containsAll(zone.climates), isTrue, reason: zone.name);
        expect(zone.sources, isNotEmpty, reason: zone.name);
      }
      for (final c in allowed) {
        expect(zones.any((e) => e.climates.contains(c)), isTrue, reason: c);
      }
      // Zone-locked items name zones that exist in the map.
      final items = CatalogService.parse(File('assets/farm_items.json').readAsStringSync());
      final names = zones.map((e) => e.name.toLowerCase()).toSet();
      for (final i in items) {
        final lock = Zone.lockedZone(i);
        if (lock != null) expect(names, contains(lock.toLowerCase()), reason: i.name);
      }
    });
  });

  group('controller: wither warnings and farms', () {
    late DateTime now;
    late RecordingService notes;
    setUp(() {
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      now = DateTime.utc(2026, 10, 17, 8);
      notes = RecordingService(NotificationMode.inAppOnly);
    });
    TimerController make() => TimerController(
      repository: TimerRepository(),
      notifications: notes,
      clock: () => now,
      alertSettings: AlertSettings(),
      farms: FarmStore(),
    );

    test('custom wither time is stored and triggers an in-app warning', () async {
      final c = make();
      await c.load();
      final alerts = <TimerAlert>[];
      c.alerts.listen(alerts.add);
      final t = await c.startTimer(_temperateItem, label: 'Home', witherMinutes: 120, zone: 'Two Crowns');
      expect(t.witherMinutes, 120);
      expect(t.witherCustom, isTrue);
      expect(c.farms.zoneFor('Home'), 'Two Crowns');
      expect(c.farms.lastZone, 'Two Crowns');
      // Item without data and no custom value: no wither time.
      final plain = await c.startTimer(_temperateItem);
      expect(plain.witherMinutes, isNull);
      expect(plain.witherCustom, isFalse);

      now = t.readyAtUtc.add(const Duration(minutes: 1));
      c.tick();
      now = t.witherAtUtc!.subtract(const Duration(minutes: 29));
      c.tick();
      await Future<void>.delayed(Duration.zero);
      expect(alerts.where((a) => a.witherWarning).single.timer.id, t.id);
      expect(notes.log, contains('warn:${t.id}'));
      // No duplicate warning on the next tick.
      c.tick();
      await Future<void>.delayed(Duration.zero);
      expect(alerts.where((a) => a.witherWarning).length, 1);
      c.dispose();
    });

    test('changing the lead resyncs alerts', () async {
      final c = make();
      await c.load();
      notes.log.clear();
      await c.setWitherLead(60);
      expect(c.alertSettings.witherLeadMinutes, 60);
      expect(notes.log, contains('sync:0'));
      expect(await SharedPreferencesAsync().getInt(AlertSettings.kWitherLead), 60);
    });

    test('farm names, rename and delete', () async {
      final c = make();
      await c.load();
      final a = await c.startTimer(_temperateItem, label: 'Home');
      await c.startTimer(_aridItem, label: 'Home');
      final b = await c.startTimer(_anyItem, label: 'Lake plot');
      expect(c.farmNames, ['Home', 'Lake plot']);

      await c.renameFarm('Home', 'Main farm');
      expect(c.timers.where((t) => t.label == 'Main farm').length, 2);
      expect(c.farmNames, ['Lake plot', 'Main farm']);
      expect(c.farms.farms, isNot(contains('Home')));

      notes.log.clear();
      await c.deleteFarm('Lake plot'); // keep timers
      expect(c.timers.firstWhere((t) => t.id == b.id).label, isNull);
      expect(c.farmNames, ['Main farm']);

      await c.deleteFarm('Main farm', deleteTimers: true);
      expect(c.timers.map((t) => t.id), [b.id]);
      // the farm's timers are cancelled in one batch call
      expect(notes.log.where((l) => l.startsWith('cancelAll:') && l.contains(a.id)), hasLength(1));

      // Persisted: a fresh controller sees the same state.
      final c2 = make();
      await c2.load();
      expect(c2.timers.single.label, isNull);
      expect(c2.farmNames, isEmpty);
    });
  });

  group('widgets', () {
    Future<TimerController> pumpApp(WidgetTester tester, {void Function(TimerController)? seed}) async {
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      final controller = TimerController(
        repository: TimerRepository(),
        notifications: RecordingService(NotificationMode.inAppOnly),
      );
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        FarmTimerApp(
          controller: controller,
          catalog: CatalogService(bundle: _Bundle()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return controller;
    }

    testWidgets('zone picker sets the preferred-climate toggle and is remembered', (tester) async {
      final controller = await pumpApp(tester);
      await tester.tap(find.text('Catalog'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lily Seed'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('zonePicker')), findsOneWidget);
      SwitchListTile toggle() => tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle().value, isFalse);

      await tester.tap(find.byKey(const Key('zonePicker')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Two Crowns').last);
      await tester.pumpAndSettle();
      expect(toggle().value, isTrue);
      expect(find.byKey(const Key('zoneHint')), findsOneWidget);

      await tester.tap(find.byKey(const Key('zonePicker')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Solis Headlands').last);
      await tester.pumpAndSettle();
      expect(toggle().value, isFalse);
      // Player can still override.
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(toggle().value, isTrue);

      await tester.enterText(find.byKey(const Key('farmField')), 'Desert farm');
      await tester.ensureVisible(find.text('Start timer'));
      await tester.tap(find.text('Start timer'));
      await tester.pumpAndSettle();
      expect(controller.timers.single.label, 'Desert farm');
      expect(controller.timers.single.preferredClimate, isTrue);
      expect(controller.farms.lastZone, 'Solis Headlands');
      expect(controller.farms.zoneFor('Desert farm'), 'Solis Headlands');

      // Second planting: farm chip offered; zone preselected from memory.
      await tester.tap(find.text('Catalog'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lily Seed'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('farmChip:Desert farm')), findsOneWidget);
      expect(toggle().value, isFalse); // Solis is Arid, Lily is Temperate
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('timers grouped by farm with counts, collapse and flat toggle', (tester) async {
      final controller = await pumpApp(tester);
      await controller.startTimer(_temperateItem, label: 'Home');
      await controller.startTimer(_anyItem, label: 'Home', plantedAgo: const Duration(minutes: 10));
      await controller.startTimer(_aridItem, label: 'Lake plot');
      await controller.startTimer(_aridItem);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('farmHeader:Home')), findsOneWidget);
      expect(find.byKey(const ValueKey('farmHeader:Lake plot')), findsOneWidget);
      expect(find.byKey(const ValueKey('farmHeader:')), findsOneWidget); // no farm
      expect(
        find.descendant(of: find.byKey(const ValueKey('farmCount:Home')), matching: find.text('1/2 ready')),
        findsOneWidget,
      );
      expect(find.text('Lily Seed'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('farmHeader:Home')));
      await tester.pumpAndSettle();
      expect(find.text('Lily Seed'), findsNothing);
      expect(controller.farms.isCollapsed('Home'), isTrue);

      // Flat view shows everything again, with farm labels on cards.
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('farmHeader:Home')), findsNothing);
      expect(find.text('Lily Seed'), findsOneWidget);
      expect(find.text('Lake plot'), findsOneWidget);
      expect(controller.farms.grouped, isFalse);

      // Rename via the farm menu.
      await tester.tap(find.byIcon(Icons.yard_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('farmMenu:Lake plot')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename farm'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('renameField')), 'North lake');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('farmHeader:North lake')), findsOneWidget);
      expect(controller.timers.where((t) => t.label == 'North lake').length, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('settings wither-warning dropdown', (tester) async {
      final controller = await pumpApp(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('witherLead')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1h').last);
      await tester.pumpAndSettle();
      expect(controller.alertSettings.witherLeadMinutes, 60);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData(0);
  @override
  Future<String> loadString(String key, {bool cache = true}) async => key.endsWith('zones.json')
      ? _zonesJson
      : jsonEncode([
          {'name': 'Lily Seed', 'category': 'crop', 'growTimeMinutes': 86, 'climate': 'Temperate'},
          {'name': 'Aloe Seed', 'category': 'crop', 'growTimeMinutes': 100, 'climate': 'Arid'},
        ]);
}
