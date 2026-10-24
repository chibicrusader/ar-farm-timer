import 'package:flutter/material.dart';

import '../../services/timer_queue.dart';

/// Bottom buttons of the start sheet: "Save changes" when editing a list
/// entry, otherwise "Add to list" / "Start timer" (+ "Add and start all").
class StartSheetButtons extends StatelessWidget {
  const StartSheetButtons({
    super.key,
    required this.editing,
    required this.busy,
    required this.queue,
    required this.onQueue,
    required this.onStart,
  });

  final bool editing;
  final bool busy;
  final TimerQueue queue;

  /// Adds to (or saves in) the list; `thenStart` starts the whole list.
  final void Function({bool thenStart}) onQueue;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    if (editing) {
      return FilledButton.icon(
        key: const Key('saveQueued'),
        onPressed: onQueue,
        icon: const Icon(Icons.check),
        label: const Text('Save changes'),
      );
    }
    final queued = queue.length;
    final canQueue = !busy && !queue.isFull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('addToList'),
                onPressed: canQueue ? onQueue : null,
                icon: const Icon(Icons.playlist_add),
                label: const Text('Add to list'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                key: const Key('startOne'),
                onPressed: busy ? null : onStart,
                icon: const Icon(Icons.timer_outlined),
                label: const Text('Start timer'),
              ),
            ),
          ],
        ),
        if (queued > 0) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            key: const Key('addAndStartAll'),
            onPressed: canQueue ? () => onQueue(thenStart: true) : null,
            icon: const Icon(Icons.playlist_play),
            label: Text('Add and start all ${queued + 1} timers'),
          ),
          Text(
            queue.isFull
                ? 'The list is full ($queued). Start it first.'
                : '$queued already in the list. "Start timer" starts only this one.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
