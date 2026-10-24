import 'dart:io';

/// Linux desktop notifications go over the D-Bus session bus. Without one
/// (headless/minimal sessions) the plugin throws an uncatchable async error,
/// so check first and fall back to in-app alerts.
bool linuxSessionBusAvailable() {
  final addr = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
  if (addr != null && addr.isNotEmpty) {
    final m = RegExp(r'unix:path=([^,;]+)').firstMatch(addr);
    return m == null || File(m.group(1)!).existsSync();
  }
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  return runtime != null && File('$runtime/bus').existsSync();
}
