import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/terminal/osc52_clipboard.dart';

/// The parameters xterm hands to `onPrivateOSC` for `OSC 52 ; sel ; data`.
List<String> osc(String selection, String data) => [selection, data];

String b64(String text) => base64.encode(utf8.encode(text));

void main() {
  group('Osc52.decode', () {
    test('decodes a plain clipboard write', () {
      expect(Osc52.decode(osc('c', b64('hello world'))), 'hello world');
    });

    test('keeps the text verbatim, newlines included', () {
      const text = 'rm -rf /tmp/x\nls\n';
      expect(Osc52.decode(osc('c', b64(text))), text);
    });

    test('round-trips multi-byte UTF-8', () {
      const text = 'héllo wörld: 日本語 🍊';
      expect(Osc52.decode(osc('c', b64(text))), text);
    });

    test('accepts every selection name, since there is one clipboard', () {
      for (final sel in ['c', 'p', 's', '0', '7', 'cp', 'pq', '']) {
        expect(Osc52.decode(osc(sel, b64('x'))), 'x', reason: 'sel=$sel');
      }
    });

    test('repairs missing base64 padding', () {
      final unpadded = b64('ab').replaceAll('=', ''); // "YWI"
      expect(unpadded, isNot(endsWith('=')));
      expect(Osc52.decode(osc('c', unpadded)), 'ab');
    });

    test('accepts the URL-safe alphabet', () {
      final urlSafe = base64Url.encode(utf8.encode('??>>'));
      expect(urlSafe, contains(RegExp('[-_]')));
      expect(Osc52.decode(osc('c', urlSafe)), '??>>');
    });

    test('refuses the read-back query and reports it as one', () {
      expect(Osc52.isQuery(osc('c', '?')), isTrue);
      expect(Osc52.decode(osc('c', '?')), isNull);
      expect(Osc52.isQuery(osc('c', b64('?'))), isFalse);
    });

    test('ignores an empty or missing payload', () {
      expect(Osc52.decode(osc('c', '')), isNull);
      expect(Osc52.decode(osc('c', '   ')), isNull);
      expect(Osc52.decode(['c']), isNull);
      expect(Osc52.decode(const []), isNull);
    });

    test('ignores malformed base64 instead of clearing the clipboard', () {
      expect(Osc52.decode(osc('c', 'not base64!')), isNull);
      expect(Osc52.decode(osc('c', '@@@@')), isNull);
    });

    test('ignores an oversize payload rather than truncating it', () {
      final huge = 'A' * (Osc52.maxEncodedLength + 4);
      expect(Osc52.decode(osc('c', huge)), isNull);
      final atLimit = b64('x' * ((Osc52.maxEncodedLength ~/ 4) * 3));
      expect(atLimit.length, lessThanOrEqualTo(Osc52.maxEncodedLength));
      expect(Osc52.decode(osc('c', atLimit)), isNotNull);
    });

    test('tolerates malformed UTF-8 in the payload', () {
      final bytes = base64.encode([0x68, 0x69, 0xff, 0xfe]);
      expect(Osc52.decode(osc('c', bytes)), startsWith('hi'));
    });
  });

  group('xterm delivery', () {
    // The whole feature rests on the emulator handing OSC 52 to
    // onPrivateOSC as (code, [selection, payload]); pin that contract for
    // both terminators and check nothing of the sequence leaks on screen.
    test('BEL-terminated OSC 52 reaches onPrivateOSC split on ;', () {
      final t = Terminal(maxLines: 100);
      final calls = <(String, List<String>)>[];
      t.onPrivateOSC = (code, args) => calls.add((code, args));
      t.write('\x1b]52;c;${b64('hello')}\x07');
      expect(calls.length, 1);
      expect(calls.single.$1, '52');
      expect(calls.single.$2, ['c', b64('hello')]);
      expect(Osc52.decode(calls.single.$2), 'hello');
      expect(t.buffer.lines[0].toString().trim(), isEmpty);
    });

    test('ST-terminated OSC 52 and the query form reach onPrivateOSC', () {
      final t = Terminal(maxLines: 100);
      final calls = <(String, List<String>)>[];
      t.onPrivateOSC = (code, args) => calls.add((code, args));
      t.write('\x1b]52;;${b64('x')}\x1b\\');
      t.write('\x1b]52;c;?\x1b\\');
      expect(calls.length, 2);
      expect(calls[0].$1, '52');
      expect(calls[0].$2, ['', b64('x')]);
      expect(Osc52.isQuery(calls[1].$2), isTrue);
      expect(t.buffer.lines[0].toString().trim(), isEmpty);
    });

    test('a split write still delivers one OSC 52', () {
      final t = Terminal(maxLines: 100);
      final calls = <(String, List<String>)>[];
      t.onPrivateOSC = (code, args) => calls.add((code, args));
      final seq = '\x1b]52;c;${b64('split')}\x07';
      t.write(seq.substring(0, 6));
      t.write(seq.substring(6));
      expect(calls.length, 1);
      expect(Osc52.decode(calls.single.$2), 'split');
    });
  });
}
