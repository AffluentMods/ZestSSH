import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zestssh/utils/logger.dart';

/// What a released app prints to the console (found in a security review
/// of the client): its warnings and errors went out as they were, a
/// host, a user, a password in a line, a key in an error, into a phone's own
/// log of the device; Copy details scrubbed the same lines. Now the console
/// gets them scrubbed the same way, without the stack, which an obfuscated
/// build names nothing in; a build made to debug prints them as they are.
void main() {
  LogRecord record(String message, [Object? error]) =>
      LogRecord(Level.WARNING, message, 'ZestSSH', error, StackTrace.fromString('#0 main (file:///x.dart:1:1)'));

  const key = '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUA\n-----END OPENSSH PRIVATE KEY-----';

  test("a released app's console line holds no secret and no name of the person's, and no stack", () {
    final said = AppLogger.consoleLine(
      record('Sign-in to deploy@web-01.example.com failed: password=hunter2', const FormatException('bad key: $key')),
      released: true,
    );
    expect(said, contains('WARNING'));
    expect(said, contains('failed'));
    for (final secret in ['hunter2', 'deploy@web-01', 'web-01.example.com', 'b3BlbnNzaC1rZXktdjEA', 'Stack:', 'x.dart']) {
      expect(said, isNot(contains(secret)), reason: secret);
    }
    expect(said, contains('[private key removed]'));
  });

  test('a build made to debug prints the line as it is, with what was thrown and the stack', () {
    final said = AppLogger.consoleLine(record('Sign-in to deploy@web-01.example.com failed', StateError('why')), released: false);
    expect(said, contains('deploy@web-01.example.com'));
    expect(said, contains('Error: Bad state: why'));
    expect(said, contains('Stack: #0 main'));
    expect(AppLogger.consoleLine(record('a note'), released: false), endsWith('WARNING: a note'));
  });

  test('the console is given that line, as released or not', () {
    final source = File('lib/utils/logger.dart').readAsStringSync();
    expect(source, contains('debugPrint(consoleLine(record, released: kReleaseMode));'));
    expect('debugPrint('.allMatches(source), hasLength(1), reason: 'nothing else prints');
  });
}
