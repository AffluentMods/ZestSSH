import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/networks/engine/cidr.dart';

void main() {
  group('Cidr.tryParse', () {
    test('parses a basic IPv4 CIDR', () {
      final c = Cidr.tryParse('10.50.0.0/16');
      expect(c, isNotNull);
      expect(c.toString(), '10.50.0.0/16');
    });

    test('parses /0 wildcard for IPv4', () {
      final c = Cidr.tryParse('0.0.0.0/0');
      expect(c, isNotNull);
      expect(c!.isWildcard, isTrue);
    });

    test('parses /32 single-host for IPv4', () {
      expect(Cidr.tryParse('192.168.1.1/32'), isNotNull);
    });

    test('parses an IPv6 CIDR with shorthand', () {
      final c = Cidr.tryParse('fd00::/8');
      expect(c, isNotNull);
    });

    test('parses an IPv6 CIDR with full address', () {
      expect(
        Cidr.tryParse('2001:0db8:85a3:0000:0000:8a2e:0370:7334/64'),
        isNotNull,
      );
    });

    test('parses :: as the zero address', () {
      expect(Cidr.tryParse('::/0'), isNotNull);
    });

    test('parses v4-mapped IPv6 notation', () {
      expect(Cidr.tryParse('::ffff:192.0.2.1/128'), isNotNull);
    });

    test('rejects garbage input', () {
      expect(Cidr.tryParse(''), isNull);
      expect(Cidr.tryParse('garbage'), isNull);
      expect(Cidr.tryParse('10.50.0.0'), isNull); // missing slash
      expect(Cidr.tryParse('10.50.0.0/'), isNull); // missing prefix
      expect(Cidr.tryParse('10.50.0.0/abc'), isNull); // non-int prefix
      expect(Cidr.tryParse('10.50.0.0/33'), isNull); // out-of-range v4 prefix
      expect(Cidr.tryParse('10.50.0.0/-1'), isNull);
      expect(Cidr.tryParse('256.0.0.0/8'), isNull); // octet too large
      expect(Cidr.tryParse('10.50.0/24'), isNull); // missing octet
      expect(Cidr.tryParse('::g/8'), isNull); // bad hex
      expect(Cidr.tryParse('1::2::3/8'), isNull); // two ::
      expect(Cidr.tryParse('fd00::/129'), isNull); // out-of-range v6 prefix
    });
  });

  group('Cidr.contains (IPv4)', () {
    test('10.50.0.0/16 contains 10.50.5.7', () {
      expect(Cidr.tryParse('10.50.0.0/16')!.contains('10.50.5.7'), isTrue);
    });

    test('10.50.0.0/16 does not contain 10.21.0.1', () {
      expect(Cidr.tryParse('10.50.0.0/16')!.contains('10.21.0.1'), isFalse);
    });

    test('192.168.1.0/24 contains 192.168.1.255', () {
      expect(
          Cidr.tryParse('192.168.1.0/24')!.contains('192.168.1.255'), isTrue);
    });

    test('192.168.1.0/24 does not contain 192.168.2.0', () {
      expect(
          Cidr.tryParse('192.168.1.0/24')!.contains('192.168.2.0'), isFalse);
    });

    test('0.0.0.0/0 contains everything (v4)', () {
      final c = Cidr.tryParse('0.0.0.0/0')!;
      expect(c.contains('1.2.3.4'), isTrue);
      expect(c.contains('255.255.255.255'), isTrue);
      expect(c.contains('10.0.0.1'), isTrue);
    });

    test('/32 only matches the exact host', () {
      final c = Cidr.tryParse('192.168.1.42/32')!;
      expect(c.contains('192.168.1.42'), isTrue);
      expect(c.contains('192.168.1.43'), isFalse);
    });

    test('returns false for invalid IPv4 input', () {
      final c = Cidr.tryParse('10.0.0.0/8')!;
      expect(c.contains('not-an-ip'), isFalse);
      expect(c.contains(''), isFalse);
    });

    test('returns false when given a v6 address', () {
      // Type mismatch should not throw.
      final c = Cidr.tryParse('10.0.0.0/8')!;
      expect(c.contains('::1'), isFalse);
    });
  });

  group('Cidr.contains (IPv6)', () {
    test('fd00::/8 contains fd12:3456::1', () {
      expect(Cidr.tryParse('fd00::/8')!.contains('fd12:3456::1'), isTrue);
    });

    test('fd00::/8 does not contain fc00::1', () {
      expect(Cidr.tryParse('fd00::/8')!.contains('fc00::1'), isFalse);
    });

    test('::/0 contains everything (v6)', () {
      final c = Cidr.tryParse('::/0')!;
      expect(c.contains('::1'), isTrue);
      expect(c.contains('2001:db8::1'), isTrue);
      expect(c.contains('fe80::1'), isTrue);
    });

    test('/128 only matches the exact host', () {
      final c = Cidr.tryParse('2001:db8::1/128')!;
      expect(c.contains('2001:db8::1'), isTrue);
      expect(c.contains('2001:db8::2'), isFalse);
    });

    test('strips v6 zone id from address before matching', () {
      // The detector strips the zone, so callers may also pass
      // pre-stripped addresses. Ensure neither breaks.
      final c = Cidr.tryParse('fe80::/10')!;
      expect(c.contains('fe80::1'), isTrue);
    });

    test('handles v4-mapped notation', () {
      final c = Cidr.tryParse('::ffff:0:0/96')!;
      // The two address representations resolve to the same bytes.
      expect(c.contains('::ffff:192.0.2.1'), isTrue);
    });
  });
}
