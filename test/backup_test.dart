import 'dart:convert';

import 'package:archeragefarmtimer/models/farm_item.dart';
import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/services/backup_service.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes.dart';

FarmTimer _t(String id, {int hours = 1}) => FarmTimer(
  id: id,
  notificationId: 5,
  itemName: 'Rice',
  category: 'crops',
  label: 'Plot $id',
  plantedAtUtc: DateTime.utc(2026, 10, 17),
  readyAtUtc: DateTime.utc(2026, 10, 17, hours),
  growMinutes: hours * 60.0,
  watered: true,
);

void main() {
  test('encode/decode round trip', () {
    final json = BackupService.encode([_t('a'), _t('b', hours: 3)], DateTime.utc(2026, 10, 17, 9));
    expect(json, contains('"format": "archerage-farm-timer-backup"'));
    final back = BackupService.decode(json);
    expect(back.map((t) => t.id), ['a', 'b']);
    expect(back.first.toJson(), _t('a').toJson());
  });

  test('accepts a bare list', () {
    final list = '[${BackupService.encode([_t('a')], DateTime.utc(2026)).split('"timers": [')[1].split(']\n}')[0]}]';
    expect(BackupService.decode(list).single.id, 'a');
  });

  test('rejects bad input with readable messages', () {
    expect(() => BackupService.decode('not json'), throwsA(isA<FormatException>()));
    expect(() => BackupService.decode('{"hello": 1}'), throwsA(isA<FormatException>()));
    expect(() => BackupService.decode('{"format":"other","timers":[]}'), throwsA(isA<FormatException>()));
    expect(
      () => BackupService.decode('{"format":"archerage-farm-timer-backup","version":99,"timers":[]}'),
      throwsA(isA<FormatException>()),
    );
    expect(() => BackupService.decode('{"timers":[{"id":"x"}]}'), throwsA(isA<FormatException>()));
  });

  group('untrusted backups / #import= links', () {
    String backup(Map<String, dynamic> Function(Map<String, dynamic>) edit) {
      final j = _t('a').toJson();
      return '{"timers":[${jsonEncode(edit(j))}]}';
    }

    test('values that would crash the app are rejected', () {
      final bad = <Map<String, dynamic> Function(Map<String, dynamic>)>[
        (j) => j..['witherMinutes'] = 1e300,
        (j) => j..['growMinutes'] = -5,
        (j) => j..['regrowMinutes'] = 1e12,
        (j) => j..['quantity'] = 0,
        (j) => j..['cycle'] = 0,
        (j) => j..['totalCycles'] = 0,
        (j) => j..['readyAtUtc'] = '9999-01-01T00:00:00Z',
        (j) => j..['plantedAtUtc'] = '1900-01-01T00:00:00Z',
        (j) => j..['id'] = '',
        (j) => j..['id'] = 'x' * 101,
        (j) => j..['itemName'] = '   ',
        (j) => j..['label'] = 42,
      ];
      for (final edit in bad) {
        expect(() => BackupService.decode(backup(edit)), throwsFormatException);
        expect(
          () => BackupService.decodeTransfer(base64Url.encode(utf8.encode(backup(edit))).replaceAll('=', '')),
          throwsFormatException,
        );
      }
    });

    test('over-long text is cut, not stored whole', () {
      final t = BackupService.decode(
        backup(
          (j) => j
            ..['itemName'] = 'N' * 5000
            ..['label'] = 'L' * 5000
            ..['category'] = 'c' * 500,
        ),
      ).single;
      expect(t.itemName.length, 200);
      expect(t.label!.length, 200);
      expect(t.category.length, 64);
    });

    test('too many timers are refused', () {
      final one = jsonEncode(_t('a').toJson());
      final many = '[${List.filled(BackupService.maxImportTimers + 1, one).join(',')}]';
      expect(() => BackupService.decode(many), throwsFormatException);
      expect(BackupService.decode('[${List.filled(3, one).join(',')}]'), hasLength(3));
    });

    test('control and bidi-override characters are replaced (no fake dialog lines)', () {
      final t = BackupService.decode(
        backup(
          (j) => j
            ..['itemName'] = 'Carrot\n\nThis link is verified\u202Eevil'
            ..['label'] = 'Farm\u0000\u2066x',
        ),
      ).single;
      expect(t.itemName, 'Carrot  This link is verified evil');
      expect(t.label, 'Farm  x');
      // A cut never leaves half a surrogate pair.
      final e = BackupService.decode(backup((j) => j..['itemName'] = '${'a' * 199}\u{1F955}')).single;
      expect(e.itemName, 'a' * 199);
    });

    test('markup in names stays plain text (no HTML anywhere)', () {
      final t = BackupService.decode(backup((j) => j..['itemName'] = '<img src=x onerror=alert(1)>')).single;
      expect(t.itemName, '<img src=x onerror=alert(1)>');
    });
  });

  test('file name', () {
    expect(BackupService.fileName(DateTime(2026, 1, 2, 3, 4)), 'ar-farm-timers-20260102-0304.json');
  });

  group('controller import', () {
    setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

    test('merge skips existing ids, replace swaps everything, alerts resynced', () async {
      final notes = RecordingService(NotificationMode.inAppOnly);
      final c = TimerController(
        repository: TimerRepository(),
        notifications: notes,
        clock: () => DateTime.utc(2026, 10, 17),
      );
      await c.load();
      const item = FarmItem(name: 'Potato', category: FarmCategory.crops, growTimeMinutes: 30);
      final mine = await c.startTimer(item);

      expect(await c.importTimers([_t('a'), _t('b'), _t('a')]), 2);
      expect(c.timers.map((t) => t.id).toSet(), {mine.id, 'a', 'b'});
      expect(notes.log.last, 'sync:3');
      // notification ids are regenerated
      expect(c.timers.firstWhere((t) => t.id == 'a').notificationId, isNot(5));

      expect(await c.importTimers([_t('a'), _t('c')]), 1);
      expect(c.timers, hasLength(4));

      expect(await c.importTimers([_t('z')], replace: true), 1);
      expect(c.timers.map((t) => t.id), ['z']);
      // all four old timers cancelled in one batch call
      final cancels = notes.log.where((l) => l.startsWith('cancelAll:')).toList();
      expect(cancels, hasLength(1));
      expect(cancels.single.substring('cancelAll:'.length).split(','), hasLength(4));
      expect((await TimerRepository().loadAll()).map((t) => t.id), ['z']);
    });
  });
}
