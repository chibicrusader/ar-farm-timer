import 'package:archeragefarmtimer/models/farm_item.dart';
import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class RecordingNotifications extends NoopNotificationService {
  final scheduled = <int>[];
  final cancelled = <int>[];
  final shown = <int>[];
  @override
  Future<void> scheduleReady(FarmTimer timer) async => scheduled.add(timer.notificationId);
  @override
  Future<void> cancel(FarmTimer timer) async => cancelled.add(timer.notificationId);
  @override
  Future<void> showReadyNow(FarmTimer timer) async => shown.add(timer.notificationId);
  @override
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []}) async {
    cancelled.addAll(replacing.map((t) => t.notificationId));
    scheduled.addAll(timers.map((t) => t.notificationId));
  }

  @override
  Future<void> cancelAll(List<FarmTimer> timers) async => cancelled.addAll(timers.map((t) => t.notificationId));
}

void main() {
  late DateTime now;
  late RecordingNotifications notes;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    now = DateTime.utc(2026, 10, 17, 8);
    notes = RecordingNotifications();
  });

  TimerController makeController() =>
      TimerController(repository: TimerRepository(), notifications: notes, clock: () => now);

  const potato = FarmItem(name: 'Potato', category: FarmCategory.crops, growTimeMinutes: 30, witherOrDeathMinutes: 15);
  const apple = FarmItem(
    name: 'Apple Tree',
    category: FarmCategory.trees,
    growTimeMinutes: 240,
    harvestCycles: null,
    harvestIntervalMinutes: 60,
    climate: 'Temperate',
  );

  test('FarmTimer JSON round-trip keeps absolute UTC instants', () {
    final t = FarmTimer(
      id: 'a',
      notificationId: 7,
      itemName: 'Apple Tree',
      category: 'trees',
      label: 'Plot 3',
      quantity: 4,
      plantedAtUtc: DateTime.utc(2026, 1, 1, 10),
      readyAtUtc: DateTime.utc(2026, 1, 1, 14, 0, 30),
      growMinutes: 240.5,
      regrowMinutes: 60,
      witherMinutes: 10,
      totalCycles: null,
      repeating: true,
      cycle: 3,
      preferredClimate: true,
    );
    final json = t.toJson();
    expect(json['readyAtUtc'], '2026-01-01T14:00:30.000Z');
    final r = FarmTimer.fromJson(json);
    expect(r.toJson(), json);
    expect(r.readyAtUtc.isUtc, isTrue);
    expect(r.hasMoreCycles, isTrue);
  });

  test('repository saves and loads timers, tolerating corrupt entries', () async {
    final repo = TimerRepository();
    expect(await repo.loadAll(), isEmpty);
    final c = makeController();
    await c.load();
    await c.startTimer(potato, label: '  Solzreed  ', quantity: 3);
    final loaded = await repo.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single.label, 'Solzreed');
    expect(loaded.single.quantity, 3);
    expect(loaded.single.readyAtUtc, now.add(const Duration(minutes: 30)));

    await SharedPreferencesAsync().setString(TimerRepository.storageKey, '[{"bad":1}, ${'{}'}]');
    expect(await repo.loadAll(), isEmpty);
    await SharedPreferencesAsync().setString(TimerRepository.storageKey, 'not json');
    expect(await repo.loadAll(), isEmpty);
  });

  test('timers survive a "restart" (new controller, same storage)', () async {
    final c1 = makeController();
    await c1.load();
    await c1.startTimer(apple, preferredClimate: true);
    await c1.startTimer(potato, plantedAgo: const Duration(minutes: 10));
    expect(notes.scheduled, hasLength(2));

    final c2 = makeController();
    await c2.load();
    final timers = c2.timers;
    expect(timers.map((t) => t.itemName), ['Potato', 'Apple Tree']); // soonest first
    expect(timers.first.readyAtUtc, now.add(const Duration(minutes: 20)));
    expect(timers.last.readyAtUtc, now.add(const Duration(minutes: 168))); // 240 * 0.7
    expect(timers.last.preferredClimate, isTrue);
  });

  test('harvest restarts repeating items and removes single ones; delete cancels', () async {
    final c = makeController();
    await c.load();
    final a = await c.startTimer(apple);
    final p = await c.startTimer(potato);
    now = now.add(const Duration(hours: 5));

    final next = await c.harvest(a.id);
    expect(next, isNotNull);
    expect(next!.cycle, 2);
    expect(next.readyAtUtc, now.add(const Duration(minutes: 60)));
    expect(notes.cancelled, contains(a.notificationId));
    expect(notes.scheduled, contains(next.notificationId));

    expect(await c.harvest(p.id), isNull);
    expect(c.timers.map((t) => t.itemName), ['Apple Tree']);

    await c.delete(next.id);
    expect(c.timers, isEmpty);
    expect(await TimerRepository().loadAll(), isEmpty);
  });

  test('tick emits ready and overdue alerts once', () async {
    final c = makeController();
    await c.load();
    final p = await c.startTimer(potato);
    final alerts = <TimerStatus>[];
    final sub = c.alerts.listen((a) => alerts.add(a.status));
    c.tick();
    now = now.add(const Duration(minutes: 31));
    c.tick();
    c.tick();
    now = now.add(const Duration(minutes: 15));
    c.tick();
    await Future<void>.delayed(Duration.zero);
    expect(alerts, [TimerStatus.ready, TimerStatus.overdue]);
    expect(notes.shown, [p.notificationId]);
    await sub.cancel();
    c.dispose();
  });
}
