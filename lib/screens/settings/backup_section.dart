import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/pwa_bridge.dart';
import '../../services/backup_service.dart';
import '../../services/timer_controller.dart';
import 'settings_section.dart';

/// Settings > Backup: export (share / download / show JSON) and import.
class BackupSection extends StatelessWidget {
  const BackupSection({super.key, required this.controller, required this.bridge});

  final TimerController controller;
  final PwaBridge bridge;

  void _export(BuildContext context) {
    final now = controller.now;
    final json = BackupService.encode(controller.timers, now);
    final name = BackupService.fileName(now);
    if (bridge.info.isWeb) {
      // Share/download must start synchronously inside the tap.
      final saving = bridge.saveFile(name, json);
      unawaited(
        saving.then((r) {
          if (!context.mounted) return;
          if (r == 'unsupported') _showJson(context, json);
          if (r == 'downloaded') showSnack(context, 'Backup downloaded: $name');
        }),
      );
    } else {
      _showJson(context, json);
    }
  }

  void _showJson(BuildContext context, String json) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Backup JSON'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: SelectableText(json, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: json)));
                Navigator.pop(ctx);
                showSnack(context, 'Backup copied to clipboard');
              },
              child: const Text('Copy'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  void _pickFile(BuildContext context) {
    final picking = bridge.pickTextFile();
    unawaited(
      picking.then((text) async {
        if (text != null && context.mounted) await _confirmImport(context, text);
      }),
    );
  }

  Future<void> _pasteImport(BuildContext context) async {
    final text = await showDialog<String>(context: context, builder: (ctx) => const _PasteDialog());
    if (text != null && text.trim().isNotEmpty && context.mounted) await _confirmImport(context, text);
  }

  Future<void> _confirmImport(BuildContext context, String text) async {
    final List<dynamic> timers;
    try {
      timers = BackupService.decode(text);
    } on FormatException catch (e) {
      showSnack(context, e.message);
      return;
    }
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Import ${timers.length} timer${timers.length == 1 ? '' : 's'}?'),
        content: const Text('Merge keeps your current timers and adds new ones. Replace deletes current timers first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Merge')),
        ],
      ),
    );
    if (replace == null) return;
    final added = await controller.importTimers(BackupService.decode(text), replace: replace);
    if (context.mounted) showSnack(context, 'Imported $added timer${added == 1 ? '' : 's'}.');
  }

  @override
  Widget build(BuildContext context) {
    final isWeb = bridge.info.isWeb;
    return SettingsSection(
      title: 'Backup',
      children: [
        Text('${controller.timers.length} timer(s). Export regularly; it\'s a small JSON file.'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('export'),
              onPressed: () => _export(context),
              icon: const Icon(Icons.ios_share),
              label: Text(isWeb ? 'Export file' : 'Export'),
            ),
            if (isWeb)
              OutlinedButton.icon(
                onPressed: () => _pickFile(context),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import file'),
              ),
            OutlinedButton.icon(
              key: const Key('pasteImport'),
              onPressed: () => unawaited(_pasteImport(context)),
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste backup'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Owns its TextEditingController so it is disposed after the dialog closes.
class _PasteDialog extends StatefulWidget {
  const _PasteDialog();
  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Paste backup'),
    content: SizedBox(
      width: 480,
      child: TextField(
        controller: _ctrl,
        maxLines: 10,
        minLines: 5,
        decoration: const InputDecoration(hintText: '{"format": "archerage-farm-timer-backup", ...}'),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _ctrl.text), child: const Text('Next')),
    ],
  );
}
