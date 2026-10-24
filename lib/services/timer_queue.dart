import 'package:flutter/foundation.dart';

import '../models/pending_timer.dart';

/// Timers waiting to be started together ("Add to list" → "Start N timers").
/// Starting them all at once sends ONE request to the push server instead of
/// one per timer. In memory only: the list is short-lived by design.
class TimerQueue extends ChangeNotifier {
  /// Most timers in one list (one push-server request; 2 alerts each).
  static const maxItems = 50;

  final List<PendingTimer> _items = [];

  List<PendingTimer> get items => List.unmodifiable(_items);
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  bool get isFull => _items.length >= maxItems;

  /// Adds [p]; returns false when the list is full.
  bool add(PendingTimer p) {
    if (isFull) return false;
    _items.add(p);
    notifyListeners();
    return true;
  }

  void replaceAt(int index, PendingTimer p) {
    if (index < 0 || index >= _items.length) return;
    _items[index] = p;
    notifyListeners();
  }

  PendingTimer? removeAt(int index) {
    if (index < 0 || index >= _items.length) return null;
    final p = _items.removeAt(index);
    notifyListeners();
    return p;
  }

  void insert(int index, PendingTimer p) {
    _items.insert(index.clamp(0, _items.length), p);
    notifyListeners();
  }

  /// Removes and returns everything.
  List<PendingTimer> takeAll() {
    final all = List.of(_items);
    _items.clear();
    notifyListeners();
    return all;
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}
