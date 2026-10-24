import 'package:flutter/material.dart';

import '../platform/pwa_bridge.dart';
import '../theme/app_theme.dart';

/// Shown in a browser tab (not the installed app): how to install, and the
/// warning that tab and Home Screen app keep separate timers.
class InstallBanner extends StatelessWidget {
  const InstallBanner({super.key, required this.info, required this.onDismiss, this.onShowGuide});
  final PwaInfo info;
  final VoidCallback onDismiss;
  final VoidCallback? onShowGuide;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Material(
      color: const Color(0xFF2A2416),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.add_to_home_screen, color: AppColors.gold),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.ios ? 'Install on your iPhone' : 'Install this app',
                    style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    info.ios
                        ? 'Tap Share (square with arrow) → "Add to Home Screen", then open it from the icon. '
                              'Harvest alerts only work in the Home Screen app.'
                        : 'Use your browser menu → "Install app" or "Add to Home screen" for offline use and alerts.',
                    style: small,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Heads-up: timers in this browser tab and in the Home Screen app are stored separately. '
                    'Use Settings → Export / Import to move them.',
                    style: small?.copyWith(color: const Color(0xFFE0A070)),
                  ),
                  if (onShowGuide != null)
                    TextButton.icon(
                      onPressed: onShowGuide,
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.help_outline, size: 16),
                      label: const Text('Show me how'),
                    ),
                ],
              ),
            ),
            IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close, size: 18), onPressed: onDismiss),
          ],
        ),
      ),
    );
  }
}
