// What a live view says inside its secure channel (share_messages.dart):
// every message survives the trip, a message from the wrong side or of the
// wrong shape is refused rather than guessed at, and terminal output is cut
// into frames without ever splitting a character.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_messages.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void refused(List<int> message, {required bool fromHost, String? reason}) => expect(
    () => ShareMessage.decode(message, fromHost: fromHost), throwsFormatException,
    reason: reason ?? '$message from the ${fromHost ? 'host' : 'viewer'}');

void main() {
  group('from the host', () {
    T trip<T extends ShareMessage>(T m) {
      expect(m.fromHost, isTrue);
      return ShareMessage.decode(m.encode(), fromHost: true) as T;
    }

    test('the screen: its size and the text that rebuilds it', () {
      final s = trip(const ShareScreen(columns: 132, rows: 43, text: '\x1b[2J\x1b[Hdeploy@db-primary:~\$ é漢😀'));
      expect([s.columns, s.rows], [132, 43]);
      expect(s.text, '\x1b[2J\x1b[Hdeploy@db-primary:~\$ é漢😀');
      // An empty screen is still a screen.
      expect(trip(const ShareScreen(columns: 1, rows: 1, text: '')).text, '');
      expect(const ShareScreen(columns: 80, rows: 24, text: 'a').encode(), [0x01, 0, 80, 0, 24, 0x61]);
    });

    test('output, a resize, who has the keyboard, and the end', () {
      expect(trip(const ShareOutput('ls -la\r\n')).text, 'ls -la\r\n');
      expect(const ShareOutput('é').encode(), [0x02, 0xc3, 0xa9]);

      final r = trip(const ShareResize(columns: 1000, rows: 500));
      expect([r.columns, r.rows], [1000, 500]);
      expect(const ShareResize(columns: 80, rows: 24).encode(), [0x03, 0, 80, 0, 24]);

      for (final k in ShareKeyboard.values) {
        expect(trip(ShareKeyboardState(k)).holder, k);
      }
      expect(const ShareKeyboardState(ShareKeyboard.you).encode(), [0x04, 1]);
      for (final e in ShareEndReason.values) {
        expect(trip(ShareEnd(e)).reason, e);
      }
      expect(const ShareEnd(ShareEndReason.removed).encode(), [0x05, 2]);
    });

    test('the order of the choices is the wire: it never changes', () {
      expect(ShareKeyboard.values, [ShareKeyboard.host, ShareKeyboard.you, ShareKeyboard.someoneElse]);
      expect(ShareEndReason.values,
          [ShareEndReason.stopped, ShareEndReason.sessionClosed, ShareEndReason.removed]);
    });

    test('a size that is not a terminal, or a choice that is not one, is refused', () {
      for (final size in [
        [0, 0, 0, 24], // no columns
        [0, 80, 0, 0], // no rows
        [0x03, 0xe9, 0, 24], // 1001 columns
        [0, 80, 0x01, 0xf5], // 501 rows
      ]) {
        refused([0x03, ...size], fromHost: true);
        refused([0x01, ...size, 0x61], fromHost: true);
      }
      refused([0x03, 0, 80, 0], fromHost: true, reason: 'a short resize');
      refused([0x03, 0, 80, 0, 24, 0], fromHost: true, reason: 'a long resize');
      refused([0x01, 0, 80, 0], fromHost: true, reason: 'a screen with no size');
      refused([0x04], fromHost: true);
      refused([0x04, 3], fromHost: true, reason: 'a fourth keyboard state');
      refused([0x04, 1, 0], fromHost: true);
      refused([0x05], fromHost: true);
      refused([0x05, 3], fromHost: true, reason: 'a fourth reason');
      refused([0x05, 0, 0], fromHost: true);
    });

    test('text has to be UTF-8 and fit one frame', () {
      refused([0x02, 0xff, 0xfe], fromHost: true, reason: 'not UTF-8');
      refused([0x02, 0xc3], fromHost: true, reason: 'half a character');
      refused([0x01, 0, 80, 0, 24, 0xc3], fromHost: true);
      final most = Uint8List(kShareOutputMax)..fillRange(0, kShareOutputMax, 0x61);
      expect((ShareMessage.decode([0x02, ...most], fromHost: true) as ShareOutput).text.length, kShareOutputMax);
      refused([0x02, ...most, 0x61], fromHost: true, reason: 'one byte over');
      refused([0x01, 0, 80, 0, 24, ...most, 0x61], fromHost: true);
      // The largest message of each kind fits the channel's frame.
      expect(1 + 4 + kShareOutputMax, lessThanOrEqualTo(kShareFramePlainMax));
      expect(const ShareScreen(columns: 80, rows: 24, text: '').encode().length + kShareOutputMax,
          lessThanOrEqualTo(kShareFramePlainMax));
    });
  });

  group('from a viewer', () {
    T trip<T extends ShareMessage>(T m) {
      expect(m.fromHost, isFalse);
      return ShareMessage.decode(m.encode(), fromHost: false) as T;
    }

    test('ready, asking for the keyboard, giving it back, leaving, ending the session: nothing but the kind', () {
      expect(trip(const ShareReady()), isA<ShareReady>());
      expect(trip(const ShareAskKeyboard()), isA<ShareAskKeyboard>());
      expect(trip(const ShareGiveBack()), isA<ShareGiveBack>());
      expect(trip(const ShareLeave()), isA<ShareLeave>());
      expect(trip(const ShareEndSession()), isA<ShareEndSession>());
      expect(const ShareReady().encode(), [0x11]);
      expect(const ShareAskKeyboard().encode(), [0x13]);
      expect(const ShareGiveBack().encode(), [0x14]);
      expect(const ShareLeave().encode(), [0x15]);
      expect(const ShareEndSession().encode(), [0x17]);
      for (final kind in [0x11, 0x13, 0x14, 0x15, 0x17]) {
        refused([kind, 0], fromHost: false, reason: 'kind $kind carries nothing');
      }
    });

    test('keys: the bytes as typed, one to 4096 of them', () {
      final typed = bytes([0x1b, 0x5b, 0x41, 0x03, 0xff, 0x00]);
      expect(trip(ShareInput(typed)).bytes, typed, reason: 'bytes, not text: nothing is decoded');
      expect(ShareInput(bytes([0x0d])).encode(), [0x12, 0x0d]);
      final most = Uint8List(kShareInputMax)..fillRange(0, kShareInputMax, 0x61);
      expect(trip(ShareInput(most)).bytes.length, kShareInputMax);
      refused([0x12], fromHost: false, reason: 'no keys');
      refused([0x12, ...most, 0x61], fromHost: false, reason: 'one over');
    });

    test('an ack counts the frames taken', () {
      expect(trip(const ShareAck(0)).received, 0);
      expect(trip(const ShareAck(123456789012)).received, 123456789012);
      expect(const ShareAck(258).encode(), [0x16, 0, 0, 0, 0, 0, 0, 1, 2]);
      refused([0x16, 0, 0, 0, 0, 0, 0, 1], fromHost: false, reason: 'seven bytes');
      refused([0x16, 0, 0, 0, 0, 0, 0, 1, 2, 3], fromHost: false, reason: 'nine bytes');
      refused([0x16, 0x80, 0, 0, 0, 0, 0, 0, 0], fromHost: false, reason: 'not a count');
    });
  });

  test('a message from the wrong side, or that is not one, is refused', () {
    // What only the host says is not taken from a viewer, and the other way.
    for (final m in <ShareMessage>[
      const ShareScreen(columns: 80, rows: 24, text: 'x'),
      const ShareOutput('x'),
      const ShareResize(columns: 80, rows: 24),
      const ShareKeyboardState(ShareKeyboard.you),
      const ShareEnd(ShareEndReason.stopped),
    ]) {
      refused(m.encode(), fromHost: false, reason: '${m.runtimeType} from a viewer');
    }
    for (final m in <ShareMessage>[
      const ShareReady(),
      ShareInput(bytes([0x61])),
      const ShareAskKeyboard(),
      const ShareGiveBack(),
      const ShareLeave(),
      const ShareAck(1),
      const ShareEndSession(),
    ]) {
      refused(m.encode(), fromHost: true, reason: '${m.runtimeType} from the host');
    }
    for (final fromHost in [true, false]) {
      refused(const [], fromHost: fromHost, reason: 'nothing');
      refused([0x00], fromHost: fromHost);
      refused([0x06], fromHost: fromHost);
      refused([0x18], fromHost: fromHost);
      refused([0x21], fromHost: fromHost, reason: 'no pings');
      refused([0xff, 1, 2], fromHost: fromHost);
    }
  });

  test('a message decodes from a plain list as well as from bytes', () {
    final plain = <int>[0x02, 0x6f, 0x6b];
    expect((ShareMessage.decode(plain, fromHost: true) as ShareOutput).text, 'ok');
    expect((ShareMessage.decode(bytes(plain), fromHost: true) as ShareOutput).text, 'ok');
    // A view into a larger buffer reads its own part only.
    final buffer = bytes([9, 9, 0x02, 0x6f, 0x6b, 9]);
    expect(
        (ShareMessage.decode(Uint8List.sublistView(buffer, 2, 5), fromHost: true) as ShareOutput).text, 'ok');
  });

  group('cutting output into frames', () {
    test('nothing gives nothing; what fits stays whole', () {
      expect(shareOutputPieces(''), isEmpty);
      expect(shareOutputPieces('abc').toList(), ['abc']);
      expect(shareOutputPieces('abcdef', max: 6).toList(), ['abcdef']);
      expect(shareOutputPieces('abcdefg', max: 6).toList(), ['abcdef', 'g']);
      expect(shareOutputPieces('abcdefghijklm', max: 4).toList(), ['abcd', 'efgh', 'ijkl', 'm']);
    });

    test('a character is never split, whatever its width', () {
      // é is 2 bytes, 漢 3, 😀 4 (two UTF-16 units).
      expect(shareOutputPieces('aéb', max: 2).toList(), ['a', 'é', 'b']);
      expect(shareOutputPieces('aé', max: 3).toList(), ['aé']);
      expect(shareOutputPieces('漢漢', max: 5).toList(), ['漢', '漢']);
      expect(shareOutputPieces('a😀b', max: 4).toList(), ['a', '😀', 'b']);
      expect(shareOutputPieces('😀😀', max: 7).toList(), ['😀', '😀']);
      expect(shareOutputPieces('😀😀', max: 8).toList(), ['😀😀']);
      // A character wider than the limit still goes, alone.
      expect(shareOutputPieces('a😀', max: 2).toList(), ['a', '😀']);
    });

    test('the pieces are the text, each fits a frame, and each is a message the viewer takes', () {
      final text = StringBuffer();
      for (var i = 0; i < 9000; i++) {
        text.write(const ['a', 'é', '漢', '😀', '\x1b[31m', '\r\n'][i % 6]);
      }
      final whole = text.toString();
      final pieces = shareOutputPieces(whole, max: 1000).toList();
      expect(pieces.join(), whole);
      expect(pieces.length, greaterThan(10));
      for (final p in pieces) {
        expect(utf8.encode(p).length, lessThanOrEqualTo(1000));
        expect((ShareMessage.decode(ShareOutput(p).encode(), fromHost: true) as ShareOutput).text, p);
      }
      // By default a piece fills an output message exactly.
      final big = 'x' * (kShareOutputMax * 2 + 5);
      final frames = shareOutputPieces(big).toList();
      expect(frames.map((f) => f.length), [kShareOutputMax, kShareOutputMax, 5]);
      expect(ShareOutput(frames.first).encode().length, lessThanOrEqualTo(kShareFramePlainMax));
    });

    test('a lone half of a surrogate pair does not break the cut', () {
      final lone = String.fromCharCode(0xd83d);
      final pieces = shareOutputPieces('a${lone}b', max: 3).toList();
      expect(pieces.join(), 'a${lone}b');
      for (final p in pieces) {
        // It goes out as the replacement character: three bytes, counted so.
        expect(utf8.encode(p).length, lessThanOrEqualTo(3));
      }
    });
  });
}
