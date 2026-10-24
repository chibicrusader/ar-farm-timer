import 'dart:io';

import 'package:archeragefarmtimer/util/log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logDebug never prints an exception message, only its type', () {
    final lines = <String?>[];
    final old = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m);
    try {
      logDebug('save failed', const FormatException('https://push.example.test/sub/0123 secret'));
      logDebug('plain');
    } finally {
      debugPrint = old;
    }
    expect(lines, ['save failed (FormatException)', 'plain']);
  });

  test('no debugPrint/print calls outside the logger', () {
    // Release builds must stay silent: everything goes through logDebug.
    final offenders = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && !f.path.endsWith('log.dart'))
          if (RegExp(r'(^|[^A-Za-z_.])(debugPrint|print)\(', multiLine: true).hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });
}
