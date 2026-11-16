import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/pin_strength.dart';

void main() {
  group('isTrivialPin', () {
    test('rejects a single repeated digit', () {
      for (final p in ['0000', '1111', '9999', '000000', '22222222']) {
        expect(isTrivialPin(p), isTrue, reason: p);
      }
    });

    test('rejects consecutive ascending runs', () {
      for (final p in ['1234', '0123', '3456', '456789']) {
        expect(isTrivialPin(p), isTrue, reason: p);
      }
    });

    test('rejects consecutive descending runs', () {
      for (final p in ['4321', '9876', '3210', '987654']) {
        expect(isTrivialPin(p), isTrue, reason: p);
      }
    });

    test('accepts non-trivial PINs', () {
      for (final p in ['1379', '2846', '1357', '1122', '9042', '135791']) {
        expect(isTrivialPin(p), isFalse, reason: p);
      }
    });

    test('empty is not flagged (length check handles it)', () {
      expect(isTrivialPin(''), isFalse);
    });
  });
}
