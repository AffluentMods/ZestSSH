import 'package:zestssh/features/teams/crypto/fingerprint_word_list.dart';

/// How many words a person's fingerprint is read in: 88 bits, out of reach of
/// a server that would grind keys to match one target (3.0).
const kFingerprintWordCount = 8;

/// [bytes] as [count] words of the BIP-39 English list, eleven bits a word
/// from the first bytes, most significant first (as BIP-39 maps its
/// entropy). A person's fingerprint reads as [kFingerprintWordCount] words;
/// the same fingerprint as the 60 digits, shown another way.
List<String> fingerprintWords(List<int> bytes, {int count = kFingerprintWordCount}) {
  if (count < 1 || bytes.length * 8 < count * 11) {
    throw ArgumentError.value(count, 'count', 'needs ${count * 11} bits, ${bytes.length * 8} given');
  }
  final out = <String>[];
  var acc = 0;
  var bits = 0;
  var next = 0;
  while (out.length < count) {
    while (bits < 11) {
      acc = (acc << 8) | (bytes[next++] & 0xff);
      bits += 8;
    }
    bits -= 11;
    out.add(kFingerprintWordList[(acc >> bits) & 0x7ff]);
    acc &= (1 << bits) - 1;
  }
  return out;
}
