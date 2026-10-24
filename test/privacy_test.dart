import 'dart:convert';
import 'dart:io';

import 'package:archeragefarmtimer/app.dart';
import 'package:archeragefarmtimer/platform/pwa_bridge.dart';
import 'package:archeragefarmtimer/privacy/privacy_text.dart';
import 'package:archeragefarmtimer/screens/privacy_screen.dart';
import 'package:archeragefarmtimer/screens/settings_screen.dart';
import 'package:archeragefarmtimer/services/catalog_service.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';
import 'package:archeragefarmtimer/services/push_service.dart';
import 'package:archeragefarmtimer/services/timer_controller.dart';
import 'package:archeragefarmtimer/services/timer_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes.dart';

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData(0);
  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      '[{"name":"Rice","category":"crop","growTimeMinutes":60}]';
}

/// Plain text of an HTML fragment: tags dropped, entities the page uses decoded, whitespace collapsed.
String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Every <li> in document order, each with its OWN text (nested lists are
/// reported as their own items after it).
List<String> _listItems(String html) {
  final out = <String>[];
  final open = <int>[]; // index in [out] of each open <li>
  final buf = <StringBuffer>[];
  var depthInLi = 0; // <ul> nesting inside the innermost open <li>
  final nestedUl = <int>[];
  var pos = 0;
  for (final m in RegExp(r'<(/?)(li|ul)\b[^>]*>').allMatches(html)) {
    final chunk = html.substring(pos, m.start);
    if (buf.isNotEmpty && depthInLi == 0) buf.last.write(chunk);
    pos = m.end;
    final closing = m[1] == '/';
    if (m[2] == 'li') {
      if (!closing) {
        nestedUl.add(depthInLi);
        depthInLi = 0;
        open.add(out.length);
        out.add('');
        buf.add(StringBuffer());
      } else {
        out[open.removeLast()] = _text(buf.removeLast().toString());
        depthInLi = nestedUl.removeLast();
      }
    } else if (buf.isNotEmpty) {
      depthInLi += closing ? -1 : 1;
    }
  }
  return out;
}

void main() {
  Future<void> pump(WidgetTester tester, FakeBridge bridge) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final push = PushAlertService(
      client: MockClient((r) async {
        final body = switch (r.url.path) {
          '/vapid-public-key' => {'publicKey': 'BKEY'},
          '/subscribe' => {'subscriptionId': 'sub-1234567890abcdef'},
          _ => {'ok': true},
        };
        return http.Response(jsonEncode(body), 200);
      }),
      defaultServerUrl: 'https://srv.test',
    );
    final controller = TimerController(
      repository: TimerRepository(),
      notifications: CompositeNotificationService([NoopNotificationService(), push]),
    );
    await controller.notifications.init();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      FarmTimerApp(
        controller: controller,
        catalog: CatalogService(bundle: _Bundle()),
        bridge: bridge,
        push: push,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('Settings: alert note, Privacy section, full page with headings, bullets and contact email', (
    tester,
  ) async {
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, ios: true, standalone: true, pushSupported: true));
    await pump(tester, bridge);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text(privacyAlertNote), findsOneWidget); // next to "Enable alerts"
    expect(find.byKey(const Key('enableAlerts')), findsOneWidget);

    final settingsList = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('privacyOpen')), 200, scrollable: settingsList);
    await tester.pumpAndSettle();
    expect(find.text('PRIVACY'), findsOneWidget); // section title
    expect(find.text(privacySummary), findsOneWidget);
    expect(find.text('Read the full Privacy page'), findsOneWidget);

    await tester.tap(find.byKey(const Key('privacyOpen')));
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyScreen), findsOneWidget);
    expect(find.text(privacyTitle), findsOneWidget);
    expect(find.text(privacyUpdated), findsOneWidget);
    expect(find.text("What we don't collect"), findsOneWidget);
    expect(find.text('No ads.'), findsOneWidget);
    expect(find.text('•  '), findsWidgets);

    await tester.tap(find.byKey(const Key('privacyOpenWeb')));
    expect(bridge.calls, contains('openUrl:https://artimer.win/privacy.html'));

    final page = find.byKey(const Key('privacyPage'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('privacyEmail')),
      300,
      scrollable: find.descendant(of: page, matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('chibicrusader.business@gmail.com'), findsOneWidget);
    expect(find.text('Not affiliated'), findsOneWidget);
    await tester.tap(find.byKey(const Key('privacyEmail')));
    expect(bridge.calls, contains('openUrl:mailto:chibicrusader.business@gmail.com'));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the alert note is hidden once alerts are on', (tester) async {
    final bridge = FakeBridge(info: const PwaInfo(isWeb: true, ios: true, standalone: true, pushSupported: true));
    await pump(tester, bridge);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enableAlerts')));
    await tester.pumpAndSettle();
    expect(find.text('Send test alert'), findsOneWidget);
    expect(find.text(privacyAlertNote), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('web/privacy.html carries the same notice as the in-app page', () {
    final html = File('web/privacy.html').readAsStringSync();
    final body = html.substring(html.indexOf('<article>'), html.indexOf('</article>'));
    final h1 = RegExp(r'<h1>(.*?)</h1>', dotAll: true).allMatches(body).map((m) => _text(m[1]!)).toList();
    final h2 = RegExp(r'<h2>(.*?)</h2>', dotAll: true).allMatches(body).map((m) => _text(m[1]!)).toList();
    final li = _listItems(body);
    final p = RegExp(
      r'<p( class="updated")?>(.*?)</p>',
      dotAll: true,
    ).allMatches(body).map((m) => _text(m[2]!)).toList();

    expect(h1, [privacyTitle]);
    expect(p.first, privacyUpdated);
    expect(h2, [for (final b in privacyBlocks.whereType<PrivacyHeading>()) b.text]);
    expect(li, [
      for (final b in privacyBlocks.whereType<PrivacyBullet>()) ...[_text('${b.text} ${b.after ?? ''}'), ...b.sub],
    ]);
    expect(p.skip(1).toList(), [
      for (final b in privacyBlocks.whereType<PrivacyParagraph>()) b.email ? '${b.text}$privacyEmail' : b.text,
    ]);
    // email_off: stops Cloudflare's Email Obfuscation from swapping the address for a script.
    expect(body, contains('<!--email_off--><a href="mailto:$privacyEmail">$privacyEmail</a><!--/email_off-->'));
    expect(html, contains('href="/"')); // link back to the app
    expect(html, isNot(contains('<script'))); // standalone, no scripts
  });
}
