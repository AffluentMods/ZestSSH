// Remote screens (4.0): where Keep the bar shown and Files
// are offered, their place in the list, and which SSH connection a session's
// files go through.
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/services/session_ssh.dart';

void main() {
  ScreenMenuState of({required bool phone, bool barKept = false, bool filesOffered = false}) =>
      ScreenMenuState.of(phone: phone, fit: ScreenFit.fit, viewOnly: false, barKept: barKept, filesOffered: filesOffered);

  test('Keep the bar shown: a phone\'s switch in Session, before Disconnect; never a computer\'s', () {
    expect(of(phone: true).offers(ScreenAction.keepBar), isTrue);
    expect(of(phone: false).offers(ScreenAction.keepBar), isFalse);
    expect(ScreenAction.keepBar.group, ScreenActionGroup.session);
    expect(ScreenAction.keepBar.kind, ScreenActionKind.toggle);
    final session = of(phone: true).inGroup(ScreenActionGroup.session);
    expect(session.indexOf(ScreenAction.keepBar), session.indexOf(ScreenAction.disconnect) - 1);
    expect(of(phone: true, barKept: true).isOn(ScreenAction.keepBar), isTrue);
    expect(of(phone: true).isOn(ScreenAction.keepBar), isFalse);
  });

  test('Files: in Clipboard and files, on both, only where the screen goes through an SSH host', () {
    for (final phone in [true, false]) {
      expect(of(phone: phone).offers(ScreenAction.files), isFalse, reason: 'no SSH host');
      expect(of(phone: phone, filesOffered: true).offers(ScreenAction.files), isTrue);
      expect(of(phone: phone, filesOffered: true).enabled(ScreenAction.files), isTrue);
    }
    expect(ScreenAction.files.group, ScreenActionGroup.clipboard);
    expect(ScreenAction.files.kind, ScreenActionKind.plain);
  });

  test('a session with no SSH connection in this process has no files to open that way', () {
    expect(sshServiceOfShell(null), isNull);
    expect(sshServiceOfShell('a telnet shell'), isNull);
  });
}
