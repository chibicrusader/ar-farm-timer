import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/farm_timer.dart';

/// Persists timers as a JSON list in shared_preferences.
class TimerRepository {
  TimerRepository({SharedPreferencesAsync? prefs}) : _prefs = prefs ?? SharedPreferencesAsync();

  static const storageKey = 'farm_timers_v1';
  final SharedPreferencesAsync _prefs;

  Future<List<FarmTimer>> loadAll() async {
    final raw = await _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = <FarmTimer>[];
      for (final e in list) {
        try {
          out.add(FarmTimer.fromJson(Map<String, dynamic>.from(e as Map)));
        } catch (_) {
          // Skip a corrupt entry rather than losing every timer.
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<FarmTimer> timers) =>
      _prefs.setString(storageKey, jsonEncode(timers.map((t) => t.toJson()).toList()));
}
