import 'package:flutter/material.dart';

import '../models/farm_item.dart';
import '../services/catalog_service.dart';
import '../services/timer_controller.dart';
import '../services/timer_math.dart';
import '../theme/app_theme.dart';
import '../widgets/catalog_text.dart';
import '../widgets/start_timer_sheet.dart';
import '../widgets/status_chip.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.items, required this.controller, this.onStarted, this.onStartQueued});
  final List<FarmItem> items;
  final TimerController controller;
  final VoidCallback? onStarted;

  /// "Add and start all" in the start sheet: start the whole list.
  final VoidCallback? onStartQueued;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = CatalogService.search(widget.items, _query);
    final groups = CatalogService.group(filtered);
    final hasExample = widget.items.any((i) => i.isExampleData);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search crops, trees, livestock…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
            ),
          ),
        ),
        if (hasExample)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '⚠ Showing EXAMPLE DATA — real ArcheRage item data not bundled yet.',
              style: TextStyle(color: AppColors.overdue, fontSize: 12),
            ),
          ),
        Expanded(
          child: groups.isEmpty
              ? const Center(child: Text('No items match your search.'))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final entry in groups.entries) ...[
                      _SectionHeader(category: entry.key, count: entry.value.length),
                      for (final item in entry.value)
                        _ItemTile(
                          item: item,
                          onTap: () async {
                            final result = await showStartTimerSheet(context, item, widget.controller);
                            switch (result) {
                              case StartSheetResult.started:
                                widget.onStarted?.call();
                              case StartSheetResult.startAll:
                                widget.onStartQueued?.call();
                              case StartSheetResult.queued || null:
                                break; // stay here to pick the next item
                            }
                          },
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.category, required this.count});
  final FarmCategory category;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Row(
      children: [
        Icon(categoryIcon(category), color: AppColors.gold, size: 18),
        const SizedBox(width: 8),
        Text(
          category.label.toUpperCase(),
          style: const TextStyle(color: AppColors.gold, letterSpacing: 1.5, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Text('$count', style: const TextStyle(color: AppColors.goldDim)),
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: Color(0x33C9A45C))),
      ],
    ),
  );
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.onTap});
  final FarmItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      TimerMath.formatMinutes(item.growTimeMinutes),
      if (item.isRepeating) harvestText(item),
      if (item.witherOrDeathMinutes != null) 'withers +${TimerMath.formatMinutes(item.witherOrDeathMinutes!)}',
    ];
    return ListTile(
      onTap: onTap,
      title: Text(item.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details.join(' • ')),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                TagChip(
                  item.subcategory == null ? item.categoryLabel : '${item.categoryLabel} · ${item.subcategory}',
                  color: AppColors.parchment,
                ),
                if (item.climate != null && item.climate!.toLowerCase() != 'any') TagChip(item.climate!),
                if (item.isExampleData) const TagChip('example', color: AppColors.overdue),
                if (item.archerageConfirmed == false && !item.isExampleData)
                  const TagChip('unverified on ArcheRage', color: AppColors.growing),
              ],
            ),
          ),
        ],
      ),
      trailing: const Icon(Icons.add_alarm, color: AppColors.gold),
    );
  }
}
