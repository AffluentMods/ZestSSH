import 'dart:math';
import 'dart:typed_data';

import 'package:zestssh/services/fido/cbor.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(' ', '');
  return Uint8List.fromList([for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)]);
}

String toHex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('what is written', () {
    test('the examples of RFC 8949, appendix A, that CTAP2 can say', () {
      final cases = <Object?, String>{
        0: '00',
        1: '01',
        10: '0a',
        23: '17',
        24: '1818',
        25: '1819',
        100: '1864',
        1000: '1903e8',
        1000000: '1a000f4240',
        1000000000000: '1b000000e8d4a51000',
        -1: '20',
        -10: '29',
        -100: '3863',
        -1000: '3903e7',
        false: 'f4',
        true: 'f5',
        null: 'f6',
        '': '60',
        'a': '6161',
        'IETF': '6449455446',
        'ü': '62c3bc',
        '水': '63e6b0b4',
      };
      for (final e in cases.entries) {
        expect(toHex(cborEncode(e.key)), e.value, reason: '${e.key}');
        expect(cborDecode(hex(e.value)), e.key, reason: e.value);
      }
      expect(toHex(cborEncode(Uint8List(0))), '40');
      expect(toHex(cborEncode(hex('01020304'))), '4401020304');
      expect(toHex(cborEncode(<Object?>[])), '80');
      expect(toHex(cborEncode([1, 2, 3])), '83010203');
      expect(
          toHex(cborEncode([
            1,
            [2, 3],
            [4, 5]
          ])),
          '8301820203820405');
      expect(toHex(cborEncode(<Object?, Object?>{})), 'a0');
      expect(toHex(cborEncode({1: 2, 3: 4})), 'a201020304');
      expect(toHex(cborEncode({'a': 1, 'b': [2, 3]})), 'a26161016162820203');
    });

    test('a map\'s keys go in CTAP2\'s order whatever order they were given in', () {
      // Numbers before text; among text, the shorter first, then by bytes.
      final written = cborEncode({'bb': 1, 'a': 2, 1000: 3, 2: 4, -1: 5, 'ab': 6});
      expect(toHex(written), 'a6' '0204' '1903e803' '2005' '616102' '62616206' '62626201');
      // The request of a real getAssertion: keys 1, 2, 3, 5.
      expect(toHex(cborEncode({5: true, 1: 'ssh:', 3: <Object?>[], 2: Uint8List(2)})), 'a4' '01647373683a' '02420000' '0380' '05f5');
    });

    test('what cannot be said is refused', () {
      expect(() => cborEncode(1.5), throwsA(isA<CborError>()));
      expect(() => cborEncode({1.5: 1}), throwsA(isA<CborError>()));
      expect(() => cborEncode({Uint8List(1): 1}), throwsA(isA<CborError>()));
    });
  });

  group('what is read', () {
    test('comes back as it was written', () {
      final value = {
        1: 'ssh:',
        2: hex('00112233445566778899aabbccddeeff'),
        3: [
          {'type': 'public-key', 'id': hex('deadbeef')}
        ],
        5: {'up': true, 'uv': false},
        -2: null,
        'big': 0x7fffffffffffffff,
        'neg': -0x8000000000000000,
      };
      expect(cborDecode(cborEncode(value)), value);
    });

    test('the first value, and where it ends', () {
      final bytes = Uint8List.fromList([...cborEncode({1: 2}), 0xaa, 0xbb]);
      final (value, end) = cborDecodeFirst(bytes);
      expect(value, {1: 2});
      expect(end, 3);
      expect(() => cborDecode(bytes), throwsA(isA<CborError>()), reason: 'bytes left over');
    });

    test('nothing it does not know is taken', () {
      for (final (bad, why) in [
        ('', 'nothing'),
        ('18', 'a number cut short'),
        ('4401', 'a byte string cut short'),
        ('62c3', 'text cut short'),
        ('61ff', 'text that is not UTF-8'),
        ('5f4101ff', 'a byte string of open length'),
        ('9f01ff', 'an array of open length'),
        ('bf0102ff', 'a map of open length'),
        ('c074323031332d30332d32315432303a30343a30305a', 'a tag'),
        ('f93e00', 'a half float'),
        ('fa47c35000', 'a float'),
        ('fb3ff199999999999a', 'a double'),
        ('f7', 'undefined'),
        ('f0', 'a simple value'),
        ('1c', 'a head that means nothing'),
        ('1bffffffffffffffff', 'a number a Dart int cannot hold'),
        ('3bffffffffffffffff', 'a negative number a Dart int cannot hold'),
        ('a2010201 03', 'the same key twice'),
        ('a1 4101 02', 'a byte string as a key'),
        ('a1 8101 02', 'an array as a key'),
        ('9a00ffffff', 'an array said to hold more than there are bytes'),
        ('ba00ffffff', 'a map said to hold more than there are bytes'),
        ('5a7fffffff', 'a byte string said to be longer than what is left'),
      ]) {
        expect(() => cborDecode(hex(bad)), throwsA(isA<CborError>()), reason: why);
      }
    });

    test('how deep and how many are bounded', () {
      // Nine arrays inside one another: one too many.
      expect(() => cborDecode(hex('81' * (kCborMaxDepth + 1) + '00')), throwsA(isA<CborError>()));
      expect(cborDecode(hex('81' * kCborMaxDepth + '00')), isNotNull);
      // An array of more values than a message may hold.
      final many = Uint8List.fromList([0x99, 0x10, 0x01, ...List.filled(0x1001, 0)]);
      expect(() => cborDecode(many), throwsA(isA<CborError>()));
    });

    test('random bytes, and real messages cut or changed anywhere, are read or refused: nothing else is thrown', () {
      final random = Random(20261114);
      final real = cborEncode({
        1: 'packed',
        2: Uint8List.fromList(List.generate(164, (i) => i)),
        3: {
          'alg': -7,
          'sig': Uint8List(70),
          'x5c': [Uint8List(300)]
        },
      });
      var read = 0;
      for (var round = 0; round < 20000; round++) {
        final Uint8List bytes;
        if (round.isEven) {
          bytes = Uint8List.fromList(List.generate(random.nextInt(48), (_) => random.nextInt(256)));
        } else {
          bytes = Uint8List.fromList(real.sublist(0, random.nextInt(real.length + 1)));
          if (bytes.isNotEmpty) bytes[random.nextInt(bytes.length)] = random.nextInt(256);
        }
        try {
          cborDecode(bytes);
          read++;
        } on CborError {
          // Refused, with a reason.
        }
      }
      expect(read, greaterThan(0));
    });
  });
}
