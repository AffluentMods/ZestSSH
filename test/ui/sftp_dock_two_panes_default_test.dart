import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/ui/screens/desktop/widgets/sftp_dock.dart';

/// The SFTP panel docked beside a session opens with two panes side by side
/// (this computer and the host) until the person picks one pane in More; a
/// choice already made on this device is kept.
void main() {
  test('two panes is the default, and a choice of one pane is kept', () async {
    expect(const SftpDockPrefs().twoPanes, isTrue);

    SharedPreferences.setMockInitialValues({});
    expect(SftpDockPrefsNotifier(await SharedPreferences.getInstance()).state.twoPanes, isTrue);

    SharedPreferences.setMockInitialValues({'sftp_dock_two_panes': false});
    expect(SftpDockPrefsNotifier(await SharedPreferences.getInstance()).state.twoPanes, isFalse);
  });
}
