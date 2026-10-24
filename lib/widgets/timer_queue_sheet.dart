import 'package:flutter/material.dart';

import '../models/pending_timer.dart';
import '../services/timer_controller.dart';
import '../services/timer_math.dart';
import '../services/timer_queue.dart';
import '../theme/app_theme.dart';
import 'start_timer_sheet.dart';
import 'status_chip.dart';

/// Grow time of a list entry with all of its modifiers.
double pendingGrowMinutes(PendingTimer p) => TimerMath.effectiveGrowMinutes(
  p.item,
  preferredClimate: p.preferredClimate,
  watered: p.watered,
  farmhand: p.farmhand,
  overrideMinutes: p.overrideGrowMinutes,
);

/// "Ready in 1h 26m" if the list were started now.
String pendingReadyText(PendingTimer p) {
  final left = TimerMath.minutes(pendingGrowMinutes(p)) - p.plantedAgo;
  return left <= Duration.zero ? 'Ready now' : 'Ready in ${TimerMath.formatDuration(left)}';
}

/// Short tags for the options set on a list entry.
List<String> pendingTags(PendingTimer p) {
  final item = p.item;
  final overridden = (p.overrideGrowMinutes ?? 0) > 0;
  return [
    if (p.preferredClimate && item.hasClimateBonus && !overridden) 'climate',
    if (p.watered && item.wateredMultiplier != null && !overridden) 'watered',
    if (p.farmhand && (item.farmhandMultiplier ?? 1.0) != 1.0 && !overridden) 'farmhand',
    if (overridden) 'custom ${TimerMath.formatMinutes(p.overrideGrowMinutes!)}',
    if ((p.witherMinutes ?? 0) > 0) 'own wither time',
    if (p.plantedAgo > Duration.zero) 'planted ${TimerMath.formatMinutes(p.plantedAgo.inSeconds / 60)} ago',
  ];
}

/// Bar shown under the Catalog / Timers tabs while the list has entries.
class TimerQueueBar extends StatelessWidget {
  const TimerQueueBar({
    super.key,
    required this.queue,
    required this.onReview,
    required this.onStart,
    this.busy = false,
  });
  final TimerQueue queue;
  final VoidCallback onReview;
  final VoidCallback onStart;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final n = queue.length;
    return Material(
      key: const Key('queueBar'),
      color: AppColors.surfaceHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const Key('reviewQueue'),
                  onTap: onReview,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.playlist_add_check, color: AppColors.gold),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                n == 1 ? '1 timer in list' : '$n timers in list',
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                'Tap to review or edit',
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.goldDim),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('startQueuedBar'),
                onPressed: busy ? null : onStart,
                icon: const Icon(Icons.play_arrow),
                label: Text('Start $n'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "to start" list: review, edit or remove entries, then start them
/// all with one tap. Returns true when the player tapped Start.
Future<bool?> showTimerQueueSheet(BuildContext context, TimerController controller) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    builder: (_) => TimerQueueSheet(controller: controller),
  );
}

class TimerQueueSheet extends StatelessWidget {
  const TimerQueueSheet({super.key, required this.controller});
  final TimerController controller;

  Future<void> _edit(BuildContext context, int index, PendingTimer p) =>
      showStartTimerSheet(context, p.item, controller, initial: p, editIndex: index);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final queue = controller.queue;
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        final items = queue.items;
        final n = items.length;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.playlist_add_check, color: AppColors.gold),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Timers to start ($n)', style: theme.textTheme.titleLarge)),
                      if (n > 0)
                        TextButton(key: const Key('clearQueue'), onPressed: queue.clear, child: const Text('Clear')),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Times count from when you tap Start. Tap an entry to edit it.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  if (n == 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'The list is empty. Pick items in the Catalog and tap "Add to list".',
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: n,
                        separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0x33C9A45C)),
                        itemBuilder: (context, i) => _QueueTile(
                          key: ValueKey('queued:$i'),
                          entry: items[i],
                          onTap: () => _edit(context, i, items[i]),
                          onRemove: () => queue.removeAt(i),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('addMore'),
                          onPressed: () => Navigator.of(context).pop(false),
                          icon: const Icon(Icons.add),
                          label: const Text('Add more'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('startQueued'),
                          onPressed: n == 0 ? null : () => Navigator.of(context).pop(true),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(n == 1 ? 'Start 1 timer' : 'Start $n timers'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({super.key, required this.entry, required this.onTap, required this.onRemove});
  final PendingTimer entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = entry;
    final where = [?p.farm, ?p.zone].join(' · ');
    final tags = pendingTags(p);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: Icon(categoryIcon(p.item.category), color: AppColors.gold),
      title: Text(p.quantity > 1 ? '${p.item.name} ×${p.quantity}' : p.item.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [if (where.isNotEmpty) where, pendingReadyText(p)].join(' • '),
            style: const TextStyle(color: AppColors.parchment),
          ),
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, runSpacing: 4, children: [for (final t in tags) TagChip(t)]),
            ),
        ],
      ),
      trailing: IconButton(tooltip: 'Remove from list', icon: const Icon(Icons.close), onPressed: onRemove),
    );
  }
}
