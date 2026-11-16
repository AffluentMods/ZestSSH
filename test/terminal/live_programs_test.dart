import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';

/// Real programs with the app's terminal emulator in front of them: what
/// the program writes goes into the emulator, and what the emulator answers
/// goes back to the program as typed, the way it does in a session. A
/// recording cannot show this: it is of a program that was answered by
/// something else.
///
/// A bug in 2.2.1: a configuration dialog of the package system, in a
/// session that says it is a Linux console, showed as text, not as a
/// dialog that could be used. The emulator answered that console's code for
/// "hide the cursor" as if it had been asked what it is; the dialog read the
/// answer as keys, the first of them Escape, and closed.
///
/// Needs Linux with python3 and the programs themselves: on Windows through
/// WSL (`wsl -e python3 tool/terminal/pty_bridge.py ...`), elsewhere
/// directly. A test whose program is not there skips itself.
class _Live {
  _Live._(this.terminal, this._process) {
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    _process.stderr.transform(utf8.decoder).listen(_errors.write);
    terminal.onOutput = (keys) {
      answers.add(keys);
      _process.stdin.add(utf8.encode(keys));
    };
    _process.exitCode.then((code) => exit = code);
  }

  final Terminal terminal;
  final Process _process;
  final _errors = StringBuffer();

  /// What the emulator sent back by itself, without anything being typed.
  final answers = <String>[];

  /// The program's exit code, once it has ended.
  int? exit;

  static const _bridge = 'tool/terminal/pty_bridge.py';

  /// The command that runs [args] on Linux: through WSL on Windows.
  static List<String> _linux(List<String> args) =>
      Platform.isWindows ? ['wsl', '-e', ...args] : args;

  static String _bridgePath() {
    final here = Directory.current.path;
    if (!Platform.isWindows) return '$here/$_bridge';
    final drive = here[0].toLowerCase();
    return '/mnt/$drive${here.substring(2).replaceAll(r'\', '/')}/$_bridge';
  }

  /// The programs in [needed] that are missing where the bridge would run
  /// them ("python3" among them when there is no Linux to run it on).
  static Future<List<String>> missing(List<String> needed) async {
    try {
      final command = _linux([
        'sh',
        '-c',
        'for p in python3 ${needed.join(' ')}; do '
            'command -v "\$p" >/dev/null 2>&1 || echo "\$p"; done',
      ]);
      final result = await Process.run(command.first, command.sublist(1))
          .timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) return ['python3'];
      return LineSplitter.split('${result.stdout}')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    } catch (_) {
      return ['python3'];
    }
  }

  static Future<_Live> start(
    List<String> program, {
    required String term,
    int rows = 30,
    int cols = 100,
  }) async {
    final terminal = Terminal(maxLines: 500);
    terminal.resize(cols, rows);
    final command = _linux(
        ['python3', _bridgePath(), term, '$rows', '$cols', '--', ...program]);
    final process = await Process.start(command.first, command.sublist(1));
    final live = _Live._(terminal, process);
    addTearDown(live.stop);
    return live;
  }

  /// Types [keys], as the person at the keyboard.
  void type(String keys) => _process.stdin.add(utf8.encode(keys));

  String row(int y) =>
      terminal.buffer.lines[terminal.buffer.scrollBack + y].getText().trimRight();

  List<String> get screen =>
      [for (var y = 0; y < terminal.viewHeight; y++) row(y)];

  String get shown => screen.where((l) => l.isNotEmpty).join('\n');

  Future<void> until(bool Function() check, {required String what}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!check()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $what. The screen:\n$shown\n'
            'errors: $_errors\nexit: $exit');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> wait(Duration time) => Future<void>.delayed(time);

  Future<int> ended() async {
    await until(() => exit != null, what: 'the program to end');
    return exit!;
  }

  Future<void> stop() async {
    if (exit == null) _process.kill();
    await _process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }
}

void main() {
  const esc = '\x1b';
  const down = '$esc[B';
  const enter = '\r';
  const note = '/tmp/zest_live_note.txt';

  /// Skips the test when [programs] cannot be run here, and says so.
  Future<bool> cannotRun(List<String> programs) async {
    final missing = await _Live.missing(programs);
    if (missing.isEmpty) return false;
    markTestSkipped('needs ${missing.join(', ')} on Linux'
        '${Platform.isWindows ? ' (through WSL)' : ''}');
    return true;
  }

  const dialog = [
    'whiptail', '--title', 'Configuring demo', //
    '--menu', 'What do you want to do about the file?', '16', '70', '4',
    'install', 'install the new version',
    'keep', 'keep the version installed',
    'diff', 'show the differences',
    'shell', 'start a shell',
  ];

  for (final term in ['linux', 'xterm-256color']) {
    test('a configuration dialog as $term waits for the person, and takes '
        'what they pick', () async {
      if (await cannotRun(['whiptail'])) return;
      final live = await _Live.start(dialog, term: term);
      await live.until(() => live.shown.contains('keep the version installed'),
          what: 'the dialog');

      // Nobody has touched a key. The dialog is still there a second later,
      // and nothing was typed into it.
      await live.wait(const Duration(seconds: 1));
      expect(live.exit, isNull, reason: 'the dialog closed by itself');
      expect(live.answers, isEmpty);

      live.type(down);
      live.type(enter);
      expect(await live.ended(), 0);
      // Its answer is what it writes when it ends: the choice that was
      // picked, one down from the first.
      await live.until(() => live.shown.contains('keep'), what: 'the choice');
      expect(live.screen.where((l) => l.trim() == 'keep' || l.endsWith('keep')),
          isNotEmpty);
    });
  }

  for (final term in ['linux', 'xterm-256color']) {
    test('vim as $term: keys do what they say, and the file is as it was',
        () async {
      if (await cannotRun(['vim'])) return;
      final live = await _Live.start([
        'sh', '-c', //
        'printf "one\\ntwo\\nthree\\n" > $note; vim -u NONE $note; '
            'echo; cat $note; echo END-OF-FILE',
      ], term: term);
      await live.until(() => live.screen.take(3).join('|') == 'one|two|three',
          what: 'the file in vim');
      await live.wait(const Duration(milliseconds: 700));

      // Down one line, then write and quit. Typed into by the emulator, vim
      // was waiting to finish a command that changes lines: the j completed
      // it.
      live.type('j');
      await live.wait(const Duration(milliseconds: 200));
      live.type(':wq$enter');
      await live.until(() => live.shown.contains('END-OF-FILE'),
          what: 'vim to end');
      final file = live.screen
          .skipWhile((l) => l != 'one')
          .takeWhile((l) => l != 'END-OF-FILE')
          .toList();
      expect(file, ['one', 'two', 'three']);
    });
  }

  // A bug in 2.2.1, on a phone: arrows that did nothing. A pager asks for
  // the other form of the cursor keys, and takes no arrow in the first form,
  // which is the one the row of keys above a phone's keyboard handed over
  // whatever had been asked for.
  test('less takes the arrows of the row above a phone\'s keyboard, in the form it asked for', () async {
    if (await cannotRun(['less'])) return;
    final live = await _Live.start(
      ['sh', '-c', 'seq 1 200 | sed "s/^/line /" > $note; exec less $note'],
      term: 'xterm-256color',
    );
    await live.until(() => live.row(0) == 'line 1', what: 'the file in less');
    expect(live.terminal.cursorKeysMode, isTrue, reason: 'less asked for the other form of the cursor keys');

    // The form the row hands over, sent as it is, is no arrow to it.
    live.type(down);
    live.type(down);
    await live.wait(const Duration(milliseconds: 600));
    expect(live.row(0), 'line 1');

    // Typed as the key it is, it is.
    typeSoftKey(live.terminal, down);
    typeSoftKey(live.terminal, down);
    await live.until(() => live.row(0) == 'line 3', what: 'less to go down two lines');
    live.type('q');
    expect(await live.ended(), 0);
  });

  test('nano on a Linux console leaves when asked, with nothing to save',
      () async {
    if (await cannotRun(['nano'])) return;
    final live = await _Live.start([
      'sh', '-c', //
      'printf "one\\ntwo\\n" > $note; nano --ignorercfiles $note; '
          'echo; cat $note; echo END-OF-FILE',
    ], term: 'linux');
    await live.until(() => live.shown.contains('one'), what: 'the file in nano');
    await live.wait(const Duration(milliseconds: 700));
    expect(live.answers, isEmpty);

    // Ctrl+X. With anything typed into it, nano asks whether to save.
    live.type('\x18');
    await live.until(() => live.shown.contains('END-OF-FILE'),
        what: 'nano to end without a question');
    final file = live.screen
        .skipWhile((l) => l != 'one')
        .takeWhile((l) => l != 'END-OF-FILE')
        .toList();
    expect(file, ['one', 'two']);
  });

  test('a program that asks where the cursor is, is told where it put it',
      () async {
    if (await cannotRun(['bash'])) return;
    // The shell puts the cursor at row 5, column 10, asks, and reads the
    // answer from its terminal as a program does.
    final live = await _Live.start([
      'bash', '-c', //
      r'printf "\033[5;10H\033[6n"; IFS=";" read -r -s -d R row col; '
          r'printf "\r\ngot row %s column %s\n" "${row#*[}" "$col"',
    ], term: 'xterm-256color');
    expect(await live.ended(), 0);
    await live.until(() => live.shown.contains('got row'), what: 'its answer');
    expect(live.shown, contains('got row 5 column 10'));
    expect(live.answers, ['$esc[5;10R']);
  });

  for (final term in ['linux', 'xterm-256color']) {
    test('reset as $term: the screen is clean, and what follows shows',
        () async {
      if (await cannotRun(['reset'])) return;
      final live = await _Live.start([
        'sh', '-c', //
        'echo a line from before; printf "\\033(0"; reset; echo after reset',
      ], term: term);
      expect(await live.ended(), 0);
      await live.until(() => live.shown.contains('after reset'),
          what: 'what follows reset');
      // The line from before is gone, and letters are letters (they were
      // set to be drawn as lines just before).
      expect(live.shown, 'after reset');
      expect(live.row(0), 'after reset');
    });
  }
}
