import 'package:archeragefarmtimer/models/farm_timer.dart';
import 'package:archeragefarmtimer/platform/pwa_bridge.dart';
import 'package:archeragefarmtimer/services/notification_service.dart';

class FakeBridge implements PwaBridge {
  FakeBridge({this.info = const PwaInfo(isWeb: true, ios: true, pushSupported: true, appUrl: 'https://app.test/')});
  @override
  PwaInfo info;
  PersistState persist = PersistState.notGranted;
  final calls = <String>[];
  String subscriptionJson = '{"endpoint":"https://web.push.apple.com/abc","keys":{"p256dh":"BPk","auth":"au"}}';
  String? pickResult;
  void Function()? _update;

  @override
  Future<PersistState> persisted() async => persist;
  @override
  Future<PersistState> requestPersist() async {
    calls.add('requestPersist');
    return persist = PersistState.granted;
  }

  @override
  Future<String> enablePush(String vapidPublicKey) {
    calls.add('enablePush:$vapidPublicKey');
    return Future.value(subscriptionJson);
  }

  @override
  Future<void> disablePush() async => calls.add('disablePush');
  @override
  Future<String?> currentPushSubscription() async {
    calls.add('currentPushSubscription');
    return subscriptionJson;
  }

  @override
  Future<String> saveFile(String name, String text) async {
    calls.add('saveFile:$name');
    lastSaved = text;
    return 'shared';
  }

  String? lastSaved;
  @override
  Future<String?> pickTextFile() async => pickResult;
  @override
  bool get updateReady => false;
  @override
  void onUpdateReady(void Function() callback) => _update = callback;
  void fireUpdate() => _update?.call();
  @override
  void applyUpdate() => calls.add('applyUpdate');

  String? importPayload;
  @override
  String? takeImport() {
    final v = importPayload;
    importPayload = null;
    return v;
  }

  @override
  bool movedDismissed = false;
  @override
  void dismissMoved() {
    calls.add('dismissMoved');
    movedDismissed = true;
  }

  @override
  void openUrl(String url) => calls.add('openUrl:$url');
}

class RecordingService implements NotificationService {
  RecordingService(this.mode);
  @override
  final NotificationMode mode;
  final log = <String>[];
  @override
  Future<void> init() async => log.add('init');
  @override
  Future<void> scheduleReady(FarmTimer timer) async => log.add('schedule:${timer.id}');
  @override
  Future<void> cancel(FarmTimer timer) async => log.add('cancel:${timer.id}');
  @override
  Future<void> showReadyNow(FarmTimer timer) async => log.add('show:${timer.id}');
  @override
  Future<void> showWitherWarningNow(FarmTimer timer) async => log.add('warn:${timer.id}');
  @override
  Future<void> syncAll(List<FarmTimer> timers) async => log.add('sync:${timers.length}');
  @override
  Future<void> scheduleAll(List<FarmTimer> timers, {List<FarmTimer> replacing = const []}) async => log.add(
    'scheduleAll:${timers.map((t) => t.id).join(',')}${replacing.isEmpty ? '' : ' replacing:${replacing.map((t) => t.id).join(',')}'}',
  );
  @override
  Future<void> cancelAll(List<FarmTimer> timers) async => log.add('cancelAll:${timers.map((t) => t.id).join(',')}');
}
