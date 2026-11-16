@Tags(['real-tmux'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_inband_watcher.dart';

/// Drives [TmuxController] against a REAL tmux (WSL on this machine, or a
/// native tmux on macOS / Linux) on an isolated socket with a blank config, so
/// nothing here can touch a real session. Skipped where no tmux is reachable.
///
/// `script` lends the control client the tty that `-CC` insists on; commands
/// go in through its stdin, the protocol comes out of its stdout.
const _socket = 'zestssh-test';

List<String>? _wsl;

Future<bool> _detect() async {
  if (Platform.isWindows) {
    try {
      final r = await Process.run(
          'wsl.exe', ['-d', 'Ubuntu', '--', 'bash', '-lc', 'tmux -V && which script']);
      if (r.exitCode == 0) {
        _wsl = ['-d', 'Ubuntu', '--'];
        return true;
      }
    } catch (_) {}
    return false;
  }
  try {
    final r = await Process.run('sh', ['-c', 'tmux -V && which script']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<ProcessResult> _sh(String script) {
  if (_wsl != null) {
    return Process.run('wsl.exe', [..._wsl!, 'bash', '-lc', script]);
  }
  return Process.run('sh', ['-c', script]);
}

Future<Process> _spawn(String script) {
  if (_wsl != null) {
    return Process.start('wsl.exe', [..._wsl!, 'bash', '-lc', script]);
  }
  return Process.start('sh', ['-c', script]);
}

const _t = 'tmux -L $_socket -f /dev/null';
const _shell =
    r'env -i PS1="\$ " TERM=xterm-256color HOME=/tmp PATH=/usr/bin:/bin bash --norc --noprofile';

String _text(Terminal term) {
  final b = term.buffer;
  return List.generate(b.lines.length, (i) => b.lines[i].toString()).join('\n');
}

// (Thirty seconds, where it was eight: a wait is over as soon as what it waits for is so, and eight were too
// few once, for what had scrolled off, while another run compiled beside the suite. The test passes alone.)
Future<void> _until(bool Function() cond, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// Waits until a line of [target]'s screen passes [printed].
Future<void> _untilPrinted(String target, bool Function(String line) printed, String what,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final r = await _sh('$_t capture-pane -p -t $target');
    if (r.exitCode == 0 && (r.stdout as String).split('\n').any((l) => printed(l.trimRight()))) return;
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool available;
  setUpAll(() async {
    available = await _detect();
  });

  Process? proc;
  TmuxController? c;

  Future<TmuxController> attach(String target) async {
    final p = await _spawn(
        'script -qfc "$_t -CC attach -t $target" /dev/null');
    proc = p;
    final ctl = TmuxController(
      sendBytes: (b) => p.stdin.add(b),
      scrollback: 200,
    );
    c = ctl;
    p.stdout.listen(ctl.onData, onDone: ctl.onTransportClosed);
    p.stderr.listen((_) {});
    return ctl;
  }

  tearDown(() async {
    c?.dispose();
    c = null;
    proc?.kill();
    proc = null;
    await _sh('$_t kill-server 2>/dev/null; true');
  });

  test('attach: history, split, UTF-8, cursor, then live ops end to end',
      () async {
    if (!available) {
      markTestSkipped('no tmux + script reachable');
      return;
    }
    // A session with history, a split, UTF-8 on screen and a second window.
    await _sh('''
$_t kill-server 2>/dev/null
$_t new-session -d -s demo -x 100 -y 30 '$_shell'
sleep 0.3
$_t send-keys -t demo 'seq 1 40' Enter
$_t send-keys -t demo 'printf "h\\303\\251llo \\342\\234\\223 \\346\\227\\245\\346\\234\\254\\n"' Enter
''');
    // Wait for what was typed to be printed, not for a fixed time: under
    // load the shell is slower than that, and a pane attached while it is
    // still printing is another test's business. (The printed line starts
    // with "h"; the command that prints it starts with the prompt.)
    await _untilPrinted('demo', (line) => line.startsWith('h') && line.contains('llo'), 'the seeded output');
    await _sh('''
$_t split-window -h -t demo '$_shell'
$_t new-window -t demo -n logs '$_shell'
$_t send-keys -t demo:logs 'echo in-logs-window' Enter
$_t select-window -t demo:0
''');
    await _untilPrinted('demo:logs', (line) => line.startsWith('in-logs-window'), 'the logs window');
    final ctl = await attach('demo');
    ctl.setClientSize(100, 30);
    await _until(() => ctl.phase == TmuxPhase.ready, 'ctl.phase == TmuxPhase.ready');

    expect(ctl.version.isKnown, isTrue);
    expect(ctl.currentSessionName, 'demo');
    expect(ctl.windows.map((w) => w.name), ['bash', 'logs']);
    expect(ctl.activeWindowId, ctl.windows.first.id);

    final first = ctl.windows.first;
    expect(first.panes, hasLength(2));
    expect(first.layout, isA<TmuxSplitNode>());
    final left = first.panes[first.layout!.paneIds.first]!;
    await _until(() => !left.awaitingCapture, '!left.awaitingCapture');
    await _until(() => _text(left.terminal).contains('héllo ✓ 日本'), 'the seeded output');
    // What had scrolled off above it is restored too, and may be a moment
    // behind what is on screen.
    await _until(() => RegExp('\n1 *\n').hasMatch(_text(left.terminal)), 'what had scrolled off');
    final text = _text(left.terminal);
    expect(text, contains('héllo ✓ 日本'));
    expect(RegExp('\n1 *\n').hasMatch(text), isTrue,
        reason: 'history restored');
    expect(text, contains('40'));
    // The prompt is on the last screen row with the cursor after it.
    expect(left.terminal.buffer.cursorX, 2);
    expect(left.terminal.viewWidth, 50);
    expect(left.terminal.viewHeight, 30);

    final logs = ctl.windows.last;
    final lp = logs.panes.values.single;
    await _until(() => !lp.awaitingCapture, '!lp.awaitingCapture');
    expect(_text(lp.terminal), contains('in-logs-window'));

    // Live output after the capture.
    left.terminal.onOutput!('echo live-é\r');
    await _until(() => _text(left.terminal).contains('live-é'), '_text(left.terminal).contains(live-é)');

    // New window through the API: appears, named, captured, active.
    await ctl.newWindow(name: "it's #1");
    await _until(() => ctl.windows.length == 3, 'ctl.windows.length == 3');
    final nw = ctl.windows.last;
    await _until(() => nw.name == "it's #1", 'new window named');
    await _until(() => ctl.activeWindowId == nw.id, 'ctl.activeWindowId == nw.id');
    final np = nw.panes.values.single;
    await _until(() => !np.awaitingCapture && _text(np.terminal).contains(r'$'), 'new pane captured with a prompt');

    // Split the new window, then zoom and unzoom.
    await ctl.splitPane(np.id, horizontal: false);
    await _until(() => nw.panes.length == 2, 'nw.panes.length == 2');
    final newPane = nw.panes.keys.firstWhere((k) => k != np.id);
    await _until(() => !nw.panes[newPane]!.awaitingCapture, '!nw.panes[newPane]!.awaitingCapture');
    await ctl.toggleZoom(newPane);
    await _until(() => nw.zoomed, 'nw.zoomed');
    expect(nw.renderLayout!.paneIds, [newPane]);
    await ctl.toggleZoom(newPane);
    await _until(() => !nw.zoomed, '!nw.zoomed');

    // Close the pane, then the window.
    await ctl.closePane(newPane);
    await _until(() => nw.panes.length == 1, 'nw.panes.length == 1');
    await ctl.closeWindow(nw.id);
    await _until(() => ctl.windows.length == 2, 'ctl.windows.length == 2');

    // Rename with characters that must survive quoting and format expansion.
    await ctl.renameWindow(logs.id, r'my logs; #(id) $HOME');
    await _until(() => logs.name == r'my logs; #(id) $HOME', 'window renamed with hostile characters');

    // Sessions: create + switch + back.
    expect(await ctl.newSession('second'), isTrue);
    await _until(() => ctl.currentSessionName == 'second', 'ctl.currentSessionName == second');
    await _until(() => ctl.windows.length == 1 &&
        ctl.windows.single.panes.values.every((p) => !p.awaitingCapture), 'ctl.windows.length == 1 && ctl.windows.single.panes.values.every((p) => !p.awaitingCapture)');
    final demo = ctl.sessions.firstWhere((s) => s.name == 'demo');
    await ctl.switchSession(demo.id);
    await _until(() => ctl.currentSessionName == 'demo' && ctl.windows.length == 2, 'ctl.currentSessionName == demo && ctl.windows.length == 2');

    // Detach: %exit, then the terminator.
    var ended = false;
    ctl.onControlEnd = () => ended = true;
    ctl.detach();
    await _until(() => ctl.exited && ended, 'ctl.exited && ended');
  });

  test('attach failure reports the reason', () async {
    if (!available) {
      markTestSkipped('no tmux + script reachable');
      return;
    }
    await _sh('$_t kill-server 2>/dev/null; true');
    final ctl = await attach('nope');
    await _until(() => ctl.exited, 'ctl.exited');
    expect(ctl.exitReason, anyOf(contains('no server'), contains('no sessions'),
        contains("can't find")));
  });

  test('alternate screen app is restored on attach', () async {
    if (!available) {
      markTestSkipped('no tmux + script reachable');
      return;
    }
    await _sh('''
$_t kill-server 2>/dev/null
$_t new-session -d -s alt -x 80 -y 12 '$_shell'
sleep 0.3
$_t send-keys -t alt 'printf "\\033[?1049h\\033[2J\\033[HALTLINE1\\nALTLINE2\\033[?25l"; sleep 60' Enter
sleep 0.5
''');
    final ctl = await attach('alt');
    ctl.setClientSize(80, 12);
    await _until(() => ctl.phase == TmuxPhase.ready, 'ctl.phase == TmuxPhase.ready');
    final p = ctl.windows.single.panes.values.single;
    await _until(() => !p.awaitingCapture, '!p.awaitingCapture');
    expect(p.terminal.isUsingAltBuffer, isTrue);
    expect(_text(p.terminal), contains('ALTLINE1'));
    expect(_text(p.terminal), contains('ALTLINE2'));
    expect(p.terminal.cursorVisibleMode, isFalse);
    // Interrupt the app and leave the alternate screen the way an app would:
    // the main screen with the original command line comes back.
    p.terminal.onOutput!('\x03');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    p.terminal.onOutput!('printf "\\033[?1049l"\r');
    await _until(() => !p.terminal.isUsingAltBuffer, 'back on the main screen');
    expect(_text(p.terminal), contains('sleep 60'),
        reason: 'the saved main screen (the original command line) is back');
  });

  test('in-band: typing tmux -CC into a live shell switches the stream over',
      () async {
    if (!available) {
      markTestSkipped('no tmux + script reachable');
      return;
    }
    await _sh('$_t kill-server 2>/dev/null; true');
    // A plain interactive shell on a pty: what an SSH session's channel is.
    final p = await _spawn("script -qfc '$_shell' /dev/null");
    proc = p;
    final passed = <int>[];
    final entered = <TmuxController>[];
    final exited = <TmuxController>[];
    final watcher = TmuxInbandWatcher(
      sendBytes: (b) => p.stdin.add(b),
      onPassthrough: passed.addAll,
      onEnter: entered.add,
      onExit: exited.add,
      scrollback: 200,
    );
    p.stdout.listen((b) => watcher.addBytes(Uint8List.fromList(b)),
        onDone: watcher.finish);
    p.stderr.listen((_) {});
    await _until(() => utf8.decode(passed, allowMalformed: true).contains(r'$ '),
        'shell prompt');

    // The user types tmux -CC (echoed by the shell, then the marker).
    watcher.lineEntered('$_t -CC new-session -A -s inband');
    p.stdin.add(utf8.encode('$_t -CC new-session -A -s inband\n'));
    await _until(() => entered.isNotEmpty, 'control mode entered');
    final ctl = entered.single;
    expect(watcher.inControl, isTrue);
    ctl.setClientSize(90, 26);
    await _until(() => ctl.phase == TmuxPhase.ready, 'controller ready');
    expect(ctl.currentSessionName, 'inband');
    final pane = ctl.windows.single.panes.values.single;
    await _until(() => !pane.awaitingCapture, 'pane captured');
    // Keys go to the pane through send-keys, never to the channel raw.
    pane.terminal.onOutput!('echo in-tmux\r');
    await _until(() => _text(pane.terminal).contains('in-tmux'), 'pane echo');
    final passthroughBeforeExit = passed.length;

    // Detach: %exit + terminator, and the shell is back on the same stream.
    ctl.detach();
    await _until(() => exited.isNotEmpty && !watcher.inControl, 'left control mode');
    expect(identical(exited.single, ctl), isTrue);
    p.stdin.add(utf8.encode('echo after-tmux\n'));
    await _until(
        () => utf8
            .decode(passed.sublist(passthroughBeforeExit), allowMalformed: true)
            .contains('after-tmux'),
        'shell output after tmux');
    // The tmux session outlived the detach.
    final ls = await _sh('$_t list-sessions -F "#{session_name}"');
    expect(ls.stdout.toString().trim(), 'inband');
    p.stdin.add(utf8.encode('exit\n'));
  });

  test('the golden transcripts still match what this tmux emits', () async {
    if (!available) {
      markTestSkipped('no tmux + script reachable');
      return;
    }
    // Sanity check that the fixture protocol shape is current: attach, ask
    // for the version, detach, and compare the event kinds.
    await _sh('''
$_t kill-server 2>/dev/null
$_t new-session -d -s g -x 80 -y 24 '$_shell'
sleep 0.3
''');
    final p = await _spawn('script -qfc "$_t -CC attach -t g" /dev/null');
    proc = p;
    final parser = TmuxControlParser(inband: true);
    final kinds = <String>[];
    final done = Completer<void>();
    p.stdout.listen((b) {
      for (final e in parser.addBytes(b)) {
        kinds.add(e.runtimeType.toString());
        if (e is TmuxControlEnd && !done.isCompleted) done.complete();
      }
    });
    p.stderr.listen((_) {});
    // Typed only once the client has said it is in control mode. Until then
    // the tty `script` lent it still echoes, and a command typed too early
    // comes back as ordinary output ahead of everything else: on a busy
    // machine a fixed wait was sometimes too short, and the first thing seen
    // was that echo.
    await _until(() => kinds.contains('TmuxControlBegin'), 'control mode', timeout: const Duration(seconds: 20));
    final answered = kinds.where((k) => k == 'TmuxReply').length;
    p.stdin.add(utf8.encode('display-message -p "#{version}"\n'));
    await _until(() => kinds.where((k) => k == 'TmuxReply').length > answered, 'an answer',
        timeout: const Duration(seconds: 20));
    p.stdin.add(utf8.encode('detach-client\n'));
    await done.future.timeout(const Duration(seconds: 20));
    expect(kinds.first, 'TmuxControlBegin');
    expect(kinds, contains('TmuxSessionChanged'));
    expect(kinds.where((k) => k == 'TmuxReply').length, greaterThanOrEqualTo(2));
    expect(kinds, contains('TmuxExit'));
    expect(kinds.last, 'TmuxControlEnd');
    expect(kinds, isNot(contains('TmuxStrayLine')));
  });

  // A bug: killing a window or the session (not
  // detaching) did not work. These are the commands the app sends for them.
  test('a window closed from the app is gone, in tmux and from the windows the app shows', () async {
    if (!available) {
      markTestSkipped('no tmux + script reachable');
      return;
    }
    await _sh('''
$_t kill-server 2>/dev/null
$_t new-session -d -s work -x 100 -y 30 '$_shell'
$_t new-window -t work -n logs '$_shell'
$_t select-window -t work:0
''');
    final ctl = await attach('work');
    ctl.setClientSize(100, 30);
    await _until(() => ctl.phase == TmuxPhase.ready, 'ctl.phase == TmuxPhase.ready');
    await _until(() => ctl.windows.length == 2, 'both windows');
    final logs = ctl.windows.firstWhere((w) => w.name == 'logs').id;

    expect(await ctl.closeWindow(logs), isTrue);
    await _until(() => ctl.windows.length == 1, 'the window gone from the app');
    expect(ctl.windows.single.id, isNot(logs), reason: 'the other window stays');
    final left = await _sh('$_t list-windows -t work -F "#{window_id}"');
    expect((left.stdout as String).split('\n'), isNot(contains(logs)), reason: 'gone in tmux');
    expect(ctl.exited, isFalse, reason: 'the session goes on');
  });

  test('the session killed from the app is gone in tmux, and the app is told it ended', () async {
    if (!available) {
      markTestSkipped('no tmux + script reachable');
      return;
    }
    await _sh('''
$_t kill-server 2>/dev/null
$_t new-session -d -s work -x 100 -y 30 '$_shell'
$_t new-session -d -s other -x 100 -y 30 '$_shell'
''');
    final ctl = await attach('work');
    ctl.setClientSize(100, 30);
    await _until(() => ctl.phase == TmuxPhase.ready, 'ctl.phase == TmuxPhase.ready');
    await _until(() => ctl.currentSessionId != null, 'the session attached');
    final id = ctl.currentSessionId!;

    await ctl.killSession(id);
    await _until(() => ctl.exited, 'the app told the session ended');
    final left = await _sh('$_t list-sessions -F "#{session_name}"');
    final names = (left.stdout as String).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    expect(names, ['other'], reason: 'work gone in tmux, the other session left');
  });
}
