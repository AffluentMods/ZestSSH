import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sftp_service.dart';

/// Which of a host's files a download keeps to its owner on macOS and Linux
/// (found in a security review): one none but its owner may
/// read there, as its permissions say (test/services/sftp_transfers_real_host_test.dart
/// downloads one).
void main() {
  test("a file is its owner's alone when neither its group nor others have any of its bits", () {
    for (final mode in [0x180 /* 600 */, 0x100 /* 400 */, 0x1C0 /* 700 */, 0x8180 /* a file at 600 */, 0]) {
      expect(isOwnerOnly(mode), isTrue, reason: mode.toRadixString(8));
    }
    for (final mode in [0x1A4 /* 644 */, 0x1A0 /* 640 */, 0x184 /* 604 */, 0x181 /* 601 */, 0x188 /* 610 */, 0x81A4]) {
      expect(isOwnerOnly(mode), isFalse, reason: mode.toRadixString(8));
    }
    expect(isOwnerOnly(null), isFalse, reason: 'a host that says nothing of it');
  });
}
