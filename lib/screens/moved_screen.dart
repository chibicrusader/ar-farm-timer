import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/pwa_bridge.dart';
import '../services/backup_service.dart';
import '../services/timer_controller.dart';
import '../theme/app_theme.dart';

/// Blocking notice on the old address (archerage-farm-timer.pages.dev) when
/// this browser has saved data: explains the move to artimer.win and helps
/// carry the timers over (file export, clipboard, or a one-tap transfer link).
/// Visitors without saved data never see it: web/moved.js redirects them.
class MovedScreen extends StatefulWidget {
  const MovedScreen({super.key, required this.controller, required this.bridge, required this.onContinue});
  final TimerController controller;
  final PwaBridge bridge;

  /// "Continue here for now".
  final VoidCallback onContinue;

  static const newHost = 'artimer.win';

  @override
  State<MovedScreen> createState() => _MovedScreenState();
}

class _MovedScreenState extends State<MovedScreen> {
  String? _status;

  String get _newUrl => widget.bridge.info.movedTo ?? 'https://${MovedScreen.newHost}/';
  PwaInfo get _info => widget.bridge.info;

  /// iPhone/iPad Home Screen app: its storage is separate from Safari's, so a
  /// transfer link opened in Safari would not reach the new Home Screen app.
  bool get _iosApp => _info.ios && _info.standalone;

  void _export() {
    final now = widget.controller.now;
    final json = BackupService.encode(widget.controller.timers, now);
    final name = BackupService.fileName(now);
    // Share/download must start synchronously inside the tap.
    final saving = widget.bridge.saveFile(name, json);
    unawaited(
      saving.then(
        (r) {
          if (!mounted) return;
          setState(() {
            _status = switch (r) {
              'shared' => 'Backup shared. Keep the file (e.g. Save to Files).',
              'downloaded' => 'Backup downloaded: $name',
              'cancelled' => null,
              _ => 'Export is not available here. Use "Copy backup" instead.',
            };
          });
        },
        onError: (Object e) {
          if (mounted) setState(() => _status = 'Export failed ($e). Use "Copy backup" instead.');
        },
      ),
    );
  }

  void _copy() {
    unawaited(
      Clipboard.setData(ClipboardData(text: BackupService.encode(widget.controller.timers, widget.controller.now))),
    );
    setState(() => _status = 'Backup copied. In the new app: Settings → Backup → Paste backup.');
  }

  String? get _transferUrl {
    final payload = BackupService.encodeTransfer(widget.controller.timers, widget.controller.now);
    if (payload.length > BackupService.maxTransferLength) return null;
    return '$_newUrl#import=$payload';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final n = widget.controller.timers.length;
                final loaded = widget.controller.loaded;
                final transfer = loaded && n > 0 && !_iosApp ? _transferUrl : null;
                final saved = !loaded
                    ? 'Your timers are saved on this device, under the old address.'
                    : n == 0
                    ? 'Your farms and alert settings are saved on this device, under the old address.'
                    : 'Your $n timer${n == 1 ? ' is' : 's are'} saved on this device, under the old address.';
                return SingleChildScrollView(
                  key: const Key('movedScreen'),
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.move_up, color: AppColors.gold, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        'The app has moved to ${MovedScreen.newHost}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(color: AppColors.gold),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '$saved This address will stop getting updates. Move your timers over in a minute:',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                          child: Column(
                            children: [
                              const _Step(1, 'Tap "Export backup" below (or "Copy backup").'),
                              _Step(
                                2,
                                'Open ${MovedScreen.newHost} in ${_info.android ? 'Chrome' : 'Safari (iPhone) or Chrome'}.',
                              ),
                              const _Step(
                                3,
                                'Add it to the Home Screen: Share → "Add to Home Screen" (iPhone) or ⋮ → "Install app".',
                              ),
                              const _Step(4, 'In the new app: Settings → Backup → Import file (or Paste backup).'),
                              const _Step(5, 'Settings → Alerts → "Enable alerts" again. Then remove the old icon.'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const Key('movedExport'),
                        onPressed: loaded ? _export : null,
                        icon: const Icon(Icons.ios_share),
                        label: const Text('Export backup'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('movedCopy'),
                        onPressed: loaded ? _copy : null,
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy backup'),
                      ),
                      if (_status != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _status!,
                            key: const Key('movedStatus'),
                            textAlign: TextAlign.center,
                            style: small?.copyWith(color: AppColors.ready),
                          ),
                        ),
                      const SizedBox(height: 16),
                      if (transfer != null) ...[
                        FilledButton.tonalIcon(
                          key: const Key('movedTransfer'),
                          onPressed: () => widget.bridge.openUrl(transfer),
                          icon: const Icon(Icons.bolt),
                          label: Text('Open ${MovedScreen.newHost} with my timers'),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 8),
                          child: Text(
                            'One tap: ${MovedScreen.newHost} offers to add these timers in this browser. '
                            'A Home Screen app on iPhone keeps its own storage, so import the backup there.',
                            textAlign: TextAlign.center,
                            style: small,
                          ),
                        ),
                      ],
                      OutlinedButton.icon(
                        key: const Key('movedOpen'),
                        onPressed: () => widget.bridge.openUrl(_newUrl),
                        icon: const Icon(Icons.open_in_new),
                        label: Text('Open ${MovedScreen.newHost}'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        key: const Key('movedContinue'),
                        onPressed: widget.onContinue,
                        child: const Text('Continue here for now'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: AppColors.gold,
          child: Text(
            '$n',
            style: const TextStyle(color: AppColors.surface, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
