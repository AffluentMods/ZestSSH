// The X11 forwarder's pure parts (the live path is checked against the test servers,
// separately).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_screen_example/x11_forward.dart';
import 'package:zest_screen_example/x_program.dart';

Uint8List setupBytes({bool big = false, String name = mitMagicCookie, List<int>? data, int major = 11}) {
  final s = X11Setup.build(X11Auth(name, data ?? List.filled(16, 7)), bigEndian: big);
  if (major != 11) ByteData.sublistView(s).setUint16(2, major, big ? Endian.big : Endian.little);
  return s;
}

void main() {
  group('X11Setup', () {
    test('reads a little-endian setup only once it is whole', () {
      final s = setupBytes(data: List.generate(16, (i) => i));
      expect(s.length, 12 + 20 + 16);
      for (var n = 0; n < s.length; n++) {
        expect(X11Setup.tryParse(Uint8List.sublistView(s, 0, n)), isNull, reason: '$n bytes');
      }
      final p = X11Setup.tryParse(Uint8List.fromList([...s, 1, 2, 3]))!;
      expect(p.bigEndian, isFalse);
      expect(p.authName, mitMagicCookie);
      expect(p.authData, List.generate(16, (i) => i));
      expect(p.length, s.length);
    });

    test('reads a big-endian setup', () {
      final p = X11Setup.tryParse(setupBytes(big: true))!;
      expect(p.bigEndian, isTrue);
      expect(p.major, 11);
      expect(p.authData.length, 16);
    });

    test('refuses what is not an X11 setup', () {
      expect(() => X11Setup.tryParse(Uint8List.fromList([0x16, 3, 1])), throwsFormatException);
      expect(() => X11Setup.tryParse(setupBytes(major: 10)), throwsFormatException);
    });

    test('rewrites the authorization in the client byte order, padded', () {
      for (final big in [false, true]) {
        final p = X11Setup.tryParse(setupBytes(big: big))!;
        final real = List.generate(16, (i) => 200 + i);
        final out = X11Setup.tryParse(p.rewrite(X11Auth.cookie(real)))!;
        expect(out.bigEndian, big);
        expect(out.authName, mitMagicCookie);
        expect(out.authData, real);
        final none = p.rewrite(const X11Auth.none());
        expect(none.length, 12);
        final n = X11Setup.tryParse(none)!;
        expect(n.authName, isEmpty);
        expect(n.authData, isEmpty);
      }
    });

    test('pads odd lengths to four bytes', () {
      final s = X11Setup.build(const X11Auth('ABCDE', [1, 2, 3]));
      expect(s.length, 12 + 8 + 4);
      expect(X11Setup.tryParse(s)!.authName, 'ABCDE');
    });
  });

  test('constantTimeEquals', () {
    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
  });

  test('hexBytes and toHex', () {
    expect(toHex(hexBytes('00ff10')), '00ff10');
    expect(() => hexBytes('abc'), throwsFormatException);
  });

  group('X11Display.parse', () {
    test('local displays', () {
      final w = X11Display.parse(':0', windows: true);
      expect(w.host, '127.0.0.1');
      expect(w.port, 6000);
      final l = X11Display.parse(':1.0', windows: false);
      expect(l.unixPath, '/tmp/.X11-unix/X1');
      expect(X11Display.parse('unix:2', windows: false).unixPath, '/tmp/.X11-unix/X2');
    });

    test('TCP and the XQuartz launchd socket', () {
      final t = X11Display.parse('localhost:10.0', windows: false);
      expect(t.host, 'localhost');
      expect(t.port, 6010);
      final q = X11Display.parse('/private/tmp/com.apple.launchd.AbC/org.xquartz:0', windows: false);
      expect(q.unixPath, '/private/tmp/com.apple.launchd.AbC/org.xquartz');
      expect(q.number, 0);
    });

    test('refuses text that is not a display', () {
      expect(() => X11Display.parse('nocolon'), throwsFormatException);
      expect(() => X11Display.parse('host:x'), throwsFormatException);
    });
  });

  test('xauthorityCookie picks this host, then a wildcard', () {
    Uint8List entry(int family, String address, String number, String name, List<int> data) {
      final b = BytesBuilder();
      void f(List<int> v) {
        b.add([v.length >> 8, v.length & 0xff]);
        b.add(v);
      }

      b.add([family >> 8, family & 0xff]);
      f(address.codeUnits);
      f(number.codeUnits);
      f(name.codeUnits);
      f(data);
      return b.toBytes();
    }

    final file = Uint8List.fromList([
      ...entry(256, 'other', '0', mitMagicCookie, [1]),
      ...entry(256, 'this', '1', mitMagicCookie, [2]),
      ...entry(65535, '', '0', mitMagicCookie, [3]),
      ...entry(256, 'this', '0', 'XDM-AUTHORIZATION-1', [4]),
      ...entry(256, 'this', '0', mitMagicCookie, [5]),
    ]);
    expect(xauthorityCookie(file, 0, hostname: 'this'), [5]);
    expect(xauthorityCookie(file, 1, hostname: 'this'), [2]);
    expect(xauthorityCookie(file, 0, hostname: 'nobody'), [3]);
    expect(xauthorityCookie(file, 7, hostname: 'this'), isNull);
    // A cut file: what was read whole still counts.
    expect(xauthorityCookie(Uint8List.sublistView(file, 0, file.length - 3), 0, hostname: 'nobody'), [3]);
  });

  test('shellQuote', () {
    expect(shellQuote("xterm -e 'top'"), r"'xterm -e '\''top'\'''");
    expect(shellQuote(''), "''");
  });
}
