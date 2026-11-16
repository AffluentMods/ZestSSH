import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cryptography the tests run with: everything as in the app, but
/// Argon2id is stood in for (see [StandInArgon2id]). Put in place for every
/// test file by `test/flutter_test_config.dart`.
///
/// Why: the app derives its keys with the pure Dart Argon2id of
/// package:cryptography. Under the test runner's just-in-time compiler the
/// inner function of that implementation is compiled for small integers,
/// thrown away when a 64-bit value comes, compiled again, and after sixteen
/// such rounds never compiled again: from then on one derivation takes
/// twenty to fifty seconds where it took half a second, in that process
/// until it ends. Whether a test file gets there is luck, so files that
/// derive keys timed out now and then, another one every few runs of the
/// suite. A built app is compiled ahead of time and has none of this.
class TestCryptography extends DartCryptography {
  TestCryptography();

  @override
  Argon2id argon2id({
    required int memory,
    required int parallelism,
    required int iterations,
    required int hashLength,
  }) =>
      StandInArgon2id(memory: memory, parallelism: parallelism, iterations: iterations, hashLength: hashLength);
}

/// Stands in for Argon2id in tests: at once, the same key for the same
/// secret, salt and cost, and another key when any of them is another. It is
/// no password hash (it is one SHA-512), which is why it lives under test/.
class StandInArgon2id extends Argon2id {
  const StandInArgon2id({
    required this.memory,
    required this.parallelism,
    required this.iterations,
    required this.hashLength,
  }) : super.constructor();

  @override
  final int memory;

  @override
  final int parallelism;

  @override
  final int iterations;

  @override
  final int hashLength;

  @override
  Future<SecretKey> deriveKey({
    required SecretKey secretKey,
    required List<int> nonce,
    List<int> optionalSecret = const <int>[],
    List<int> associatedData = const <int>[],
  }) async {
    if (hashLength < 1 || hashLength > 64) {
      throw ArgumentError.value(hashLength, 'hashLength', 'the stand-in gives 1 to 64 bytes');
    }
    final secret = await secretKey.extractBytes();
    // Each part with its length before it, so that no two different inputs
    // are the same bytes.
    final input = <int>[
      ...utf8.encode('zestssh test argon2id stand-in v1'),
      for (final part in [
        utf8.encode('$memory/$parallelism/$iterations/$hashLength'),
        secret,
        nonce,
        optionalSecret,
        associatedData,
      ]) ...[
        (part.length >> 24) & 0xFF,
        (part.length >> 16) & 0xFF,
        (part.length >> 8) & 0xFF,
        part.length & 0xFF,
        ...part,
      ],
    ];
    final digest = await const DartSha512().hash(input);
    return SecretKey(digest.bytes.sublist(0, hashLength));
  }
}

/// Runs the tests of this file with the real Argon2id, for the few that are
/// about the derivation itself. A real derivation can take most of a minute
/// here (see [TestCryptography]): give such a test a timeout of minutes.
void useRealKeyDerivation() {
  late Cryptography before;
  setUpAll(() {
    before = Cryptography.instance;
    Cryptography.instance = DartCryptography.defaultInstance;
  });
  tearDownAll(() => Cryptography.instance = before);
}
