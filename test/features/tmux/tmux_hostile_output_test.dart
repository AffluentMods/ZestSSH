import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';

import 'fake_tmux.dart';

/// What a host can put on a control-mode line (hostile server audit, 30 October
/// 2026). The app has one isolate for its screen and every session, so a line
/// must not hold it; and what a host names is shown in the tabs and the lists,
/// so it must not read other than it is.
void main() {
  Uint8List bytes(String s) => Uint8List.fromList(latin1.encode(s));

  Duration time(void Function() body) {
    final clock = Stopwatch()..start();
    body();
    return clock.elapsed;
  }

  // (These took 12.8 s and 3.3 s. The limit is far above what they take now, so
  // that a slow machine does not fail them, and far below what they took.)
  const limit = Duration(seconds: 2);

  group('lines made to be slow', () {
    test('a layout of digits', () {
      expect(time(() => parseLayoutPaneIds('1' * 160000)), lessThan(limit));
      expect(time(() => parseLayoutPaneIds('1' * maxTmuxLayoutLength)), lessThan(limit));
      expect(parseLayoutPaneIds('1' * (maxTmuxLayoutLength + 1)), isEmpty);
    });

    test('a layout of numbers that nearly fit', () {
      expect(time(() => parseLayoutPaneIds('1x1,1,1,' * 8000)), lessThan(limit));
    });

    test('a real layout still gives its panes', () {
      expect(parseLayoutPaneIds('bc62,80x24,0,0,0'), ['%0']);
      expect(parseLayoutPaneIds('e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}'), ['%1', '%2']);
      expect(parseLayoutPaneIds('a1b2,200x60,0,0[200x30,0,0,12,200x29,0,31{100x29,0,31,13,99x29,101,31,14}]'),
          ['%12', '%13', '%14']);
    });

    test('a layout nested deeper than any window can be is none', () {
      String nested(int depth) => 'x,${'1x1,0,0{' * depth}1x1,0,0,1${'}' * depth}';
      expect(parseTmuxLayoutTree(nested(60))?.paneIds, ['%1']);
      expect(parseTmuxLayoutTree(nested(70)), isNull);
      expect(parseTmuxLayoutTree(nested(7000)), isNull);
    });

    test('a version of digits', () {
      expect(time(() => TmuxVersion.parse('1' * 80000)), lessThan(limit));
      expect(TmuxVersion.parse('1' * 80000).isKnown, isFalse);
    });

    test('a version with a number too long for one no longer throws', () {
      expect(TmuxVersion.parse('${'9' * 40}.1').isKnown, isTrue, reason: 'the last digits of it, which is harmless');
    });

    test('real versions still read', () {
      for (final (text, major, minor) in const [
        ('3.6', 3, 6),
        ('3.3a', 3, 3),
        ('next-3.4', 3, 4),
        ('openbsd-7.4', 7, 4),
      ]) {
        final v = TmuxVersion.parse(text);
        expect((v.major, v.minor, v.text), (major, minor, text));
      }
    });

    test('the longest line the parser takes, as a layout change', () {
      final parser = TmuxControlParser();
      final line = bytes('%layout-change @1 ${'1' * (TmuxControlParser.maxLineBytes - 32)}\n');
      late List<TmuxEvent> events;
      expect(time(() => events = parser.addBytes(line)), lessThan(limit));
      expect(events, isEmpty, reason: 'no notification is that long');
    });

    test('a real layout change still comes through whole', () {
      final parser = TmuxControlParser();
      final events = parser.addBytes(bytes('%layout-change @1 e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2} e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n'));
      expect(events.single, isA<TmuxLayoutChange>().having((e) => e.paneIds, 'its panes', ['%1', '%2']));
    });

    test('a long line in small pieces costs its length once', () {
      final parser = TmuxControlParser();
      final piece = bytes('%output %1 ${'x' * (32 * 1024)}');
      final clock = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        parser.addBytes(piece);
      }
      expect(clock.elapsed, lessThan(limit));
    });

    test('past the longest line, what is left of it is no line of its own', () {
      final parser = TmuxControlParser();
      expect(parser.addBytes(Uint8List(TmuxControlParser.maxLineBytes + 1)..fillRange(0, 5, 0x78)), isEmpty);
      // Its tail would have been read as a notification.
      final tail = parser.addBytes(bytes('%window-add @7\n%window-add @8\n'));
      expect(tail.whereType<TmuxWindowAdd>().map((e) => e.windowId), ['@8']);
    });
  });

  group('marker lines in control mode', () {
    test('only the first begins it', () {
      final parser = TmuxControlParser();
      final events = parser.addBytes(bytes('\x1bP1000p%window-add @1\n\x1bP1000p%window-add @2\n\x1bP1000p\n'));
      expect(events.whereType<TmuxControlBegin>(), hasLength(1));
      expect(events.whereType<TmuxWindowAdd>().map((e) => e.windowId), ['@1', '@2']);
    });

    test('inside a reply block it is what the pane holds', () {
      final parser = TmuxControlParser();
      final events = parser.addBytes(bytes('\x1bP1000p%begin 1 1 1\n\x1bP1000pcontent\n%end 1 1 1\n'));
      expect(events.whereType<TmuxControlBegin>(), hasLength(1));
      expect(events.whereType<TmuxReply>().single.lines, ['\x1bP1000pcontent']);
    });

    test('a parser told to hold stops at the marker until it is told', () {
      final parser = TmuxControlParser(inband: true, holdAtMarker: true);
      final events = parser.addBytes(bytes('before\x1bP1000p%window-add @1\n'));
      expect(events, hasLength(2));
      expect(latin1.decode((events[0] as TmuxPassthrough).data), 'before');
      expect(events[1], isA<TmuxMarkerHeld>());
      expect(parser.holdsMarker, isTrue);
      expect(parser.addBytes(bytes('%window-add @2\n')), isEmpty);
      expect(parser.heldBytes, greaterThan(20));
      final accepted = parser.acceptMarker();
      expect(accepted.first, isA<TmuxControlBegin>());
      expect(accepted.whereType<TmuxWindowAdd>().map((e) => e.windowId), ['@1', '@2']);
      expect(parser.inControlMode, isTrue);
    });

    test('declined, it and what waited are the output they are', () {
      final parser = TmuxControlParser(inband: true, holdAtMarker: true);
      parser.addBytes(bytes('\x1bP1000pa\x1bP1000pb'));
      final declined = parser.declineMarker();
      expect(latin1.decode((declined.single as TmuxPassthrough).data), '\x1bP1000pa\x1bP1000pb');
      expect(parser.holdsMarker, isFalse);
      expect(parser.inControlMode, isFalse);
    });
  });

  group('what a host names', () {
    late FakeTmux tmux;
    late TmuxController c;

    setUp(() {
      tmux = FakeTmux();
      c = TmuxController(sendBytes: tmux.receive, scrollback: 50);
      tmux.controller = c;
    });
    tearDown(() => c.dispose());

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a window renamed: no control character, no direction override', () async {
      tmux.attach(tmux.addSession('demo'));
      await settle();
      tmux.emit('%window-renamed @0 ev\x1b[31mil\u{202E}txt.exe\u{200B}');
      expect(c.windows.single.name, 'ev[31miltxt.exe');
    });

    test('a window listed, and its panes\' titles', () async {
      final s = tmux.addSession('demo');
      tmux.addWindow(s, 'plain\u{202E}gnp.exe');
      tmux.attach(s);
      await settle();
      final w = c.windows.single;
      expect(w.name, 'plaingnp.exe');
      // A program in the pane sets its title.
      final pane = w.panes.values.single;
      pane.terminal.write('\x1b]2;a\u{202E}cod.exe\x07');
      expect(pane.title, 'acod.exe');
    });

    test('no more of a name is kept than can be shown', () async {
      tmux.attach(tmux.addSession('demo'));
      await settle();
      tmux.emit('%window-renamed @0 ${'x' * 60000}');
      expect(c.windows.single.name.length, lessThanOrEqualTo(TmuxController.maxNameLength + 1));
    });

    test('the session a host says it is, and those it lists', () async {
      tmux.attach(tmux.addSession('demo'));
      await settle();
      tmux.emit('%session-changed \$0 ok\u{202E}txt');
      await settle();
      expect(c.currentSessionName, 'oktxt');
      final listed = TmuxSessionHost.parseSessionLine('\$3 1 0 1 1 ev\u{202E}il\x07name');
      expect(listed!.name, 'evilname');
    });

    test('a real name stays as it is, spaces and scripts too', () async {
      tmux.attach(tmux.addSession('demo'));
      await settle();
      tmux.emit('%window-renamed @0 my 日本語 window');
      expect(c.windows.single.name, 'my 日本語 window');
    });
  });

  group('how many windows a host names', () {
    late List<String> sent;
    late TmuxController c;

    setUp(() {
      sent = [];
      c = TmuxController(sendBytes: (b) => sent.add(utf8.decode(b)), expectMarker: false);
    });
    tearDown(() => c.dispose());

    test('no more than a session can show, and no command is typed for those past it', () {
      c.onData(utf8.encode('\n'));
      for (var i = 0; i < TmuxController.maxWindows + 500; i++) {
        c.onData(utf8.encode('%window-add @$i\n'));
      }
      expect(c.windows, hasLength(TmuxController.maxWindows));
      final before = sent.length;
      c.onData(utf8.encode('%window-add @99999\n'));
      c.onData(utf8.encode('%window-renamed @99998 x\n'));
      c.onData(utf8.encode('%layout-change @99997 bc62,80x24,0,0,0\n'));
      expect(sent.length, before);
      expect(c.windows, hasLength(TmuxController.maxWindows));
    });

    test('one that closes makes room', () {
      for (var i = 0; i < TmuxController.maxWindows; i++) {
        c.onData(utf8.encode('%window-add @$i\n'));
      }
      c.onData(utf8.encode('%window-close @0\n'));
      c.onData(utf8.encode('%window-add @99999\n'));
      expect(c.windows.map((w) => w.id), contains('@99999'));
    });
  });
}
