import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'platform/pwa_bridge.dart';
import 'services/alert_settings.dart';
import 'services/catalog_service.dart';
import 'services/farm_store.dart';
import 'services/notification_service.dart';
import 'services/push_service.dart';
import 'services/timer_controller.dart';
import 'services/timer_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = createPwaBridge();
  final alertSettings = AlertSettings();
  await alertSettings.load(); // lead time is needed before alerts are scheduled
  int lead() => alertSettings.witherLeadMinutes;
  final local = LocalNotificationService(witherLead: lead);
  // Push alerts (via the optional push server) are a web-app feature; native
  // builds use OS-scheduled local notifications instead.
  final push = kIsWeb
      ? PushAlertService(
          appUrl: bridge.info.appUrl,
          witherLead: lead,
          currentSubscription: bridge.currentPushSubscription,
        )
      : null;
  final notifications = CompositeNotificationService([local, ?push]);
  await notifications.init();
  final controller = TimerController(
    repository: TimerRepository(),
    notifications: notifications,
    alertSettings: alertSettings,
    farms: FarmStore(),
  );
  runApp(FarmTimerApp(controller: controller, catalog: CatalogService(), bridge: bridge, push: push));
}
