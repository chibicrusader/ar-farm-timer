import 'dart:convert';

import 'package:archeragefarmtimer/app.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FixtureBundle extends CachingAssetBundle {
  _FixtureBundle(this.json);
  final String json;
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(Uint8List.fromList(utf8.encode(json)));
  @override
  Future<String> loadString(String key, {bool cache = true}) async => json;
}

const _fixture = '''[
 {"name":"Example Potato","category":"crop","growTimeMinutes":30,"harvestCycles":1,"climate":"Temperate","notes":"EXAMPLE DATA","archerageConfirmed":false},
 {"name":"Example Apple Tree","category":"fruit_tree","growTimeMinutes":240,"harvestCycles":null,"harvestIntervalMinutes":60,"climate":"Any","archerageConfirmed":true}
]''';

void main() {
  testWidgets('catalog -> start timer -> appears in timers list', (tester) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final controller = TimerController(repository: TimerRepository(), notifications: NoopNotificationService());
    await tester.pumpWidget(
      FarmTimerApp(
        controller: controller,
        catalog: CatalogService(bundle: _FixtureBundle(_fixture)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No active timers'), findsOneWidget);

    await tester.tap(find.text('Browse catalog'));
    await tester.pumpAndSettle();
    expect(find.text('CROPS'), findsOneWidget);
    expect(find.text('TREES'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'potato');
    await tester.pumpAndSettle();
    expect(find.text('Example Apple Tree'), findsNothing);

    await tester.tap(find.text('Example Potato'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Planted in preferred climate'), findsOneWidget);
    // Crop: both checkboxes visible and off by default; preview updates.
    expect(find.byKey(const Key('watered')), findsOneWidget);
    expect(find.byKey(const Key('farmhand')), findsOneWidget);
    expect(find.byKey(const Key('adjustedGrow')), findsNothing);
    for (final k in ['watered', 'farmhand']) {
      await tester.ensureVisible(find.byKey(Key(k)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(k)));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('×1.080'), findsOneWidget); // 0.9 * 1.2
    await tester.ensureVisible(find.text('Start timer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start timer'));
    await tester.pumpAndSettle();

    expect(controller.timers, hasLength(1));
    expect(find.text('Example Potato'), findsOneWidget);
    expect(find.text('Growing'), findsOneWidget);
    expect(find.text('watered'), findsOneWidget);
    expect(find.text('farmhand'), findsOneWidget);
    expect(controller.timers.single.growMinutes, closeTo(30 * 0.9 * 1.2, 1e-9));
    await tester.pumpWidget(const SizedBox());
  });
}
