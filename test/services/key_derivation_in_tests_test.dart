import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:zestssh/services/sync_service.dart';

import '../helpers/test_cryptography.dart';

/// What the tests derive keys with, and that the app does not (3.0): a
/// stand-in for Argon2id is put in place for every test file, because the
/// real one is now and then a hundred times slower under the test runner
/// (see [TestCryptography]). The app's own checks, and everything that is
/// not Argon2id, are the app's in tests too.
void main() {
  Future<List<int>> derive(String secret, List<int> salt, {int memory = 65536, int iterations = 3, int lanes = 4}) async {
    final key = await Argon2id(memory: memory, iterations: iterations, parallelism: lanes, hashLength: 32)
        .deriveKey(secretKey: SecretKey(utf8.encode(secret)), nonce: salt);
    return key.extractBytes();
  }

  group('in tests', () {
    final salt = List<int>.generate(32, (i) => i);

    test('Argon2id is the stand-in, without a test asking for it', () {
      expect(Cryptography.instance, isA<TestCryptography>());
      final argon2 = Argon2id(memory: 131072, iterations: 3, parallelism: 4, hashLength: 32);
      expect(argon2, isA<StandInArgon2id>());
      expect([argon2.memory, argon2.iterations, argon2.parallelism, argon2.hashLength], [131072, 3, 4, 32]);
    });

    test('the same secret, salt and cost give the same key, of the length asked for', () async {
      expect(await derive('correct horse', salt), await derive('correct horse', salt));
      expect(await derive('correct horse', salt), hasLength(32));
      final short = await Argon2id(memory: 4096, iterations: 4, parallelism: 2, hashLength: 16)
          .deriveKey(secretKey: SecretKey(utf8.encode('1234')), nonce: salt);
      expect(await short.extractBytes(), hasLength(16));
    });

    test('another secret, salt or cost gives another key', () async {
      final key = await derive('correct horse', salt);
      expect(await derive('correct horsf', salt), isNot(key));
      expect(await derive('correct horse', [...salt.sublist(1), 0]), isNot(key));
      expect(await derive('correct horse', salt, memory: 131072), isNot(key));
      expect(await derive('correct horse', salt, iterations: 4), isNot(key));
      expect(await derive('correct horse', salt, lanes: 2), isNot(key));
      // Where one part ends and the next begins is part of what is hashed.
      expect(await derive('ab', utf8.encode('c')), isNot(await derive('a', utf8.encode('bc'))));
      expect(await derive('', salt), isNot(await derive('', const [])));
    });

    test('the app derives through it, and still refuses a cost under its floor first', () async {
      final a = await SyncService.deriveKey('pw', Uint8List.fromList(salt));
      final b = await SyncService.deriveKey('pw', Uint8List.fromList(salt), params: SyncService.legacyArgon2Params);
      expect(await a.extractBytes(), await derive('pw', salt, memory: 131072));
      expect(await b.extractBytes(), await derive('pw', salt), reason: 'the cost a store names is the cost used');
      await expectLater(
        SyncService.deriveKey('pw', Uint8List.fromList(salt), params: {'memory': 19456, 'iterations': 2, 'parallelism': 1}),
        throwsFormatException,
      );
    });

    test('nothing else is stood in for: ciphers, digests and the rest are the library\'s', () {
      expect(AesGcm.with256bits(), isA<DartAesGcm>());
      expect(Sha256(), isA<DartSha256>());
      expect(Hkdf(hmac: Hmac.sha256(), outputLength: 32), isA<DartHkdf>());
      expect(Chacha20.poly1305Aead(), isA<DartChacha20>());
    });
  });

  group('in the app', () {
    test('the library gives its own Argon2id', () {
      for (final library in [Cryptography.defaultInstance, DartCryptography.defaultInstance]) {
        expect(library.argon2id(memory: 65536, parallelism: 4, iterations: 3, hashLength: 32), isA<DartArgon2id>());
      }
    });

    test('nothing under lib/ chooses the cryptography: only a test can', () {
      final choosing = RegExp(r'Cryptography\s*\.\s*(instance\s*=[^=]|freezeInstance)|TestCryptography|StandInArgon2id');
      final found = <String>[];
      var read = 0;
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        read++;
        if (choosing.hasMatch(entity.readAsStringSync())) found.add(entity.path);
      }
      expect(read, greaterThan(500), reason: 'the app was read');
      expect(found, isEmpty);
    });
  });

  group('the real derivation, where a test asks for it', () {
    useRealKeyDerivation();

    test('is Argon2id: another implementation of it gives the same key', () async {
      expect(Argon2id(memory: 4096, iterations: 4, parallelism: 2, hashLength: 32), isA<DartArgon2id>());
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
      // The cost of the app lock's PIN, and a small one with more lanes.
      for (final (memory, iterations, lanes) in [(4096, 4, 2), (1024, 3, 4)]) {
        final ours = await derive('correct horse', salt, memory: memory, iterations: iterations, lanes: lanes);
        final other = Uint8List(32);
        (pc.Argon2BytesGenerator()
              ..init(pc.Argon2Parameters(
                pc.Argon2Parameters.ARGON2_id,
                salt,
                desiredKeyLength: 32,
                iterations: iterations,
                memory: memory,
                lanes: lanes,
                version: pc.Argon2Parameters.ARGON2_VERSION_13,
              )))
            .deriveKey(Uint8List.fromList(utf8.encode('correct horse')), 0, other, 0);
        expect(ours, other, reason: '$memory KiB, $iterations passes, $lanes lanes');
        expect(ours, isNot(await const StandInArgon2id(
                memory: 4096, iterations: 4, parallelism: 2, hashLength: 32)
            .deriveKey(secretKey: SecretKey(utf8.encode('correct horse')), nonce: salt)
            .then((k) => k.extractBytes())));
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  test('after such a group the stand-in is back', () {
    expect(Cryptography.instance, isA<TestCryptography>());
  });
}
