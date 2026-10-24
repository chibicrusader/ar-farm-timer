import 'package:flutter/material.dart';

import '../models/farm_item.dart';
import '../models/farm_timer.dart';
import '../services/timer_math.dart';
import '../theme/app_theme.dart';
import 'status_chip.dart';

String formatLocalTime(BuildContext context, DateTime utc) {
  final local = utc.toLocal();
  final now = DateTime.now();
  final time = TimeOfDay.fromDateTime(local).format(context);
  final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
  if (sameDay) return time;
  return '${local.month}/${local.day} $time';
}

class TimerCard extends StatelessWidget {
  const TimerCard({
    super.key,
    required this.timer,
    required this.now,
    required this.onHarvest,
    required this.onDelete,
    this.showLabel = true,
  });

  /// Hidden in the grouped view, where the farm is the section header.
  final bool showLabel;

  final FarmTimer timer;
  final DateTime now;
  final VoidCallback onHarvest;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = timer;
    final status = TimerMath.status(t, now);
    final color = AppColors.forStatus(status);
    final remaining = TimerMath.remaining(t, now);
    final wither = TimerMath.untilWither(t, now);
    final theme = Theme.of(context);
    final category = FarmCategory.values.firstWhere((c) => c.name == t.category, orElse: () => FarmCategory.other);

    final mainText = switch (status) {
      TimerStatus.growing => TimerMath.formatDuration(remaining),
      TimerStatus.ready => 'READY',
      TimerStatus.overdue => 'LOST',
    };
    final subText = switch (status) {
      TimerStatus.growing => 'Ready at ${formatLocalTime(context, t.readyAtUtc)}',
      TimerStatus.ready => 'Ready for ${TimerMath.formatDuration(remaining)}',
      TimerStatus.overdue => 'Withered ${TimerMath.formatDuration(wither!)} ago',
    };

    String? witherLine;
    if (t.witherAtUtc != null && status != TimerStatus.overdue) {
      witherLine = status == TimerStatus.ready
          ? 'Withers in ${TimerMath.formatDuration(wither!)} (${formatLocalTime(context, t.witherAtUtc!)})'
          : 'Withers at ${formatLocalTime(context, t.witherAtUtc!)} if not harvested';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(categoryIcon(category), color: AppColors.gold, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.quantity > 1 ? '${t.itemName}  ×${t.quantity}' : t.itemName,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (t.label != null && showLabel)
                            Text(t.label!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.goldDim)),
                          if (t.cycleLabel != null) Text('Harvest ${t.cycleLabel}', style: theme.textTheme.bodySmall),
                          if (t.preferredClimate) const TagChip('climate', color: AppColors.growing),
                          if (t.watered) const TagChip('watered', color: AppColors.growing),
                          if (t.farmhand) const TagChip('farmhand', color: AppColors.goldDim),
                          if (t.witherCustom) const TagChip('own wither time', color: AppColors.overdue),
                        ],
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          mainText,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(subText, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: TimerMath.progress(t, now),
                minHeight: 5,
                color: color,
                backgroundColor: AppColors.surfaceHigh,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: FittedBox(fit: BoxFit.scaleDown, child: StatusChip(status)),
                      ),
                      const SizedBox(width: 8),
                      if (witherLine != null)
                        Expanded(
                          flex: 3,
                          child: Text(
                            witherLine,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: status == TimerStatus.ready ? AppColors.overdue : null,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                if (status != TimerStatus.growing)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
                    child: TextButton.icon(
                      onPressed: onHarvest,
                      icon: Icon(t.hasMoreCycles ? Icons.replay : Icons.agriculture, size: 18),
                      label: Text(
                        status == TimerStatus.overdue
                            ? 'Clear'
                            : t.hasMoreCycles
                            ? 'Harvest & regrow'
                            : 'Harvest',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Delete timer',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
