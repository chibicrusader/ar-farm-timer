import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/log.dart';

/// User alert preferences. witherLeadMinutes = how long before a known
/// wither/death deadline the "about to wither" warning fires (0 = off).
class AlertSettings extends ChangeNotifier {
  AlertSettings({SharedPreferencesAsync? prefs, int witherLeadMinutes = defaultWitherLead})
    : _prefsOverride = prefs,
      _lead = witherLeadMinutes;

  static const kWitherLead = 'wither_warning_minutes';
  static const defaultWitherLead = 30;
  static const leadOptions = [0, 10, 15, 30, 60, 120, 240];

  final SharedPreferencesAsync? _prefsOverride;
  SharedPreferencesAsync? _prefsCache;
  SharedPreferencesAsync get _prefs => _prefsOverride ?? (_prefsCache ??= SharedPreferencesAsync());

  int _lead;
  int get witherLeadMinutes => _lead;

  Future<void> load() async {
    try {
      _lead = (await _prefs.getInt(kWitherLead)) ?? _lead;
    } catch (e) {
      logDebug('AlertSettings load failed', e);
    }
    notifyListeners();
  }

  Future<void> setWitherLead(int minutes) async {
    _lead = minutes < 0 ? 0 : minutes;
    notifyListeners();
    try {
      await _prefs.setInt(kWitherLead, _lead);
    } catch (e) {
      logDebug('AlertSettings save failed', e);
    }
  }
}
