import 'package:flutter/foundation.dart';

/// Debug-only diagnostics.
///
/// Silent in release and profile builds. Never logs an exception's message
/// (it may contain URLs, ids or server text): only its type.
void logDebug(String message, [Object? error]) {
  if (!kDebugMode) return;
  debugPrint(error == null ? message : '$message (${error.runtimeType})');
}
