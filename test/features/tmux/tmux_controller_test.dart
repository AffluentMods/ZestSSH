import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';

import 'fake_tmux.dart';

const _twoPane =
    '%layout-change @1 e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2} e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n';
const _onePane = '%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n';

String _bufferText(Terminal term) {
  final b = term.buffer;
  return List.generate(b.lines.length, (i) => b.lines[i].toString())
      .join('\n');
}

String _paneText(TmuxController c, String windowId, {String? paneId}) {
  final w = c.windows.firstWhere((w) => w.id == windowId);
  final term = paneId != null ? w.panes[paneId]!.terminal : w.activeTerminal!;
  return _bufferText(term);
}

/// Let the fake answer everything outstanding (each reply is a microtask,
/// and replies trigger further commands).
Future<void> settle() async {
  for (var i = 0; i < 40; i++) {
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notification-driven model (no server replies)', () {
    late List<String> sent;
    late TmuxController c;

    setUp(() {
      sent = [];
      c = TmuxController(
        sendBytes: (bytes) => sent.add(utf8.decode(bytes)),
        expectMarker: false,
      );
    });
    tearDown(() => c.dispose());

    test('start() types the launch command into the transport', () {
      c.start(sessionName: 'zestssh');
      expect(sent.single.trim(), 'tmux -CC new -A -s zestssh');
    });

    test('a window is added and becomes active', () {
      c.onData(utf8.encode('%window-add @1\n'));
      expect(c.windows.map((w) => w.id), ['@1']);
      expect(c.activeWindowId, '@1');
    });

    test('layout maps panes and sets the active pane', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_onePane));
      expect(c.windows.single.paneIds, ['%0']);
      expect(c.windows.single.activePaneId, '%0');
    });

    test('a new pane is queried before its output is trusted', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_onePane));
      expect(sent.any((s) => s.startsWith('display-message -p -t %0 ')), isTrue);
      expect(c.windows.single.panes['%0']!.awaitingCapture, isTrue);
      // Output before the capture completes is dropped (it is in the capture).
      c.onData(utf8.encode('%output %0 hi\\015\\012\n'));
      expect(_paneText(c, '@1'), isNot(contains('hi')));
    });

    test('typing goes to the active pane as hex-encoded send-keys', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_twoPane));
      c.selectPane('@1', '%2');
      c.windows.single.activeTerminal!.onOutput!('ls');
      expect(sent.last.trim(), 'send-keys -t %2 -H 6c 73');
    });

    test('a large paste is chunked into several send-keys commands', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_onePane));
      final before = sent.length;
      c.sendText('%0', 'x' * 1500);
      final keys = sent.sublist(before).where((s) => s.startsWith('send-keys'));
      expect(keys.length, 3);
      expect(keys.first.split(' ').length, 4 + 512);
    });

    test('selectPane focuses a pane and tells tmux', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_twoPane));
      c.selectPane('@1', '%2');
      expect(c.windows.single.activePaneId, '%2');
      expect(sent.last.trim(), 'select-pane -t %2');
    });

    test('selectWindow is local first and then tells tmux', () {
      c.onData(utf8.encode('%window-add @1\n%window-add @2\n'));
      c.selectWindow('@2');
      expect(c.activeWindowId, '@2');
      expect(sent.last.trim(), 'select-window -t @2');
    });

    test('tmux switching the window (another client) updates the tabs', () {
      c.onData(utf8.encode('%session-changed \$0 main\n'));
      c.onData(utf8.encode('%window-add @1\n%window-add @2\n'));
      c.onData(utf8.encode('%session-window-changed \$0 @2\n'));
      expect(c.activeWindowId, '@2');
    });

    test('closing a pane prunes its terminal on the next layout', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_twoPane));
      expect(c.windows.single.panes.keys.toSet(), {'%1', '%2'});
      c.onData(utf8.encode(_onePane)); // back to a single pane %0
      expect(c.windows.single.panes.keys.toSet(), {'%0'});
    });

    test('zoom renders the visible layout, unzoom the full one', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_twoPane));
      c.onData(utf8.encode(
          '%layout-change @1 e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bc62,80x24,0,0,2 *Z\n'));
      final w = c.windows.single;
      expect(w.zoomed, isTrue);
      expect(w.renderLayout!.paneIds, ['%2']);
      expect(w.panes.keys.toSet(), {'%1', '%2'}, reason: 'both panes kept');
      expect(w.panes['%2']!.width, 80, reason: 'zoomed pane fills the window');
      c.onData(utf8.encode(_twoPane));
      expect(w.zoomed, isFalse);
      expect(w.renderLayout!.paneIds, ['%1', '%2']);
      expect(w.panes['%2']!.width, 39);
    });

    test('setClientSize sends refresh-client and dedups', () {
      c.setClientSize(80, 24);
      expect(sent.last.trim(), 'refresh-client -C 80,24');
      final n = sent.length;
      c.setClientSize(80, 24);
      expect(sent.length, n, reason: 'identical size is not re-sent');
      c.setClientSize(100, 30);
      expect(sent.last.trim(), 'refresh-client -C 100,30');
    });

    test('closing a window removes it and repoints the active window', () {
      c.onData(utf8.encode('%window-add @1\n%window-add @2\n'));
      expect(c.windows, hasLength(2));
      c.selectWindow('@2');
      c.onData(utf8.encode('%window-close @2\n'));
      expect(c.windows.map((w) => w.id), ['@1']);
      expect(c.activeWindowId, '@1');
    });

    test('rename updates the window name', () {
      c.onData(utf8.encode('%window-add @1\n%window-renamed @1 build\n'));
      expect(c.windows.single.name, 'build');
    });

    test('%exit marks the controller exited and fails pending commands',
        () async {
      final f = c.run('list-windows');
      c.onData(utf8.encode('%exit bye\n'));
      expect(c.exited, isTrue);
      expect(c.exitReason, 'bye');
      expect((await f).error, isTrue);
    });

    test('a malformed pane id is never interpolated into a send-keys command',
        () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode('%window-pane-changed @1 %0;kill-server\n'));
      final before = sent.length;
      c.windows.single.activeTerminal!.onOutput!('x');
      expect(sent.length, before, reason: 'no send-keys for a malformed target');
      expect(sent.any((s) => s.contains('kill-server')), isFalse);
    });

    test('%pause asks tmux to continue, %continue re-captures the pane', () {
      c.onData(utf8.encode('%window-add @1\n'));
      c.onData(utf8.encode(_onePane));
      final term = c.windows.single.panes['%0']!.terminal;
      c.onData(utf8.encode('%pause %0\n'));
      expect(sent.last.trim(), 'refresh-client -A %0:continue');
      expect(c.windows.single.panes['%0']!.paused, isTrue);
      c.onData(utf8.encode('%continue %0\n'));
      final p = c.windows.single.panes['%0']!;
      expect(p.paused, isFalse);
      expect(p.awaitingCapture, isTrue);
      expect(identical(p.terminal, term), isFalse,
          reason: 'a fresh terminal replaces the stale mirror');
    });

    // Hand-written replies for the FIFO: any block number works, replies
    // correlate with commands in send order.
    String block(int n, List<String> lines) =>
        '%begin 1 $n 1\n${lines.map((l) => '$l\n').join()}%end 1 $n 1\n';
    String paneInfo(String id, String win,
            {int w = 80, int h = 24, int cx = 2}) =>
        '$id $w $h $cx 0 0 0 0 0 0 0 ${h - 1} 1 0 0 0 1 0 0 0 0 0 0 1 $win bash';
    int countSent(String prefix) =>
        sent.where((s) => s.startsWith(prefix)).length;

    test('output in the same read as the capture reply is kept, not dropped',
        () async {
      // No %window-add here: it would queue a list-windows that absorbs
      // the hand-written replies below.
      c.onData(utf8.encode(_onePane));
      expect(countSent('display-message -p -t %0'), 1);
      c.onData(utf8.encode(block(1, [paneInfo('%0', '@1', cx: 10)])));
      await pumpEventQueue();
      expect(countSent('capture-pane -p -e -N -t %0'), 1);
      // The reply and two more output lines arrive in ONE network read.
      c.onData(utf8.encode('${block(2, ['\$ captured'])}'
          '%output %0 tail-1\\015\\012\n'
          '%output %0 tail-2\\015\\012\n'));
      await pumpEventQueue();
      final p = c.windows.single.panes['%0']!;
      expect(p.awaitingCapture, isFalse);
      final text = _paneText(c, '@1');
      expect(text, contains('\$ captured'));
      expect(text, contains('tail-1'));
      expect(text, contains('tail-2'));
      expect(text.indexOf('tail-1'), lessThan(text.indexOf('tail-2')));
    });

    test('%window-pane-changed for a window of another session is ignored',
        () {
      c.onData(utf8.encode('%session-changed \$0 main\n%window-add @1\n'));
      c.onData(utf8.encode('%window-pane-changed @7 %9\n'));
      expect(c.windows.map((w) => w.id), ['@1']);
      expect(sent.any((s) => s.contains('%9')), isFalse);
    });

    test('a resync while a capture is in flight abandons the stale capture',
        () async {
      // No %window-add here: it would queue a list-windows that absorbs
      // the hand-written replies below.
      c.onData(utf8.encode(_onePane));
      c.onData(utf8.encode(block(1, [paneInfo('%0', '@1')])));
      await pumpEventQueue();
      expect(countSent('capture-pane'), 1);
      final before = c.windows.single.panes['%0']!.terminal;
      // Not awaited: it completes only once the replies below are fed.
      final resync = c.resyncAll();
      expect(countSent('display-message -p -t %0'), 2,
          reason: 'the resync asks about the pane again');
      final p = c.windows.single.panes['%0']!;
      expect(identical(p.terminal, before), isFalse);
      // The stale capture reply arrives now and must be ignored.
      c.onData(utf8.encode(block(2, ['OLD CONTENT'])));
      await pumpEventQueue();
      expect(p.awaitingCapture, isTrue);
      expect(_paneText(c, '@1'), isNot(contains('OLD')));
      // The resync's own display-message + capture complete normally.
      c.onData(utf8.encode(block(3, [paneInfo('%0', '@1')])));
      await pumpEventQueue();
      expect(countSent('capture-pane'), 2);
      c.onData(utf8.encode(block(4, ['NEW CONTENT'])));
      await pumpEventQueue();
      expect(p.awaitingCapture, isFalse);
      expect(_paneText(c, '@1'), contains('NEW CONTENT'));
      expect(_paneText(c, '@1'), isNot(contains('OLD')));
      await resync;
    });

    test('a layout change during the capture triggers a fresh capture',
        () async {
      // No %window-add here: it would queue a list-windows that absorbs
      // the hand-written replies below.
      c.onData(utf8.encode(_onePane));
      c.onData(utf8.encode(block(1, [paneInfo('%0', '@1')])));
      await pumpEventQueue();
      expect(countSent('capture-pane'), 1);
      // The pane grows to 100x30 before the capture reply lands.
      c.onData(utf8.encode(
          '%layout-change @1 bc62,100x30,0,0,0 bc62,100x30,0,0,0 *\n'));
      c.onData(utf8.encode(block(2, ['stale 80x24 content'])));
      await pumpEventQueue();
      final p = c.windows.single.panes['%0']!;
      expect(p.awaitingCapture, isTrue, reason: 'stale content discarded');
      expect(countSent('display-message -p -t %0'), 2);
      c.onData(utf8.encode(block(3, [paneInfo('%0', '@1', w: 100, h: 30)])));
      await pumpEventQueue();
      expect(countSent('capture-pane'), 2);
      c.onData(utf8.encode(block(4, ['fresh 100x30 content'])));
      await pumpEventQueue();
      expect(p.awaitingCapture, isFalse);
      expect(p.terminal.viewWidth, 100);
      expect(p.terminal.viewHeight, 30);
      expect(_paneText(c, '@1'), contains('fresh 100x30 content'));
      expect(_paneText(c, '@1'), isNot(contains('stale')));
    });

    test('forceExit sends the empty line that detaches a control client', () {
      c.forceExit();
      expect(sent.last, '\n');
    });
  });

  group('argument quoting', () {
    test('single-quotes names and escapes embedded quotes', () {
      expect(TmuxController.quoteArg("it's; kill-server"),
          r"'it'\''s; kill-server'");
    });

    test('strips control characters so a newline cannot end the command',
        () {
      expect(TmuxController.quoteArg('a\nkill-server\x1b[0m'),
          "'akill-server[0m'");
    });

    test('doubles # so format expansion cannot run a shell command', () {
      expect(TmuxController.quoteFormatArg('#(rm -rf ~) #{x}'),
          "'##(rm -rf ~) ##{x}'");
    });

    test('launchCommand attaches by id or creates a named session', () {
      expect(
        TmuxController.launchCommand(attachTarget: r'$3'),
        "sh -c 'PATH=\"\${PATH:-/usr/bin:/bin}:${TmuxController.extraPath}\"; export PATH; "
        "exec tmux -u -CC attach-session -t \\\$3'",
      );
      expect(
        TmuxController.launchCommand(sessionName: 'main'),
        contains('exec tmux -u -CC new-session -A -s "main"\''),
      );
    });

    test('launchCommand drops shell and format metacharacters from a name', () {
      final cmd = TmuxController.launchCommand(
          sessionName: 'x"; rm -rf ~; echo "\$HOME `id` \'#(id)\n');
      // Quotes, backslashes, $, backticks and control characters are gone
      // (not escaped: the outer login shell and the inner sh disagree on
      // escapes), # is doubled so tmux cannot format-expand it.
      expect(cmd, isNot(contains('\n')));
      expect(cmd,
          contains(r'new-session -A -s "x; rm -rf ~; echo HOME id ##(id)"'));
    });

    test('launchCommand rejects an attach target that is not an id', () {
      expect(() => TmuxController.launchCommand(attachTarget: 'main; x'),
          throwsArgumentError);
    });

    test('pane sizes from the host are clamped before a terminal is sized', () {
      expect(TmuxController.clampCols(0), 1);
      expect(TmuxController.clampCols(200), 200);
      expect(TmuxController.clampCols(1 << 30), TmuxController.maxPaneCols);
      expect(TmuxController.clampRows(-5), 1);
      expect(TmuxController.clampRows(1 << 30), TmuxController.maxPaneRows);
    });

    test('killSessionCommand escapes the id like launchCommand and refuses '
        'anything that is not a session id', () {
      expect(TmuxController.killSessionCommand(r'$7'),
          contains(r"tmux kill-session -t \$7 2>&1'"));
      expect(TmuxController.killSessionCommand('main'), isNull);
      expect(TmuxController.killSessionCommand(r'$7; rm -rf ~'), isNull);
      expect(TmuxController.killSessionCommand('@1'), isNull);
    });

    test('management commands validate ids before interpolating them',
        () async {
      final sent = <String>[];
      final c = TmuxController(
          sendBytes: (b) => sent.add(utf8.decode(b)), expectMarker: false);
      expect(await c.closeWindow('@1;kill-server'), isFalse);
      expect(await c.splitPane('%1 x', horizontal: true), isFalse);
      expect(await c.switchSession('main'), isFalse);
      expect(sent, isEmpty);
      c.dispose();
    });
  });

  group('against a scripted tmux', () {
    late FakeTmux tmux;
    late TmuxController c;

    setUp(() {
      tmux = FakeTmux();
      c = TmuxController(sendBytes: tmux.receive, scrollback: 50);
      tmux.controller = c;
    });
    tearDown(() => c.dispose());

    test('attach to an existing session: windows, panes and content are fetched',
        () async {
      final s = tmux.addSession('demo');
      final w0 = tmux.addWindow(s, 'editor',
          history: ['old 1', 'old 2'],
          screen: ['\$ echo hi', 'hi', '\$ '],
          cursorX: 2,
          cursorY: 2);
      tmux.splitRight(w0, screen: ['right pane']);
      tmux.addWindow(s, 'logs', screen: ['in-logs-window']);
      expect(c.phase, TmuxPhase.waiting);
      tmux.attach(s);
      // %session-changed arrives with the attach and starts the sync at once.
      expect(c.phase, TmuxPhase.syncing);
      await settle();

      expect(c.phase, TmuxPhase.ready);
      expect(c.version.toString(), '3.6');
      expect(c.currentSessionName, 'demo');
      expect(c.sessions.single.name, 'demo');
      expect(c.windows.map((w) => w.name), ['editor', 'logs']);
      expect(c.activeWindowId, '@0');
      final editor = c.windows.first;
      expect(editor.panes.keys.toSet(), {'%0', '%1'});
      expect(editor.layout, isA<TmuxSplitNode>());
      final left = editor.panes['%0']!;
      expect(left.awaitingCapture, isFalse);
      expect(left.terminal.viewWidth, 40);
      final text = _bufferText(left.terminal);
      expect(text, contains('old 1'));
      expect(text, contains('\$ echo hi'));
      expect(text, contains('hi'));
      expect(left.terminal.buffer.cursorX, 2);
      expect(left.terminal.buffer.cursorY, 2);
      expect(_bufferText(editor.panes['%1']!.terminal), contains('right pane'));
      expect(_paneText(c, '@1'), contains('in-logs-window'));
      // The first commands: version, then flow control (3.6 supports it).
      expect(tmux.commands.first, 'display-message -p "#{version}"');
      expect(tmux.commands, contains('refresh-client -f pause-after=8'));
    });

    test('a pane still printing when it was listed keeps the lines that scrolled off since',
        () async {
      // The listing saw one line of history; by the capture there are four.
      // (Asking for the listed count restored only the last one.)
      final s = tmux.addSession('demo');
      final w0 = tmux.addWindow(s, 'build',
          history: ['line 1', 'line 2', 'line 3', 'line 4'], screen: ['line 5', '\$ '], cursorX: 2, cursorY: 1);
      tmux.panes[w0.paneIds.single]!.listedHistorySize = 1;
      tmux.attach(s);
      await settle();
      final text = _paneText(c, w0.id);
      for (final line in ['line 1', 'line 2', 'line 3', 'line 4', 'line 5']) {
        expect(text, contains(line));
      }
    });

    test('a fresh session shows its first prompt (output before the capture is in it)',
        () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash', screen: ['\x1b[?2004h\$ ']);
      tmux.attach(s);
      // tmux emits the prompt immediately; we have not asked about the pane.
      tmux.output('%0', utf8.encode('\x1b[?2004h\$ '));
      await settle();
      expect(_paneText(c, '@0'), contains('\$ '));
      expect(_paneText(c, '@0'), isNot(contains('\$ \$ ')),
          reason: 'the early output was not applied twice');
    });

    test('live output after the capture is rendered, including split UTF-8',
        () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      tmux.output('%0', utf8.encode('h'));
      // é split across two %output lines.
      tmux.output('%0', [0xc3]);
      tmux.output('%0', [0xa9, ...utf8.encode(' ✓ 日\r\n')]);
      expect(_paneText(c, '@0'), contains('hé ✓ 日'));
    });

    test('keystrokes reach the pane as bytes and echo back', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.echoKeys = true;
      tmux.attach(s);
      await settle();
      c.windows.single.activeTerminal!.onOutput!('ls\r');
      await settle();
      expect(tmux.typed['%0'], utf8.encode('ls\r'));
      expect(_paneText(c, '@0'), contains('ls'));
    });

    test('the pane terminal does not answer device queries (tmux does)',
        () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      final before = tmux.commands.length;
      tmux.output('%0', utf8.encode('\x1b[c\x1b[6n'));
      await settle();
      expect(tmux.commands.length, before,
          reason: 'no send-keys reply to DA / cursor position requests');
    });

    test('new window: appears in tab order with its pane captured', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      final ok = await c.newWindow(name: 'build');
      expect(ok, isTrue);
      await settle();
      expect(c.windows.map((w) => w.name), ['bash', 'build']);
      expect(c.activeWindowId, '@1');
      final p = c.windows.last.panes.values.single;
      expect(p.awaitingCapture, isFalse);
      expect(_bufferText(p.terminal), contains('\$ '));
      expect(tmux.commands, contains("new-window -n 'build'"));
    });

    test('split and close pane follow the layout notifications', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      await c.splitPane('%0', horizontal: true);
      await settle();
      final w = c.windows.single;
      expect(w.panes.keys.toSet(), {'%0', '%1'});
      expect(w.activePaneId, '%1');
      expect(w.panes['%1']!.awaitingCapture, isFalse);
      expect(w.panes['%1']!.terminal.viewWidth, 39);
      await c.closePane('%1');
      await settle();
      expect(w.panes.keys.toSet(), {'%0'});
      expect(w.activePaneId, '%0');
    });

    test('zoom through tmux', () async {
      final s = tmux.addSession('main');
      final w0 = tmux.addWindow(s, 'bash');
      tmux.splitRight(w0);
      tmux.attach(s);
      await settle();
      await c.toggleZoom('%0');
      await settle();
      final w = c.windows.single;
      expect(w.zoomed, isTrue);
      expect(w.renderLayout!.paneIds, ['%0']);
      await c.toggleZoom('%0');
      await settle();
      expect(w.zoomed, isFalse);
    });

    test('a window created by another client is picked up', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      final w = tmux.addWindow(s, 'remote', screen: ['from elsewhere']);
      tmux.emit('%window-add ${w.id}');
      await settle();
      expect(c.windows.map((w) => w.name), ['bash', 'remote']);
      expect(_paneText(c, w.id), contains('from elsewhere'));
    });

    test('rename with a hostile name is quoted and format-escaped', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      await c.renameWindow('@0', "it's; kill-server #(id)");
      await settle();
      expect(tmux.commands.last, r"rename-window -t @0 'it'\''s; kill-server ##(id)'");
      expect(c.windows.single.name, "it's; kill-server #(id)");
    });

    test('switching sessions rebuilds the model', () async {
      final a = tmux.addSession('alpha');
      tmux.addWindow(a, 'a-win', screen: ['alpha content']);
      final b = tmux.addSession('beta');
      tmux.addWindow(b, 'b-win', screen: ['beta content']);
      tmux.attach(a);
      await settle();
      expect(_paneText(c, '@0'), contains('alpha content'));
      await c.switchSession(b.id);
      await settle();
      expect(c.currentSessionName, 'beta');
      expect(c.windows.map((w) => w.name), ['b-win']);
      expect(_paneText(c, '@1'), contains('beta content'));
    });

    test('new session creates, switches and lists', () async {
      final a = tmux.addSession('alpha');
      tmux.addWindow(a, 'bash');
      tmux.attach(a);
      await settle();
      expect(await c.newSession('deploy'), isTrue);
      await settle();
      expect(c.currentSessionName, 'deploy');
      expect(c.sessions.map((s) => s.name), ['alpha', 'deploy']);
    });

    test('alternate screen is restored with the saved main screen behind it',
        () async {
      final s = tmux.addSession('main');
      final w = tmux.addWindow(s, 'vim',
          history: ['h1'], screen: ['\$ vim', ''], cursorX: 3, cursorY: 5);
      final p = tmux.panes[w.paneIds.single]!
        ..alt = ['~ line 1', '~ line 2']
        ..savedX = 0
        ..savedY = 1
        ..cursorVisible = false
        ..cursorKeys = true
        ..mouseAny = true;
      tmux.attach(s);
      await settle();
      final term = c.windows.single.panes[p.id]!.terminal;
      expect(term.isUsingAltBuffer, isTrue);
      expect(_bufferText(term), contains('~ line 1'));
      expect(_bufferText(term), isNot(contains('\$ vim')));
      expect(term.buffer.cursorX, 3);
      expect(term.buffer.cursorY, 5);
      expect(term.cursorVisibleMode, isFalse);
      expect(term.cursorKeysMode, isTrue);
      expect(term.mouseMode, isNot(MouseMode.none));
      // Leaving the alternate screen reveals the main screen and its history.
      tmux.output(p.id, utf8.encode('\x1b[?1049l'));
      expect(term.isUsingAltBuffer, isFalse);
      final main = _bufferText(term);
      expect(main, contains('h1'));
      expect(main, contains('\$ vim'));
    });

    test('flow control: pause drops output on the server, continue re-captures',
        () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash', screen: ['before']);
      tmux.attach(s);
      await settle();
      final pane = tmux.panes['%0']!;
      // Output produced while paused is dropped by tmux; the screen moves on.
      pane.screen = ['after the pause'];
      tmux.emit('%pause %0');
      await settle();
      expect(tmux.commands, contains('refresh-client -A %0:continue'));
      expect(_paneText(c, '@0'), contains('after the pause'));
      expect(c.windows.single.panes['%0']!.paused, isFalse);
    });

    test('a tmux parse error (stray line) fails only that command', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      final bad = c.run('list-windows -F "#{window_id}');
      // The fake would answer with a guarded block; a real tmux prints a bare
      // line. Simulate that by answering out of band.
      tmux.emit('unterminated quoted string');
      final r = await bad;
      expect(r.error, isTrue);
      expect(r.lines.single, 'unterminated quoted string');
      // The next command still correlates with its own reply.
      final good = await c.run('display-message -p "#{version}"');
      expect(good.error, isFalse);
      expect(good.lines.single, '3.6');
    });

    test('an attach failure surfaces the reason and exits', () async {
      tmux.attachError('no sessions');
      await settle();
      expect(c.exited, isTrue);
      expect(c.phase, TmuxPhase.exited);
      expect(c.exitReason, 'no sessions');
    });

    test('detach ends control mode cleanly', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      var ended = false;
      c.onControlEnd = () => ended = true;
      c.detach();
      await settle();
      expect(c.exited, isTrue);
      expect(c.exitReason, 'detached');
      expect(ended, isTrue);
    });

    test('activity and bell badges on inactive windows', () async {
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.addWindow(s, 'other');
      tmux.attach(s);
      await settle();
      tmux.output('%1', utf8.encode('ping\r\n'));
      expect(c.windows[1].hasActivity, isTrue);
      tmux.output('%1', [0x07]);
      expect(c.windows[1].hasBell, isTrue);
      c.selectWindow('@1');
      expect(c.windows[1].hasActivity, isFalse);
      expect(c.windows[1].hasBell, isFalse);
    });

    test('an old tmux without flow control still syncs', () async {
      tmux = FakeTmux(version: '2.6', flowControl: false);
      c.dispose();
      c = TmuxController(sendBytes: tmux.receive, scrollback: 50);
      tmux.controller = c;
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash', screen: ['legacy']);
      tmux.attach(s);
      await settle();
      expect(c.phase, TmuxPhase.ready);
      expect(c.version.supportsFlowControl, isFalse);
      expect(tmux.commands.any((x) => x.contains('pause-after')), isFalse);
      // capture-pane -N is unknown there: the fallback without it is used.
      expect(_paneText(c, '@0'), contains('legacy'));
    });

    test('in-band: bytes before the marker and after the terminator pass through',
        () async {
      final passed = <int>[];
      c.onPassthrough = (b) => passed.addAll(b);
      tmux.emitRaw(utf8.encode('\$ tmux -CC\r\n'));
      final s = tmux.addSession('main');
      tmux.addWindow(s, 'bash');
      tmux.attach(s);
      await settle();
      expect(utf8.decode(passed), '\$ tmux -CC\r\n');
      expect(c.preControlText, '\$ tmux -CC\r\n');
      c.detach();
      await settle();
      tmux.emitRaw(utf8.encode('\$ '));
      expect(utf8.decode(passed), '\$ tmux -CC\r\n\$ ');
    });
  });
}
