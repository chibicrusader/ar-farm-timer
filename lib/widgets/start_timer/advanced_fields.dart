import 'package:flutter/material.dart';

import '../../models/farm_item.dart';
import '../../services/timer_math.dart';

/// The "Advanced" expander: planted-ago, custom grow time, custom wither time.
class AdvancedFields extends StatelessWidget {
  const AdvancedFields({
    super.key,
    required this.item,
    required this.plantedAgo,
    required this.customGrow,
    required this.wither,
    required this.onChanged,
  });

  final FarmItem item;
  final TextEditingController plantedAgo;
  final TextEditingController customGrow;
  final TextEditingController wither;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    const number = TextInputType.numberWithOptions(decimal: true);
    final data = item.witherOrDeathMinutes;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Advanced'),
      children: [
        TextField(
          controller: plantedAgo,
          keyboardType: number,
          onChanged: (_) => onChanged(),
          decoration: const InputDecoration(labelText: 'Planted minutes ago (if already planted)'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: customGrow,
          keyboardType: number,
          onChanged: (_) => onChanged(),
          decoration: const InputDecoration(labelText: 'Custom grow time in minutes (overrides data)'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('witherField'),
          controller: wither,
          keyboardType: number,
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: 'Withers/dies N minutes after ready (your value)',
            helperText: data != null
                ? 'Data: ${TimerMath.formatMinutes(data)}. Leave empty to use it.'
                : 'Unknown for this item. Enter it to get a wither warning.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}
