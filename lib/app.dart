import 'dart:async';

import 'package:flutter/material.dart';

import 'models/farm_item.dart';
import 'platform/pwa_bridge.dart';
import 'screens/home_screen.dart';
import 'services/catalog_service.dart';
import 'services/push_service.dart';
import 'services/timer_controller.dart';
import 'theme/app_theme.dart';

class FarmTimerApp extends StatefulWidget {
  const FarmTimerApp({
    super.key,
    required this.controller,
    required this.catalog,
    this.bridge = const NoPwaBridge(),
    this.push,
  });
  final TimerController controller;
  final CatalogService catalog;
  final PwaBridge bridge;
  final PushAlertService? push;

  @override
  State<FarmTimerApp> createState() => _FarmTimerAppState();
}

class _FarmTimerAppState extends State<FarmTimerApp> {
  late final Future<List<FarmItem>> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.catalog.load();
    unawaited(widget.catalog.loadZones().then(widget.controller.farms.setZones));
    unawaited(widget.controller.load().then((_) => widget.controller.startTicking()));
    // Installed web app: ask the browser to never auto-clear our storage.
    // (Safari decides silently; no prompt is shown.)
    final info = widget.bridge.info;
    if (info.isWeb && info.standalone) unawaited(widget.bridge.requestPersist());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Farm Timer',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: FutureBuilder<List<FarmItem>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(body: Center(child: Text('Failed to load farm_items.json:\n${snap.error}')));
          }
          if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          return HomeScreen(controller: widget.controller, items: snap.data!, bridge: widget.bridge, push: widget.push);
        },
      ),
    );
  }
}
