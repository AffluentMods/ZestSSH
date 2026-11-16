import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';

/// Canonical one-line description of an event, so two parses can be compared
/// exactly (used by the chunk-boundary fuzzing).
String describe(TmuxEvent e) {
  switch (e) {
    case TmuxPassthrough(:final data):
      return 'passthrough ${data.join(',')}';
    case TmuxControlBegin():
      return 'control-begin';
    case TmuxMarkerHeld():
      return 'marker-held';
    case TmuxControlEnd():
      return 'control-end';
    case TmuxOutput(:final paneId, :final data, :final ageMs):
      return 'output $paneId $ageMs ${data.join(',')}';
    case TmuxPause(:final paneId):
      return 'pause $paneId';
    case TmuxContinue(:final paneId):
      return 'continue $paneId';
    case TmuxWindowAdd(:final windowId):
      return 'window-add $windowId';
    case TmuxWindowClose(:final windowId):
      return 'window-close $windowId';
    case TmuxWindowRenamed(:final windowId, :final name):
      return 'window-renamed $windowId $name';
    case TmuxWindowPaneChanged(:final windowId, :final paneId):
      return 'window-pane-changed $windowId $paneId';
    case TmuxLayoutChange(
        :final windowId,
        :final layout,
        :final visibleLayout,
        :final flags
      ):
      return 'layout-change $windowId $layout $visibleLayout $flags';
    case TmuxSessionChanged(:final sessionId, :final name):
      return 'session-changed $sessionId $name';
    case TmuxSessionRenamed(:final sessionId, :final name):
      return 'session-renamed $sessionId $name';
    case TmuxSessionWindowChanged(:final sessionId, :final windowId):
      return 'session-window-changed $sessionId $windowId';
    case TmuxSessionsChanged():
      return 'sessions-changed';
    case TmuxPaneModeChanged(:final paneId):
      return 'pane-mode-changed $paneId';
    case TmuxReply(:final number, :final error, :final flags, :final rawLines):
      return 'reply $number ${error ? 'error' : 'ok'} $flags '
          '${rawLines.map((l) => l.join(',')).join('|')}';
    case TmuxStrayLine(:final line):
      return 'stray $line';
    case TmuxExit(:final reason):
      return 'exit $reason';
    case TmuxUnhandled(:final line):
      return 'unhandled $line';
  }
}

List<String> parseAll(List<int> bytes, {bool inband = false}) {
  final p = TmuxControlParser(inband: inband);
  return [...p.addBytes(bytes).map(describe), ...p.finish().map(describe)];
}

Uint8List fixture(String name) =>
    File('test/features/tmux/fixtures/$name').readAsBytesSync();

const marker = TmuxControlParser.marker;

void main() {
  group('hostile stream bounds', () {
    test('a reply block past maxBlockBytes is truncated, not accumulated',
        () {
      final parser = TmuxControlParser();
      final events = <TmuxEvent>[];
      events.addAll(parser.addBytes(
          Uint8List.fromList(utf8.encode('\x1bP1000p%begin 1 7 1\n'))));
      // 64 lines of 1 MB: twice the cap.
      final line = Uint8List(1024 * 1024)
        ..fillRange(0, 1024 * 1024 - 1, 0x61)
        ..[1024 * 1024 - 1] = 0x0a;
      for (var i = 0; i < 64; i++) {
        events.addAll(parser.addBytes(line));
      }
      events.addAll(
          parser.addBytes(Uint8List.fromList(utf8.encode('%end 1 7 1\n'))));
      final reply = events.whereType<TmuxReply>().single;
      expect(reply.truncated, isTrue);
      expect(reply.lines.length, lessThanOrEqualTo(32));
      expect(reply.lines.length, greaterThan(0));
      // The next block starts clean.
      events.clear();
      events.addAll(parser.addBytes(
          Uint8List.fromList(utf8.encode('%begin 2 8 1\nok\n%end 2 8 1\n'))));
      final next = events.whereType<TmuxReply>().single;
      expect(next.truncated, isFalse);
      expect(next.lines, ['ok']);
    });
  });

  group('parseLayoutPaneIds', () {
    test('single-pane layout', () {
      expect(parseLayoutPaneIds('bc62,80x24,0,0,0'), ['%0']);
    });

    test('two-pane split layout', () {
      expect(
        parseLayoutPaneIds('e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}'),
        ['%1', '%2'],
      );
    });

    test('stacked (vertical) split layout', () {
      expect(
        parseLayoutPaneIds('a1b2,80x24,0,0[80x12,0,0,3,80x11,0,13,4]'),
        ['%3', '%4'],
      );
    });
  });

  group('unescapeTmuxOutput', () {
    test('decodes octal escapes for CR/LF', () {
      expect(unescapeTmuxOutput(r'ls\015\012'), [108, 115, 13, 10]);
    });

    test('passes printable ASCII through', () {
      expect(unescapeTmuxOutput('hello'), 'hello'.codeUnits);
    });

    test('decodes an ESC byte (\\033)', () {
      expect(unescapeTmuxOutput(r'\033[0m'), [27, 0x5b, 0x30, 0x6d]);
    });

    test('decodes the escaped backslash (\\134) and leaves raw UTF-8 alone',
        () {
      // "h" + raw é (c3 a9) + escaped backslash, as tmux 3.6 really emits it.
      final wire = [0x68, 0xc3, 0xa9, ...r'\134n'.codeUnits];
      expect(unescapeTmuxOutputBytes(wire), [0x68, 0xc3, 0xa9, 0x5c, 0x6e]);
    });

    test('a backslash not followed by three octal digits is literal', () {
      expect(unescapeTmuxOutput(r'a\9b'), r'a\9b'.codeUnits);
      expect(unescapeTmuxOutput(r'end\'), r'end\'.codeUnits);
    });
  });

  group('parseTmuxLayoutTree', () {
    test('single pane leaf with geometry', () {
      final n = parseTmuxLayoutTree('bc62,80x24,0,0,0');
      expect(n, isA<TmuxPaneNode>());
      final leaf = n as TmuxPaneNode;
      expect(leaf.paneId, '%0');
      expect(leaf.width, 80);
      expect(leaf.height, 24);
    });

    test('horizontal split ({}) of two panes', () {
      final n = parseTmuxLayoutTree('e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}');
      expect(n, isA<TmuxSplitNode>());
      final split = n as TmuxSplitNode;
      expect(split.horizontal, isTrue);
      expect(split.children, hasLength(2));
      expect(split.paneIds, ['%1', '%2']);
      expect((split.children[0] as TmuxPaneNode).width, 40);
      expect(split.leaves.map((l) => l.x), [0, 41]);
    });

    test('vertical split ([]) of two panes', () {
      final n = parseTmuxLayoutTree('a1b2,80x24,0,0[80x12,0,0,3,80x11,0,13,4]');
      final split = n as TmuxSplitNode;
      expect(split.horizontal, isFalse);
      expect(split.paneIds, ['%3', '%4']);
    });

    test('nested split: one pane beside a vertical stack of two', () {
      final n = parseTmuxLayoutTree(
          'c3d4,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}');
      final root = n as TmuxSplitNode;
      expect(root.horizontal, isTrue);
      expect(root.children[0], isA<TmuxPaneNode>());
      expect(root.children[1], isA<TmuxSplitNode>());
      expect((root.children[1] as TmuxSplitNode).horizontal, isFalse);
      expect(root.paneIds, ['%1', '%2', '%3']);
    });

    test('returns null on malformed input', () {
      expect(parseTmuxLayoutTree('not-a-layout'), isNull);
      expect(parseTmuxLayoutTree(''), isNull);
      expect(parseTmuxLayoutTree('abcd,80x'), isNull);
    });
  });

  group('TmuxControlParser (text API)', () {
    test('parses a %begin/%end reply block', () {
      final p = TmuxControlParser();
      final events = p.addChunk(
        '%begin 123 7 1\n'
        'line one\n'
        'line two\n'
        '%end 123 7 1\n',
      );
      expect(events, hasLength(1));
      final reply = events.single as TmuxReply;
      expect(reply.number, 7);
      expect(reply.error, isFalse);
      expect(reply.flags, 1);
      expect(reply.issuedByThisClient, isTrue);
      expect(reply.lines, ['line one', 'line two']);
    });

    test('marks an %error block', () {
      final p = TmuxControlParser();
      final events = p.addChunk('%begin 1 2 1\nboom\n%error 1 2 1\n');
      expect((events.single as TmuxReply).error, isTrue);
    });

    test('a block closes only on its own number', () {
      final p = TmuxControlParser();
      final events = p.addChunk(
        '%begin 1 5 1\n'
        '%end 1 999 1\n' // pane content that merely looks like an %end
        '%error 1 4 0\n'
        'real\n'
        '%end 1 5 1\n',
      );
      final reply = events.single as TmuxReply;
      expect(reply.number, 5);
      expect(reply.lines, ['%end 1 999 1', '%error 1 4 0', 'real']);
    });

    test('flags 0 marks a block not issued by this client', () {
      final p = TmuxControlParser();
      final e = p.addChunk('%begin 9 1 0\n%end 9 1 0\n');
      expect((e.single as TmuxReply).issuedByThisClient, isFalse);
    });

    test('parses %output and unescapes the payload', () {
      final p = TmuxControlParser();
      final events = p.addChunk('%output %1 done\\015\\012\n');
      final out = events.single as TmuxOutput;
      expect(out.paneId, '%1');
      expect(out.data, [...'done'.codeUnits, 13, 10]);
    });

    test('parses %extended-output with its age', () {
      final p = TmuxControlParser();
      final e = p.addChunk('%extended-output %1 250 : echo ext\\015\\012\n');
      final out = e.single as TmuxOutput;
      expect(out.paneId, '%1');
      expect(out.ageMs, 250);
      expect(out.data, [...'echo ext'.codeUnits, 13, 10]);
    });

    test('parses window lifecycle notifications', () {
      final p = TmuxControlParser();
      final e = p.addChunk(
        '%window-add @2\n'
        '%window-renamed @2 build\n'
        '%window-pane-changed @2 %5\n'
        '%window-close @2\n'
        '%unlinked-window-close @3\n',
      );
      expect(e[0], isA<TmuxWindowAdd>());
      expect((e[0] as TmuxWindowAdd).windowId, '@2');
      expect((e[1] as TmuxWindowRenamed).name, 'build');
      expect((e[2] as TmuxWindowPaneChanged).paneId, '%5');
      expect(e[3], isA<TmuxWindowClose>());
      expect((e[4] as TmuxWindowClose).windowId, '@3');
    });

    test('parses %layout-change with the visible layout and flags', () {
      final p = TmuxControlParser();
      final e = p.addChunk(
          '%layout-change @1 e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bc62,80x24,0,0,1 *Z\n');
      final lc = e.single as TmuxLayoutChange;
      expect(lc.windowId, '@1');
      expect(lc.paneIds, ['%1', '%2']);
      expect(lc.visibleLayout, 'bc62,80x24,0,0,1');
      expect(lc.flags, '*Z');
      expect(lc.zoomed, isTrue);
    });

    test('parses a legacy %layout-change with only the layout', () {
      final p = TmuxControlParser();
      final e = p.addChunk('%layout-change @1 bc62,80x24,0,0,0\n');
      final lc = e.single as TmuxLayoutChange;
      expect(lc.visibleLayout, isNull);
      expect(lc.zoomed, isFalse);
    });

    test('parses session notifications and %exit', () {
      final p = TmuxControlParser();
      final e = p.addChunk('%session-changed \$0 main\n'
          '%session-renamed \$0 my main\n'
          '%session-window-changed \$0 @4\n'
          '%sessions-changed\n'
          '%exit server exited\n');
      expect((e[0] as TmuxSessionChanged).sessionId, r'$0');
      expect((e[0] as TmuxSessionChanged).name, 'main');
      expect((e[1] as TmuxSessionRenamed).name, 'my main');
      expect((e[2] as TmuxSessionWindowChanged).windowId, '@4');
      expect(e[3], isA<TmuxSessionsChanged>());
      expect((e[4] as TmuxExit).reason, 'server exited');
    });

    test('parses flow control notifications', () {
      final p = TmuxControlParser();
      final e = p.addChunk('%pause %1\n%continue %1\n');
      expect((e[0] as TmuxPause).paneId, '%1');
      expect((e[1] as TmuxContinue).paneId, '%1');
    });

    test('%pause inside a reply block is surfaced, not swallowed as content',
        () {
      final p = TmuxControlParser();
      final e = p.addChunk('%begin 1 8 1\n%pause %0\n%end 1 8 1\n');
      expect(e[0], isA<TmuxPause>());
      expect((e[1] as TmuxReply).lines, isEmpty);
    });

    test('surfaces unknown notifications instead of dropping them', () {
      final p = TmuxControlParser();
      final e = p.addChunk('%client-detached foo\n');
      expect(e.single, isA<TmuxUnhandled>());
    });

    test('a plain line outside a block is a stray line (tmux parse error)',
        () {
      final p = TmuxControlParser();
      final e = p.addChunk('unterminated quoted string\n');
      expect((e.single as TmuxStrayLine).line, 'unterminated quoted string');
    });

    test('reassembles a notification split across chunks', () {
      final p = TmuxControlParser();
      expect(p.addChunk('%window-ad'), isEmpty);
      final e = p.addChunk('d @9\n');
      expect((e.single as TmuxWindowAdd).windowId, '@9');
    });

    test('handles CRLF line endings', () {
      final p = TmuxControlParser();
      final e = p.addChunk('%window-add @3\r\n');
      expect((e.single as TmuxWindowAdd).windowId, '@3');
    });

    test('tolerates a leading marker in default mode', () {
      final p = TmuxControlParser();
      final e = p.addBytes([...marker, ...'%begin 1 1 0\n%end 1 1 0\n'.codeUnits]);
      expect(e[0], isA<TmuxControlBegin>());
      expect(e[1], isA<TmuxReply>());
    });
  });

  group('TmuxControlParser (bytes)', () {
    test('%output keeps raw UTF-8 bytes intact', () {
      final p = TmuxControlParser();
      final line = [
        ...'%output %0 h'.codeUnits,
        0xc3, 0xa9, 0x20, 0xe2, 0x9c, 0x93,
        ...r'\015\012'.codeUnits,
        0x0a,
      ];
      final out = p.addBytes(line).single as TmuxOutput;
      expect(utf8.decode(out.data), 'hé ✓\r\n');
    });

    test('reply lines keep raw bytes (capture-pane content is not escaped)',
        () {
      final p = TmuxControlParser();
      final bytes = [
        ...'%begin 1 3 1\n'.codeUnits,
        0x1b, 0x5b, 0x37, 0x6d, // ESC [ 7 m
        ...'bar'.codeUnits,
        0x0a,
        ...'%end 1 3 1\n'.codeUnits,
      ];
      final r = p.addBytes(bytes).single as TmuxReply;
      expect(r.rawLines.single, [0x1b, 0x5b, 0x37, 0x6d, ...'bar'.codeUnits]);
      expect(r.lines.single, '\x1b[7mbar');
    });

    test('a raw ESC backslash inside a reply does not end control mode', () {
      final p = TmuxControlParser(inband: true);
      final bytes = [
        ...marker,
        ...'%begin 1 3 1\n'.codeUnits,
        ...'link'.codeUnits, 0x1b, 0x5c, ...' tail'.codeUnits, 0x0a,
        ...'%end 1 3 1\n'.codeUnits,
        ...'%window-add @1\n'.codeUnits,
      ];
      final e = p.addBytes(bytes);
      expect(e.map(describe), [
        'control-begin',
        'reply 3 ok 1 ${[
          ...'link'.codeUnits,
          0x1b,
          0x5c,
          ...' tail'.codeUnits
        ].join(',')}',
        'window-add @1',
      ]);
      expect(p.inControlMode, isTrue);
    });
  });

  group('in-band demux', () {
    test('passthrough until the marker, control after it', () {
      final p = TmuxControlParser(inband: true);
      final e = p.addBytes([
        ...'\$ tmux -CC\r\n'.codeUnits,
        ...marker,
        ...'%begin 1 1 0\n%end 1 1 0\n'.codeUnits,
      ]);
      expect(e[0], isA<TmuxPassthrough>());
      expect(utf8.decode((e[0] as TmuxPassthrough).data), '\$ tmux -CC\r\n');
      expect(e[1], isA<TmuxControlBegin>());
      expect(e[2], isA<TmuxReply>());
    });

    test('a marker split across chunks is still recognised', () {
      final p = TmuxControlParser(inband: true);
      final e1 = p.addBytes([...'abc'.codeUnits, ...marker.sublist(0, 3)]);
      // "abc" is forwarded; the partial marker is held back.
      expect(e1.map(describe), ['passthrough ${'abc'.codeUnits.join(',')}']);
      final e2 = p.addBytes([...marker.sublist(3), ...'%window-add @1\n'.codeUnits]);
      expect(e2.map(describe), ['control-begin', 'window-add @1']);
    });

    test('a held partial marker that turns out to be output is released', () {
      final p = TmuxControlParser(inband: true);
      expect(p.addBytes([0x1b, 0x50, 0x31]), isEmpty);
      final e = p.addBytes('X'.codeUnits);
      expect(e.map(describe), ['passthrough 27,80,49,88']);
    });

    test('a bare ESC at a chunk end is held then released on finish', () {
      final p = TmuxControlParser(inband: true);
      final e1 = p.addBytes([...'ab'.codeUnits, 0x1b]);
      expect(e1.map(describe), ['passthrough 97,98']);
      expect(p.finish().map(describe), ['passthrough 27']);
    });

    test('%exit then ESC backslash returns to passthrough', () {
      final p = TmuxControlParser(inband: true);
      final e = p.addBytes([
        ...marker,
        ...'%exit\n'.codeUnits,
        0x1b, 0x5c,
        ...'\$ '.codeUnits,
      ]);
      expect(e.map(describe), [
        'control-begin',
        'exit null',
        'control-end',
        'passthrough 36,32',
      ]);
    });

    test('the terminator split across chunks', () {
      final p = TmuxControlParser(inband: true);
      final e1 = p.addBytes([...marker, ...'%exit detached\n'.codeUnits, 0x1b]);
      expect(e1.map(describe), ['control-begin', 'exit detached']);
      final e2 = p.addBytes([0x5c, ...'ok'.codeUnits]);
      expect(e2.map(describe), ['control-end', 'passthrough 111,107']);
    });

    test('a second control-mode session can start after the first ended', () {
      final p = TmuxControlParser(inband: true);
      p.addBytes([...marker, ...'%exit\n'.codeUnits, 0x1b, 0x5c]);
      final e = p.addBytes([...marker, ...'%window-add @7\n'.codeUnits]);
      expect(e.map(describe), ['control-begin', 'window-add @7']);
    });
  });

  group('golden transcripts (tmux 3.6)', () {
    test('session_ops: attach, split, UTF-8, new window, zoom, kill, exit',
        () {
      final events = parseAll(fixture('session_ops_3_6.bin'), inband: true);
      expect(events.first, 'control-begin');
      expect(events.last, 'control-end');
      // The startup block is flags 0; a command we issued is flags 1.
      expect(events[1], 'reply 277 ok 0 ');
      expect(events[2], r'session-changed $0 demo');
      expect(events, contains('reply 283 ok 1 ${'3.6'.codeUnits.join(',')}'));
      // Live UTF-8 arrives as raw bytes and survives un-escaping.
      final utf = events.firstWhere((e) => e.startsWith('output %0 0 104,195,169'));
      final bytes = utf.split(' ').last.split(',').map(int.parse).toList();
      expect(utf8.decode(bytes), 'hé ✓ 日\r\n\x1b[?2004h');
      // new-window: session-window-changed, window-add, then output for a
      // pane we have not been told about (must be captured, not assumed).
      final i = events.indexOf(r'session-window-changed $0 @1');
      expect(events[i + 1], 'window-add @1');
      expect(events[i + 2], startsWith('output %2 0 '));
      // Zoom: full layout, visible layout, flags with Z.
      expect(
          events,
          contains('layout-change @0 f91d,120x40,0,0{60x40,0,0,0,59x40,61,0,1} '
              'aafd,120x40,0,0,0 *Z'));
      // pause-after switches the stream to %extended-output (age 0 here).
      expect(events, contains(startsWith('output %1 0 ${'echo ext'.codeUnits.join(',')}')));
      expect(events, contains('window-close @1'));
      expect(events, contains('sessions-changed'));
      expect(events[events.length - 2], 'exit null');
      expect(events.where((e) => e.startsWith('stray')), isEmpty);
      expect(events.where((e) => e.startsWith('unhandled')), isEmpty);
    });

    test('capture_and_flow: alt screen, trailing spaces, split escapes', () {
      final events = parseAll(fixture('capture_and_flow_3_6.bin'), inband: true);
      expect(events.first, 'control-begin');
      expect(events.last, 'control-end');
      // A window rename through the quoting idiom keeps the apostrophe and
      // the semicolon as text.
      expect(events, contains("window-renamed @0 it's; kill-server"));
      // capture-pane -N output keeps trailing spaces (line ends with spaces).
      final replies = events.where((e) => e.startsWith('reply ')).toList();
      final withSpaces = replies.where((r) => r.contains(',32,32,32,32,32,32|'));
      expect(withSpaces, isNotEmpty);
      // A pending partial escape sequence is reported as raw bytes.
      expect(events, contains('output %0 0 ${[...'abc'.codeUnits, 27, 0x5b, 0x33].join(',')}'));
      expect(events.where((e) => e.startsWith('stray')), isEmpty);
    });

    for (final name in ['session_ops_3_6.bin', 'capture_and_flow_3_6.bin']) {
      test('$name parses identically at every chunk boundary', () {
        final bytes = fixture(name);
        final whole = parseAll(bytes, inband: true);
        for (var cut = 1; cut < bytes.length; cut++) {
          final p = TmuxControlParser(inband: true);
          final got = [
            ...p.addBytes(bytes.sublist(0, cut)).map(describe),
            ...p.addBytes(bytes.sublist(cut)).map(describe),
            ...p.finish().map(describe),
          ];
          expect(got, whole, reason: 'split at byte $cut');
        }
      });

      test('$name parses identically in random fragments', () {
        final bytes = fixture(name);
        final whole = parseAll(bytes, inband: true);
        final rnd = Random(42);
        for (var round = 0; round < 200; round++) {
          final p = TmuxControlParser(inband: true);
          final got = <String>[];
          var i = 0;
          while (i < bytes.length) {
            final n = 1 + rnd.nextInt(64);
            final end = min(bytes.length, i + n);
            got.addAll(p.addBytes(bytes.sublist(i, end)).map(describe));
            i = end;
          }
          got.addAll(p.finish().map(describe));
          expect(got, whole, reason: 'round $round');
        }
      });
    }
  });
}
