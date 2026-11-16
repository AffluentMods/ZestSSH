// A remote screen's session and Apple's sign-in (4.0, found in a security
// review): Apple Remote Desktop is used only where the host's options chose it
// (ScreenOptions.auth, `apple`), never by itself because its key has a user
// name; otherwise the engine never sees it offered.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';

class _Trust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;

  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => false;

  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  /// What the engine saw of a server offering ARD and VNC authentication to
  /// a screen whose key has a user name, with [options].
  Future<(ScreenConnectOptions, List<int>)> offerSeen(ScreenOptions options) async {
    final engine = FakeScreenNative()..onOpen = (s) => s.connect();
    final input = StreamController<Uint8List>();
    final shell = ScreenShellService(
      target: const DirectTlsTarget('mac.example.com', 5900),
      trust: _Trust(),
      username: 'me',
      password: 'account-password',
      options: options,
      native: engine,
      openDirect: (host, port) async => ScreenChannel(input.stream, StreamController<List<int>>()),
    );
    await shell.connect();
    input.add(Uint8List.fromList([...ascii.encode('RFB 003.008\n'), 2, 30, 2]));
    await _settle();
    final seen = (shell.session!.options, engine.sessions.single.fed.toBytes().sublist(12));
    await shell.disconnect();
    return seen;
  }

  test("a screen whose key has a user name: Apple's sign-in is not offered to the engine unless the host chose it",
      () async {
    final (auto, autoSeen) = await offerSeen(ScreenOptions.defaults);
    expect(auto.allowAppleSignIn, isFalse);
    expect(auto.username, 'me', reason: "still given: VeNCrypt's X509Plain uses it, inside pinned TLS");
    expect(autoSeen, [1, 2], reason: 'ARD taken out: VNC authentication only');

    final (apple, appleSeen) = await offerSeen(const ScreenOptions(auth: ScreenAuth.apple));
    expect(apple.allowAppleSignIn, isTrue);
    expect(appleSeen, [2, 30, 2]);
  });
}
