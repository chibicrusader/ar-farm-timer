import 'dart:async';
import 'dart:convert';

import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/push_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes.dart';

FarmTimer _t(String id, Duration fromNow, {String? label, int qty = 1}) {
  final now = DateTime.now().toUtc();
  return FarmTimer(
    id: id,
    notificationId: 42,
    itemName: 'Rice',
    category: 'crops',
    label: label,
    quantity: qty,
    plantedAtUtc: now,
    readyAtUtc: now.add(fromNow),
    growMinutes: 60,
  );
}

void main() {
  late List<http.Request> requests;
  late int Function(http.Request) statusFor;

  Future<http.Response> handler(http.Request req) async {
    requests.add(req);
    final status = statusFor(req);
    final path = req.url.path;
    final body = switch (path) {
      '/vapid-public-key' => {'publicKey': 'BKEY'},
      '/health' => {'ok': true},
      '/subscribe' => {'subscriptionId': 'sub-1234567890abcdef'},
      '/test' => {'pushStatus': 201},
      _ => status >= 400 ? {'error': 'unknown subscription'} : {'ok': true},
    };
    return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
  }

  MockClient client() => MockClient(handler);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    requests = [];
    statusFor = (_) => 200;
  });

  Map<String, dynamic> bodyOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

  test('normalizeUrl', () {
    expect(PushAlertService.normalizeUrl(' x.workers.dev/ '), 'https://x.workers.dev');
    expect(PushAlertService.normalizeUrl('http://127.0.0.1:8787//'), 'http://127.0.0.1:8787');
    expect(PushAlertService.normalizeUrl(''), '');
  });

  test('without a server everything is a no-op', () async {
    final p = PushAlertService(client: client(), defaultServerUrl: '');
    await p.init();
    expect(p.active, isFalse);
    expect(p.mode, NotificationMode.inAppOnly);
    await p.scheduleReady(_t('a', const Duration(hours: 1)));
    await p.cancel(_t('a', const Duration(hours: 1)));
    await p.syncAll([_t('a', const Duration(hours: 1))]);
    expect(requests, isEmpty);
  });

  test('register, schedule, cancel, sync, test, unregister', () async {
    final p = PushAlertService(client: client(), defaultServerUrl: 'srv.test/', appUrl: 'https://app.test/');
    await p.init();
    expect(p.serverUrl, 'https://srv.test');
    expect(await p.fetchVapidKey(), 'BKEY');

    final future = _t('t1', const Duration(hours: 2), label: 'Plot 3', qty: 4);
    final past = _t('t0', const Duration(minutes: -5));
    await p.register('{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"a","auth":"b"}}', [future, past]);
    expect(p.active, isTrue);
    expect(p.mode, NotificationMode.push);
    expect(await SharedPreferencesAsync().getString('push_subscription_id'), 'sub-1234567890abcdef');

    final sub = requests.firstWhere((r) => r.url.path == '/subscribe');
    expect((bodyOf(sub)['subscription'] as Map)['endpoint'], 'https://web.push.apple.com/x');
    final sync = requests.lastWhere((r) => r.url.path == '/sync');
    final alerts = (bodyOf(sync)['alerts'] as List).cast<Map<String, dynamic>>();
    expect(alerts, hasLength(1)); // past timer skipped
    final alert = alerts.single;
    expect(alert['id'], 't1:42');
    expect(alert['title'], 'Rice is ready!');
    expect(alert['body'], 'Harvest 4× Rice at Plot 3.');
    expect(alert['url'], 'https://app.test/');
    expect(DateTime.parse(alert['fireAt'] as String), future.readyAtUtc);

    await p.scheduleReady(future);
    expect(bodyOf(requests.last)['subscriptionId'], 'sub-1234567890abcdef');
    expect(requests.last.url.path, '/schedule');
    final n = requests.length;
    await p.scheduleReady(past); // not sent: already due
    expect(requests.length, n);

    await p.cancel(future);
    expect(requests.last.url.path, '/cancel');
    expect(bodyOf(requests.last)['ids'], ['t1:42', 't1:42:wither']);

    expect(await p.sendTest(), 201);

    await p.unregister();
    expect(p.active, isFalse);
    expect(requests.last.url.path, '/unsubscribe');
  });

  test('server errors never throw from timer operations; 404 drops subscription', () async {
    final p = PushAlertService(client: client(), defaultServerUrl: 'https://srv.test');
    await p.init();
    await p.register('{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"a","auth":"b"}}', []);
    statusFor = (_) => 500;
    await p.scheduleReady(_t('a', const Duration(hours: 1)));
    expect(p.lastError, isNotNull);
    expect(p.active, isTrue);
    statusFor = (_) => 404;
    await p.cancel(_t('a', const Duration(hours: 1)));
    expect(p.active, isFalse);
    expect(await SharedPreferencesAsync().getString('push_subscription_id'), isNull);
  });

  test('network failure is reported, not thrown', () async {
    final p = PushAlertService(
      client: MockClient((_) async => throw http.ClientException('offline')),
      defaultServerUrl: 'https://srv.test',
    );
    await p.init();
    await expectLater(p.fetchVapidKey(), throwsA(isA<PushServerException>()));
  });

  test('a saved custom server URL is ignored and deleted; built-in URL always used', () async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString('push_server_url', 'https://custom.example');
    await prefs.setString('push_subscription_id', 'sub-from-custom-server');
    final p = PushAlertService(client: client(), defaultServerUrl: 'https://srv.test');
    await p.init();
    expect(p.serverUrl, 'https://srv.test');
    expect(await prefs.getString('push_server_url'), isNull);
    // That subscription lived on the custom server: dropped so the user re-enables.
    expect(p.active, isFalse);
    expect(await prefs.getString('push_subscription_id'), isNull);
  });

  test('a saved URL equal to the built-in one keeps the subscription', () async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString('push_server_url', 'srv.test/');
    await prefs.setString('push_subscription_id', 'sub-1234567890abcdef');
    final p = PushAlertService(client: client(), defaultServerUrl: 'https://srv.test');
    await p.init();
    expect(p.active, isTrue);
    expect(await prefs.getString('push_server_url'), isNull);
  });

  test('errors never contain the server URL', () async {
    final offline = PushAlertService(
      client: MockClient((r) async => throw http.ClientException('XMLHttpRequest error.', r.url)),
      defaultServerUrl: 'https://srv.test',
    );
    await offline.init();
    await expectLater(
      offline.fetchVapidKey(),
      throwsA(isA<PushServerException>().having((e) => e.message, 'message', PushAlertService.unreachableMessage)),
    );
    final failing = PushAlertService(
      client: MockClient((r) async => http.Response('{"error":"see https://srv.test/docs"}', 500)),
      defaultServerUrl: 'https://srv.test',
    );
    await failing.init();
    await expectLater(
      failing.fetchVapidKey(),
      throwsA(isA<PushServerException>().having((e) => e.message, 'message', isNot(contains('srv.test')))),
    );
    final none = PushAlertService(client: client(), defaultServerUrl: '');
    await none.init();
    expect(none.hasServer, isFalse);
    await expectLater(none.fetchVapidKey(), throwsA(isA<PushServerException>()));
  });

  test('composite fans out and reports the best mode', () async {
    final a = RecordingService(NotificationMode.inAppOnly);
    final b = RecordingService(NotificationMode.push);
    final c = CompositeNotificationService([a, b]);
    expect(c.mode, NotificationMode.push);
    final t = _t('x', const Duration(hours: 1));
    await c.scheduleReady(t);
    await c.cancel(t);
    await c.syncAll([t]);
    expect(a.log, ['schedule:x', 'cancel:x', 'sync:1']);
    expect(b.log, a.log);
    expect(CompositeNotificationService([a]).mode, NotificationMode.inAppOnly);
  });

  group('fallback address (same server, e.g. old workers.dev URL)', () {
    const primary = 'https://push.example.test';
    const fallback = 'https://old.workers.example.test';

    PushAlertService service({required bool primaryDown, Exception? error}) {
      return PushAlertService(
        client: MockClient((req) async {
          if (req.url.host == 'push.example.test' && primaryDown) {
            requests.add(req);
            throw error ?? http.ClientException('Failed to fetch', req.url);
          }
          return handler(req);
        }),
        defaultServerUrl: primary,
        fallbackServerUrl: fallback,
      );
    }

    test('a connection failure retries once on the fallback and stays there', () async {
      final p = service(primaryDown: true);
      await p.init();
      expect(await p.fetchVapidKey(), 'BKEY');
      expect(requests.map((r) => r.url.host), ['push.example.test', 'old.workers.example.test']);
      requests.clear();
      await p.register('{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"a","auth":"b"}}', []);
      expect(p.active, isTrue);
      // No further tries on the unreachable address this session.
      expect(requests.map((r) => r.url.host).toSet(), {'old.workers.example.test'});
    });

    test('a healthy primary never touches the fallback', () async {
      final p = service(primaryDown: false);
      await p.init();
      await p.fetchVapidKey();
      expect(requests.single.url.host, 'push.example.test');
    });

    test('timeouts and HTTP errors are not retried elsewhere (the request may have landed)', () async {
      final p = service(primaryDown: true, error: TimeoutException('slow'));
      await p.init();
      await expectLater(p.fetchVapidKey(), throwsA(isA<PushServerException>()));
      expect(requests.map((r) => r.url.host), ['push.example.test']);

      requests.clear();
      statusFor = (_) => 503;
      final q = service(primaryDown: false);
      await q.init();
      await expectLater(q.fetchVapidKey(), throwsA(isA<PushServerException>()));
      expect(requests.map((r) => r.url.host), ['push.example.test']);
    });

    test('both addresses down: the usual message, no URL in it', () async {
      final p = PushAlertService(
        client: MockClient((req) async => throw http.ClientException('Failed to fetch', req.url)),
        defaultServerUrl: primary,
        fallbackServerUrl: fallback,
      );
      await p.init();
      final e = await p.fetchVapidKey().then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<PushServerException>());
      expect('$e', PushAlertService.unreachableMessage);
      expect('$e', isNot(contains('://')));
    });

    test('a legacy saved URL equal to the fallback keeps the subscription (same database)', () async {
      await SharedPreferencesAsync().setString('push_subscription_id', 'sub-1');
      await SharedPreferencesAsync().setString('push_server_url', 'old.workers.example.test/');
      final p = service(primaryDown: false);
      await p.init();
      expect(p.subscriptionId, 'sub-1');
      expect(await SharedPreferencesAsync().getString('push_server_url'), isNull);
    });
  });

  group('re-register after the server pruned the subscription (404)', () {
    // A tiny stateful push server: ids it knows, a counter for new ones.
    late Set<String> known;
    late int next;
    late bool subscribeWorks;
    MockClient server() => MockClient((req) async {
      requests.add(req);
      final b = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
      Map<String, dynamic> body;
      var status = 200;
      if (req.url.path == '/subscribe') {
        final id = 'sub-${next++}';
        if (subscribeWorks) known.add(id);
        body = {'subscriptionId': id};
      } else if (!known.contains(b['subscriptionId'])) {
        status = 404;
        body = {'error': 'unknown subscription (enable alerts again)'};
      } else {
        body = req.url.path == '/test' ? {'pushStatus': 201} : {'ok': true};
      }
      return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
    });
    const browserSub = '{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"a","auth":"b"}}';

    setUp(() {
      known = {};
      next = 1;
      subscribeWorks = true;
    });

    Future<PushAlertService> registered({Future<String?> Function()? current}) async {
      final p = PushAlertService(
        client: server(),
        defaultServerUrl: 'https://srv.test',
        currentSubscription: current ?? () async => browserSub,
      );
      await p.init();
      await p.register(browserSub, []);
      expect(p.subscriptionId, 'sub-1');
      known.clear(); // the server prunes it
      requests.clear();
      return p;
    }

    List<String> trace() => [
      for (final r in requests) '${r.url.path}:${r.body.isEmpty ? '' : bodyOf(r)['subscriptionId'] ?? ''}',
    ];

    test('schedule: silently re-subscribes and retries once with the new id', () async {
      final p = await registered();
      await p.scheduleReady(_t('a', const Duration(hours: 1)));
      expect(trace(), ['/schedule:sub-1', '/subscribe:', '/schedule:sub-2']);
      expect(bodyOf(requests[1])['subscription'], jsonDecode(browserSub));
      expect(p.active, isTrue);
      expect(p.lastError, isNull);
      expect(await SharedPreferencesAsync().getString('push_subscription_id'), 'sub-2');
      // Later calls use the new id directly.
      requests.clear();
      await p.cancel(_t('a', const Duration(hours: 1)));
      expect(trace(), ['/cancel:sub-2']);
    });

    test('sync, cancel and test re-subscribe the same way', () async {
      final p = await registered();
      await p.syncAll([_t('a', const Duration(hours: 1))]);
      expect(trace(), ['/sync:sub-1', '/subscribe:', '/sync:sub-2']);
      expect(p.lastError, isNull);
      known.clear();
      requests.clear();
      await p.cancelAll([_t('a', const Duration(hours: 1))]);
      expect(trace(), ['/cancel:sub-2', '/subscribe:', '/cancel:sub-3']);
      known.clear();
      requests.clear();
      expect(await p.sendTest(), 201);
      expect(trace(), ['/test:sub-3', '/subscribe:', '/test:sub-4']);
    });

    test('no loop: if the retry is refused too, it stops and alerts must be enabled again', () async {
      final p = await registered();
      subscribeWorks = false; // server hands out ids it then doesn't know
      await p.scheduleReady(_t('a', const Duration(hours: 1)));
      expect(trace(), ['/schedule:sub-1', '/subscribe:', '/schedule:sub-2']);
      expect(p.active, isFalse);
      expect(p.lastError, isNotNull);
      requests.clear();
      await p.scheduleReady(_t('b', const Duration(hours: 1)));
      expect(requests, isEmpty); // inactive: no more calls
    });

    test('no browser subscription (permission revoked): drops it like before, no /subscribe', () async {
      final p = await registered(current: () async => null);
      await p.scheduleReady(_t('a', const Duration(hours: 1)));
      expect(trace(), ['/schedule:sub-1']);
      expect(p.active, isFalse);
    });

    test('a hanging service worker lookup times out instead of blocking timers', () async {
      final p = await registered(current: () => Completer<String?>().future);
      await expectLater(
        p.scheduleReady(_t('a', const Duration(hours: 1))).timeout(const Duration(seconds: 15)),
        completes,
      );
      expect(p.active, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('parallel calls that hit 404 share ONE re-subscribe', () async {
      final p = await registered();
      await Future.wait([
        p.scheduleReady(_t('a', const Duration(hours: 1))),
        p.scheduleReady(_t('b', const Duration(hours: 1))),
        p.cancel(_t('c', const Duration(hours: 1))),
      ]);
      expect(trace().where((t) => t.startsWith('/subscribe')).length, 1);
      expect(p.subscriptionId, 'sub-2');
      expect(p.active, isTrue);
      expect(trace().where((t) => t.endsWith('sub-2')).length, 3);
    });

    test('410 from /test (push service: subscription gone) does not re-subscribe', () async {
      final p = PushAlertService(
        client: MockClient((req) async {
          requests.add(req);
          final body = switch (req.url.path) {
            '/subscribe' => {'subscriptionId': 'sub-1'},
            '/test' => {'error': 'subscription expired'},
            _ => {'ok': true},
          };
          final status = switch (req.url.path) {
            '/test' => 410,
            _ => 200,
          };
          return http.Response(jsonEncode(body), status);
        }),
        defaultServerUrl: 'https://srv.test',
        currentSubscription: () async => browserSub,
      );
      await p.init();
      await p.register(browserSub, []);
      requests.clear();
      await expectLater(p.sendTest(), throwsA(isA<PushServerException>()));
      expect(trace(), ['/test:sub-1']);
    });
  });
}
