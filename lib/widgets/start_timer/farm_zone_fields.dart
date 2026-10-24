import 'package:flutter/material.dart';

import '../../models/farm_item.dart';
import '../../models/zone.dart';
import '../../theme/app_theme.dart';

/// Hint under the zone picker (climate match, planting restriction, note).
({String? text, Color? color}) zoneHint(Zone? zone, FarmItem item) {
  if (zone == null) return (text: null, color: null);
  String? hint;
  Color? color;
  final locked = Zone.lockedZone(item);
  final m = zone.matches(item);
  if (locked != null && locked.toLowerCase() != zone.name.toLowerCase()) {
    hint = '${item.name} can only be planted in $locked.';
    color = AppColors.overdue;
  } else if (m == true) {
    hint = '${zone.name} is ${zone.climateLabel}: preferred climate on.';
    color = AppColors.ready;
  } else if (m == false) {
    hint = '${zone.name} is ${zone.climateLabel}, not ${item.climate}: no climate bonus.';
  } else if (item.hasClimateBonus) {
    hint = '${zone.name}: climate unknown. Set the toggle yourself.';
  }
  if (zone.note != null) hint = [?hint, zone.note!].join('\n');
  return (text: hint, color: color);
}

/// Farm / plot name with quick-pick chips, and the zone picker.
class FarmZoneFields extends StatelessWidget {
  const FarmZoneFields({
    super.key,
    required this.item,
    required this.label,
    required this.farmNames,
    required this.zones,
    required this.zone,
    required this.onLabelChanged,
    required this.onFarmPicked,
    required this.onZoneChanged,
  });

  final FarmItem item;
  final TextEditingController label;
  final List<String> farmNames;

  /// Known zones, sorted for display.
  final List<Zone> zones;

  /// The selected zone, if any.
  final Zone? zone;
  final VoidCallback onLabelChanged;
  final ValueChanged<String> onFarmPicked;
  final ValueChanged<String?> onZoneChanged;

  @override
  Widget build(BuildContext context) {
    final hint = zoneHint(zone, item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('farmField'),
          controller: label,
          onChanged: (_) => onLabelChanged(),
          decoration: const InputDecoration(
            labelText: 'Farm / plot (optional)',
            hintText: 'e.g. Solzreed farm, plot 3',
            prefixIcon: Icon(Icons.yard_outlined),
          ),
        ),
        if (farmNames.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              for (final n in farmNames)
                ChoiceChip(
                  key: ValueKey('farmChip:$n'),
                  label: Text(n),
                  selected: label.text.trim() == n,
                  onSelected: (_) => onFarmPicked(n),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
        if (zones.isNotEmpty) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: const Key('zonePicker'),
            initialValue: zone?.name,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Zone', prefixIcon: Icon(Icons.public)),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Not set')),
              for (final z in zones)
                DropdownMenuItem<String?>(
                  value: z.name,
                  child: Text('${z.name} · ${z.continent} · ${z.climateLabel}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onZoneChanged,
          ),
          if (hint.text != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                hint.text!,
                key: const Key('zoneHint'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: hint.color),
              ),
            ),
        ],
      ],
    );
  }
}
