import 'package:flutter/material.dart';

import '../../platform/pwa_bridge.dart';
import '../../theme/app_theme.dart';
import '../install_guide_screen.dart';
import 'settings_section.dart';

/// Settings > Install: link to the install guide and the browser hint.
class InstallSection extends StatelessWidget {
  const InstallSection({super.key, required this.info});

  final PwaInfo info;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return SettingsSection(
      title: 'Install',
      children: [
        ListTile(
          key: const Key('installTile'),
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.install_mobile, color: AppColors.gold),
          title: const Text('Install the app', style: TextStyle(fontSize: 15)),
          subtitle: Text(
            info.standalone ? 'Running as an installed app. ✓' : 'Step-by-step for iPhone / iPad and Android',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => InstallGuideScreen.open(context, info),
        ),
        if (info.isWeb && !info.standalone) ...[
          Text(
            info.ios
                ? 'Open in Safari, tap Share, then "Add to Home Screen". Push alerts only work in the Home Screen app (iOS 16.4+).'
                : 'Use your browser menu: "Install app" / "Add to Home screen".',
          ),
          const SizedBox(height: 6),
          Text(
            'Timers in this browser tab and in the installed app are stored separately. '
            'Use Export/Import below to move them.',
            style: small?.copyWith(color: AppColors.overdue),
          ),
        ],
      ],
    );
  }
}
