import 'package:flutter/material.dart';

import '../../models/farm_item.dart';
import '../../services/timer_math.dart';
import '../../theme/app_theme.dart';
import '../catalog_text.dart';

/// Item name, grow/wither times and data notes at the top of the start sheet.
class StartSheetHeader extends StatelessWidget {
  const StartSheetHeader({super.key, required this.item, required this.editing});

  final FarmItem item;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wither = item.witherOrDeathMinutes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(categoryIcon(item.category), color: AppColors.gold),
            const SizedBox(width: 10),
            Expanded(child: Text('${editing ? 'Edit' : 'Plant'} ${item.name}', style: theme.textTheme.titleLarge)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Grows in ${TimerMath.formatMinutes(item.growTimeMinutes)}'
          '${item.isRepeating ? ' • ${harvestText(item)}' : ''}'
          '${wither != null ? ' • withers ${TimerMath.formatMinutes(wither)} after ready' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        if (item.notes != null || item.sources.isNotEmpty || item.archerageConfirmed == false) ...[
          const SizedBox(height: 6),
          Text(
            [
              if (item.archerageConfirmed == false) '⚠ Unverified on ArcheRage.',
              ?item.notes,
              if (item.sources.isNotEmpty) 'Source: ${item.sources.join('\n')}',
            ].join('\n'),
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.goldDim),
          ),
        ],
      ],
    );
  }
}
