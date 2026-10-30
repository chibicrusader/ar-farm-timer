import 'package:flutter/material.dart';

import '../platform/pwa_bridge.dart';
import '../privacy/privacy_text.dart';
import '../services/push_service.dart';
import '../services/timer_controller.dart';
import 'privacy_screen.dart';
import 'settings/alerts_section.dart';
import 'settings/backup_section.dart';
import 'settings/install_section.dart';
import 'settings/settings_section.dart';
import 'settings/storage_section.dart';

/// Settings tab: one card per section (see settings/).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller, required this.bridge, this.push});
  final TimerController controller;
  final PwaBridge bridge;

  /// Null when push alerts aren't available on this platform (native apps).
  final PushAlertService? push;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, ?push]),
      builder: (context, _) {
        final info = bridge.info;
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            InstallSection(info: info),
            AlertsSection(controller: controller, bridge: bridge, push: push),
            if (info.isWeb) StorageSection(bridge: bridge),
            BackupSection(controller: controller, bridge: bridge),
            SettingsSection(
              title: 'Privacy',
              children: [
                const Text(privacySummary, key: Key('privacySummary')),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('privacyOpen'),
                  onPressed: () => PrivacyScreen.open(context, bridge),
                  icon: const Icon(Icons.privacy_tip_outlined),
                  label: const Text('Read the full Privacy page'),
                ),
                if (info.isWeb)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('consentNoticeOpen'),
                      onPressed: bridge.showConsentNotice,
                      icon: const Icon(Icons.info_outline),
                      label: const Text('View the "Before you use" notice'),
                    ),
                  ),
              ],
            ),
            SettingsSection(
              title: 'About',
              children: [
                const Text('Item data: ArcheRage wiki DB + forum research (see notes per item). Times are estimates.'),
                const SizedBox(height: 4),
                Text('Timers are stored only on this device.', style: small),
              ],
            ),
          ],
        );
      },
    );
  }
}
