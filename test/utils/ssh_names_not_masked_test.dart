import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';
import 'package:zestssh/utils/ssh_protocol_names.dart';

/// A name of the SSH protocol is no user at a host (3.0; found while the
/// SSH core's audit was at what a host and the app offer each other).
///
/// Many names of the protocol have an at sign in them, by the rule the
/// protocol has for names that are no standard's (RFC 4251, 6:
/// "chacha20-poly1305@openssh.com", "curve25519-sha256@libssh.org"). What
/// makes text fit for a report, and what recording mode masks on screen,
/// took every one of them for a user at a host: the log of a connection
/// that a report carries said "user01@192.0.2.1" where it had named the
/// cipher that was agreed on.
///
/// Only names that are known are left as they are: anything else before
/// and after an at sign is still masked.
void main() {
  setUp(() {
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = false;
    ReportScrub.clearFolders();
  });

  tearDown(() {
    Redactor.instance.clearNames();
    ReportScrub.clearFolders();
  });

  test('a name of the protocol stays as it is in a report and in recording mode: alone, in a list, in brackets, '
      'and at the end of a sentence', () {
    for (final text in [
      'chacha20-poly1305@openssh.com',
      // As the log of a connection has them while it is made.
      'debug: SSHTransport._kexType: SSHKexType(curve25519-sha256@libssh.org)',
      'debug: SSHTransport._clientCipherType: SSHCipherType(chacha20-poly1305@openssh.com)',
      'debug: SSHTransport._clientMacType: SSHMacType(hmac-sha2-256-etm@openssh.com)',
      'debug: SSHTransport: server supports strict KEX (Terrapin mitigation)',
      'aes256-gcm@openssh.com,aes128-gcm@openssh.com',
      'aes256-gcm@openssh.com, aes128-gcm@openssh.com and rijndael-cbc@lysator.liu.se',
      '[the server offers: aes256-gcm@openssh.com,aes128-gcm@openssh.com]',
      'The server offers only aes256-gcm@openssh.com.',
      'It offers sntrup761x25519-sha512@openssh.com: nothing else.',
      'Asking for keepalive@openssh.com...',
      'SftpExtensionUnsupportedError(statvfs@openssh.com)',
    ]) {
      expect(ReportScrub.scrub(text), text, reason: 'in a report: $text');
      expect(Redactor.line(text), text, reason: 'in recording mode: $text');
    }
  });

  test('every name the list has stays, and so does it in capitals nowhere: a name is said as the protocol has it',
      () {
    expect(sshNamesWithAnAtSign, isNotEmpty);
    for (final name in sshNamesWithAnAtSign) {
      expect(name, matches(RegExp(r'^[a-z0-9][a-z0-9.-]*@[a-z0-9.-]+\.[a-z]+$')), reason: name);
      expect(Redactor.line('it is $name here'), 'it is $name here', reason: name);
      expect(ReportScrub.scrub('($name)'), '($name)', reason: name);
      // Another spelling is no name of the protocol.
      expect(Redactor.line(name.toUpperCase()), isNot(name.toUpperCase()), reason: name);
    }
  });

  test('a user at a host is masked as before, also at a host that such names end with, and whatever only begins or '
      'ends like a name of the protocol', () {
    for (final text in [
      'deploy@web-01.example.com',
      'deploy@openssh.com',
      'alex@libssh.org',
      // A name of the protocol and more after it: a host of that name.
      'chacha20-poly1305@openssh.com.example.net',
      'chacha20-poly1305@openssh.com:2222',
      // And more before it: a user of that name.
      'robin.chacha20-poly1305@openssh.com',
      'morgan@chacha20-poly1305@openssh.com',
      // A name nobody knows.
      'made-up-cipher@openssh.com',
    ]) {
      expect(Redactor.line(text), isNot(contains(text)), reason: 'in recording mode: $text');
      expect(ReportScrub.scrub(text), isNot(contains(text)), reason: 'in a report: $text');
    }
    // The user and the host go, each for itself.
    final masked = Redactor.line('deploy@openssh.com');
    expect(masked, isNot(contains('deploy')));
    expect(masked, isNot(contains('openssh.com')));
  });

  test('a line with both: the name stays and the user at a host goes', () {
    final line = Redactor.line('deploy@web-01.example.com agreed on chacha20-poly1305@openssh.com');
    expect(line, endsWith(' agreed on chacha20-poly1305@openssh.com'));
    expect(line, isNot(contains('deploy')));
    expect(line, isNot(contains('web-01')));
  });

  test('every name with an at sign that the SSH core has in its code is in the list', () {
    // Read from the package: a name it comes to know later is asked for here.
    final written = RegExp(r'''['"]([a-z0-9][a-z0-9.-]*@(?:openssh\.com|libssh\.org|lysator\.liu\.se))['"]''');
    final found = <String>{};
    for (final file in Directory('packages/zest_ssh_core/lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in written.allMatches(file.readAsStringSync())) {
        found.add(match[1]!);
      }
    }
    expect(found.length, greaterThan(15), reason: 'the names were not found where they are written');
    expect(found.difference(sshNamesWithAnAtSign), isEmpty, reason: 'names of the SSH core that the list does not have');
  });
}
