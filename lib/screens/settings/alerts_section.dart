import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/pwa_bridge.dart';
import '../../privacy/privacy_text.dart';
import '../../services/alert_settings.dart';
import '../../services/push_service.dart';
import '../../services/timer_controller.dart';
import '../../services/timer_math.dart';
import '../../theme/app_theme.dart';
import 'settings_section.dart';

/// Settings > Alerts: wither warning lead time and push alerts on/off.
/// Never shows the push server address.
class AlertsSection extends StatefulWidget {
  const AlertsSection({super.key, required this.controller, required this.bridge, this.push});

  final TimerController controller;
  final PwaBridge bridge;

  /// Null when push alerts aren't available on this platform (native apps).
  final PushAlertService? push;

  @override
  State<AlertsSection> createState() => _AlertsSectionState();
}

class _AlertsSectionState extends State<AlertsSection> with AutomaticKeepAliveClientMixin {
  bool _busy = false;
  String? _pushMessage;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_prefetchKey());
  }

  /// Loads the VAPID key ahead of time so "Enable alerts" can ask for
  /// permission synchronously inside the tap (required by iOS).
  Future<void> _prefetchKey() async {
    final push = widget.push;
    if (push == null || !push.hasServer || push.cachedVapidKey != null) return;
    try {
      await push.fetchVapidKey();
      if (mounted) setState(() => _pushMessage = null);
    } catch (e) {
      if (mounted) setState(() => _pushMessage = _errorText(e));
    }
  }

  /// User-facing error text. Server errors are already worded for users;
  /// anything else that mentions a URL gets the generic message.
  static String _errorText(Object e) {
    if (e is PushServerException) return e.message;
    final s = '$e';
    return s.contains('://') ? PushAlertService.unreachableMessage : s;
  }

  void _enableAlerts() {
    final push = widget.push!;
    final key = push.cachedVapidKey;
    if (key == null) {
      setState(() => _pushMessage = PushAlertService.unreachableMessage);
      unawaited(_prefetchKey());
      return;
    }
    // Synchronous call into JS first (inside the tap), then await.
    final pending = widget.bridge.enablePush(key);
    setState(() => _busy = true);
    unawaited(_finishEnable(push, pending));
  }

  Future<void> _finishEnable(PushAlertService push, Future<String> pending) async {
    try {
      final sub = await pending;
      await push.register(sub, widget.controller.timers);
      _pushMessage = null;
      if (mounted) showSnack(context, 'Alerts enabled. Timers will notify you even when the app is closed.');
    } catch (e) {
      _pushMessage = _errorText(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disableAlerts() async {
    setState(() => _busy = true);
    await widget.bridge.disablePush().catchError((_) {});
    await widget.push!.unregister();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _test() async {
    try {
      final status = await widget.push!.sendTest();
      if (mounted) showSnack(context, 'Test alert sent (push service status $status).');
    } catch (e) {
      if (mounted) setState(() => _pushMessage = _errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final push = widget.push;
    return SettingsSection(
      title: 'Alerts',
      children: [
        Text('Now: ${widget.controller.notifications.mode.description}'),
        const SizedBox(height: 8),
        _WitherLeadRow(controller: widget.controller),
        Text(
          'Only for items with a known wither/death time, or where you entered your own '
          '(start-timer sheet → Advanced). Most crops have no wither data.',
          style: small,
        ),
        if (push != null) ..._pushControls(push, small),
      ],
    );
  }

  List<Widget> _pushControls(PushAlertService push, TextStyle? small) {
    final info = widget.bridge.info;
    return [
      const SizedBox(height: 12),
      if (!push.hasServer)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '${PushAlertService.noServerMessage} You still get in-app alerts while the app is open.',
            style: small,
          ),
        ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (!push.active)
            FilledButton.icon(
              key: const Key('enableAlerts'),
              onPressed: _busy || !push.hasServer || !info.pushSupported ? null : _enableAlerts,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Enable alerts'),
            )
          else ...[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.send),
              label: const Text('Send test alert'),
            ),
            OutlinedButton(onPressed: _busy ? null : widget.controller.resyncAlerts, child: const Text('Resync')),
            TextButton(onPressed: _busy ? null : _disableAlerts, child: const Text('Disable')),
          ],
        ],
      ),
      if (!push.active)
        Padding(
          key: const Key('alertPrivacyNote'),
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 14, color: AppColors.goldDim),
              const SizedBox(width: 6),
              Expanded(child: Text(privacyAlertNote, style: small)),
            ],
          ),
        ),
      if (info.isWeb && !info.pushSupported)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            info.ios
                ? 'Push needs the Home Screen app on iOS 16.4 or newer.'
                : 'This browser does not support Web Push.',
            style: small,
          ),
        ),
      if (info.permission == 'denied') Text('Notifications are blocked: enable them in system Settings.', style: small),
      if (_pushMessage != null || push.lastError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_pushMessage ?? push.lastError!, style: small?.copyWith(color: AppColors.overdue)),
        ),
    ];
  }
}

class _WitherLeadRow extends StatelessWidget {
  const _WitherLeadRow({required this.controller});

  final TimerController controller;

  @override
  Widget build(BuildContext context) {
    final lead = controller.alertSettings.witherLeadMinutes;
    return Row(
      children: [
        const Expanded(child: Text('Wither warning before the deadline')),
        DropdownButton<int>(
          key: const Key('witherLead'),
          value: AlertSettings.leadOptions.contains(lead) ? lead : AlertSettings.defaultWitherLead,
          items: [
            for (final m in AlertSettings.leadOptions)
              DropdownMenuItem(value: m, child: Text(m == 0 ? 'Off' : TimerMath.formatMinutes(m.toDouble()))),
          ],
          onChanged: (v) {
            if (v != null) unawaited(controller.setWitherLead(v));
          },
        ),
      ],
    );
  }
}
