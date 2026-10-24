import 'package:archeragefarmtimer/models/farm_item.dart';
import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/services/timer_math.dart';
import 'package:flutter_test/flutter_test.dart';

FarmTimer _timer({
  required DateTime planted,
  double grow = 60,
  double? regrow,
  double? wither,
  int? cycles = 1,
  bool repeating = false,
  int cycle = 1,
}) => FarmTimer(
  id: 'x',
  notificationId: 1,
  itemName: 'Potato',
  category: 'crops',
  plantedAtUtc: planted,
  readyAtUtc: TimerMath.readyAt(planted, grow),
  growMinutes: grow,
  regrowMinutes: regrow,
  witherMinutes: wither,
  totalCycles: cycles,
  repeating: repeating,
  cycle: cycle,
);

void main() {
  final t0 = DateTime.utc(2026, 10, 17, 12);
  const item = FarmItem(name: 'Rice', category: FarmCategory.crops, growTimeMinutes: 100, climate: 'Tropical');

  group('effectiveGrowMinutes', () {
    test('uses data value by default', () {
      expect(TimerMath.effectiveGrowMinutes(item), 100);
    });
    test('preferred climate is ~30% faster', () {
      expect(TimerMath.effectiveGrowMinutes(item, preferredClimate: true), closeTo(70, 1e-9));
    });
    test('no climate bonus for Any / zone-locked / null climate', () {
      for (final c in ['Any', 'Zone-locked: Ahnimar', null]) {
        final i = FarmItem(name: 'n', category: FarmCategory.crops, growTimeMinutes: 100, climate: c);
        expect(TimerMath.effectiveGrowMinutes(i, preferredClimate: true), 100, reason: '$c');
      }
    });
    test('override wins', () {
      expect(TimerMath.effectiveGrowMinutes(item, preferredClimate: true, overrideMinutes: 42), 42);
    });
  });

  test('readyAt adds fractional minutes and normalises to UTC', () {
    final r = TimerMath.readyAt(t0.toLocal(), 771.5);
    expect(r.isUtc, isTrue);
    expect(r, t0.add(const Duration(minutes: 771, seconds: 30)));
  });

  group('status', () {
    test('growing -> ready -> overdue with wither deadline', () {
      final t = _timer(planted: t0, grow: 60, wither: 30);
      expect(TimerMath.status(t, t0.add(const Duration(minutes: 59))), TimerStatus.growing);
      expect(TimerMath.status(t, t0.add(const Duration(minutes: 60))), TimerStatus.ready);
      expect(TimerMath.status(t, t0.add(const Duration(minutes: 89))), TimerStatus.ready);
      expect(TimerMath.status(t, t0.add(const Duration(minutes: 90))), TimerStatus.overdue);
    });
    test('without wither data stays ready forever', () {
      final t = _timer(planted: t0, grow: 60);
      expect(t.witherAtUtc, isNull);
      expect(TimerMath.status(t, t0.add(const Duration(days: 30))), TimerStatus.ready);
      expect(TimerMath.untilWither(t, t0), isNull);
    });
  });

  test('remaining and progress', () {
    final t = _timer(planted: t0, grow: 60);
    final half = t0.add(const Duration(minutes: 30));
    expect(TimerMath.remaining(t, half), const Duration(minutes: 30));
    expect(TimerMath.progress(t, half), closeTo(0.5, 1e-9));
    expect(TimerMath.progress(t, t0.subtract(const Duration(minutes: 5))), 0);
    expect(TimerMath.progress(t, t0.add(const Duration(hours: 5))), 1);
    expect(TimerMath.remaining(t, t0.add(const Duration(minutes: 70))).isNegative, isTrue);
  });

  group('harvest', () {
    test('single harvest returns null', () {
      expect(TimerMath.harvest(_timer(planted: t0), t0.add(const Duration(hours: 2))), isNull);
    });
    test('limited cycles restart with harvest interval until exhausted', () {
      var t = _timer(planted: t0, grow: 60, regrow: 20, cycles: 3, repeating: true);
      final h1 = t0.add(const Duration(minutes: 65));
      t = TimerMath.harvest(t, h1)!;
      expect(t.cycle, 2);
      expect(t.plantedAtUtc, h1);
      expect(t.readyAtUtc, h1.add(const Duration(minutes: 20)));
      t = TimerMath.harvest(t, h1.add(const Duration(minutes: 20)))!;
      expect(t.cycle, 3);
      expect(t.cycleLabel, '3/3');
      expect(TimerMath.harvest(t, h1.add(const Duration(minutes: 40))), isNull);
    });
    test('unlimited repeating keeps going', () {
      var t = _timer(planted: t0, grow: 60, regrow: 720, cycles: null, repeating: true);
      for (var i = 0; i < 20; i++) {
        t = TimerMath.harvest(t, t.readyAtUtc)!;
      }
      expect(t.cycle, 21);
      expect(t.cycleLabel, '21/∞');
    });
    test('regrow falls back to grow minutes', () {
      final t = _timer(planted: t0, grow: 45, cycles: 2, repeating: true);
      final next = TimerMath.harvest(t, t0)!;
      expect(next.readyAtUtc, t0.add(const Duration(minutes: 45)));
    });
  });

  test('sortBySoonest orders by ready time', () {
    final a = _timer(planted: t0, grow: 90);
    final b = _timer(planted: t0, grow: 10);
    final c = _timer(planted: t0.subtract(const Duration(hours: 1)), grow: 30);
    expect(TimerMath.sortBySoonest([a, b, c]), [c, b, a]);
  });

  test('formatDuration', () {
    expect(TimerMath.formatDuration(const Duration(seconds: 12)), '12s');
    expect(TimerMath.formatDuration(const Duration(minutes: 4, seconds: 9)), '4m 09s');
    expect(TimerMath.formatDuration(const Duration(hours: 1, minutes: 5)), '1h 05m');
    expect(TimerMath.formatDuration(const Duration(days: 2, hours: 3)), '2d 3h');
    expect(TimerMath.formatDuration(const Duration(minutes: -3)), '3m 00s');
  });

  test('formatMinutes', () {
    expect(TimerMath.formatMinutes(90), '1h 30m');
    expect(TimerMath.formatMinutes(0.5), '30s');
    expect(TimerMath.formatMinutes(1543), '1d 1h 43m');
  });

  test('notification ids are positive 31-bit', () {
    for (var i = 0; i < 1000; i++) {
      final id = TimerMath.newNotificationId();
      expect(id, inInclusiveRange(1, 0x7FFFFFFF));
    }
  });
}
