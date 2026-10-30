/// Browser / PWA capabilities, abstracted so the app compiles everywhere and
/// tests can use a fake. Use [createPwaBridge] to get the platform version.
library;

export 'pwa_bridge_stub.dart' if (dart.library.js_interop) 'pwa_bridge_web.dart' show createPwaBridge;

class PwaInfo {
  const PwaInfo({
    this.isWeb = false,
    this.standalone = false,
    this.ios = false,
    this.android = false,
    this.pushSupported = false,
    this.permission = 'unsupported',
    this.storageApi = false,
    this.appUrl,
    this.movedTo,
  });

  final bool isWeb;

  /// Running as an installed Home Screen / standalone web app.
  final bool standalone;
  final bool ios;

  /// Android browser (from the user agent).
  final bool android;
  final bool pushSupported;

  /// Notification permission: default | granted | denied | unsupported.
  final String permission;
  final bool storageApi;

  /// The app's own URL (opened when a push notification is tapped).
  final String? appUrl;

  /// Set on the old address (archerage-farm-timer.pages.dev) when this
  /// browser has saved data: the new address to move to (web/moved.js).
  final String? movedTo;

  /// Show the "Add to Home Screen" hint: in a browser tab, not installed.
  bool get showInstallHint => isWeb && !standalone;
}

/// Result of a storage persistence query/request.
enum PersistState { granted, notGranted, unsupported }

abstract class PwaBridge {
  PwaInfo get info;

  Future<PersistState> persisted();
  Future<PersistState> requestPersist();

  /// Asks for notification permission and subscribes to push. MUST be
  /// called directly from a button tap (iOS requirement). Returns the
  /// PushSubscription JSON string.
  Future<String> enablePush(String vapidPublicKey);
  Future<void> disablePush();

  /// The browser's current PushSubscription JSON (no permission prompt, no
  /// tap needed), or null when there is none. Used to re-register silently
  /// after the push server forgot an idle subscription.
  Future<String?> currentPushSubscription();

  /// Share sheet / download. Returns 'shared' | 'downloaded' | 'cancelled' |
  /// 'unsupported'.
  Future<String> saveFile(String name, String text);

  /// Opens a file picker; returns its text or null if cancelled/unsupported.
  Future<String?> pickTextFile();

  bool get updateReady;
  void onUpdateReady(void Function() callback);
  void applyUpdate();

  /// One-tap transfer payload from the `#import=` URL hash (base64url
  /// backup), or null. Returned once; moved.js already removed it from the URL.
  String? takeImport();

  /// "Continue here for now" was chosen this session (old address only).
  bool get movedDismissed;
  void dismissMoved();

  /// Opens [url] (installed app: in the browser; tab: navigates there).
  void openUrl(String url);

  /// Shows the "Before you use" notice again (web/consent.js). Records no
  /// new consent; the first-launch notice is handled before the app starts.
  void showConsentNotice();
}

/// Non-web: no PWA features.
class NoPwaBridge implements PwaBridge {
  const NoPwaBridge();
  @override
  PwaInfo get info => const PwaInfo();
  @override
  Future<PersistState> persisted() async => PersistState.unsupported;
  @override
  Future<PersistState> requestPersist() async => PersistState.unsupported;
  @override
  Future<String> enablePush(String vapidPublicKey) => Future.error(UnsupportedError('Push alerts need the web app.'));
  @override
  Future<void> disablePush() async {}
  @override
  Future<String?> currentPushSubscription() async => null;
  @override
  Future<String> saveFile(String name, String text) async => 'unsupported';
  @override
  Future<String?> pickTextFile() async => null;
  @override
  bool get updateReady => false;
  @override
  void onUpdateReady(void Function() callback) {}
  @override
  void applyUpdate() {}
  @override
  String? takeImport() => null;
  @override
  bool get movedDismissed => false;
  @override
  void dismissMoved() {}
  @override
  void openUrl(String url) {}
  @override
  void showConsentNotice() {}
}
