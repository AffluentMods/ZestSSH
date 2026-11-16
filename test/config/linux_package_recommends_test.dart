import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Linux packages bring what the app's file dialogs and tray need
/// (with gdbus and gio, found in a review): file_picker runs
/// zenity or kdialog for every Open and Save, and the .deb named neither.
/// Read, not run (the packages are built in WSL).
void main() {
  final script = File('tool/linux/build_linux_repo.sh').readAsStringSync().replaceAll('\r\n', '\n');

  test('the .deb recommends a file dialog program, gdbus and gio, and xdg-utils', () {
    expect(script, contains('\nRecommends: xdg-utils, zenity | kdialog, libglib2.0-bin\n'));
  });

  test('the .rpm recommends them too', () {
    expect(script, contains('\nRecommends: zenity, glib2\n'));
  });
}
