import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/ssh_cert/ssh_wire.dart';

/// We can't easily test the real `_AgentSignature` from outside the
/// library (it's private). What we *can* do - and what's actually most
/// valuable - is fuzz the same `SshWireReader` that `_AgentSignature`
/// uses for validation, plus assert that legitimate SSH-agent
/// signature bytes round-trip cleanly through it.
///
/// These tests guard the security invariants the audit flagged:
///   * algorithm name parses to a non-empty string under the cap
///   * signature bytes parse as a length-prefixed string
///   * trailing bytes are detected
void main() {
  group('SSH agent signature wire shape', () {
    test('legitimate signature blob has algo + sig and consumes fully',
        () {
      // Build a wire-shaped sig: string algo || string sig_bytes.
      final w = SshWireWriter()
        ..writeUtf8String('ssh-ed25519')
        ..writeString(Uint8List.fromList(List.filled(64, 0xAB)));
      final blob = w.takeBytes();

      final r = SshWireReader(blob);
      expect(r.readUtf8String(maxLength: 256), 'ssh-ed25519');
      expect(r.readString(maxLength: 64 * 1024).length, 64);
      expect(r.isExhausted, isTrue,
          reason: 'a clean blob is fully consumed');
    });

    test('blob with trailing garbage is detected', () {
      final clean = SshWireWriter()
        ..writeUtf8String('ssh-ed25519')
        ..writeString(Uint8List.fromList(List.filled(64, 0xAB)));
      final cleanBytes = clean.takeBytes();
      final dirty = Uint8List(cleanBytes.length + 4);
      dirty.setRange(0, cleanBytes.length, cleanBytes);
      // Append 4 garbage bytes - would slip past a non-strict parser.
      dirty[cleanBytes.length] = 0xDE;
      dirty[cleanBytes.length + 1] = 0xAD;
      dirty[cleanBytes.length + 2] = 0xBE;
      dirty[cleanBytes.length + 3] = 0xEF;

      final r = SshWireReader(dirty);
      r.readUtf8String(maxLength: 256);
      r.readString(maxLength: 64 * 1024);
      expect(r.isExhausted, isFalse,
          reason: 'trailing 4 bytes must be visible to the validator');
      expect(r.remaining, 4);
    });

    test('truncated blob blows up at parse time', () {
      // Length prefix says 100 bytes follow, but only 8 are present.
      final w = SshWireWriter()
        ..writeUtf8String('ssh-ed25519')
        ..writeUint32(100); // claims 100 bytes follow
      // Add only 8 bytes of "signature".
      final partial = w.takeBytes();
      final out = Uint8List(partial.length + 8);
      out.setRange(0, partial.length, partial);
      out.setRange(partial.length, out.length, [1, 2, 3, 4, 5, 6, 7, 8]);

      final r = SshWireReader(out);
      r.readUtf8String(maxLength: 256);
      expect(() => r.readString(maxLength: 64 * 1024),
          throwsFormatException);
    });

    test('over-cap algorithm names are rejected', () {
      final hugeName = 'a' * 1024;
      final w = SshWireWriter()..writeUtf8String(hugeName);
      // Don't even add a sig - we expect the algo read to fail first.
      final r = SshWireReader(w.takeBytes());
      expect(() => r.readUtf8String(maxLength: 256), throwsFormatException);
    });
  });
}
