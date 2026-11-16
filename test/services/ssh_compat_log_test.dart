import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A connection's log in compatibility mode (found in a
/// check): it said "DH group-1 included", which compatibility mode does
/// not offer. It names what compatibility mode adds to the defaults.
void main() {
  test("compatibility mode's log line names what it adds, and no DH group 1, which it never offers", () {
    final compat = SshService.buildAlgorithms(compatibility: true);
    expect(compat.kex, isNot(contains(SSHKexType.dh1Sha1)));
    expect(compat.kex, containsAll([SSHKexType.dh14Sha1, SSHKexType.dhGexSha1]));
    expect(compat.cipher, contains(SSHCipherType.aes128cbc));
    expect(compat.mac, contains(SSHMacType.hmacMd5));
    const line = SshService.compatibilityLogLine;
    expect(line, isNot(contains('group-1 included')));
    expect(line, contains('never DH group 1'));
    expect(compat.minDhGroupBits, 1024);
    expect(const SSHAlgorithms().minDhGroupBits, 2048);
    for (final added in ['CBC ciphers', 'hmac-md5', 'SHA-1 key exchanges', 'key exchange groups of 1024 bits']) {
      expect(line, contains(added));
    }
  });
}
