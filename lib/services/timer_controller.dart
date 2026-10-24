import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/farm_item.dart';
import '../models/farm_timer.dart';
import '../models/pending_timer.dart';
import 'alert_settings.dart';
import 'farm_store.dart';
import 'notification_service.dart';
import 'timer_math.dart';
import 'timer_queue.dart';
import 'timer_repository.dart';

typedef Clock = DateTime Function();

/// Emitted when a timer changes state while the app is open.
class TimerAlert {
  const TimerAlert(this.timer, this.status, {this.witherWarning = false});
  final FarmTimer timer;
  final TimerStatus status;

  /// "About to wither" warning (status is still ready).
  final bool witherWarning;
}

/// App state for active timers: CRUD, persistence, ticking and alerts.
class TimerController extends ChangeNotifier {
  TimerController({
    required TimerRepository repository,
    required this.notifications,
    Clock? clock,
    String Function()? idGenerator,
    AlertSettings? alertSettings,
    FarmStore? farms,
    TimerQueue? queue,
  }) : _repo = repository,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _newId = idGenerator ?? _defaultId,
       alertSettings = alertSettings ?? AlertSettings(),
       farms = farms ?? FarmStore(),
       queue = queue ?? TimerQueue();

  /// Wither-warning lead time etc.
  final AlertSettings alertSettings;

  /// Saved farm names, zone memory and list view options.
  final FarmStore farms;

  /// Timers set up with "Add to list", started together by [startQueued].
  final TimerQueue queue;

  final TimerRepository _repo;
  final NotificationService notifications;
  final Clock _clock;
  final String Function() _newId;

  static int _seq = 0;
  static String _defaultId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${(_seq++).toRadixString(36)}';

  List<FarmTimer> _timers = [];
  final Map<String, TimerStatus> _lastStatus = {};
  final Map<String, bool> _pastWarning = {};
  final _alerts = StreamController<TimerAlert>.broadcast();
  Timer? _ticker;
  bool _loaded = false;

  bool get loaded => _loaded;
  DateTime get now => _clock();
  Stream<TimerAlert> get alerts => _alerts.stream;

  /// Timers sorted soonest-ready first.
  List<FarmTimer> get timers => TimerMath.sortBySoonest(_timers);

  int countWhere(TimerStatus s) => _timers.where((t) => TimerMath.status(t, now) == s).length;

  /// Farm names in use by timers plus saved ones, alphabetical.
  List<String> get farmNames {
    final names = {...farms.farms, for (final t in _timers) ?t.label};
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  bool _isPastWarning(FarmTimer t, DateTime n) {
    final w = TimerMath.witherWarningAt(t, alertSettings.witherLeadMinutes);
    return w != null && !n.isBefore(w);
  }

  void _track(FarmTimer t, DateTime n) {
    _lastStatus[t.id] = TimerMath.status(t, n);
    _pastWarning[t.id] = _isPastWarning(t, n);
  }

  void _untrack(String id) {
    _lastStatus.remove(id);
    _pastWarning.remove(id);
  }

  Future<void> load() async {
    await Future.wait([alertSettings.load(), farms.load()]);
    _timers = await _repo.loadAll();
    final n = now;
    for (final t in _timers) {
      _track(t, n);
    }
    // Re-register future notifications / push alerts (idempotent).
    unawaited(notifications.syncAll(List.of(_timers)));
    _loaded = true;
    notifyListeners();
  }

  /// Starts a 1-second ticker that refreshes countdowns and fires alerts.
  void startTicking() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  @visibleForTesting
  void tick() {
    final n = now;
    for (final t in _timers) {
      final s = TimerMath.status(t, n);
      final prev = _lastStatus[t.id];
      if (prev != null && prev != s && s != TimerStatus.growing) {
        _alerts.add(TimerAlert(t, s));
        if (s == TimerStatus.ready) unawaited(notifications.showReadyNow(t));
      }
      _lastStatus[t.id] = s;
      final warn = _isPastWarning(t, n);
      if (warn && _pastWarning[t.id] == false && s == TimerStatus.ready) {
        _alerts.add(TimerAlert(t, s, witherWarning: true));
        unawaited(notifications.showWitherWarningNow(t));
      }
      _pastWarning[t.id] = warn;
    }
    notifyListeners();
  }

  Future<FarmTimer> startTimer(
    FarmItem item, {
    String? label,
    int quantity = 1,
    bool preferredClimate = false,
    bool watered = false,
    bool farmhand = false,
    double? overrideGrowMinutes,
    double? witherMinutes,
    Duration plantedAgo = Duration.zero,
    String? zone,
  }) async {
    final p = PendingTimer(
      item: item,
      label: label,
      quantity: quantity,
      preferredClimate: preferredClimate,
      watered: watered,
      farmhand: farmhand,
      overrideGrowMinutes: overrideGrowMinutes,
      witherMinutes: witherMinutes,
      plantedAgo: plantedAgo,
      zone: zone,
    );
    final t = _build(p, now);
    _timers.add(t);
    _track(t, now);
    await _persist();
    await farms.remember(t.label, zone: zone);
    await notifications.scheduleReady(t);
    notifyListeners();
    return t;
  }

  /// Starts several timers at once: one save and ONE push-server request
  /// for all of their alerts (ready + wither warnings). Every timer counts
  /// from now (minus its own "planted ago").
  Future<List<FarmTimer>> startTimers(List<PendingTimer> pending) async {
    if (pending.isEmpty) return const [];
    final n = now;
    final started = [for (final p in pending) _build(p, n)];
    for (final t in started) {
      _timers.add(t);
      _track(t, n);
    }
    await _persist();
    for (final p in pending) {
      await farms.remember(p.farm, zone: p.zone);
    }
    await notifications.scheduleAll(started);
    notifyListeners();
    return started;
  }

  /// Starts everything in [queue] and empties it.
  Future<List<FarmTimer>> startQueued() => startTimers(queue.takeAll());

  FarmTimer _build(PendingTimer p, DateTime n) {
    final item = p.item;
    final planted = n.subtract(p.plantedAgo);
    final overrideGrowMinutes = p.overrideGrowMinutes;
    final witherMinutes = p.witherMinutes;
    final grow = TimerMath.effectiveGrowMinutes(
      item,
      preferredClimate: p.preferredClimate,
      watered: p.watered,
      farmhand: p.farmhand,
      overrideMinutes: overrideGrowMinutes,
    );
    final overridden = overrideGrowMinutes != null && overrideGrowMinutes > 0;
    final customWither = witherMinutes != null && witherMinutes > 0;
    return FarmTimer(
      id: _newId(),
      notificationId: TimerMath.newNotificationId(),
      itemName: item.name,
      category: item.category.name,
      label: p.farm,
      quantity: p.quantity < 1 ? 1 : p.quantity,
      plantedAtUtc: planted,
      readyAtUtc: TimerMath.readyAt(planted, grow),
      growMinutes: grow,
      regrowMinutes: item.regrowMinutes,
      witherMinutes: customWither ? witherMinutes : item.witherOrDeathMinutes,
      witherCustom: customWither,
      totalCycles: item.harvestCycles,
      repeating: item.isRepeating,
      preferredClimate: p.preferredClimate && item.hasClimateBonus && !overridden,
      // Only record modifiers that actually changed the time.
      watered: p.watered && item.wateredMultiplier != null && !overridden,
      farmhand: p.farmhand && (item.farmhandMultiplier ?? 1.0) != 1.0 && !overridden,
    );
  }

  Future<void> delete(String id) async {
    final t = _find(id);
    if (t == null) return;
    _timers.removeWhere((e) => e.id == id);
    _untrack(id);
    await notifications.cancel(t);
    await _persist();
    notifyListeners();
  }

  /// Harvests: restarts multi-harvest items for the next cycle, otherwise
  /// removes the timer. Returns the restarted timer, or null if removed.
  Future<FarmTimer?> harvest(String id) async {
    final t = _find(id);
    if (t == null) return null;
    final next = TimerMath.harvest(t, now, newNotificationId: TimerMath.newNotificationId());
    _timers.removeWhere((e) => e.id == id);
    _untrack(id);
    if (next != null) {
      _timers.add(next);
      _track(next, now);
      // Cancel this cycle and schedule the next in one push request.
      await notifications.scheduleAll([next], replacing: [t]);
    } else {
      await notifications.cancel(t);
    }
    await _persist();
    notifyListeners();
    return next;
  }

  /// Imports timers from a backup. Merge skips timers whose id already
  /// exists; replace removes all current timers first. Returns the number
  /// of timers added.
  Future<int> importTimers(List<FarmTimer> incoming, {bool replace = false}) async {
    if (replace) {
      await notifications.cancelAll(List.of(_timers));
      _timers = [];
      _lastStatus.clear();
      _pastWarning.clear();
    }
    final existing = _timers.map((t) => t.id).toSet();
    var added = 0;
    final n = now;
    for (final t in incoming) {
      if (!existing.add(t.id)) continue;
      // Fresh notification id so it can't collide with a scheduled one.
      final copy = t.copyWith(notificationId: TimerMath.newNotificationId());
      _timers.add(copy);
      _track(copy, n);
      added++;
    }
    await _persist();
    await notifications.syncAll(List.of(_timers));
    notifyListeners();
    return added;
  }

  /// Re-sends every pending alert (Settings > "Resync alerts").
  Future<void> resyncAlerts() => notifications.syncAll(List.of(_timers));

  /// Changes the wither-warning lead time and reschedules every alert.
  Future<void> setWitherLead(int minutes) async {
    await alertSettings.setWitherLead(minutes);
    final n = now;
    for (final t in _timers) {
      _pastWarning[t.id] = _isPastWarning(t, n);
    }
    await resyncAlerts();
    notifyListeners();
  }

  /// Renames a farm on every timer that uses it (and in the saved list).
  Future<void> renameFarm(String from, String to) async {
    final name = to.trim();
    if (name.isEmpty || name == from) return;
    _timers = [for (final t in _timers) t.label == from ? t.copyWith(label: name) : t];
    await _persist();
    await farms.rename(from, name);
    // Alert texts mention the farm name.
    await resyncAlerts();
    notifyListeners();
  }

  /// Deletes a farm. With [deleteTimers] its timers are removed too;
  /// otherwise they stay and just lose the farm name.
  Future<void> deleteFarm(String name, {bool deleteTimers = false}) async {
    final affected = _timers.where((t) => t.label == name).toList();
    if (deleteTimers) {
      await notifications.cancelAll(affected); // one push request for the whole farm
      for (final t in affected) {
        _untrack(t.id);
      }
      _timers.removeWhere((t) => t.label == name);
    } else {
      _timers = [for (final t in _timers) t.label == name ? t.copyWith(label: null) : t];
    }
    await _persist();
    await farms.remove(name);
    if (!deleteTimers && affected.isNotEmpty) await resyncAlerts();
    notifyListeners();
  }

  FarmTimer? _find(String id) {
    for (final t in _timers) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _persist() => _repo.saveAll(_timers);

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_alerts.close());
    super.dispose();
  }
}
