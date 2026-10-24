import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/farm_timer.dart';
import '../util/log.dart';
import 'platform_env.dart';
import 'timer_math.dart';

/// How "ready" alerts reach the player on the current platform.
enum NotificationMode {
  /// OS-scheduled notification; fires even if the app is closed
  /// (Android, iOS, macOS).
  scheduled('System notifications (scheduled, work while app is closed)'),

  /// OS notification shown by the app when a timer hits ready; only while
  /// the app is running (Linux: the plugin has no scheduling on Linux).
  whileRunning('Desktop notifications while the app is running'),

  /// Web Push via the push server; works while the web app is closed.
  push('Push alerts on (work while the app is closed)'),

  /// No OS notifications; in-app alerts only (Windows, web, or failed init).
  inAppOnly('In-app alerts only (keep the app open)');

  const NotificationMode(this.description);
  final String description;
}

/// Abstraction so the controller can be tested without platform channels.
/// Every timer can have two alerts: "ready" and, when its wither/death time
/// is known, an "about to wither" warning. [scheduleReady] schedules both and
/// [cancel] cancels both.
abstract class NotificationService {
  NotificationMode get mode;
  Future<void> init();
  Future<void> scheduleReady(FarmTimer timer);
  Future<void> cancel(FarmTimer timer);
  Future<void> showReadyNow(FarmTimer timer);

  /// Shows the wither warning immediately (only used while the app runs
  /// on platforms without scheduling).
  Future<void> showWitherWarningNow(FarmTimer timer);

  /// Re-registers every pending timer (after load/import). Default: schedule each.
  Future<void> syncAll(List<FarmTimer> timers);

  /// Schedules several timers at once, after cancelling [replacing] (e.g. a
  /// harvested cycle). The push server gets ONE request for the whole batch.
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []});

  /// Cancels several timers at once (one push-server request).
  Future<void> cancelAll(List<FarmTimer> timers);
}

/// Fans out to several services (local notifications + push server).
class CompositeNotificationService implements NotificationService {
  CompositeNotificationService(this.services);
  final List<NotificationService> services;

  @override
  NotificationMode get mode {
    final modes = services.map((s) => s.mode).toList();
    for (final m in [NotificationMode.push, NotificationMode.scheduled, NotificationMode.whileRunning]) {
      if (modes.contains(m)) return m;
    }
    return NotificationMode.inAppOnly;
  }

  @override
  Future<void> init() async {
    for (final s in services) {
      await s.init();
    }
  }

  Future<void> _all(Future<void> Function(NotificationService s) f) async {
    for (final s in services) {
      try {
        await f(s);
      } catch (e) {
        logDebug('notification service error', e);
      }
    }
  }

  @override
  Future<void> scheduleReady(FarmTimer timer) => _all((s) => s.scheduleReady(timer));
  @override
  Future<void> cancel(FarmTimer timer) => _all((s) => s.cancel(timer));
  @override
  Future<void> showReadyNow(FarmTimer timer) => _all((s) => s.showReadyNow(timer));
  @override
  Future<void> showWitherWarningNow(FarmTimer timer) => _all((s) => s.showWitherWarningNow(timer));
  @override
  Future<void> syncAll(List<FarmTimer> timers) => _all((s) => s.syncAll(timers));
  @override
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []}) =>
      _all((s) => s.scheduleAll(timers, replacing: replacing));
  @override
  Future<void> cancelAll(List<FarmTimer> timers) => _all((s) => s.cancelAll(timers));
}

/// No-op implementation (tests, unsupported platforms).
class NoopNotificationService implements NotificationService {
  @override
  NotificationMode get mode => NotificationMode.inAppOnly;
  @override
  Future<void> init() async {}
  @override
  Future<void> scheduleReady(FarmTimer timer) async {}
  @override
  Future<void> cancel(FarmTimer timer) async {}
  @override
  Future<void> showReadyNow(FarmTimer timer) async {}
  @override
  Future<void> showWitherWarningNow(FarmTimer timer) async {}
  @override
  Future<void> syncAll(List<FarmTimer> timers) async {}
  @override
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []}) async {}
  @override
  Future<void> cancelAll(List<FarmTimer> timers) async {}
}

/// Shared wording for wither warnings (local notifications and push).
String witherWarningTitle(FarmTimer t) => '${t.itemName} will wither soon!';
String witherWarningBody(FarmTimer t, int leadMinutes) {
  final where = t.label == null ? '' : ' at ${t.label}';
  final qty = t.quantity > 1 ? '${t.quantity}× ' : '';
  final lead = TimerMath.witherWarningLead(t, leadMinutes);
  return 'Harvest $qty${t.itemName}$where within ${TimerMath.formatMinutes(lead.toDouble())} or it is lost.';
}

/// flutter_local_notifications-backed implementation.
class LocalNotificationService implements NotificationService {
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin, int Function()? witherLead})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
      _witherLead = witherLead ?? (() => 30);

  final FlutterLocalNotificationsPlugin _plugin;
  final int Function() _witherLead;
  NotificationMode _mode = NotificationMode.inAppOnly;

  @override
  NotificationMode get mode => _mode;

  static NotificationMode platformMode() {
    if (kIsWeb) return NotificationMode.inAppOnly;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return NotificationMode.scheduled;
      case TargetPlatform.linux:
        return NotificationMode.whileRunning;
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
        // Windows toast scheduling needs MSIX/app identity setup; v1 falls
        // back to in-app alerts. See README.
        return NotificationMode.inAppOnly;
    }
  }

  static const _android = AndroidNotificationDetails(
    'farm_ready',
    'Farm ready alerts',
    channelDescription: 'Alerts when crops, trees or livestock are ready to harvest',
    importance: Importance.high,
    priority: Priority.high,
  );
  static const _darwin = DarwinNotificationDetails();
  static const _details = NotificationDetails(
    android: _android,
    iOS: _darwin,
    macOS: _darwin,
    linux: LinuxNotificationDetails(),
  );

  @override
  Future<void> init() async {
    final target = platformMode();
    if (target == NotificationMode.inAppOnly) {
      _mode = target;
      return;
    }
    if (target == NotificationMode.whileRunning && !linuxSessionBusAvailable()) {
      logDebug('No D-Bus session bus; using in-app alerts only.');
      _mode = NotificationMode.inAppOnly;
      return;
    }
    try {
      const darwin = DarwinInitializationSettings();
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: darwin,
          macOS: darwin,
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
      );
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _mode = ok == false ? NotificationMode.inAppOnly : target;
    } catch (e) {
      logDebug('Notifications unavailable, using in-app alerts', e);
      _mode = NotificationMode.inAppOnly;
    }
  }

  String _title(FarmTimer t) => '${t.itemName} is ready!';
  String _body(FarmTimer t) {
    final where = t.label == null ? '' : ' at ${t.label}';
    final qty = t.quantity > 1 ? '${t.quantity}× ' : '';
    return 'Harvest $qty${t.itemName}$where before it withers.';
  }

  Future<void> _scheduleAt(int id, String title, String body, DateTime atUtc, String payload) async {
    if (!atUtc.isAfter(DateTime.now().toUtc())) return;
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        // Absolute UTC instant: no local-timezone lookup needed.
        scheduledDate: tz.TZDateTime.from(atUtc, tz.UTC),
        notificationDetails: _details,
        // Inexact avoids the restricted SCHEDULE_EXACT_ALARM permission; may
        // fire a few minutes late under Doze. See README.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    } catch (e) {
      logDebug('Failed to schedule notification', e);
    }
  }

  Future<void> _cancelId(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (e) {
      logDebug('Failed to cancel notification', e);
    }
  }

  @override
  Future<void> scheduleReady(FarmTimer t) async {
    if (_mode != NotificationMode.scheduled) return;
    await _scheduleAt(t.notificationId, _title(t), _body(t), t.readyAtUtc, t.id);
    final lead = _witherLead();
    final warnAt = TimerMath.witherWarningAt(t, lead);
    final warnId = TimerMath.warningNotificationId(t.notificationId);
    if (warnAt == null) {
      await _cancelId(warnId); // e.g. warnings switched off
    } else {
      await _scheduleAt(warnId, witherWarningTitle(t), witherWarningBody(t, lead), warnAt, t.id);
    }
  }

  @override
  Future<void> cancel(FarmTimer t) async {
    if (_mode == NotificationMode.inAppOnly) return;
    await _cancelId(t.notificationId);
    await _cancelId(TimerMath.warningNotificationId(t.notificationId));
  }

  @override
  Future<void> syncAll(List<FarmTimer> timers) async {
    for (final t in timers) {
      await scheduleReady(t);
    }
  }

  // Local notifications cost nothing on a server: one OS call per timer.
  @override
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []}) async {
    await cancelAll(replacing);
    for (final t in timers) {
      await scheduleReady(t);
    }
  }

  @override
  Future<void> cancelAll(List<FarmTimer> timers) async {
    for (final t in timers) {
      await cancel(t);
    }
  }

  @override
  Future<void> showReadyNow(FarmTimer t) async {
    if (_mode != NotificationMode.whileRunning) return;
    try {
      await _plugin.show(
        id: t.notificationId,
        title: _title(t),
        body: _body(t),
        notificationDetails: _details,
        payload: t.id,
      );
    } catch (e) {
      logDebug('Failed to show notification', e);
    }
  }

  @override
  Future<void> showWitherWarningNow(FarmTimer t) async {
    if (_mode != NotificationMode.whileRunning) return;
    try {
      await _plugin.show(
        id: TimerMath.warningNotificationId(t.notificationId),
        title: witherWarningTitle(t),
        body: witherWarningBody(t, _witherLead()),
        notificationDetails: _details,
        payload: t.id,
      );
    } catch (e) {
      logDebug('Failed to show notification', e);
    }
  }
}
