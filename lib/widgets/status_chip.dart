import 'package:flutter/material.dart';

import '../models/farm_timer.dart';
import '../theme/app_theme.dart';

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final TimerStatus status;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.forStatus(status);
    final text = switch (status) {
      TimerStatus.growing => 'Growing',
      TimerStatus.ready => 'Ready',
      TimerStatus.overdue => 'Withered / dead',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Small outlined tag used in catalog rows.
class TagChip extends StatelessWidget {
  const TagChip(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.goldDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withValues(alpha: 0.7)),
      ),
      child: Text(text, style: TextStyle(color: c, fontSize: 11)),
    );
  }
}
