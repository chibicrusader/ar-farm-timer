import 'package:flutter/material.dart';

import '../platform/pwa_bridge.dart';
import '../privacy/privacy_text.dart';
import '../theme/app_theme.dart';

/// The full privacy notice (same text as web/privacy.html).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key, required this.bridge});
  final PwaBridge bridge;

  static Future<void> open(BuildContext context, PwaBridge bridge) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrivacyScreen(bridge: bridge)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.45);
    final link = body?.copyWith(color: AppColors.gold, decoration: TextDecoration.underline);
    return Scaffold(
      appBar: AppBar(title: const Text('PRIVACY')),
      body: SelectionArea(
        child: ListView(
          key: const Key('privacyPage'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Semantics(
              header: true,
              child: Text(privacyTitle, style: theme.textTheme.headlineSmall?.copyWith(color: AppColors.gold)),
            ),
            const SizedBox(height: 6),
            Text(privacyUpdated, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('privacyOpenWeb'),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                onPressed: () => bridge.openUrl(privacyUrl),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open as web page'),
              ),
            ),
            for (final b in privacyBlocks)
              switch (b) {
                PrivacyHeading() => Padding(
                  padding: const EdgeInsets.only(top: 22, bottom: 8),
                  child: Semantics(
                    header: true,
                    child: Text(
                      b.text,
                      style: theme.textTheme.titleMedium?.copyWith(color: AppColors.gold, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                PrivacyBullet() => Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('•  ', style: body?.copyWith(color: AppColors.gold)),
                      Expanded(
                        child: b.sub.isEmpty && b.after == null
                            ? Text(b.text, style: body)
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(b.text, style: body),
                                  for (final s in b.sub)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6, top: 4),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('◦  ', style: body?.copyWith(color: AppColors.gold)),
                                          Expanded(child: Text(s, style: body)),
                                        ],
                                      ),
                                    ),
                                  if (b.after != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(b.after!, style: body),
                                    ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                PrivacyParagraph() => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: b.email
                      ? Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: b.text),
                              WidgetSpan(
                                alignment: PlaceholderAlignment.baseline,
                                baseline: TextBaseline.alphabetic,
                                child: InkWell(
                                  key: const Key('privacyEmail'),
                                  onTap: () => bridge.openUrl('mailto:$privacyEmail'),
                                  child: Text(privacyEmail, style: link),
                                ),
                              ),
                            ],
                          ),
                          style: body,
                        )
                      : Text(b.text, style: body),
                ),
              },
          ],
        ),
      ),
    );
  }
}
