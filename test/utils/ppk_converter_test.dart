import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/utils/ppk_converter.dart';

void main() {
  group('PpkConverter', () {
    // ── Format detection ─────────────────────────────────────────

    group('format detection', () {
      test('rejects empty input', () {
        expect(
          () => PpkConverter.toPem(''),
          throwsA(isA<FormatException>()),
        );
      });

      test('rejects non-PPK content', () {
        expect(
          () => PpkConverter.toPem('-----BEGIN RSA PRIVATE KEY-----\ndata\n'
              '-----END RSA PRIVATE KEY-----'),
          throwsA(isA<FormatException>()),
        );
      });

      test('rejects plain text', () {
        expect(
          () => PpkConverter.toPem('this is not a key file'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    // ── Encrypted key detection ──────────────────────────────────

    // Made-up keys built with Python's cryptography package by the format
    // PuTTY documents (not written by PuTTYgen itself): one key, without a
    // passphrase, with one as version 3 (Argon2id) and as version 2.
    group('a key with a passphrase', () {
      const passphrase = 'demo passphrase for tests';
      const publicBlob = 'AAAAC3NzaC1lZDI1NTE5AAAAIHm1Vi6P5lT5QHixEuipi6eQH4U65pW+1+DjkQutBJZk';
      const plain3 = '''
PuTTY-User-Key-File-3: ssh-ed25519
Encryption: none
Comment: demo@northwind.example
Public-Lines: 2
AAAAC3NzaC1lZDI1NTE5AAAAIHm1Vi6P5lT5QHixEuipi6eQH4U65pW+1+DjkQut
BJZk
Private-Lines: 1
AAAAIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g
Private-MAC: d64971abf36b2d12b887a9cb86d9ada74a5d02dc93aec493275a9b52705f4d70
''';
      const enc3 = '''
PuTTY-User-Key-File-3: ssh-ed25519
Encryption: aes256-cbc
Comment: demo@northwind.example
Public-Lines: 2
AAAAC3NzaC1lZDI1NTE5AAAAIHm1Vi6P5lT5QHixEuipi6eQH4U65pW+1+DjkQut
BJZk
Key-Derivation: Argon2id
Argon2-Memory: 1024
Argon2-Passes: 3
Argon2-Parallelism: 1
Argon2-Salt: 404142434445464748494a4b4c4d4e4f
Private-Lines: 1
BTQP6Gmu99rIQLq8JDbwjdp6+o026Exu4IlUh66nuZlPXn7hyGt3XbTkJEOM8nPn
Private-MAC: 255ad71837fe334e525131f365122c3aab5421a1e0c7ceae4ed88fedb59d730a
''';
      const enc2 = '''
PuTTY-User-Key-File-2: ssh-ed25519
Encryption: aes256-cbc
Comment: demo@northwind.example
Public-Lines: 2
AAAAC3NzaC1lZDI1NTE5AAAAIHm1Vi6P5lT5QHixEuipi6eQH4U65pW+1+DjkQut
BJZk
Private-Lines: 1
jRJaA9JtjbVmlRziVVFwQUq6dILJY5q1voXt1lpOZnvFYAVzHKo0rn/GRyapZ0uP
Private-MAC: d98aa40c091cf767536d72e45f021b0e5db6e0c0
''';

      String publicOf(String pem) => base64Encode(SSHKeyPair.fromPem(pem).single.toPublicKey().encode());

      test('is told from one without', () {
        expect(PpkConverter.isEncrypted(plain3.trimLeft()), isFalse);
        expect(PpkConverter.isEncrypted(enc3.trimLeft()), isTrue);
        expect(PpkConverter.isEncrypted(enc2.trimLeft()), isTrue);
        expect(PpkConverter.isEncrypted('not a key'), isFalse);
      });

      test('version 3 (Argon2id) opens with its passphrase, to the key the file without one holds', () {
        expect(publicOf(PpkConverter.toPem(plain3.trimLeft())), publicBlob);
        expect(publicOf(PpkConverter.toPem(enc3.trimLeft(), passphrase)), publicBlob);
      });

      test('version 2 opens with its passphrase, to the same key', () {
        expect(publicOf(PpkConverter.toPem(enc2.trimLeft(), passphrase)), publicBlob);
      });

      test('given none, it says a passphrase is needed', () {
        for (final key in [enc3, enc2]) {
          for (final none in [null, '']) {
            expect(() => PpkConverter.toPem(key.trimLeft(), none),
                throwsA(isA<PpkPassphraseError>().having((e) => e.missing, 'missing', isTrue)));
          }
        }
      });

      test('given a wrong one, it says so and gives no key', () {
        for (final key in [enc3, enc2]) {
          expect(() => PpkConverter.toPem(key.trimLeft(), 'not the passphrase'),
              throwsA(isA<PpkPassphraseError>().having((e) => e.missing, 'missing', isFalse)));
        }
      });

      test('a file changed after it was written fails the same way, with the right passphrase', () {
        final changed = enc3.trimLeft().replaceFirst('Comment: demo@northwind.example', 'Comment: admin@northwind.example');
        expect(() => PpkConverter.toPem(changed, passphrase), throwsA(isA<PpkPassphraseError>()));
      });

      test('a file that asks for more work than a key would is refused before any is done', () {
        String with_(String from, String to) => enc3.trimLeft().replaceFirst(from, to);
        for (final bad in [
          with_('Argon2-Memory: 1024', 'Argon2-Memory: 99999999'),
          with_('Argon2-Passes: 3', 'Argon2-Passes: 0'),
          with_('Argon2-Passes: 3', 'Argon2-Passes: 100000'),
          with_('Argon2-Parallelism: 1', 'Argon2-Parallelism: 4096'),
          with_('Key-Derivation: Argon2id', 'Key-Derivation: Scrypt'),
          with_('Argon2-Salt: 404142434445464748494a4b4c4d4e4f', 'Argon2-Salt: zz'),
          with_('Encryption: aes256-cbc', 'Encryption: rot13'),
        ]) {
          expect(() => PpkConverter.toPem(bad, passphrase), throwsFormatException);
        }
      });
    });

    group('unsupported key types', () {
      test('throws FormatException for unsupported key type', () {
        const ppk = 'PuTTY-User-Key-File-2: ecdsa-sha2-nistp256\n'
            'Encryption: none\n'
            'Comment: ecdsa-key\n'
            'Public-Lines: 1\n'
            'AAAA\n'
            'Private-Lines: 1\n'
            'BBBB\n';

        expect(
          () => PpkConverter.toPem(ppk),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Unsupported PPK key type'),
            ),
          ),
        );
      });
    });

    // ── Malformed PPK ────────────────────────────────────────────

    group('malformed PPK structure', () {
      test('throws when Public-Lines section is missing', () {
        const ppk = 'PuTTY-User-Key-File-2: ssh-rsa\n'
            'Encryption: none\n'
            'Comment: test\n'
            'Private-Lines: 1\n'
            'BBBB\n';

        expect(
          () => PpkConverter.toPem(ppk),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws when Private-Lines section is missing', () {
        const ppk = 'PuTTY-User-Key-File-2: ssh-rsa\n'
            'Encryption: none\n'
            'Comment: test\n'
            'Public-Lines: 1\n'
            'AAAA\n';

        expect(
          () => PpkConverter.toPem(ppk),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws when line count is invalid', () {
        const ppk = 'PuTTY-User-Key-File-2: ssh-rsa\n'
            'Encryption: none\n'
            'Comment: test\n'
            'Public-Lines: notanumber\n'
            'AAAA\n'
            'Private-Lines: 1\n'
            'BBBB\n';

        expect(
          () => PpkConverter.toPem(ppk),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws when file is truncated (not enough data lines)', () {
        const ppk = 'PuTTY-User-Key-File-2: ssh-rsa\n'
            'Encryption: none\n'
            'Comment: test\n'
            'Public-Lines: 5\n'
            'AAAA\n';

        expect(
          () => PpkConverter.toPem(ppk),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws on invalid base64 in section', () {
        const ppk = 'PuTTY-User-Key-File-2: ssh-rsa\n'
            'Encryption: none\n'
            'Comment: test\n'
            'Public-Lines: 1\n'
            '!!!not-base64!!!\n'
            'Private-Lines: 1\n'
            'BBBB\n';

        expect(
          () => PpkConverter.toPem(ppk),
          throwsA(isA<FormatException>()),
        );
      });
    });

    // ── Version detection ────────────────────────────────────────

    group('version detection', () {
      test('detects v2 format', () {
        // A version 2 key with a passphrase derives its key from the
        // passphrase alone, so it gets as far as the private blob.
        const ppk = 'PuTTY-User-Key-File-2: ssh-rsa\n'
            'Encryption: aes256-cbc\n'
            'Comment: test\n'
            'Public-Lines: 1\n'
            'AAAA\n'
            'Private-Lines: 1\n'
            'BBBB\n';

        expect(
          () => PpkConverter.toPem(ppk, 'a passphrase'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('whole blocks'),
            ),
          ),
        );
      });

      test('detects v3 format', () {
        const ppk = 'PuTTY-User-Key-File-3: ssh-rsa\n'
            'Encryption: aes256-cbc\n'
            'Comment: test\n'
            'Public-Lines: 1\n'
            'AAAA\n'
            'Private-Lines: 1\n'
            'BBBB\n';

        expect(
          () => PpkConverter.toPem(ppk, 'a passphrase'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Key-Derivation'),
            ),
          ),
        );
      });
    });
  });
}
