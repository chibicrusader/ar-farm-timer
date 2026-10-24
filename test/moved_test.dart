import 'dart:convert';

import 'package:archeragefarmtimer/app.dart';
import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/platform/pwa_bridge.dart';
import 'package:archeragefarmtimer/services/backup_service.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes.dart';

FarmTimer _t(String id, {String label = 'Home'}) {
  final now = DateTime.now().toUtc();
  return FarmTimer(
    id: id,
    notificationId: id.hashCode & 0x3fffffff,
    itemName: 'Rice $id',
    category: 'crops',
    label: label,
    plantedAtUtc: now,
    readyAtUtc: now.add(const Duration(hours: 2)),
    growMinutes: 120,
  );
}

const _oldSite = PwaInfo(
  isWeb: true,
  ios: true,
  pushSupported: true,
  appUrl: 'https://archerage-farm-timer.pages.dev/',
  movedTo: 'https://artimer.win/',
);
const _newSite = PwaInfo(isWeb: true, ios: true, pushSupported: true, appUrl: 'https://artimer.win/');

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData(0);
  @override
  Future<String> loadString(String key, {bool cache = true}) async => key.endsWith('zones.json')
      ? '{"zones":[]}'
      : jsonEncode([
          {'name': 'Rice', 'category': 'crop', 'growTimeMinutes': 60},
        ]);
}

void main() {
  group('transfer encoding', () {
    test('round trip, URL-safe, no padding', () {
      final timers = [_t('a'), _t('b', label: 'Lake plot ✓ ü')];
      final p = BackupService.encodeTransfer(timers, DateTime.utc(2026, 10, 19));
      expect(p, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      final back = BackupService.decodeTransfer(p);
      expect(back.map((t) => t.id), ['a', 'b']);
      expect(back.last.label, 'Lake plot ✓ ü');
      expect(BackupService.decodeTransfer('$p=').map((t) => t.id), ['a', 'b']); // padding tolerated
    });

    test('damaged or foreign payloads are rejected', () {
      expect(() => BackupService.decodeTransfer(''), throwsFormatException);
      expect(() => BackupService.decodeTransfer('not base64!'), throwsFormatException);
      expect(() => BackupService.decodeTransfer('AAAA'), throwsFormatException);
      final foreign = base64Url.encode(utf8.encode('{"format":"other","timers":[]}'));
      expect(() => BackupService.decodeTransfer(foreign), throwsFormatException);
      expect(
        () => BackupService.decodeTransfer('A' * (BackupService.maxTransferLength * 2 + 1)),
        throwsFormatException,
      );
    });

    test('about 60 timers fit in one transfer link', () {
      final p = BackupService.encodeTransfer([for (var i = 0; i < 60; i++) _t('timer-$i')], DateTime.utc(2026));
      expect(p.length, lessThan(BackupService.maxTransferLength));
    });
  });

  group('moved notice and import link', () {
    late List<String> clipboard;

    Future<(TimerController, FakeBridge)> pumpApp(
      WidgetTester tester, {
      required PwaInfo info,
      List<FarmTimer> saved = const [],
      String? importPayload,
      bool dismissed = false,
    }) async {
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      clipboard = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
        return null;
      });
      await tester.runAsync(() => TimerRepository().saveAll(saved));
      final controller = TimerController(repository: TimerRepository(), notifications: NoopNotificationService());
      final bridge = FakeBridge(info: info)
        ..importPayload = importPayload
        ..movedDismissed = dismissed;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        FarmTimerApp(
          controller: controller,
          catalog: CatalogService(bundle: _Bundle()),
          bridge: bridge,
        ),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && !controller.loaded; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      return (controller, bridge);
    }

    testWidgets('old address with saved timers: blocking notice, export, copy, transfer, continue', (tester) async {
      final (c, bridge) = await pumpApp(tester, info: _oldSite, saved: [_t('a'), _t('b'), _t('c')]);
      expect(find.byKey(const Key('movedScreen')), findsOneWidget);
      expect(find.text('The app has moved to artimer.win'), findsOneWidget);
      expect(find.textContaining('Your 3 timers are saved on this device'), findsOneWidget);
      expect(find.text('Catalog'), findsNothing); // blocking: the app is behind it

      // Export: existing share/download path with the full backup
      await tester.ensureVisible(find.byKey(const Key('movedExport')));
      await tester.tap(find.byKey(const Key('movedExport')));
      await tester.pumpAndSettle();
      expect(bridge.calls.where((x) => x.startsWith('saveFile:ar-farm-timers-')), hasLength(1));
      expect(BackupService.decode(bridge.lastSaved!).map((t) => t.id).toSet(), {'a', 'b', 'c'});
      expect(find.textContaining('Backup shared'), findsOneWidget);

      // Copy: clipboard gets the same backup (for "Paste backup")
      await tester.ensureVisible(find.byKey(const Key('movedCopy')));
      await tester.tap(find.byKey(const Key('movedCopy')));
      await tester.pumpAndSettle();
      expect(BackupService.decode(clipboard.single), hasLength(3));
      expect(find.textContaining('Paste backup'), findsWidgets);

      // One-tap transfer link (browser tab on iPhone: offered with a caveat)
      await tester.ensureVisible(find.byKey(const Key('movedTransfer')));
      await tester.tap(find.byKey(const Key('movedTransfer')));
      final open = bridge.calls.lastWhere((x) => x.startsWith('openUrl:'));
      expect(open, startsWith('openUrl:https://artimer.win/#import='));
      final payload = open.split('#import=').last;
      expect(BackupService.decodeTransfer(payload), hasLength(3));

      await tester.ensureVisible(find.byKey(const Key('movedOpen')));
      await tester.tap(find.byKey(const Key('movedOpen')));
      expect(bridge.calls.last, 'openUrl:https://artimer.win/');

      // Not locked out
      await tester.ensureVisible(find.byKey(const Key('movedContinue')));
      await tester.tap(find.byKey(const Key('movedContinue')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('dismissMoved'));
      expect(find.byKey(const Key('movedScreen')), findsNothing);
      expect(find.text('Catalog'), findsWidgets); // the app itself
      expect(c.timers, hasLength(3)); // nothing was deleted
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('installed iPhone app: no transfer link (separate storage), file/copy only', (tester) async {
      await pumpApp(
        tester,
        info: const PwaInfo(isWeb: true, ios: true, standalone: true, movedTo: 'https://artimer.win/'),
        saved: [_t('a')],
      );
      expect(find.textContaining('Your 1 timer is saved'), findsOneWidget);
      expect(find.byKey(const Key('movedTransfer')), findsNothing);
      expect(find.byKey(const Key('movedExport')), findsOneWidget);
      expect(find.byKey(const Key('movedOpen')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a backup too big for a URL falls back to file/copy', (tester) async {
      await pumpApp(tester, info: _oldSite, saved: [for (var i = 0; i < 120; i++) _t('t$i')]);
      expect(find.byKey(const Key('movedScreen')), findsOneWidget);
      expect(find.byKey(const Key('movedTransfer')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('dismissed this session, or the new address: no notice', (tester) async {
      await pumpApp(tester, info: _oldSite, saved: [_t('a')], dismissed: true);
      expect(find.byKey(const Key('movedScreen')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, info: _newSite, saved: [_t('a')]);
      expect(find.byKey(const Key('movedScreen')), findsNothing);
      expect(find.text('Catalog'), findsWidgets); // the app itself
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('#import link on the new address: confirm, then merge (nothing replaced)', (tester) async {
      final payload = BackupService.encodeTransfer([_t('a'), _t('b'), _t('x')], DateTime.utc(2026));
      final (c, _) = await pumpApp(tester, info: _newSite, saved: [_t('x'), _t('mine')], importPayload: payload);
      expect(find.byKey(const Key('importLinkDialog')), findsOneWidget);
      expect(find.text('Import 3 timers?'), findsOneWidget);
      expect(find.textContaining('added to the 2 timers you have here'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('importLinkMerge')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(c.timers.map((t) => t.id).toSet(), {'x', 'mine', 'a', 'b'});
      expect(find.textContaining('Imported 2 timers'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('#import link: cancel imports nothing; a damaged link only shows a message', (tester) async {
      final payload = BackupService.encodeTransfer([_t('a')], DateTime.utc(2026));
      var (c, _) = await pumpApp(tester, info: _newSite, saved: [_t('mine')], importPayload: payload);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.timers.map((t) => t.id), ['mine']);
      await tester.pumpWidget(const SizedBox());

      (c, _) = await pumpApp(tester, info: _newSite, saved: [_t('mine')], importPayload: 'AAAA');
      expect(find.byKey(const Key('importLinkDialog')), findsNothing);
      expect(find.textContaining('Could not import'), findsOneWidget);
      expect(c.timers, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
