import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/pwa_bridge.dart';
import 'settings_section.dart';

/// Settings > Storage (web): persistent storage status and request.
class StorageSection extends StatefulWidget {
  const StorageSection({super.key, required this.bridge});

  final PwaBridge bridge;

  @override
  State<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<StorageSection> with AutomaticKeepAliveClientMixin {
  PersistState? _persist;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load(widget.bridge.persisted()));
  }

  Future<void> _load(Future<PersistState> state) async {
    final p = await state;
    if (mounted) setState(() => _persist = p);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SettingsSection(
      title: 'Storage',
      children: [
        Text(switch (_persist) {
          PersistState.granted => 'Persistent storage: granted ✓ (timers won\'t be cleared automatically)',
          PersistState.notGranted => 'Persistent storage: not granted (iOS usually grants it to Home Screen apps)',
          PersistState.unsupported => 'Persistent storage: not supported by this browser',
          null => 'Persistent storage: checking…',
        }),
        if (_persist == PersistState.notGranted)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: () => unawaited(_load(widget.bridge.requestPersist())),
              child: const Text('Request persistent storage'),
            ),
          ),
      ],
    );
  }
}
