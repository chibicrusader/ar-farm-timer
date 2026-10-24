import 'dart:async';

import 'package:flutter/material.dart';

import '../models/farm_item.dart';
import '../models/pending_timer.dart';
import '../models/zone.dart';
import '../services/timer_controller.dart';
import '../services/timer_math.dart';
import '../theme/app_theme.dart';
import 'start_timer/advanced_fields.dart';
import 'start_timer/farm_zone_fields.dart';
import 'start_timer/modifier_tiles.dart';
import 'start_timer/sheet_buttons.dart';
import 'start_timer/sheet_header.dart';
import 'timer_card.dart' show formatLocalTime;

/// What the start sheet did.
enum StartSheetResult {
  /// Started this one timer right away.
  started,

  /// Added to (or updated in) the "to start" list.
  queued,

  /// Added to the list; the caller should start the whole list now.
  startAll,
}

/// Bottom sheet to start a timer for [item], or add it to the list.
/// With [initial] and [editIndex] it edits that list entry instead.
Future<StartSheetResult?> showStartTimerSheet(
  BuildContext context,
  FarmItem item,
  TimerController controller, {
  PendingTimer? initial,
  int? editIndex,
}) {
  return showModalBottomSheet<StartSheetResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: StartTimerSheet(item: item, controller: controller, initial: initial, editIndex: editIndex),
    ),
  );
}

class StartTimerSheet extends StatefulWidget {
  const StartTimerSheet({super.key, required this.item, required this.controller, this.initial, this.editIndex});
  final FarmItem item;
  final TimerController controller;

  /// Pre-filled values (editing a list entry).
  final PendingTimer? initial;

  /// Index in the list being edited; null = new timer.
  final int? editIndex;

  @override
  State<StartTimerSheet> createState() => _StartTimerSheetState();
}

class _StartTimerSheetState extends State<StartTimerSheet> {
  final _label = TextEditingController();
  final _override = TextEditingController();
  final _plantedAgo = TextEditingController();
  final _wither = TextEditingController();
  String? _zone;
  int _qty = 1;
  bool _preferredClimate = false;
  bool _watered = false;
  bool _farmhand = false;
  bool _busy = false;

  bool get _editing => widget.editIndex != null;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    if (p != null) {
      String num(double? v) => v == null ? '' : (v == v.roundToDouble() ? '${v.round()}' : '$v');
      _label.text = p.label ?? '';
      _qty = p.quantity;
      _zone = p.zone;
      _preferredClimate = p.preferredClimate;
      _watered = p.watered;
      _farmhand = p.farmhand;
      _override.text = num(p.overrideGrowMinutes);
      _wither.text = num(p.witherMinutes);
      _plantedAgo.text = p.plantedAgo == Duration.zero ? '' : num(p.plantedAgo.inSeconds / 60);
      return;
    }
    final farms = widget.controller.farms;
    final last = farms.zoneNamed(farms.lastZone);
    if (last != null) _applyZone(last.name, rebuild: false);
  }

  /// Selects a zone and sets the preferred-climate toggle from it (the
  /// player can still flip the toggle afterwards).
  void _applyZone(String? name, {bool rebuild = true}) {
    void apply() {
      _zone = name;
      final m = widget.controller.farms.zoneNamed(name)?.matches(widget.item);
      if (m != null) _preferredClimate = m;
    }

    rebuild ? setState(apply) : apply();
  }

  void _pickFarm(String name) {
    setState(() => _label.text = name);
    // Saved farm, or one only used in the "to start" list so far.
    final z =
        widget.controller.farms.zoneFor(name) ??
        widget.controller.queue.items.where((p) => p.farm == name && p.zone != null).firstOrNull?.zone;
    if (z != null && widget.controller.farms.zoneNamed(z) != null) _applyZone(z);
  }

  @override
  void dispose() {
    _wither.dispose();
    _label.dispose();
    _override.dispose();
    _plantedAgo.dispose();
    super.dispose();
  }

  double? _parse(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  double get _growMinutes => TimerMath.effectiveGrowMinutes(
    widget.item,
    preferredClimate: _preferredClimate,
    watered: _watered,
    farmhand: _farmhand,
    overrideMinutes: _parse(_override),
  );

  Duration get _ago => TimerMath.minutes((_parse(_plantedAgo) ?? 0).clamp(0, 1e7).toDouble());

  PendingTimer get _pending => PendingTimer(
    item: widget.item,
    label: _label.text,
    quantity: _qty,
    preferredClimate: _preferredClimate,
    watered: _watered,
    farmhand: _farmhand,
    overrideGrowMinutes: _parse(_override),
    witherMinutes: _parse(_wither),
    plantedAgo: _ago,
    zone: _zone,
  );

  Future<void> _start() async {
    setState(() => _busy = true);
    final p = _pending;
    await widget.controller.startTimer(
      p.item,
      label: p.label,
      quantity: p.quantity,
      preferredClimate: p.preferredClimate,
      watered: p.watered,
      farmhand: p.farmhand,
      overrideGrowMinutes: p.overrideGrowMinutes,
      witherMinutes: p.witherMinutes,
      plantedAgo: p.plantedAgo,
      zone: p.zone,
    );
    if (mounted) Navigator.of(context).pop(StartSheetResult.started);
  }

  /// "Add to list" (or "Save changes" when editing a list entry).
  void _queue({bool thenStart = false}) {
    final queue = widget.controller.queue;
    if (_editing) {
      queue.replaceAt(widget.editIndex!, _pending);
    } else if (!queue.add(_pending)) {
      return;
    }
    // Pre-select this zone in the next sheet, like a started timer does.
    if (_zone != null) unawaited(widget.controller.farms.setLastZone(_zone));
    Navigator.of(context).pop(thenStart ? StartSheetResult.startAll : StartSheetResult.queued);
  }

  String? _witherPreview(BuildContext context, DateTime readyAt) {
    final custom = _parse(_wither);
    final w = (custom != null && custom > 0) ? custom : widget.item.witherOrDeathMinutes;
    if (w == null || w <= 0) return null;
    final witherAt = readyAt.add(TimerMath.minutes(w));
    final lead = widget.controller.alertSettings.witherLeadMinutes;
    final double warnLead = lead <= 0 ? 0 : (lead < w / 2 ? lead.toDouble() : w / 2);
    final warn = lead <= 0 ? 'wither warning off' : 'warning ${TimerMath.formatMinutes(warnLead)} before';
    return 'Withers at ${formatLocalTime(context, witherAt)} if not harvested ($warn)';
  }

  List<Zone> get _sortedZones => [...widget.controller.farms.zones]
    ..sort((a, b) {
      final c = a.continent.compareTo(b.continent);
      return c != 0 ? c : a.name.compareTo(b.name);
    });

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final controller = widget.controller;
    final readyAt = TimerMath.readyAt(controller.now.subtract(_ago), _growMinutes);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            StartSheetHeader(item: item, editing: _editing),
            const SizedBox(height: 16),
            FarmZoneFields(
              item: item,
              label: _label,
              farmNames: {...controller.farmNames, for (final p in controller.queue.items) ?p.farm}.toList(),
              zones: _sortedZones,
              zone: controller.farms.zoneNamed(_zone),
              onLabelChanged: _changed,
              onFarmPicked: _pickFarm,
              onZoneChanged: _applyZone,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Quantity'),
                const Spacer(),
                IconButton(
                  onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                SizedBox(
                  width: 40,
                  child: Text('$_qty', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                ),
                IconButton(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add_circle_outline)),
              ],
            ),
            if (item.hasClimateBonus)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Planted in preferred climate (${item.climate})'),
                subtitle: const Text('~30% faster growth (ArcheAge mechanic, unverified on ArcheRage)'),
                value: _preferredClimate,
                onChanged: (v) => setState(() => _preferredClimate = v),
              )
            else if (item.climate != null && item.climate!.toLowerCase() != 'any')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Climate: ${item.climate}', style: theme.textTheme.bodySmall),
              ),
            ModifierTiles(
              item: item,
              watered: _watered,
              farmhand: _farmhand,
              overridden: (_parse(_override) ?? 0) > 0,
              onWatered: (v) => setState(() => _watered = v),
              onFarmhand: (v) => setState(() => _farmhand = v),
            ),
            AdvancedFields(
              item: item,
              plantedAgo: _plantedAgo,
              customGrow: _override,
              wither: _wither,
              onChanged: _changed,
            ),
            const SizedBox(height: 8),
            if (_growMinutes != item.growTimeMinutes)
              Text(
                'Grow time ${TimerMath.formatMinutes(item.growTimeMinutes)} → '
                '${TimerMath.formatMinutes(_growMinutes)} '
                '(×${(_growMinutes / item.growTimeMinutes).toStringAsFixed(3)})',
                key: const Key('adjustedGrow'),
                style: theme.textTheme.bodySmall,
              ),
            Text(
              key: const Key('readyPreview'),
              'Ready at ${formatLocalTime(context, readyAt)} (in ${TimerMath.formatDuration(readyAt.difference(controller.now))})',
              style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.gold),
            ),
            if (_witherPreview(context, readyAt) case final w?)
              Text(w, key: const Key('witherPreview'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            StartSheetButtons(
              editing: _editing,
              busy: _busy,
              queue: controller.queue,
              onQueue: _queue,
              onStart: () => unawaited(_start()),
            ),
          ],
        ),
      ),
    );
  }
}
