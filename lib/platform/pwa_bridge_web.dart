import 'dart:convert';
import 'dart:js_interop';

import 'pwa_bridge.dart';

@JS('arPwa')
external ArPwaJs? get _arPwa;

extension type ArPwaJs._(JSObject _) implements JSObject {
  external JSString info();
  external JSPromise<JSString> persisted();
  external JSPromise<JSString> requestPersist();
  external JSPromise<JSString> enablePush(JSString key);
  external JSPromise<JSAny?> disablePush();
  external JSPromise<JSString> currentSubscription();
  external JSPromise<JSString> saveFile(JSString name, JSString text);
  external JSPromise<JSString> pickTextFile();
  external JSBoolean isUpdateReady();
  external void onUpdateReady(JSFunction fn);
  external void applyUpdate();
  external JSString takeImport();
  external JSBoolean movedDismissed();
  external void dismissMoved();
  external void openUrl(JSString url);
}

PwaBridge createPwaBridge() => _arPwa == null ? const _WebWithoutGlue() : WebPwaBridge(_arPwa!);

PersistState _persist(String s) => switch (s) {
  'granted' => PersistState.granted,
  'not-granted' => PersistState.notGranted,
  _ => PersistState.unsupported,
};

/// Turns a rejected JS promise into a readable Dart exception.
Future<T> _guard<T>(Future<T> f) async {
  try {
    return await f;
  } catch (e) {
    final msg = e.toString().replaceFirst(RegExp(r'^(Uncaught )?(Error|StateError|TypeError): '), '');
    throw StateError(msg);
  }
}

class WebPwaBridge implements PwaBridge {
  WebPwaBridge(this._js);
  final ArPwaJs _js;

  @override
  PwaInfo get info {
    final m = jsonDecode(_js.info().toDart) as Map<String, dynamic>;
    return PwaInfo(
      isWeb: true,
      standalone: m['standalone'] == true,
      ios: m['ios'] == true,
      android: m['android'] == true,
      pushSupported: m['pushSupported'] == true,
      permission: (m['permission'] as String?) ?? 'unsupported',
      storageApi: m['storageApi'] == true,
      appUrl: m['appUrl'] as String?,
      movedTo: m['movedTo'] as String?,
    );
  }

  @override
  Future<PersistState> persisted() async => _persist((await _guard(_js.persisted().toDart)).toDart);

  @override
  Future<PersistState> requestPersist() async => _persist((await _guard(_js.requestPersist().toDart)).toDart);

  @override
  Future<String> enablePush(String vapidPublicKey) async =>
      // The JS call (and Notification.requestPermission inside it) happens
      // synchronously here, still inside the tap.
      (await _guard(_js.enablePush(vapidPublicKey.toJS).toDart)).toDart;

  @override
  Future<void> disablePush() => _guard(_js.disablePush().toDart);

  @override
  Future<String?> currentPushSubscription() async {
    final s = (await _guard(_js.currentSubscription().toDart)).toDart;
    return s.isEmpty ? null : s;
  }

  @override
  Future<String> saveFile(String name, String text) async =>
      (await _guard(_js.saveFile(name.toJS, text.toJS).toDart)).toDart;

  @override
  Future<String?> pickTextFile() async {
    final s = (await _guard(_js.pickTextFile().toDart)).toDart;
    return s.isEmpty ? null : s;
  }

  @override
  bool get updateReady => _js.isUpdateReady().toDart;

  @override
  void onUpdateReady(void Function() callback) => _js.onUpdateReady(callback.toJS);

  @override
  void applyUpdate() => _js.applyUpdate();

  @override
  String? takeImport() {
    final s = _js.takeImport().toDart;
    return s.isEmpty ? null : s;
  }

  @override
  bool get movedDismissed => _js.movedDismissed().toDart;

  @override
  void dismissMoved() => _js.dismissMoved();

  @override
  void openUrl(String url) => _js.openUrl(url.toJS);
}

/// Web build served without web/pwa.js (e.g. `flutter run -d chrome`).
class _WebWithoutGlue extends NoPwaBridge {
  const _WebWithoutGlue();
  @override
  PwaInfo get info => const PwaInfo(isWeb: true);
}
