import 'package:flutter/material.dart';

import '../models/farm_timer.dart';
import '../services/timer_controller.dart';
import '../services/timer_math.dart';
import '../theme/app_theme.dart';
import '../widgets/timer_card.dart';

class TimersScreen extends StatelessWidget {
  const TimersScreen({super.key, required this.controller, required this.onBrowse});
  final TimerController controller;
  final VoidCallback onBrowse;

  Future<void> _confirmDelete(BuildContext context, FarmTimer t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete timer?'),
        content: Text('Remove the timer for ${t.itemName}${t.label != null ? ' (${t.label})' : ''}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await controller.delete(t.id);
  }

  Future<void> _harvest(BuildContext context, FarmTimer t) async {
    final messenger = ScaffoldMessenger.of(context);
    if (TimerMath.status(t, controller.now) == TimerStatus.overdue) {
      await controller.delete(t.id);
      return;
    }
    final next = await controller.harvest(t.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          next == null
              ? 'Harvested ${t.itemName}. Timer finished.'
              : 'Harvested ${t.itemName}. Harvest ${next.cycleLabel} ready in '
                    '${TimerMath.formatDuration(TimerMath.remaining(next, controller.now))}.',
        ),
      ),
    );
  }

  Future<void> _renameFarm(BuildContext context, String name) async {
    final to = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(name: name),
    );
    if (to != null && to.trim().isNotEmpty) await controller.renameFarm(name, to);
  }

  Future<void> _deleteFarm(BuildContext context, String name, int count) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete farm "$name"?'),
        content: Text(
          'Keep its $count timer(s) without a farm name, or delete the timers too. '
          'Deleting timers also cancels their alerts.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: const Text('Keep timers')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.overdue),
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: Text('Delete $count timer(s)'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await controller.deleteFarm(name, deleteTimers: choice == 'all');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.farms]),
      builder: (context, _) {
        if (!controller.loaded) return const Center(child: CircularProgressIndicator());
        final timers = controller.timers;
        final now = controller.now;
        if (timers.isEmpty) {
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.agriculture, size: 64, color: AppColors.goldDim),
                  const SizedBox(height: 12),
                  const Text('No active timers', style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 6),
                  const Text(
                    'Pick something you planted from the catalog to start tracking it.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: onBrowse,
                    icon: const Icon(Icons.menu_book),
                    label: const Text('Browse catalog'),
                  ),
                ],
              ),
            ),
          );
        }
        final ready = controller.countWhere(TimerStatus.ready);
        final overdue = controller.countWhere(TimerStatus.overdue);
        final farms = controller.farms;
        final grouped = farms.grouped;
        Widget card(FarmTimer t) => TimerCard(
          key: ValueKey(t.id),
          timer: t,
          now: now,
          showLabel: !grouped,
          onHarvest: () => _harvest(context, t),
          onDelete: () => _confirmDelete(context, t),
        );
        return ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 4,
                      children: [
                        Text('${timers.length} active'),
                        if (ready > 0) Text('$ready ready', style: const TextStyle(color: AppColors.ready)),
                        if (overdue > 0) Text('$overdue withered', style: const TextStyle(color: AppColors.overdue)),
                        Text(
                          controller.notifications.mode.description,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.goldDim),
                        ),
                      ],
                    ),
                  ),
                  SegmentedButton<bool>(
                    key: const Key('viewToggle'),
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(value: true, icon: Icon(Icons.yard_outlined, size: 18), tooltip: 'Group by farm'),
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.format_list_bulleted, size: 18),
                        tooltip: 'Soonest first',
                      ),
                    ],
                    selected: {grouped},
                    onSelectionChanged: (v) => farms.setGrouped(v.first),
                  ),
                ],
              ),
            ),
            if (!grouped)
              for (final t in timers) card(t)
            else
              for (final g in groupByFarm(timers)) ...[
                _FarmHeader(
                  key: ValueKey('farmHeader:${g.name ?? ''}'),
                  name: g.name,
                  ready: g.timers.where((t) => TimerMath.status(t, now) != TimerStatus.growing).length,
                  total: g.timers.length,
                  collapsed: farms.isCollapsed(g.name ?? ''),
                  onToggle: () => farms.toggleCollapsed(g.name ?? ''),
                  onRename: g.name == null ? null : () => _renameFarm(context, g.name!),
                  onDelete: g.name == null ? null : () => _deleteFarm(context, g.name!, g.timers.length),
                ),
                if (!farms.isCollapsed(g.name ?? ''))
                  for (final t in g.timers) card(t),
              ],
          ],
        );
      },
    );
  }
}

/// Timers of one farm (name null = no farm), in soonest-first order.
class FarmGroup {
  FarmGroup(this.name, this.timers);
  final String? name;
  final List<FarmTimer> timers;
}

/// Groups soonest-first [timers] by farm. Groups are ordered by their
/// soonest timer; timers without a farm come last.
List<FarmGroup> groupByFarm(List<FarmTimer> timers) {
  final map = <String?, List<FarmTimer>>{};
  for (final t in timers) {
    map.putIfAbsent(t.label, () => []).add(t);
  }
  final groups = [for (final e in map.entries) FarmGroup(e.key, e.value)];
  groups.sort((a, b) {
    if ((a.name == null) != (b.name == null)) return a.name == null ? 1 : -1;
    return a.timers.first.readyAtUtc.compareTo(b.timers.first.readyAtUtc);
  });
  return groups;
}

class _FarmHeader extends StatelessWidget {
  const _FarmHeader({
    super.key,
    required this.name,
    required this.ready,
    required this.total,
    required this.collapsed,
    required this.onToggle,
    this.onRename,
    this.onDelete,
  });
  final String? name;
  final int ready;
  final int total;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 2),
        child: Row(
          children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, color: AppColors.goldDim),
            const SizedBox(width: 4),
            Icon(name == null ? Icons.help_outline : Icons.yard_outlined, size: 18, color: AppColors.gold),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name ?? 'No farm',
                style: theme.textTheme.titleSmall?.copyWith(color: AppColors.gold, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              key: ValueKey('farmCount:${name ?? ''}'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ready > 0 ? AppColors.ready : AppColors.goldDim),
              ),
              child: Text(
                '$ready/$total ready',
                style: theme.textTheme.bodySmall?.copyWith(color: ready > 0 ? AppColors.ready : null),
              ),
            ),
            if (onRename != null || onDelete != null)
              PopupMenuButton<String>(
                key: ValueKey('farmMenu:${name ?? ''}'),
                tooltip: 'Farm options',
                onSelected: (v) => v == 'rename' ? onRename?.call() : onDelete?.call(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename farm')),
                  PopupMenuItem(value: 'delete', child: Text('Delete farm')),
                ],
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.name});
  final String name;
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _c = TextEditingController(text: widget.name);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename farm'),
    content: TextField(
      key: const Key('renameField'),
      controller: _c,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Farm / plot name'),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text('Rename')),
    ],
  );
}
