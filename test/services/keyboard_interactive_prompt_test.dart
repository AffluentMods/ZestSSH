import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';

/// Guards the shared keyboard-interactive password rule and pins that NO
/// answerer leaks the account password to a 2FA/OTP prompt.
///
/// Before this, the jump-host and serial paths answered a "passcode" prompt
/// with the account password (leaking it into the server's second-factor log);
/// automation lacked the non-echo check. All now route through
/// isRealPasswordPrompt, which fails closed.
void main() {
  group('isRealPasswordPrompt', () {
    test('answers only a genuine, non-echoed password prompt', () {
      for (final p in ['Password:', 'password', 'PASSWORD :', "bob's password:",
          "alice's Password: "]) {
        expect(isRealPasswordPrompt(p, echo: false), isTrue, reason: p);
      }
    });

    test('fails closed on 2FA / OTP / echoed / compound prompts', () {
      for (final p in ['Verification code:', 'passcode:', 'One-time code:',
          'Enter your OTP:', 'Duo passcode or option (1-3):',
          'old password hint:', 'Username:']) {
        expect(isRealPasswordPrompt(p, echo: false), isFalse, reason: p);
      }
      // Echoed fields never get the password, even a literal "Password:".
      expect(isRealPasswordPrompt('Password:', echo: true), isFalse);
    });

    test('a pathological long prompt returns false fast (ReDoS guard)', () {
      final evil = "x's password${' ' * 34000}y";
      final sw = Stopwatch()..start();
      final result = isRealPasswordPrompt(evil, echo: false);
      sw.stop();
      expect(result, isFalse);
      expect(sw.elapsedMilliseconds, lessThan(50),
          reason: 'the length guard must short-circuit before the regex');
    });
  });

  test('SOURCE GATE: every keyboard-interactive answerer goes through the '
      'shared KeyboardInteractiveAnswerer, and none uses the loose '
      "contains('passcode') leak pattern", () {
    // A cheap regression gate: the moment someone wires onUserInfoRequest
    // to their own answering code, or reintroduces the loose pattern, this
    // fails. The worker isolate only forwards prompts to the main-isolate
    // router, which uses the shared answerer.
    const forwardsOnly = 'lib/services/worker/worker_connection_isolate.dart';
    final wired = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path.replaceAll(r'\', '/'))
        .where((p) => File(p).readAsStringSync().contains('onUserInfoRequest:'))
        .toList();
    expect(wired, containsAll(const [
      'lib/services/ssh_service.dart',
      'lib/services/serial_service.dart',
      'lib/services/automation_service.dart',
      'lib/providers/terminal_providers.dart',
      'lib/features/hosts/host_tester.dart',
    ]));
    for (final path in wired) {
      final src = File(path).readAsStringSync();
      expect(src.contains("contains('passcode')"), isFalse,
          reason: '$path answers a passcode/2FA prompt (password leak)');
      if (path == forwardsOnly) continue;
      expect(src.contains('KeyboardInteractiveAnswerer('), isTrue,
          reason: '$path should answer keyboard-interactive through the '
              'shared answerer');
    }
    final router =
        File('lib/services/worker/ssh_callback_router.dart').readAsStringSync();
    expect(router.contains('KeyboardInteractiveAnswerer('), isTrue);
  });
}
