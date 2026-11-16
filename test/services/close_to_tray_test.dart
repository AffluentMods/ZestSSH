import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/tray_service.dart';

/// "Close to tray" hid the window whether or not a tray icon was ever put up:
/// on a desktop that shows no tray icons, or after the tray failed to start,
/// nothing could bring the window back while the app and its sessions ran on
/// (found in a review). Where there is no icon it minimises instead.
void main() {
  test('hidden only where the tray icon is there to bring it back', () {
    expect(closeToTrayAction(trayReady: true), CloseToTray.hide);
    expect(closeToTrayAction(trayReady: false), CloseToTray.minimize);
  });

  test('no tray started, none is ready', () {
    expect(TrayService.ready, isFalse);
  });

  test('the window\'s close asks the tray, and the tray says ready only once its icon is up', () {
    final shell = File('lib/ui/screens/desktop/desktop_shell.dart').readAsStringSync();
    expect(shell, contains('closeToTrayAction(trayReady: TrayService.ready)'));
    final tray = File('lib/services/tray_service.dart').readAsStringSync().replaceAll('\r\n', '\n');
    final icon = tray.indexOf('await trayManager.setIcon(iconPath);');
    final ready = tray.indexOf('_ready = true;');
    expect(icon, greaterThan(0));
    expect(ready, greaterThan(icon));
    expect(tray.substring(icon, ready), isNot(contains('catch')));
  });
}
