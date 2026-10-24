import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/zone.dart';
import '../util/log.dart';

/// Saved farm/plot names (with the zone last used for each), the last zone
/// picked, and the timers-list view options. Persisted in shared_preferences.
/// Every storage error is swallowed: this is convenience state only.
class FarmStore extends ChangeNotifier {
  FarmStore({SharedPreferencesAsync? prefs}) : _prefsOverride = prefs;

  static const kFarms = 'farms_v1';
  static const kLastZone = 'last_zone';
  static const kGrouped = 'timers_grouped';
  static const kCollapsed = 'collapsed_farms';

  final SharedPreferencesAsync? _prefsOverride;
  SharedPreferencesAsync? _prefsCache;
  SharedPreferencesAsync get _prefs => _prefsOverride ?? (_prefsCache ??= SharedPreferencesAsync());

  final Map<String, String?> _farms = {}; // name -> zone
  String? _lastZone;
  bool _grouped = true;
  final Set<String> _collapsed = {};

  /// Zone -> climate map from assets/zones.json (empty until loaded).
  List<Zone> zones = const [];
  Zone? zoneNamed(String? name) {
    if (name == null) return null;
    for (final z in zones) {
      if (z.name == name) return z;
    }
    return null;
  }

  void setZones(List<Zone> z) {
    zones = z;
    notifyListeners();
  }

  List<String> get farms => _farms.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  String? zoneFor(String farm) => _farms[farm];
  String? get lastZone => _lastZone;
  bool get grouped => _grouped;
  bool isCollapsed(String farm) => _collapsed.contains(farm);

  Future<void> load() async {
    try {
      final raw = await _prefs.getString(kFarms);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            if (e is Map && e['name'] is String && (e['name'] as String).trim().isNotEmpty) {
              _farms[(e['name'] as String).trim()] = e['zone'] as String?;
            }
          }
        }
      }
      _lastZone = await _prefs.getString(kLastZone);
      _grouped = (await _prefs.getBool(kGrouped)) ?? true;
      _collapsed.addAll((await _prefs.getStringList(kCollapsed)) ?? const []);
    } catch (e) {
      logDebug('FarmStore load failed', e);
    }
    notifyListeners();
  }

  Future<void> _save(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      logDebug('FarmStore save failed', e);
    }
  }

  Future<void> _saveFarms() => _save(
    () => _prefs.setString(
      kFarms,
      jsonEncode([
        for (final e in _farms.entries) {'name': e.key, 'zone': e.value},
      ]),
    ),
  );

  /// Remembers a farm name and the zone it is in (when given).
  Future<void> remember(String? farm, {String? zone}) async {
    if (zone != null) {
      _lastZone = zone;
      await _save(() => _prefs.setString(kLastZone, zone));
    }
    final name = farm?.trim();
    if (name != null && name.isNotEmpty) {
      _farms[name] = zone ?? _farms[name];
      await _saveFarms();
    }
    notifyListeners();
  }

  Future<void> setLastZone(String? zone) async {
    _lastZone = zone;
    await _save(() => zone == null ? _prefs.remove(kLastZone) : _prefs.setString(kLastZone, zone));
    notifyListeners();
  }

  Future<void> rename(String from, String to) async {
    final name = to.trim();
    if (name.isEmpty || name == from) return;
    final zone = _farms.remove(from);
    _farms[name] = zone ?? _farms[name];
    if (_collapsed.remove(from)) _collapsed.add(name);
    await _saveFarms();
    await _save(() => _prefs.setStringList(kCollapsed, _collapsed.toList()));
    notifyListeners();
  }

  Future<void> remove(String farm) async {
    _farms.remove(farm);
    _collapsed.remove(farm);
    await _saveFarms();
    await _save(() => _prefs.setStringList(kCollapsed, _collapsed.toList()));
    notifyListeners();
  }

  Future<void> setGrouped(bool v) async {
    _grouped = v;
    await _save(() => _prefs.setBool(kGrouped, v));
    notifyListeners();
  }

  Future<void> toggleCollapsed(String farm) async {
    if (!_collapsed.remove(farm)) _collapsed.add(farm);
    await _save(() => _prefs.setStringList(kCollapsed, _collapsed.toList()));
    notifyListeners();
  }
}
