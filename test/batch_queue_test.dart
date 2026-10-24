import 'dart:convert';

import 'package:archeragefarmtimer/app.dart';
import 'package:archeragefarmtimer/models/farm_item.dart';
import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/models/pending_timer.dart';
import 'package:archeragefarmtimer/services/alert_settings.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/push_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_queue.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _rice = FarmItem(name: 'Rice', category: FarmCategory.crops, growTimeMinutes: 60, climate: 'Temperate');
// Known wither time: gets a second (wither warning) alert.
const _goat = FarmItem(name: 'Goat', category: FarmCategory.livestock, growTimeMinutes: 120, witherOrDeathMinutes: 240);
const _apple = FarmItem(
  name: 'Apple Tree',
  category: FarmCategory.trees,
  growTimeMinutes: 240,
  harvestCycles: null,
  harvestIntervalMinutes: 60,
);

const _sub = '{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"a","auth":"b"}}';

void main() {
  late List<http.Request> requests;

  MockClient client() => MockClient((req) async {
    requests.add(req);
    final body = switch (req.url.path) {
      '/subscribe' => {'subscriptionId': 'sub-1234567890abcdef'},
      _ => {'ok': true},
    };
    return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
  });

  Map<String, dynamic> bodyOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

  /// Controller wired to a real PushAlertService on a mocked HTTP client,
  /// already subscribed; [requests] is cleared afterwards.
  Future<(TimerController, PushAlertService)> setUpPush() async {
    final settings = AlertSettings();
    final push = PushAlertService(
      client: client(),
      defaultServerUrl: 'https://srv.test',
      appUrl: 'https://artimer.win/',
      witherLead: () => settings.witherLeadMinutes,
    );
    await push.init();
    await push.register(_sub, const []);
    final c = TimerController(repository: TimerRepository(), notifications: push, alertSettings: settings);
    await c.load();
    await Future<void>.delayed(Duration.zero);
    requests.clear();
    return (c, push);
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    requests = [];
  });

  group('batching (push server requests)', () {
    test('starting 5 timers sends ONE /schedule with every ready + wither alert', () async {
      final (c, _) = await setUpPush();
      final started = await c.startTimers([
        const PendingTimer(item: _rice, label: 'Home', quantity: 4),
        const PendingTimer(item: _rice, label: 'Lake', watered: true),
        const PendingTimer(item: _goat, label: 'Barn'),
        const PendingTimer(item: _goat, label: 'Barn', quantity: 2),
        const PendingTimer(item: _rice, witherMinutes: 30, plantedAgo: Duration(minutes: 5)), // own wither time
      ]);
      expect(started, hasLength(5));
      expect(c.timers, hasLength(5));
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/schedule');
      final body = bodyOf(requests.single);
      expect(body['subscriptionId'], 'sub-1234567890abcdef');
      expect(body.containsKey('cancel'), isFalse);
      final ids = [for (final a in (body['alerts'] as List).cast<Map<String, dynamic>>()) a['id'] as String];
      expect(ids, hasLength(5 + 3)); // 5 ready + 3 wither warnings
      expect(ids.where((i) => i.endsWith(':wither')), hasLength(3));
      for (final t in started) {
        expect(ids, contains(PushAlertService.alertId(t)));
      }
    });

    test('a single timer is still one request', () async {
      final (c, _) = await setUpPush();
      await c.startTimer(_goat);
      expect(requests.map((r) => r.url.path), ['/schedule']);
      expect(bodyOf(requests.single)['alerts'], hasLength(2));
    });

    test('more than 50 timers are split into requests of 50', () async {
      final (c, _) = await setUpPush();
      await c.startTimers([for (var i = 0; i < 120; i++) const PendingTimer(item: _rice)]);
      expect(requests.map((r) => r.url.path), ['/schedule', '/schedule', '/schedule']);
      expect([for (final r in requests) (bodyOf(r)['alerts'] as List).length], [50, 50, 20]);
    });

    test('repeat harvest cancels the old cycle and schedules the next in one request', () async {
      final (c, _) = await setUpPush();
      final t = await c.startTimer(_apple);
      requests.clear();
      final next = await c.harvest(t.id);
      expect(next, isNotNull);
      expect(requests, hasLength(1));
      final body = bodyOf(requests.single);
      expect(requests.single.url.path, '/schedule');
      expect(body['cancel'], PushAlertService.idsFor(t));
      expect(((body['alerts'] as List).single as Map)['id'], PushAlertService.alertId(next!));

      // Single-harvest item: just one /cancel.
      final r = await c.startTimer(_rice);
      requests.clear();
      expect(await c.harvest(r.id), isNull);
      expect(requests.map((r) => r.url.path), ['/cancel']);
    });

    test('deleting a farm with many timers sends one /cancel', () async {
      final (c, _) = await setUpPush();
      await c.startTimers([for (var i = 0; i < 7; i++) const PendingTimer(item: _goat, label: 'Barn')]);
      await c.startTimer(_rice, label: 'Home');
      requests.clear();
      await c.deleteFarm('Barn', deleteTimers: true);
      expect(requests.map((r) => r.url.path), ['/cancel']);
      expect(bodyOf(requests.single)['ids'], hasLength(14));
      expect(c.timers, hasLength(1));
    });

    test('changing the wither lead resyncs everything in one request', () async {
      final (c, _) = await setUpPush();
      await c.startTimers([for (var i = 0; i < 6; i++) const PendingTimer(item: _goat)]);
      requests.clear();
      await c.setWitherLead(60);
      expect(requests.map((r) => r.url.path), ['/sync']);
      expect(bodyOf(requests.single)['alerts'], hasLength(12));
    });

    test('importing with replace: one /cancel + one /sync (not one per timer)', () async {
      final (c, _) = await setUpPush();
      await c.startTimers([for (var i = 0; i < 6; i++) const PendingTimer(item: _rice)]);
      final backup = c.timers;
      requests.clear();
      await c.importTimers(backup, replace: true);
      expect(requests.map((r) => r.url.path), ['/cancel', '/sync']);
    });

    test('without a subscription nothing is sent', () async {
      final push = PushAlertService(client: client(), defaultServerUrl: 'https://srv.test');
      await push.init();
      await push.scheduleAll([], replacing: []);
      final c = TimerController(repository: TimerRepository(), notifications: push);
      await c.startTimers([const PendingTimer(item: _rice)]);
      await push.cancelAll(c.timers);
      expect(requests, isEmpty);
    });

    test('composite fans scheduleAll/cancelAll out to every service', () async {
      final log = <String>[];
      final c = CompositeNotificationService([_Log(log, 'a'), _Log(log, 'b')]);
      await c.scheduleAll(const [], replacing: const []);
      await c.cancelAll(const []);
      expect(log, ['a:scheduleAll', 'b:scheduleAll', 'a:cancelAll', 'b:cancelAll']);
    });
  });

  group('TimerQueue', () {
    test('add, edit, remove, take all, max 50', () {
      final q = TimerQueue();
      var notified = 0;
      q.addListener(() => notified++);
      expect(q.add(const PendingTimer(item: _rice)), isTrue);
      expect(q.add(const PendingTimer(item: _goat)), isTrue);
      q.replaceAt(0, const PendingTimer(item: _rice, quantity: 9));
      expect(q.items.first.quantity, 9);
      expect(q.removeAt(1)!.item.name, 'Goat');
      expect(q.length, 1);
      expect(q.takeAll(), hasLength(1));
      expect(q.isEmpty, isTrue);
      for (var i = 0; i < TimerQueue.maxItems; i++) {
        q.add(const PendingTimer(item: _rice));
      }
      expect(q.isFull, isTrue);
      expect(q.add(const PendingTimer(item: _rice)), isFalse);
      expect(q.length, 50);
      expect(notified, greaterThan(50));
    });

    test('PendingTimer.farm trims and drops empty names', () {
      expect(const PendingTimer(item: _rice, label: '  Home ').farm, 'Home');
      expect(const PendingTimer(item: _rice, label: '   ').farm, isNull);
    });
  });

  group('queue UI (390x844)', () {
    Future<TimerController> pumpApp(WidgetTester tester) async {
      final (c, _) = await tester.runAsync(setUpPush) ?? (throw StateError('setup failed'));
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        FarmTimerApp(
          controller: c,
          catalog: CatalogService(bundle: _Bundle()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      requests.clear(); // the app's own /sync on start
      return c;
    }

    Future<void> openItem(WidgetTester tester, String name) async {
      await tester.tap(find.text('Catalog'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).first);
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('build a list, edit and remove entries, then start all with one request', (tester) async {
      final c = await pumpApp(tester);

      // 1) Rice ×3 at Home
      await openItem(tester, 'Rice');
      await tester.enterText(find.byKey(const Key('farmField')), 'Home');
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tapKey(tester, 'addToList');
      expect(c.queue.length, 1);
      expect(c.timers, isEmpty);
      expect(find.byKey(const Key('queueBar')), findsOneWidget);
      expect(find.text('1 timer in list'), findsOneWidget);
      expect(find.text('CROPS'), findsOneWidget); // still in the catalog

      // 2) Rice watered at Lake: the sheet offers "Add and start all" now
      await openItem(tester, 'Rice');
      expect(find.byKey(const ValueKey('farmChip:Home')), findsOneWidget); // queued farm offered
      expect(find.text('Add and start all 2 timers'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('farmField')), 'Lake');
      await tapKey(tester, 'watered');
      await tapKey(tester, 'addToList');

      // 3) Goat with its own wither time
      await openItem(tester, 'Goat');
      await tester.ensureVisible(find.text('Advanced'));
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('witherField')), '90');
      await tapKey(tester, 'addToList');
      expect(find.text('3 timers in list'), findsOneWidget);
      expect(requests, isEmpty); // nothing sent while building the list

      // Review: entries with their options
      await tester.tap(find.byKey(const Key('reviewQueue')));
      await tester.pumpAndSettle();
      expect(find.text('Timers to start (3)'), findsOneWidget);
      expect(find.text('Rice ×3'), findsOneWidget);
      expect(find.text('watered'), findsOneWidget);
      expect(find.text('own wither time'), findsOneWidget);
      expect(find.text('Start 3 timers'), findsOneWidget);

      // Edit the first entry: quantity 3 -> 5
      await tester.tap(find.text('Rice ×3'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Rice'), findsOneWidget);
      expect(find.byKey(const Key('addToList')), findsNothing);
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tapKey(tester, 'saveQueued');
      expect(find.text('Rice ×5'), findsOneWidget);
      expect(c.queue.items.first.label, 'Home');

      // Remove the watered Lake entry
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('queued:1')), matching: find.byIcon(Icons.close)));
      await tester.pumpAndSettle();
      expect(find.text('Timers to start (2)'), findsOneWidget);
      expect(find.text('watered'), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('startQueued')));
        await _until(() => requests.any((r) => r.url.path == '/schedule'));
      });
      await tester.pumpAndSettle();

      expect(c.queue.isEmpty, isTrue);
      expect(find.byKey(const Key('queueBar')), findsNothing);
      expect(c.timers.map((t) => '${t.itemName}×${t.quantity}@${t.label}').toSet(), {'Rice×5@Home', 'Goat×1@null'});
      expect(c.timers.firstWhere((t) => t.itemName == 'Goat').witherCustom, isTrue);
      expect(find.textContaining('Started 2 timers'), findsOneWidget);
      // ONE request for both timers: 2 ready + 1 wither warning
      expect(requests.map((r) => r.url.path), ['/schedule']);
      expect(bodyOf(requests.single)['alerts'], hasLength(3));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('single timer: still one tap, list untouched', (tester) async {
      final c = await pumpApp(tester);
      await openItem(tester, 'Goat');
      expect(find.byKey(const Key('addAndStartAll')), findsNothing); // empty list: no extra button
      await tester.runAsync(() async {
        await tester.ensureVisible(find.byKey(const Key('startOne')));
        await tester.tap(find.byKey(const Key('startOne')));
        await _until(() => requests.any((r) => r.url.path == '/schedule'));
      });
      await tester.pumpAndSettle();
      expect(c.timers, hasLength(1));
      expect(c.queue.isEmpty, isTrue);
      expect(requests.map((r) => r.url.path), ['/schedule']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"Add and start all" starts the list plus this item; bar Start works', (tester) async {
      final c = await pumpApp(tester);
      c.queue.add(const PendingTimer(item: _rice, label: 'Home'));
      await openItem(tester, 'Goat');
      await tester.runAsync(() async {
        await tester.ensureVisible(find.byKey(const Key('addAndStartAll')));
        await tester.tap(find.byKey(const Key('addAndStartAll')));
        await _until(() => requests.any((r) => r.url.path == '/schedule'));
      });
      await tester.pumpAndSettle();
      expect(c.timers, hasLength(2));
      expect(requests.map((r) => r.url.path), ['/schedule']);

      // Start straight from the bar
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).removeCurrentSnackBar();
      requests.clear();
      c.queue.add(const PendingTimer(item: _rice));
      c.queue.add(const PendingTimer(item: _rice));
      await tester.pumpAndSettle();
      expect(find.text('Start 2'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('startQueuedBar')));
        await _until(() => requests.isNotEmpty);
      });
      await tester.pumpAndSettle();
      expect(c.timers, hasLength(4));
      expect(requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Lets real async work (mock HTTP, prefs) finish: waits for [done], then a
/// little longer so the awaiting code completes.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

class _Log extends NoopNotificationService {
  _Log(this.log, this.name);
  final List<String> log;
  final String name;
  @override
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []}) async =>
      log.add('$name:scheduleAll');
  @override
  Future<void> cancelAll(List<FarmTimer> timers) async => log.add('$name:cancelAll');
}

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData(0);
  @override
  Future<String> loadString(String key, {bool cache = true}) async => key.endsWith('zones.json')
      ? '{"zones":[{"name":"Two Crowns","continent":"Nuia","climates":["Temperate"]}]}'
      : jsonEncode([
          {'name': 'Rice', 'category': 'crop', 'growTimeMinutes': 60, 'climate': 'Temperate'},
          {'name': 'Goat', 'category': 'livestock', 'growTimeMinutes': 120},
        ]);
}
