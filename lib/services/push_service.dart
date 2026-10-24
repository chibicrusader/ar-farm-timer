import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/farm_timer.dart';
import '../util/log.dart';
import 'notification_service.dart';
import 'timer_math.dart';

/// The push server, fixed at build time (`tool/build_web.sh --push-server ...`
/// passes `--dart-define=PUSH_SERVER_URL=...`). Not user-editable and never
/// shown in the UI.
const kDefaultPushServerUrl = String.fromEnvironment('PUSH_SERVER_URL');

/// Optional second address of the SAME push server (same database, so the
/// same subscription ids), used only while the first can't be reached at
/// all, e.g. the old workers.dev URL while the custom domain is new
/// (`tool/build_web.sh --push-server-fallback ...`). Never shown in the UI.
const kFallbackPushServerUrl = String.fromEnvironment('PUSH_SERVER_FALLBACK_URL');

class PushServerException implements Exception {
  PushServerException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// Talks to the push server (push-server/ Cloudflare Worker) so "ready"
/// alerts arrive even when the web app is closed. Entirely optional: with no
/// built-in server URL or no subscription every method is a no-op.
class PushAlertService extends ChangeNotifier implements NotificationService {
  PushAlertService({
    http.Client? client,
    SharedPreferencesAsync? prefs,
    this.appUrl,
    String? defaultServerUrl,
    String? fallbackServerUrl,
    int Function()? witherLead,
    this._currentSubscription,
  }) : _client = client ?? http.Client(),
       _prefs = prefs ?? SharedPreferencesAsync(),
       _defaultServerUrl = defaultServerUrl ?? kDefaultPushServerUrl,
       _fallbackServerUrl = fallbackServerUrl ?? kFallbackPushServerUrl,
       _witherLead = witherLead ?? (() => 30);

  final int Function() _witherLead;

  /// The browser's existing PushSubscription JSON (see PwaBridge); lets the
  /// app re-register by itself when the server has pruned an idle
  /// subscription.
  final Future<String?> Function()? _currentSubscription;
  Future<String?>? _resubscribing;

  static const unreachableMessage = "Couldn't reach the alert server. Check your connection and try again.";
  static const noServerMessage = "Push alerts aren't available in this version of the app.";

  /// Old builds let users type a server URL and saved it here. It is no
  /// longer read; [init] deletes it.
  static const _kLegacyServer = 'push_server_url';
  static const _kSub = 'push_subscription_id';

  final http.Client _client;
  final SharedPreferencesAsync _prefs;
  final String _defaultServerUrl;
  final String _fallbackServerUrl;

  /// Opened when a notification is tapped.
  String? appUrl;

  String _serverUrl = '';
  String _fallbackUrl = '';
  String? _subscriptionId;
  String? _vapidKey;
  String? lastError;

  /// Internal (requests and tests); not for display.
  String get serverUrl => _serverUrl;
  String? get subscriptionId => _subscriptionId;
  String? get cachedVapidKey => _vapidKey;
  bool get hasServer => _serverUrl.isNotEmpty;
  bool get active => hasServer && _subscriptionId != null;

  @override
  NotificationMode get mode => active ? NotificationMode.push : NotificationMode.inAppOnly;

  @override
  Future<void> init() async {
    _serverUrl = normalizeUrl(_defaultServerUrl);
    final fallback = normalizeUrl(_fallbackServerUrl);
    _fallbackUrl = _serverUrl.isEmpty || fallback == _serverUrl ? '' : fallback;
    _subscriptionId = await _prefs.getString(_kSub);
    final legacy = await _prefs.getString(_kLegacyServer);
    if (legacy != null) {
      // A subscription made against a different (custom) server is unknown
      // to the built-in one: drop it so "Enable alerts" shows again. The
      // fallback address is the same server, so its subscriptions stay.
      final old = normalizeUrl(legacy);
      if (old != _serverUrl && (old.isEmpty || old != _fallbackUrl) && _subscriptionId != null) {
        _subscriptionId = null;
        await _prefs.remove(_kSub);
      }
      await _prefs.remove(_kLegacyServer);
    }
    notifyListeners();
  }

  /// "x.workers.dev/" -> "https://x.workers.dev"
  static String normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<http.Response> _send(String base, String path, Map<String, dynamic>? body) {
    final uri = Uri.parse('$base$path');
    final req = body == null
        ? _client.get(uri)
        : _client.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    return req.timeout(const Duration(seconds: 15));
  }

  Future<Map<String, dynamic>> _call(String path, [Map<String, dynamic>? body]) async {
    if (!hasServer) throw PushServerException(noServerMessage);
    http.Response res;
    try {
      res = await _send(_serverUrl, path, body);
    } on http.ClientException catch (e) {
      // Connection failed outright (DNS, TLS, offline): the request never
      // reached the server, so trying the fallback address can't apply it
      // twice. Timeouts are not retried (the first try may have landed).
      if (_fallbackUrl.isEmpty) {
        logDebug('alert server request failed', e);
        throw PushServerException(unreachableMessage);
      }
      try {
        res = await _send(_fallbackUrl, path, body);
      } catch (e2) {
        logDebug('alert server request failed (also via fallback)', e2);
        throw PushServerException(unreachableMessage);
      }
      logDebug('alert server: using the fallback address for this session');
      _serverUrl = _fallbackUrl;
      _fallbackUrl = '';
    } catch (e) {
      logDebug('alert server request failed', e);
      throw PushServerException(unreachableMessage);
    }
    Map<String, dynamic> data = const {};
    try {
      data = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final err = data['error'] as String?;
      throw PushServerException(
        err == null || err.isEmpty || err.contains('://')
            ? 'The alert server returned an error (${res.statusCode}).'
            : 'Alert server: $err',
        status: res.statusCode,
      );
    }
    return data;
  }

  /// Fetches the server's VAPID public key (do this BEFORE the user taps
  /// "Enable alerts" so the permission request stays inside the tap).
  Future<String> fetchVapidKey() async {
    final data = await _call('/vapid-public-key');
    final key = data['publicKey'] as String?;
    if (key == null || key.isEmpty) throw PushServerException("The alert server isn't set up for alerts yet.");
    _vapidKey = key;
    notifyListeners();
    return key;
  }

  /// Registers a browser PushSubscription (JSON from the bridge) and syncs
  /// all pending timers.
  Future<void> register(String subscriptionJson, List<FarmTimer> timers) async {
    final sub = jsonDecode(subscriptionJson);
    final data = await _call('/subscribe', {'subscription': sub});
    _subscriptionId = data['subscriptionId'] as String;
    await _prefs.setString(_kSub, _subscriptionId!);
    lastError = null;
    notifyListeners();
    await syncAll(timers);
  }

  Future<void> unregister() async {
    final id = _subscriptionId;
    _subscriptionId = null;
    await _prefs.remove(_kSub);
    notifyListeners();
    if (id != null && hasServer) {
      try {
        await _call('/unsubscribe', {'subscriptionId': id});
      } catch (e) {
        logDebug('unsubscribe failed', e);
      }
    }
  }

  Future<int?> sendTest() async => (await _callAsSubscriber('/test', {'url': appUrl}))['pushStatus'] as int?;

  /// Calls [path] with our subscription id. If the server answers 404 (it
  /// prunes idle subscriptions), re-registers the browser's existing push
  /// subscription and retries ONCE with the new id, without any visible
  /// error. A second 404, or no browser subscription, is passed on.
  Future<Map<String, dynamic>> _callAsSubscriber(String path, Map<String, dynamic> body) async {
    final id = _subscriptionId;
    try {
      return await _call(path, {...body, 'subscriptionId': id});
    } on PushServerException catch (e) {
      if (e.status != 404) rethrow;
      final fresh = await _resubscribe(id);
      if (fresh == null || fresh == id) rethrow;
      // Plain _call: the retry itself never re-subscribes again (no loops).
      return _call(path, {...body, 'subscriptionId': fresh});
    }
  }

  /// One re-registration at a time; calls that failed with the same stale
  /// id share it. Returns the new id or null.
  Future<String?> _resubscribe(String? staleId) {
    final current = _subscriptionId;
    if (current != null && current != staleId) return Future.value(current); // done by a parallel call
    return _resubscribing ??= _registerExisting().whenComplete(() => _resubscribing = null);
  }

  Future<String?> _registerExisting() async {
    final get = _currentSubscription;
    if (get == null || !hasServer) return null;
    try {
      // serviceWorker.ready never settles without a service worker: bound it.
      final json = await get().timeout(const Duration(seconds: 10));
      if (json == null || json.isEmpty) return null; // permission revoked / unsubscribed
      final data = await _call('/subscribe', {'subscription': jsonDecode(json)});
      final id = data['subscriptionId'];
      if (id is! String || id.isEmpty) return null;
      _subscriptionId = id;
      await _prefs.setString(_kSub, id);
      logDebug('push: re-registered after the server forgot the subscription');
      return id;
    } catch (e) {
      logDebug('push: re-register failed', e);
      return null;
    }
  }

  static String alertId(FarmTimer t) => '${t.id}:${t.notificationId}';
  static String warningId(FarmTimer t) => '${alertId(t)}:wither';

  Map<String, dynamic> alertFor(FarmTimer t) {
    final where = t.label == null ? '' : ' at ${t.label}';
    final qty = t.quantity > 1 ? '${t.quantity}× ' : '';
    return {
      'id': alertId(t),
      'fireAt': t.readyAtUtc.toUtc().toIso8601String(),
      'title': '${t.itemName} is ready!',
      'body': 'Harvest $qty${t.itemName}$where.',
      'url': ?appUrl,
    };
  }

  /// The wither warning alert, or null (unknown wither time / warnings off).
  Map<String, dynamic>? warningFor(FarmTimer t) {
    final lead = _witherLead();
    final at = TimerMath.witherWarningAt(t, lead);
    if (at == null) return null;
    return {
      'id': warningId(t),
      'fireAt': at.toUtc().toIso8601String(),
      'title': witherWarningTitle(t),
      'body': witherWarningBody(t, lead),
      'url': ?appUrl,
    };
  }

  /// Future alerts for [t] (ready and/or wither warning).
  List<Map<String, dynamic>> alertsFor(FarmTimer t, DateTime now) {
    final w = warningFor(t);
    return [
      if (t.readyAtUtc.isAfter(now)) alertFor(t),
      if (w != null && DateTime.parse(w['fireAt'] as String).isAfter(now)) w,
    ];
  }

  /// Runs a server call; on failure records [lastError] instead of throwing
  /// (timers must keep working without the server).
  Future<void> _bestEffort(String path, Map<String, dynamic> body) async {
    if (!active) return;
    try {
      await _callAsSubscriber(path, body);
      if (lastError != null) {
        lastError = null;
        notifyListeners();
      }
    } on PushServerException catch (e) {
      lastError = e.message;
      if (e.status == 404 || e.status == 410) {
        // Server forgot us and re-registering didn't work (or the push
        // service says the subscription is gone): user must enable again.
        _subscriptionId = null;
        await _prefs.remove(_kSub);
      }
      notifyListeners();
    }
  }

  @override
  Future<void> scheduleReady(FarmTimer timer) async {
    final alerts = alertsFor(timer, DateTime.now().toUtc());
    if (alerts.isEmpty) return;
    await _bestEffort('/schedule', {'alerts': alerts});
  }

  @override
  Future<void> cancel(FarmTimer timer) => _bestEffort('/cancel', {'ids': idsFor(timer)});

  /// Both alert ids of [t] (ready + wither warning).
  static List<String> idsFor(FarmTimer t) => [alertId(t), warningId(t)];

  /// Timers per request (2 alerts each; the server accepts 300 ids).
  static const batchSize = 50;

  static Iterable<List<T>> _chunks<T>(List<T> list, int size) sync* {
    for (var i = 0; i < list.length; i += size) {
      yield list.sublist(i, i + size > list.length ? list.length : i + size);
    }
  }

  /// One `/schedule` request for the whole batch (ready + wither alerts),
  /// with the [replacing] timers' alerts cancelled in the same request.
  /// Batches above [batchSize] timers are split.
  @override
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []}) async {
    if (!active) return;
    final now = DateTime.now().toUtc();
    final cancel = [for (final t in replacing) ...idsFor(t)];
    final chunks = _chunks(timers, batchSize).toList();
    if (chunks.isEmpty) chunks.add(const []);
    for (var i = 0; i < chunks.length; i++) {
      final alerts = [for (final t in chunks[i]) ...alertsFor(t, now)];
      final ids = i == 0 ? cancel : const <String>[];
      if (alerts.isEmpty && ids.isEmpty) continue;
      if (alerts.isEmpty) {
        await _bestEffort('/cancel', {'ids': ids});
      } else {
        await _bestEffort('/schedule', {'alerts': alerts, if (ids.isNotEmpty) 'cancel': ids});
      }
    }
  }

  /// One `/cancel` request per [batchSize] × 2 timers.
  @override
  Future<void> cancelAll(List<FarmTimer> timers) async {
    if (!active) return;
    for (final chunk in _chunks(timers, batchSize * 2)) {
      await _bestEffort('/cancel', {
        'ids': [for (final t in chunk) ...idsFor(t)],
      });
    }
  }

  @override
  Future<void> syncAll(List<FarmTimer> timers) {
    final now = DateTime.now().toUtc();
    return _bestEffort('/sync', {
      'alerts': [for (final t in timers) ...alertsFor(t, now)],
    });
  }

  @override
  Future<void> showReadyNow(FarmTimer timer) async {}
  @override
  Future<void> showWitherWarningNow(FarmTimer timer) async {}
}
