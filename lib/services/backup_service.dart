import 'dart:convert';

import '../models/farm_timer.dart';

/// Export/import of timers as a small JSON file.
class BackupService {
  const BackupService._();

  static const format = 'archerage-farm-timer-backup';
  static const version = 1;

  static String encode(List<FarmTimer> timers, DateTime now) => const JsonEncoder.withIndent('  ').convert({
    'format': format,
    'version': version,
    'exportedAt': now.toUtc().toIso8601String(),
    'timers': timers.map((t) => t.toJson()).toList(),
  });

  /// Parses a backup (or a bare list of timers). Throws [FormatException]
  /// with a user-readable message on bad input.
  static List<FarmTimer> decode(String text) {
    final Object? data;
    try {
      data = jsonDecode(text.trim());
    } on FormatException {
      throw const FormatException('Not valid JSON. Paste the whole backup file.');
    }
    final List<dynamic> list;
    if (data is List) {
      list = data;
    } else if (data is Map && data['timers'] is List) {
      if (data['format'] != null && data['format'] != format) {
        throw const FormatException('This is not an AR Farm Timer backup.');
      }
      final v = data['version'];
      if (v is num && v > version) {
        throw const FormatException('Backup is from a newer app version. Update the app first.');
      }
      list = data['timers'] as List;
    } else {
      throw const FormatException('No timers found in this file.');
    }
    if (list.length > maxImportTimers) {
      throw const FormatException('This backup has too many timers ($maxImportTimers at most).');
    }
    final out = <FarmTimer>[];
    for (final e in list) {
      final FarmTimer t;
      try {
        t = FarmTimer.fromJson(_clipStrings(Map<String, dynamic>.from(e as Map)));
      } catch (_) {
        throw const FormatException('A timer in the backup is damaged or incomplete.');
      }
      if (!_plausible(t)) throw const FormatException('A timer in the backup is damaged or incomplete.');
      out.add(t);
    }
    return out;
  }

  /// Most timers one import (file, paste or link) may add.
  static const maxImportTimers = 1000;
  static const _maxText = 200;
  static const _maxId = 100;
  static final _unsafeChars = RegExp('[\u0000-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]');

  /// Upper bound for any duration in a backup (5 years, in minutes).
  static const _maxMinutes = 5 * 525600.0;
  static final _minDate = DateTime.utc(2000);
  static final _maxDate = DateTime.utc(2100);

  /// Backups (and `#import=` links, which anyone can craft) are untrusted:
  /// over-long text is cut, so a link can't plant huge strings.
  /// Control and bidi-override characters are replaced by spaces, so a
  /// crafted name can't add fake lines or reorder the import dialog's text.
  static Map<String, dynamic> _clipStrings(Map<String, dynamic> j) {
    String? clip(Object? v, int max) {
      if (v == null) return null;
      var s = (v as String).replaceAll(_unsafeChars, ' ');
      if (s.length > max) {
        s = s.substring(0, max);
        // Don't leave half a surrogate pair at the cut.
        final last = s.codeUnitAt(s.length - 1);
        if (last >= 0xD800 && last <= 0xDBFF) s = s.substring(0, s.length - 1);
      }
      return s;
    }

    return {
      ...j,
      'itemName': clip(j['itemName'], _maxText),
      'category': clip(j['category'], 64),
      'label': clip(j['label'], _maxText),
    };
  }

  /// Rejects values the app can't handle (they would throw while drawing
  /// the timer on every start, e.g. a wither time beyond DateTime's range).
  static bool _plausible(FarmTimer t) {
    bool minutes(double? v, {bool allowNull = false}) =>
        v == null ? allowNull : v.isFinite && v >= 0 && v <= _maxMinutes;
    bool date(DateTime d) => !d.isBefore(_minDate) && d.isBefore(_maxDate);
    return t.id.isNotEmpty &&
        t.id.length <= _maxId &&
        t.itemName.trim().isNotEmpty &&
        t.quantity >= 1 &&
        t.quantity <= 100000 &&
        minutes(t.growMinutes) &&
        minutes(t.regrowMinutes) &&
        minutes(t.witherMinutes, allowNull: true) &&
        (t.totalCycles == null || (t.totalCycles! >= 1 && t.totalCycles! <= 100000)) &&
        t.cycle >= 1 &&
        t.cycle <= 1000000 &&
        date(t.plantedAtUtc) &&
        date(t.readyAtUtc);
  }

  /// Longest one-tap transfer payload we put in a URL (#import=...). Bigger
  /// backups use the file / clipboard instead. ~60 timers fit.
  static const maxTransferLength = 32000;

  /// Compact backup as base64url (no padding) for `https://artimer.win/#import=`.
  static String encodeTransfer(List<FarmTimer> timers, DateTime now) {
    final json = jsonEncode({
      'format': format,
      'version': version,
      'exportedAt': now.toUtc().toIso8601String(),
      'timers': timers.map((t) => t.toJson()).toList(),
    });
    return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  }

  /// Reverses [encodeTransfer]; throws [FormatException] on bad input.
  static List<FarmTimer> decodeTransfer(String payload) {
    final p = payload.trim();
    if (p.isEmpty || p.length > maxTransferLength * 2 || !RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(p)) {
      throw const FormatException('The transfer link is damaged.');
    }
    final String text;
    try {
      text = utf8.decode(base64Url.decode(base64Url.normalize(p)));
    } catch (_) {
      throw const FormatException('The transfer link is damaged.');
    }
    return decode(text);
  }

  static String fileName(DateTime now) {
    final l = now.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'ar-farm-timers-${l.year}${two(l.month)}${two(l.day)}-${two(l.hour)}${two(l.minute)}.json';
  }
}
