// SPDX-License-Identifier: MIT
import 'dart:io';

import 'package:test/test.dart';

/// The proof that a server holds its host key cannot be switched off (found
/// in a security review of August 2026). SSHClient and SSHTransport
/// took a flag, disableHostkeyVerification, that skipped the check of the
/// server's signature over the exchange hash while onVerifyHostKey still
/// ran: with it, any host that showed a trusted host's public key was taken
/// for that host. Nothing set it. It is gone, and this keeps one from coming
/// back under another name; what a wrong signature does is in
/// ssh_hostkey_fault_test.dart.
void main() {
  final sources = {
    for (final name in ['ssh_client.dart', 'ssh_transport.dart']) name: File('lib/src/$name').readAsStringSync(),
  };

  test('neither the client nor the transport declares a switch for the host key check', () {
    final aSwitch = RegExp(r'bool[?]?\s+\w*(disable|skip|insecure|noVerify)\w*host\s*key\w*', caseSensitive: false);
    for (final MapEntry(key: name, value: text) in sources.entries) {
      expect(aSwitch.allMatches(text).map((m) => m.group(0)), isEmpty, reason: name);
      expect(text, isNot(contains('disableHostkeyVerification;')), reason: name);
      expect(text, isNot(contains('this.disableHostkeyVerification')), reason: name);
    }
  });

  test('the signature check is called with nothing around it that could skip it', () {
    final transport = sources['ssh_transport.dart']!;
    final calls = RegExp(r'^\s*final verified = _verifyHostkey[(]', multiLine: true).allMatches(transport).toList();
    expect(calls, hasLength(1), reason: 'the one call, in the key exchange reply');
    // The last line of code above the call (comments aside) opens no condition.
    final above = transport
        .substring(0, calls.single.start)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('//'))
        .last;
    expect(above.startsWith('if') || above.startsWith('} else'), isFalse, reason: 'above the call: "$above"');
  });
}
