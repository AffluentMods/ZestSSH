import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/command_history/command_capture.dart';
import 'package:zestssh/features/command_history/history_suggester.dart';
import 'package:zestssh/features/command_history/history_suggestions.dart';

/// History suggestions (3.0) with a real terminal and a real history
/// database: the newest command starting with what is typed shows dimmed
/// once the shell echoed the typing, never at a password prompt or in a
/// full-screen program, and Right arrow sends the rest of it; nothing of a
/// suggestion is sent before that.

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Terminal terminal;
  late CommandCapture capture;
  late HistorySuggester suggester;
  late List<String> sent;
  var enabled = true;
  var lookups = 0;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final dao = db.commandHistoryDao;
    final t0 = DateTime(2026, 9, 1);
    await dao.record(command: 'git status --short', connectionId: 'web', at: t0);
    await dao.record(command: 'git stash pop', connectionId: 'db', at: t0.add(const Duration(minutes: 1)));
    await dao.record(command: 'git status', connectionId: 'web', at: t0.add(const Duration(minutes: 2)));
    await dao.record(command: 'docker ps -a', connectionId: 'web', at: t0.add(const Duration(minutes: 3)));
    terminal = Terminal();
    terminal.write('me@web:~\$ ');
    capture = CommandCapture();
    sent = [];
    enabled = true;
    lookups = 0;
    suggester = HistorySuggester(
      lookup: (typed) {
        lookups++;
        return dao.latestStartingWith(typed, preferConnectionId: 'web');
      },
      enabled: () => enabled,
    );
  });

  tearDown(() => db.close());

  String displayLine() => terminal.buffer.lines[terminal.buffer.absoluteCursorY].toString();

  /// Presses [key] as the app does: through the suggester, to the shell
  /// (which echoes it when [echo]), the capture, then a lookup.
  Future<void> press(String key, {bool echo = true}) async {
    final send = suggester.input(key, terminal);
    sent.add(send);
    capture.onInput(send, displayLine);
    if (echo && !send.startsWith('\x1b')) terminal.write(send);
    suggester.typed(capture, terminal);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> type(String text, {bool echo = true}) async {
    for (final c in text.split('')) {
      await press(c, echo: echo);
    }
  }

  test('the newest match shows after the cursor once the echo is there; Right arrow sends the rest', () async {
    await type('git st');
    expect(terminal.ghostText, 'atus', reason: 'git status is newer than git status --short and git stash pop here');
    expect(sent.join(), 'git st', reason: 'nothing of the suggestion was sent');
    await press('\x1b[C');
    expect(sent.last, 'atus');
    expect(capture.line, 'git status');
    expect(displayLine().trimRight(), endsWith('git status'));
    // A longer one still starts with it: offered next.
    expect(terminal.ghostText, ' --short');
    await type(' ');
    expect(terminal.ghostText, '--short');
    // Enter: the line is done, and so is the suggestion.
    await press('\r', echo: false);
    terminal.write('\r\n');
    expect(terminal.ghostText, isNull);
  });

  test('the other cursor-key mode accepts too, and any other key just hides it', () async {
    await type('do');
    expect(terminal.ghostText, 'cker ps -a');
    await press('c');
    expect(terminal.ghostText, 'ker ps -a');
    await press('\x1bOC');
    expect(sent.last, 'ker ps -a');
  });

  test('any other key is just that key: Left arrow with a suggestion showing sends Left arrow', () async {
    await type('do');
    expect(terminal.ghostText, 'cker ps -a');
    await press('\x1b[D', echo: false);
    expect(sent.last, '\x1b[D');
    expect(terminal.ghostText, isNull);
    for (final key in ['\x1b[D', '\x1b[A', '\x1b[B', '\x1b[1;5C', '\x1b[F', '\x1bOF', '\t', '\r', 'C', '\x1b']) {
      expect(acceptsSuggestion(key), isFalse, reason: 'only Right arrow accepts, not ${key.codeUnits}');
    }
  });

  test('no echo, no suggestion: a password prompt never shows one', () async {
    terminal.write('\r\nPassword: ');
    await type('gi', echo: false);
    expect(terminal.ghostText, isNull);
    expect(acceptsSuggestion('\x1b[C'), isTrue);
    await press('\x1b[C', echo: false);
    expect(sent.last, '\x1b[C', reason: 'Right arrow is just Right arrow with nothing shown');
  });

  test('never in a full-screen program, never on a line the capture lost track of, never when off', () async {
    terminal.write('\x1b[?1049h');
    await type('gi');
    expect(terminal.ghostText, isNull, reason: 'full-screen');
    terminal.write('\x1b[?1049l');

    await press('\x15', echo: false); // Ctrl+U: a fresh line
    await press('\x1b[D', echo: false); // an arrow key: the capture no longer knows the line
    await type('gi');
    expect(terminal.ghostText, isNull, reason: 'untrusted line');

    await press('\x15', echo: false);
    enabled = false;
    final before = lookups;
    await type('gi');
    expect(terminal.ghostText, isNull, reason: 'switched off');
    expect(lookups, before, reason: 'switched off, history is not even read');
  });

  test('one letter is too little; no match is no suggestion', () async {
    await type('g');
    expect(terminal.ghostText, isNull);
    await type('rep');
    expect(terminal.ghostText, isNull);
    expect(kSuggestMinChars, 2);
  });

  test('a slow lookup that arrives after more typing is not shown', () async {
    final pending = <String, Completer<String?>>{};
    final slow = HistorySuggester(
      lookup: (typed) => (pending[typed] = Completer<String?>()).future,
      enabled: () => true,
    );
    final c = CommandCapture();
    for (final ch in ['g', 'i']) {
      c.onInput(ch, displayLine);
      terminal.write(ch);
      slow.typed(c, terminal);
    }
    c.onInput('t', displayLine);
    terminal.write('t');
    slow.typed(c, terminal);
    pending['gi']!.complete('gist');
    await Future<void>.delayed(Duration.zero);
    expect(terminal.ghostText, isNull, reason: 'what was looked up for "gi" no longer fits');
    pending['git']!.complete('git log');
    await Future<void>.delayed(Duration.zero);
    expect(terminal.ghostText, ' log');
  });

  test('a slow lookup that arrives after a newer one changes nothing', () async {
    final pending = <String, Completer<String?>>{};
    final slow = HistorySuggester(
      lookup: (typed) => (pending[typed] = Completer<String?>()).future,
      enabled: () => true,
    );
    final c = CommandCapture();
    for (final ch in ['g', 'i', 't']) {
      c.onInput(ch, displayLine);
      terminal.write(ch);
      slow.typed(c, terminal);
    }
    pending['git']!.complete('git log');
    await Future<void>.delayed(Duration.zero);
    expect(terminal.ghostText, ' log');
    pending['gi']!.complete('gist');
    await Future<void>.delayed(Duration.zero);
    expect(terminal.ghostText, ' log', reason: 'the answer for "gi" came late and is dropped');
    slow.output(c, terminal);
    expect(terminal.ghostText, ' log');
  });

  test('new output shows the suggestion only while the line is still what was looked up', () async {
    await type('git st');
    expect(terminal.ghostText, 'atus');
    suggester.output(capture, terminal);
    expect(terminal.ghostText, 'atus', reason: 'unchanged: still shown');
    // The line changes without a new lookup (the session layer always looks up
    // again, so this guards the rule itself): Ctrl+U, before the shell has
    // redrawn, so the screen still ends with "git st".
    capture.onInput('\x15', displayLine);
    suggester.output(capture, terminal);
    expect(terminal.ghostText, isNull);
  });

  group('the history lookup', () {
    test('matches the start exactly, case and all, and only something longer', () async {
      final dao = db.commandHistoryDao;
      expect(await dao.latestStartingWith('git st'), 'git status');
      expect(await dao.latestStartingWith('GIT'), isNull);
      expect(await dao.latestStartingWith('git status'), 'git status --short');
      expect(await dao.latestStartingWith('git status --short'), isNull);
      expect(await dao.latestStartingWith(''), isNull);
      // Newer, but it only contains what is typed.
      await dao.record(command: 'sudo git stash', at: DateTime(2026, 9, 5));
      expect(await dao.latestStartingWith('git st'), 'git status');
    });

    test('this host\'s commands first, then the newest anywhere', () async {
      final dao = db.commandHistoryDao;
      expect(await dao.latestStartingWith('git sta', preferConnectionId: 'db'), 'git stash pop');
      expect(await dao.latestStartingWith('git sta', preferConnectionId: 'web'), 'git status');
      expect(await dao.latestStartingWith('git sta'), 'git status', reason: 'the newest');
    });

    test('what is typed is text, never a pattern', () async {
      final dao = db.commandHistoryDao;
      await dao.record(command: 'echo 100% done', at: DateTime(2026, 9, 2));
      await dao.record(command: 'echo 1_0', at: DateTime(2026, 9, 3));
      expect(await dao.latestStartingWith('echo 100%'), 'echo 100% done');
      expect(await dao.latestStartingWith('echo 1%'), isNull);
      expect(await dao.latestStartingWith('echo 1_'), 'echo 1_0');
      expect(await dao.latestStartingWith('echo 1__'), isNull);
    });
  });

  group('the rules', () {
    test('what a suggestion adds', () {
      expect(suggestionRemainder(typed: 'ls', candidate: 'ls -la'), ' -la');
      expect(suggestionRemainder(typed: 'ls', candidate: 'ls'), isNull);
      expect(suggestionRemainder(typed: 'ls', candidate: 'cat'), isNull);
      expect(suggestionRemainder(typed: 'ls', candidate: 'ls\nrm -rf /'), isNull, reason: 'one line only');
      // Right arrow types it as keys, and a control character acts at once
      // (Ctrl-O runs the line in bash, with no Enter).
      for (final ctl in ['\x0f', '\x03', '\x1b', '\x15', '\x18\x05', '\r', '\t', '\x7f', '\u0080', '\u009b']) {
        expect(suggestionRemainder(typed: 'cat /tmp/rea', candidate: 'cat /tmp/readme$ctl'), isNull, reason: ctl);
      }
      expect(suggestionRemainder(typed: 'ls', candidate: 'ls été 日本語'), ' été 日本語');
    });

    test('when one may show', () {
      bool may({String typed = 'git', bool trusted = true, bool altBuffer = false, String before = 'me@web:~\$ git'}) =>
          mayShowSuggestion(typed: typed, trusted: trusted, altBuffer: altBuffer, beforeCursor: before);
      expect(may(), isTrue);
      expect(may(trusted: false), isFalse, reason: 'the line is no longer known');
      expect(may(altBuffer: true), isFalse, reason: 'a full-screen program');
      expect(may(before: 'Password: '), isFalse, reason: 'no echo');
      expect(may(typed: 'g', before: 'me@web:~\$ g'), isFalse, reason: 'too little');
      expect(may(typed: ' g', before: 'me@web:~\$  g'), isFalse, reason: 'spaces do not count');
    });

    test('the text before the cursor joins wrapped rows', () {
      final rows = ['me@web:~\$ a very long comm', 'and that wraps', ''];
      final text = textBeforeCursor(
        cursorY: 1,
        cursorX: 8,
        row: (y) => rows[y],
        rowUpTo: (y, to) => rows[y].substring(0, to),
        isWrapped: (y) => y == 1,
      );
      expect(text, 'me@web:~\$ a very long command that');
    });
  });
}
