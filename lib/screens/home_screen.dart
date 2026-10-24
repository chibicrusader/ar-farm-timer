import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/farm_item.dart';
import '../models/farm_timer.dart';
import '../platform/pwa_bridge.dart';
import '../services/backup_service.dart';
import '../services/notification_service.dart';
import '../services/push_service.dart';
import '../services/timer_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/install_banner.dart';
import '../widgets/timer_queue_sheet.dart';
import 'catalog_screen.dart';
import 'install_guide_screen.dart';
import 'moved_screen.dart';
import 'settings_screen.dart';
import 'timers_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.items,
    this.bridge = const NoPwaBridge(),
    this.push,
    this.prefs,
  });
  final TimerController controller;
  final List<FarmItem> items;
  final PwaBridge bridge;
  final PushAlertService? push;
  final SharedPreferencesAsync? prefs;

  static const installHintKey = 'install_hint_dismissed';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  StreamSubscription<TimerAlert>? _sub;
  bool _hintDismissed = true;
  bool _updateReady = false;
  bool _starting = false;

  /// Old address with saved data: show the "moved" notice (web/moved.js).
  late bool _showMoved;

  @override
  void initState() {
    super.initState();
    _sub = widget.controller.alerts.listen(_onAlert);
    final info = widget.bridge.info;
    if (info.showInstallHint) {
      unawaited(
        (widget.prefs ?? SharedPreferencesAsync()).getBool(HomeScreen.installHintKey).then((v) {
          if (mounted) setState(() => _hintDismissed = v ?? false);
        }),
      );
    }
    widget.bridge.onUpdateReady(() {
      if (mounted) setState(() => _updateReady = true);
    });
    _showMoved = info.movedTo != null && !widget.bridge.movedDismissed;
    final payload = widget.bridge.takeImport();
    if (payload != null) WidgetsBinding.instance.addPostFrameCallback((_) => _offerImport(payload));
  }

  void _continueHere() {
    widget.bridge.dismissMoved();
    setState(() => _showMoved = false);
  }

  /// One-tap transfer from the old address (`#import=` link): confirm, then
  /// MERGE into the timers here. Never replaces anything.
  Future<void> _offerImport(String payload) async {
    final c = widget.controller;
    if (!c.loaded) {
      // Wait for saved timers to load first, or the merge would be lost.
      void wait() {
        if (!c.loaded) return;
        c.removeListener(wait);
        unawaited(_offerImport(payload));
      }

      c.addListener(wait);
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final List<FarmTimer> timers;
    try {
      timers = BackupService.decodeTransfer(payload);
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not import: ${e.message}')));
      return;
    }
    if (timers.isEmpty) return;
    final n = timers.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('importLinkDialog'),
        scrollable: true,
        title: Text('Import $n timer${n == 1 ? '' : 's'}?'),
        content: Text(
          'This link carries timers from the old address. Only import a link you made yourself. '
          '${c.timers.isEmpty ? 'They will be saved here.' : 'They will be added to the ${c.timers.length} timer${c.timers.length == 1 ? '' : 's'} you have here; nothing is deleted.'}'
          '\n\n${timers.take(5).map((t) => '• ${t.itemName}${t.label == null ? '' : ' (${t.label})'}').join('\n')}${n > 5 ? '\n• and ${n - 5} more' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('importLinkMerge'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final added = await c.importTimers(timers);
    if (!mounted) return;
    setState(() => _tab = 0);
    final push = widget.push;
    final alerts = push != null && !push.active ? ' Turn on alerts in Settings → Alerts.' : '';
    messenger.showSnackBar(SnackBar(content: Text('Imported $added timer${added == 1 ? '' : 's'}.$alerts')));
  }

  void _dismissHint() {
    setState(() => _hintDismissed = true);
    unawaited((widget.prefs ?? SharedPreferencesAsync()).setBool(HomeScreen.installHintKey, true));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _onAlert(TimerAlert a) {
    if (!mounted) return;
    final where = a.timer.label != null ? ' (${a.timer.label})' : '';
    final ready = a.status == TimerStatus.ready && !a.witherWarning;
    final msg = a.witherWarning
        ? '${a.timer.itemName}$where will wither soon. Harvest it!'
        : ready
        ? '${a.timer.itemName}$where is ready to harvest!'
        : '${a.timer.itemName}$where has withered.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              ready ? Icons.notifications_active : Icons.warning_amber,
              color: ready ? AppColors.ready : AppColors.overdue,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(msg)),
          ],
        ),
        duration: Duration(seconds: widget.controller.notifications.mode == NotificationMode.inAppOnly ? 12 : 5),
        action: SnackBarAction(label: 'View', onPressed: () => setState(() => _tab = 0)),
      ),
    );
  }

  /// Starts the whole "to start" list (one push-server request).
  Future<void> _startQueued() async {
    if (_starting || widget.controller.queue.isEmpty) return;
    setState(() => _starting = true);
    try {
      final started = await widget.controller.startQueued();
      if (!mounted) return;
      setState(() => _tab = 0);
      final n = started.length;
      final push = widget.controller.notifications.mode == NotificationMode.push;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Started ${n == 1 ? '1 timer' : '$n timers'}.${push ? ' Alerts scheduled in one request.' : ''}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _reviewQueue() async {
    final go = await showTimerQueueSheet(context, widget.controller);
    if (!mounted) return;
    if (go == true) {
      await _startQueued();
    } else if (go == false) {
      setState(() => _tab = 1); // "Add more"
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showMoved) {
      return MovedScreen(controller: widget.controller, bridge: widget.bridge, onContinue: _continueHere);
    }
    final queue = widget.controller.queue;
    final pages = [
      TimersScreen(controller: widget.controller, onBrowse: () => setState(() => _tab = 1)),
      CatalogScreen(
        items: widget.items,
        controller: widget.controller,
        onStarted: () => setState(() => _tab = 0),
        onStartQueued: _startQueued,
      ),
      SettingsScreen(controller: widget.controller, bridge: widget.bridge, push: widget.push),
    ];
    const destinations = [
      (Icons.timer_outlined, Icons.timer, 'Timers'),
      (Icons.menu_book_outlined, Icons.menu_book, 'Catalog'),
      (Icons.settings_outlined, Icons.settings, 'Settings'),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final info = widget.bridge.info;
    final body = Column(
      children: [
        if (_updateReady)
          MaterialBanner(
            backgroundColor: AppColors.surfaceHigh,
            leading: const Icon(Icons.system_update, color: AppColors.gold),
            content: const Text('A new version of the app is ready.'),
            actions: [TextButton(onPressed: widget.bridge.applyUpdate, child: const Text('Reload'))],
          ),
        if (info.showInstallHint && !_hintDismissed)
          InstallBanner(info: info, onDismiss: _dismissHint, onShowGuide: () => InstallGuideScreen.open(context, info)),
        Expanded(
          child: IndexedStack(index: _tab, children: pages),
        ),
        if (_tab != 2)
          ListenableBuilder(
            listenable: queue,
            builder: (context, _) => queue.isEmpty
                ? const SizedBox.shrink()
                : TimerQueueBar(queue: queue, busy: _starting, onReview: _reviewQueue, onStart: _startQueued),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.eco, color: AppColors.gold),
            SizedBox(width: 8),
            Flexible(
              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text('AR FARM TIMER')),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('installGuide'),
            tooltip: 'How to install',
            icon: const Icon(Icons.install_mobile),
            onPressed: () => InstallGuideScreen.open(context, info),
          ),
        ],
      ),
      floatingActionButton: _tab == 0
          ? ListenableBuilder(
              listenable: Listenable.merge([widget.controller, queue]),
              // Hidden while the list bar is shown (it would cover it).
              builder: (context, _) => widget.controller.timers.isEmpty || queue.isNotEmpty
                  ? const SizedBox.shrink()
                  : FloatingActionButton.extended(
                      onPressed: () => setState(() => _tab = 1),
                      icon: const Icon(Icons.add),
                      label: const Text('Plant'),
                    ),
            )
          : null,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (final d in destinations)
                  NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
              ],
            ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }
}
