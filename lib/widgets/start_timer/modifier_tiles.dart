import 'package:flutter/material.dart';

import '../../models/farm_item.dart';

/// Watered / Farmhand checkboxes. Hidden when the modifier doesn't apply to
/// this kind of item (unknown kinds, watering livestock); shown disabled
/// when it is confirmed to have no effect (farmhand on saplings/livestock).
class ModifierTiles extends StatelessWidget {
  const ModifierTiles({
    super.key,
    required this.item,
    required this.watered,
    required this.farmhand,
    required this.overridden,
    required this.onWatered,
    required this.onFarmhand,
  });

  final FarmItem item;
  final bool watered;
  final bool farmhand;

  /// A custom grow time is set: modifiers don't apply.
  final bool overridden;
  final ValueChanged<bool> onWatered;
  final ValueChanged<bool> onFarmhand;

  static String _pct(double m) {
    final p = ((m - 1) * 100).round();
    return p > 0 ? '+$p%' : '$p%';
  }

  @override
  Widget build(BuildContext context) {
    final kindName = switch (item.plantKind) {
      PlantKind.plant => 'single plants',
      PlantKind.bundle => 'seed bundles',
      PlantKind.sapling => 'saplings/trees',
      PlantKind.livestock => 'livestock',
      PlantKind.unknown => 'this item',
    };
    final water = item.wateredMultiplier;
    final hand = item.farmhandMultiplier;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (water != null)
          CheckboxListTile(
            key: const Key('watered'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Watered'),
            subtitle: Text(
              '${_pct(water)} first growth for $kindName (official ArcheAge value, unverified on ArcheRage)',
            ),
            value: watered,
            onChanged: overridden ? null : (v) => onWatered(v ?? false),
          ),
        if (hand != null)
          CheckboxListTile(
            key: const Key('farmhand'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Farmhand'),
            subtitle: Text(
              hand == 1.0
                  ? 'No effect on $kindName (confirmed for ArcheRage)'
                  : '${_pct(hand)} first growth for $kindName (confirmed for ArcheRage)',
            ),
            value: hand == 1.0 ? false : farmhand,
            onChanged: hand == 1.0 || overridden ? null : (v) => onFarmhand(v ?? false),
          ),
      ],
    );
  }
}
