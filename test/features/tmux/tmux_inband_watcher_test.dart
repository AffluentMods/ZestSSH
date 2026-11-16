import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_inband_watcher.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<int> passed;
  late List<String> sent;
  late List<TmuxController> entered;
  late List<TmuxController> exited;
  late TmuxInbandWatcher w;
  late List<bool> asked;
  late DateTime now;

  /// Someone entered a line that asks for control mode.
  void typedTmux() => w.lineEntered('tmux -CC');

  setUp(() {
    passed = [];
    sent = [];
    entered = [];
    exited = [];
    asked = [];
    now = DateTime(2026, 10, 30, 12);
    w = TmuxInbandWatcher(
      sendBytes: (b) => sent.add(utf8.decode(b)),
      onPassthrough: (b) => passed.addAll(b),
      onEnter: entered.add,
      onExit: exited.add,
      onAsking: asked.add,
      clock: () => now,
    );
  });

  tearDown(() => w.dispose());

  test('ordinary output passes straight through', () {
    w.addBytes(_b('\$ ls\r\nfoo bar\r\n'));
    expect(utf8.decode(passed), '\$ ls\r\nfoo bar\r\n');
    expect(w.inControl, isFalse);
    expect(entered, isEmpty);
  });

  test('the marker starts a control session on the same channel', () {
    typedTmux();
    w.addBytes(_b('\$ tmux -CC\r\n'));
    w.addBytes(Uint8List.fromList([
      ...TmuxControlParser.marker,
      ...'%begin 1 1 0\n%end 1 1 0\n%session-changed \$0 main\n'.codeUnits,
    ]));
    expect(utf8.decode(passed), '\$ tmux -CC\r\n');
    expect(w.inControl, isTrue);
    expect(entered, hasLength(1));
    final c = entered.single;
    expect(identical(c, w.controller), isTrue);
    expect(c.controlStarted, isTrue);
    expect(c.currentSessionName, 'main');
    // The controller talks through the session's own channel.
    expect(sent.first, 'display-message -p "#{version}"\n');
    expect(asked, isEmpty, reason: 'a person who typed it is asked nothing');
  });

  test('%exit and the terminator hand the stream back and dispose', () {
    typedTmux();
    w.addBytes(Uint8List.fromList(TmuxControlParser.marker));
    final c = w.controller!;
    w.addBytes(Uint8List.fromList([
      ...'%exit\n'.codeUnits,
      ...TmuxControlParser.terminator,
      ...'\$ '.codeUnits,
    ]));
    expect(w.inControl, isFalse);
    expect(exited, [c]);
    expect(c.exited, isTrue);
    expect(utf8.decode(passed), '\$ ');
    // Disposed controllers accept nothing.
    c.onData(_b('%window-add @1\n'));
    expect(c.windows, isEmpty);
  });

  test('a second tmux -CC later in the same shell gets a fresh controller',
      () {
    typedTmux();
    w.addBytes(Uint8List.fromList([
      ...TmuxControlParser.marker,
      ...'%exit\n'.codeUnits,
      ...TmuxControlParser.terminator,
    ]));
    typedTmux();
    w.addBytes(Uint8List.fromList(TmuxControlParser.marker));
    expect(entered, hasLength(2));
    expect(identical(entered[0], entered[1]), isFalse);
    expect(w.inControl, isTrue);
  });

  test('forcePassthrough abandons a wedged session', () {
    typedTmux();
    w.addBytes(Uint8List.fromList(TmuxControlParser.marker));
    final c = w.controller!;
    w.forcePassthrough();
    expect(w.inControl, isFalse);
    expect(exited, [c]);
    w.addBytes(_b('\$ back\r\n'));
    expect(utf8.decode(passed), '\$ back\r\n');
  });

  test('disabled: bytes bypass the parser, held prefix bytes are released',
      () {
    // A chunk ending in ESC would be held as a possible marker start.
    w.addBytes(Uint8List.fromList([...'ab'.codeUnits, 0x1b]));
    expect(passed, 'ab'.codeUnits);
    w.addBytes(_b('cd'), enabled: false);
    expect(passed, [...'ab'.codeUnits, 0x1b, ...'cd'.codeUnits]);
    // While disabled the marker is ordinary output.
    w.addBytes(Uint8List.fromList(TmuxControlParser.marker), enabled: false);
    expect(w.inControl, isFalse);
    expect(passed.length, 5 + TmuxControlParser.marker.length);
  });

  test('an in-flight control session keeps running while disabled', () {
    typedTmux();
    w.addBytes(Uint8List.fromList(TmuxControlParser.marker));
    w.addBytes(_b('%window-add @1\n'), enabled: false);
    expect(w.inControl, isTrue);
    expect(w.controller!.windows.map((x) => x.id), ['@1']);
  });

  test('finish() ends a control session when the stream closes', () {
    typedTmux();
    w.addBytes(Uint8List.fromList(TmuxControlParser.marker));
    final c = w.controller!;
    w.finish();
    expect(w.inControl, isFalse);
    expect(exited, [c]);
    expect(c.exited, isTrue);
  });

  group('a marker in output nobody asked for: `cat` of a file', () {
    const file = 'harmless text\r\n\x1bP1000p%session-changed \$1 work\n%window-add @1\n';

    test('nothing is typed, no workspace is shown, what follows waits, and the person is asked', () {
      w.addBytes(_b(file));
      expect(sent, isEmpty, reason: 'it typed display-message and list-windows into the shell by itself');
      expect(entered, isEmpty);
      expect(w.inControl, isFalse);
      expect(asked, [true]);
      expect(w.asking, isTrue);
      expect(utf8.decode(passed), 'harmless text\r\n', reason: 'what came before it is shown');
    });

    test('no: nothing is typed, and all of it is shown as the output it was', () {
      w.addBytes(_b(file));
      w.addBytes(_b('and the prompt \$ '));
      w.answer(false);
      expect(asked, [true, false]);
      expect(w.asking, isFalse);
      expect(sent, isEmpty);
      expect(entered, isEmpty);
      expect(utf8.decode(passed), '$file''and the prompt \$ ');
      // And what comes now goes straight through.
      w.addBytes(_b('more'));
      expect(utf8.decode(passed), endsWith('more'));
    });

    test('going on typing is a no', () {
      w.addBytes(_b(file));
      w.lineEntered('ls -la');
      expect(asked, [true, false]);
      expect(sent, isEmpty);
      expect(utf8.decode(passed), file);
    });

    test('yes: it starts with what waited, read as control mode', () {
      w.addBytes(_b(file));
      w.answer(true);
      expect(asked, [true, false]);
      expect(entered, hasLength(1));
      expect(w.inControl, isTrue);
      final c = entered.single;
      expect(c.currentSessionName, 'work');
      expect(c.windows.map((x) => x.id), ['@1']);
      expect(sent.first, 'display-message -p "#{version}"\n');
      expect(utf8.decode(passed), 'harmless text\r\n');
    });

    test('2000 markers ask once, and make no controller', () {
      w.addBytes(_b('\x1bP1000p\n' * 2000));
      w.addBytes(_b('\x1bP1000p\n' * 2000));
      expect(asked, [true]);
      expect(entered, isEmpty);
      w.answer(false);
      expect(asked, [true, false]);
      expect(sent, isEmpty);
      // More of them in the same run of output ask nothing more: each is text.
      w.addBytes(_b('\x1bP1000p\n' * 2000));
      expect(asked, [true, false]);
      expect(entered, isEmpty);
      // The next line the person enters can be asked about again.
      w.lineEntered('cat other');
      w.addBytes(_b('\x1bP1000p'));
      expect(asked, [true, false, true]);
    });

    test('after a yes, more marker lines make no more controllers, and the last one is the one let go of', () {
      w.addBytes(_b('\x1bP1000p'));
      w.answer(true);
      w.addBytes(_b('\x1bP1000p\n' * 2000));
      expect(entered, hasLength(1));
      expect(sent.where((s) => s.startsWith('display-message')), hasLength(1));
      w.addBytes(_b('%exit\n\x1b\\'));
      expect(exited, entered);
      expect(entered.single.exited, isTrue);
    });

    test('a person away: what waits is bounded, and then it goes on as output', () {
      w.addBytes(_b('\x1bP1000p'));
      final piece = Uint8List(64 * 1024);
      for (var i = 0; i < 16; i++) {
        w.addBytes(piece);
        expect(w.asking, isTrue);
      }
      w.addBytes(_b('over'));
      expect(w.asking, isFalse);
      expect(asked, [true, false]);
      expect(entered, isEmpty);
      expect(passed.length, greaterThan(TmuxInbandWatcher.maxHeldBytes));
    });

    test('the stream ends while it asks: what waited is shown', () {
      w.addBytes(_b('\x1bP1000pthe last of it'));
      w.finish();
      expect(asked, [true, false]);
      expect(utf8.decode(passed), '\x1bP1000pthe last of it');
    });

    test('switched off while it asks: a no', () {
      w.addBytes(_b('\x1bP1000p'));
      w.addBytes(_b('more'), enabled: false);
      expect(asked, [true, false]);
      expect(utf8.decode(passed), '\x1bP1000pmore');
    });

    test('with nobody to ask it is plain output', () {
      final alone = TmuxInbandWatcher(
        sendBytes: (b) => sent.add(utf8.decode(b)),
        onPassthrough: (b) => passed.addAll(b),
        onEnter: entered.add,
        onExit: exited.add,
      );
      addTearDown(alone.dispose);
      alone.addBytes(_b('a\x1bP1000pb'));
      expect(entered, isEmpty);
      expect(sent, isEmpty);
      expect(utf8.decode(passed), 'a\x1bP1000pb');
    });
  });

  group('what counts as asked for', () {
    test('a line that holds -CC, in the ways it is typed', () {
      for (final line in const [
        'tmux -CC',
        'tmux -CC new -A -s x',
        'tmux -uCC attach',
        'tmux -CCu',
        'tmux -C -C',
        '/usr/local/bin/tmux -CC a',
        'ssh other -t tmux -CC',
        'ssh other "tmux -CC attach"',
        "ssh other 'tmux -CC'",
        'docker exec -it box tmux -CC',
      ]) {
        expect(asksForControlMode(line), isTrue, reason: line);
      }
      for (final line in const ['tmux', 'tmux -C', 'tmux attach', 'cat notes-CC.txt', 'ls', '', 'echo CC']) {
        expect(asksForControlMode(line), isFalse, reason: line);
      }
    });

    test('that line, and the first marker after it only: the next one is asked about', () {
      typedTmux();
      w.addBytes(_b('\x1bP1000p%exit\n\x1b\\'));
      expect(entered, hasLength(1));
      expect(asked, isEmpty);
      w.addBytes(_b('\x1bP1000p'));
      expect(entered, hasLength(1));
      expect(asked, [true]);
    });

    test('it may go through a password first, for a minute', () {
      w.lineEntered('ssh other -t tmux -CC');
      w.lineEntered('my password');
      now = now.add(const Duration(seconds: 59));
      w.addBytes(_b('\x1bP1000p'));
      expect(entered, hasLength(1));
      expect(asked, isEmpty);
    });

    test('past the minute it is asked about', () {
      typedTmux();
      now = now.add(TmuxInbandWatcher.askedForLasts);
      w.addBytes(_b('\x1bP1000p'));
      expect(entered, isEmpty);
      expect(asked, [true]);
    });

    test('a marker split over two reads is one marker', () {
      typedTmux();
      w.addBytes(Uint8List.fromList(TmuxControlParser.marker.sublist(0, 3)));
      expect(entered, isEmpty);
      w.addBytes(Uint8List.fromList([...TmuxControlParser.marker.sublist(3), ...'%window-add @2\n'.codeUnits]));
      expect(entered, hasLength(1));
      expect(entered.single.windows.map((x) => x.id), ['@2']);
    });
  });
}
