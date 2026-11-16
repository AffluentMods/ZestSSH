import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/teams/crypto/fingerprint_word_list.dart';
import 'package:zestssh/features/teams/crypto/fingerprint_words.dart';

/// Fingerprints read as words (3.0): the BIP-39 English list, mapped
/// the way BIP-39 maps entropy.
List<int> _hex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

void main() {
  test('the word list is BIP-39 English, byte for byte', () {
    expect(kFingerprintWordList.length, 2048);
    expect(kFingerprintWordList.toSet().length, 2048);
    // Each word told apart by its first four letters.
    expect({for (final w in kFingerprintWordList) w.substring(0, w.length < 4 ? w.length : 4)}.length, 2048);
    final file = '${kFingerprintWordList.join('\n')}\n';
    expect(sha256.convert(utf8.encode(file)).toString(),
        '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda');
  });

  test("BIP-39's own vectors: its first eleven words are the entropy's bits", () {
    // From the BIP-39 test vectors (the twelfth word carries a checksum,
    // which fingerprints do not use).
    String words(String hex) => fingerprintWords(_hex(hex), count: 11).join(' ');
    expect(words('00000000000000000000000000000000'), List.filled(11, 'abandon').join(' '));
    expect(words('7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f'),
        'legal winner thank year wave sausage worth useful legal winner thank');
    expect(words('80808080808080808080808080808080'),
        'letter advice cage absurd amount doctor acoustic avoid letter advice cage');
    expect(words('ffffffffffffffffffffffffffffffff'), List.filled(11, 'zoo').join(' '));
  });

  test('a fingerprint reads as eight words from its first 88 bits', () {
    final fp = List<int>.generate(32, (i) => i * 7 + 3);
    final words = fingerprintWords(fp);
    expect(words, hasLength(8));
    // Only the first eleven bytes count.
    final tail = [...fp.take(11), ...List.filled(21, 0)];
    expect(fingerprintWords(tail), words);
    // Changing bit 87 changes the last word.
    final flipped = [...fp]..[10] ^= 0x01;
    expect(fingerprintWords(flipped).last, isNot(words.last));
    expect(fingerprintWords(flipped).take(7), words.take(7));
  });

  test('too few bytes for the words asked is refused', () {
    expect(() => fingerprintWords(List.filled(10, 0)), throwsArgumentError);
    expect(fingerprintWords(List.filled(5, 0), count: 3), List.filled(3, 'abandon'));
    expect(() => fingerprintWords(const [1, 2, 3], count: 0), throwsArgumentError);
  });
}
