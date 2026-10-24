import 'dart:convert';

import 'package:archeragefarmtimer/app.dart';
import 'package:archeragefarmtimer/platform/pwa_bridge.dart';
import 'package:archeragefarmtimer/privacy/privacy_text.dart';
import 'package:archeragefarmtimer/screens/settings_screen.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/push_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes.dart';

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData(0);
  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      '[{"name":"Rice","category":"crop","growTimeMinutes":60}]';
}

void main() {
  late List<String> paths;
  Future<(TimerController, PushAlertService?)> pump(
    WidgetTester tester,
    FakeBridge bridge, {
    bool withPush = true,
  }) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    paths = [];
    final push = withPush
        ? PushAlertService(
            client: MockClient((r) async {
              paths.add(r.url.path);
              final body = switch (r.url.path) {
                '/vapid-public-key' => {'publicKey': 'BKEY'},
                '/subscribe' => {'subscriptionId': 'sub-1234567890abcdef'},
                _ => {'ok': true},
              };
              return http.Response(jsonEncode(body), 200);
            }),
            defaultServerUrl: 'https://srv.test',
          )
        : null;
    final controller = TimerController(
      repository: TimerRepository(),
      notifications: CompositeNotificationService([NoopNotificationService(), ?push]),
    );
    await controller.notifications.init();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      FarmTimerApp(
        controller: controller,
        catalog: CatalogService(bundle: _Bundle()),
        bridge: bridge,
        push: push,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return (controller, push);
  }

  testWidgets('Safari tab shows install hint with separate-storage warning; dismiss persists', (tester) async {
    final bridge = FakeBridge();
    await pump(tester, bridge, withPush: false);
    expect(find.text('Install on your iPhone'), findsOneWidget);
    expect(find.textContaining('stored separately'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('Install on your iPhone'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('install guide opens from the app bar and shows both platforms', (tester) async {
    final bridge = FakeBridge();
    await pump(tester, bridge, withPush: false);
    await tester.tap(find.byTooltip('How to install'));
    await tester.pumpAndSettle();
    expect(find.text('HOW TO INSTALL'), findsOneWidget);
    expect(find.text('iPhone / iPad'), findsOneWidget);
    expect(find.text('Android'), findsOneWidget);
    // iOS user agent -> iPhone tab first.
    expect(find.textContaining('"Add to Home Screen"'), findsWidgets);
    expect(find.textContaining('Open the link below in Safari'), findsOneWidget);
    expect(find.text("You're already using the installed app."), findsNothing);
    await tester.tap(find.text('Android'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open the link below in Chrome'), findsOneWidget);
    expect(find.textContaining('"Install app"'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('install guide: Android tab by default, installed note, Settings tile and banner link', (tester) async {
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, android: true, standalone: true));
    await pump(tester, bridge, withPush: false);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('installTile')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open the link below in Chrome'), findsOneWidget);
    expect(find.text("You're already using the installed app."), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    await pump(tester, FakeBridge(), withPush: false);
    await tester.tap(find.text('Show me how'));
    await tester.pumpAndSettle();
    expect(find.text('HOW TO INSTALL'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('installed app: no hint, persistent storage requested', (tester) async {
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, ios: true, standalone: true, pushSupported: true));
    await pump(tester, bridge, withPush: false);
    expect(find.text('Install on your iPhone'), findsNothing);
    expect(bridge.calls, contains('requestPersist'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('update banner reloads', (tester) async {
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, standalone: true));
    await pump(tester, bridge, withPush: false);
    bridge.fireUpdate();
    await tester.pump();
    expect(find.text('A new version of the app is ready.'), findsOneWidget);
    await tester.tap(find.text('Reload'));
    expect(bridge.calls, contains('applyUpdate'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Settings: enable alerts subscribes via the bridge and server; export shares a file', (tester) async {
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, ios: true, standalone: true, pushSupported: true));
    final (controller, push) = await pump(tester, bridge);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(paths, contains('/vapid-public-key')); // prefetched before the tap
    await tester.tap(find.byKey(const Key('enableAlerts')));
    await tester.pumpAndSettle();
    expect(bridge.calls, contains('enablePush:BKEY'));
    expect(paths, containsAllInOrder(['/subscribe', '/sync']));
    expect(push!.active, isTrue);
    expect(find.text('Send test alert'), findsOneWidget);
    expect(controller.notifications.mode, NotificationMode.push);

    await tester.scrollUntilVisible(
      find.byKey(const Key('export')),
      200,
      scrollable: find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first,
    );
    await tester.pump(const Duration(seconds: 5)); // let the "Alerts enabled" snackbar go away
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export')));
    await tester.pumpAndSettle();
    expect(bridge.calls.any((c) => c.startsWith('saveFile:ar-farm-timers-')), isTrue);
    expect(bridge.lastSaved, contains('archerage-farm-timer-backup'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Settings → Alerts shows no server URL or URL field, even when the server is unreachable', (
    tester,
  ) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, ios: true, standalone: true, pushSupported: true));
    final push = PushAlertService(
      client: MockClient((r) async => throw http.ClientException('XMLHttpRequest error.', r.url)),
      defaultServerUrl: 'https://srv.test',
    );
    final controller = TimerController(
      repository: TimerRepository(),
      notifications: CompositeNotificationService([NoopNotificationService(), push]),
    );
    await controller.notifications.init();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      FarmTimerApp(
        controller: controller,
        catalog: CatalogService(bundle: _Bundle()),
        bridge: bridge,
        push: push,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enableAlerts')));
    await tester.pumpAndSettle();

    final settings = find.byType(SettingsScreen);
    expect(find.descendant(of: settings, matching: find.byType(TextField)), findsNothing);
    expect(find.descendant(of: settings, matching: find.byType(EditableText)), findsNothing);
    final texts = tester
        .widgetList<Text>(find.descendant(of: settings, matching: find.byType(Text)))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .toList();
    expect(texts, isNot(contains(contains('srv.test'))));
    expect(texts, isNot(contains(contains('://'))));
    expect(texts, isNot(contains(contains('workers.dev'))));
    expect(texts, isNot(contains(contains('Push server URL'))));
    expect(find.text(PushAlertService.unreachableMessage), findsOneWidget);
    expect(find.text('Enable alerts'), findsOneWidget);
    expect(find.byKey(const Key('witherLead')), findsOneWidget);
    expect(find.text(privacyAlertNote), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Settings: paste import merges timers', (tester) async {
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, standalone: true));
    final (controller, _) = await pump(tester, bridge, withPush: false);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('pasteImport')),
      200,
      scrollable: find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(find.byKey(const Key('pasteImport')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pasteImport')));
    await tester.pumpAndSettle();
    const backup =
        '{"format":"archerage-farm-timer-backup","version":1,"timers":[{"id":"imp1","notificationId":3,'
        '"itemName":"Rice","category":"crops","plantedAtUtc":"2026-10-17T00:00:00.000Z",'
        '"readyAtUtc":"2030-01-01T00:00:00.000Z","growMinutes":60}]}';
    await tester.enterText(find.byType(TextField).last, backup);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Import 1 timer?'), findsOneWidget);
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(controller.timers.single.id, 'imp1');
    await tester.pumpWidget(const SizedBox());
  });
}
