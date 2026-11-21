import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart' show cleanServerText;
import 'package:zestssh/utils/command_text.dart';

/// Where the controller is in the life of a control-mode connection.
enum TmuxPhase {
  /// Bytes are flowing but the `ESC P 1000 p` marker has not been seen.
  waiting,

  /// Control mode started; the attach/new command has not completed yet.
  connecting,

  /// Attached; windows, panes and their content are being fetched.
  syncing,

  /// Fully synced and live.
  ready,

  /// `%exit` arrived (detached, killed, or the attach failed).
  exited,
}

/// A parsed `#{version}`: `3.6`, `3.3a`, `next-3.4`, `openbsd-7.4`.
class TmuxVersion {
  final int major;
  final int minor;

  /// The version string exactly as tmux reported it.
  final String text;
  const TmuxVersion(this.major, this.minor, this.text);

  static const unknown = TmuxVersion(0, 0, '');

  /// The longest reply that is a version; anything longer is none. Each number
  /// is read for at most nine digits: unbounded, a reply of digits took the
  /// pattern back to every digit from every digit (80 KB of them held the app's
  /// only isolate for 3.3 s), and a number too long for an int threw.
  static const int _maxText = 64;

  static final _numbers = RegExp(r'(\d{1,9})\.(\d{1,9})');

  static TmuxVersion parse(String text) {
    if (text.length > _maxText) return unknown;
    final m = _numbers.firstMatch(text);
    if (m == null) return TmuxVersion(0, 0, text);
    return TmuxVersion(int.parse(m.group(1)!), int.parse(m.group(2)!), text);
  }

  bool get isKnown => major > 0;

  bool atLeast(int maj, int min) =>
      major > maj || (major == maj && minor >= min);

  /// `refresh-client -f pause-after`, `%pause`/`%continue`, `-A`.
  bool get supportsFlowControl => atLeast(3, 2);

  @override
  String toString() => text;
}

/// One tmux session on the server, as listed for the picker / switcher.
class TmuxSessionInfo {
  final String id; // "$N"
  final String name;
  final int windows;
  final int attached;
  final DateTime? activity;
  final DateTime? created;
  const TmuxSessionInfo({
    required this.id,
    required this.name,
    required this.windows,
    required this.attached,
    this.activity,
    this.created,
  });
}

/// One tmux pane: a [Terminal] that mirrors the pane's screen.
class TmuxPane {
  final String id; // "%N"
  String windowId;
  Terminal _terminal;
  late ByteConversionSink _decoder;

  /// Output is dropped until the pane's content has been captured; whatever
  /// arrives before that is already in the capture.
  bool awaitingCapture = true;

  /// tmux paused this pane's output (flow control); output is being dropped
  /// on the server until we ask it to continue and then re-capture.
  bool paused = false;

  /// The pane's process exited (remain-on-exit).
  bool dead = false;
  int width = 80;
  int height = 24;
  String title = '';
  int _generation = 0;
  bool _captureInFlight = false;
  int _sizeRetries = 0;
  bool _disposed = false;

  /// Output that arrived after the capture reply was received but before it
  /// was applied (the reply completes on a microtask, output in the same
  /// network read is handled synchronously). Fed once the restore is done.
  bool _bufferOutput = false;
  final BytesBuilder _pendingOutput = BytesBuilder(copy: true);
  bool _pendingOverflow = false;

  /// Cap for [_pendingOutput]; beyond it the pane is re-captured instead.
  static const int maxPendingOutput = 2 * 1024 * 1024;

  TmuxPane._(this.id, this.windowId, this._terminal) {
    _decoder = _decoderFor(this);
  }

  Terminal get terminal => _terminal;
  bool get disposed => _disposed;

  /// Decoded text as it reaches the pane's terminal (the session log taps
  /// this; it sees the same characters the screen does).
  void Function(String text)? onText;

  static ByteConversionSink _decoderFor(TmuxPane p) =>
      const Utf8Decoder(allowMalformed: true)
          .startChunkedConversion(_TerminalSink(p));

  /// Feed raw bytes; decoded per pane so a multi-byte character split across
  /// two `%output` lines still renders.
  void feed(List<int> bytes) {
    if (_disposed || bytes.isEmpty) return;
    _decoder.add(bytes);
  }

  void _resetPending() {
    _bufferOutput = false;
    _pendingOutput.clear();
    _pendingOverflow = false;
  }

  void _dispose() {
    _disposed = true;
    _resetPending();
    _detach(_terminal);
  }

  static void _detach(Terminal t) {
    t.onOutput = null;
    t.onBell = null;
    t.onTitleChange = null;
    t.onPrivateOSC = null;
  }
}

class _TerminalSink implements Sink<String> {
  final TmuxPane pane;
  const _TerminalSink(this.pane);
  @override
  void add(String data) {
    pane._terminal.write(data);
    pane.onText?.call(data);
  }

  @override
  void close() {}
}

/// One tmux window, surfaced as a native tab. A window has one or more panes
/// (a [layout] tree), each with its own [Terminal]; the UI renders the tree.
class TmuxWindow {
  final String id; // e.g. "@2"
  String name;

  /// Position in the session (tab order). Window ids are creation order, not
  /// tab order, so this comes from `#{window_index}`.
  int index;

  /// The full pane geometry tree for this window (null until known).
  TmuxLayoutNode? layout;

  /// What tmux actually shows: differs from [layout] only while a pane is
  /// zoomed (then it is that single pane at full size).
  TmuxLayoutNode? visibleLayout;

  bool zoomed = false;

  /// Raw `#{window_flags}` (`*` current, `-` last, `#` activity, `!` bell,
  /// `~` silence, `Z` zoomed, `M` marked).
  String flags = '';

  /// Output arrived while this was not the active window.
  bool hasActivity = false;

  /// A bell rang while this was not the active window.
  bool hasBell = false;

  /// The focused pane, where keystrokes go.
  String? activePaneId;

  final Map<String, TmuxPane> panes = {};

  TmuxWindow(this.id, this.name, {this.index = 0});

  int get order => index;

  /// One terminal per pane id (a view over [panes]).
  Map<String, Terminal> get paneTerminals =>
      {for (final p in panes.values) p.id: p.terminal};

  TmuxPane? get activePane =>
      activePaneId == null ? null : panes[activePaneId];

  Terminal? get activeTerminal => activePane?.terminal;

  List<String> get paneIds =>
      layout?.paneIds ?? panes.keys.toList(growable: false);

  /// The layout to render: the zoomed pane alone, or the full tree.
  TmuxLayoutNode? get renderLayout => zoomed ? (visibleLayout ?? layout) : layout;
}

class _Pending {
  final String command;
  final Completer<TmuxReply> completer = Completer<TmuxReply>();

  /// Runs synchronously when the reply arrives, before the completer fires
  /// (the future's continuation is a microtask; events in the same chunk are
  /// handled before it runs).
  final void Function(TmuxReply reply)? onReply;
  _Pending(this.command, this.onReply);
}

/// Everything `list-panes` / `display-message` tells us about a pane at one
/// instant, used to restore it into a fresh terminal.
class _PaneInfo {
  final String id;
  final String windowId;
  final int width, height;
  final int cursorX, cursorY;
  final bool alternateOn;
  final int savedX, savedY;
  final int historySize;
  final bool dead;
  final int scrollTop, scrollBottom;
  final bool cursorVisible, insertMode, cursorKeys, keypad, wrap, origin;
  final bool mouseStandard, mouseButton, mouseAny, mouseUtf8, mouseSgr;
  final bool active;
  final String title;

  const _PaneInfo({
    required this.id,
    required this.windowId,
    required this.width,
    required this.height,
    required this.cursorX,
    required this.cursorY,
    required this.alternateOn,
    required this.savedX,
    required this.savedY,
    required this.historySize,
    required this.dead,
    required this.scrollTop,
    required this.scrollBottom,
    required this.cursorVisible,
    required this.insertMode,
    required this.cursorKeys,
    required this.keypad,
    required this.wrap,
    required this.origin,
    required this.mouseStandard,
    required this.mouseButton,
    required this.mouseAny,
    required this.mouseUtf8,
    required this.mouseSgr,
    required this.active,
    required this.title,
  });

  /// Field order of [TmuxController.paneFormat]. The title is last because it
  /// is the only field that can contain spaces.
  static _PaneInfo? parse(String line) {
    final p = line.split(' ');
    if (p.length < 25) return null;
    int n(int i, [int d = 0]) => int.tryParse(p[i]) ?? d;
    bool b(int i) => p[i] == '1';
    return _PaneInfo(
      id: p[0],
      windowId: p[24],
      width: math.max(1, n(1, 80)),
      height: math.max(1, n(2, 24)),
      cursorX: n(3),
      cursorY: n(4),
      alternateOn: b(5),
      savedX: n(6),
      savedY: n(7),
      historySize: n(8),
      dead: b(9),
      scrollTop: n(10),
      scrollBottom: n(11, -1),
      cursorVisible: p[12] == '' ? true : b(12),
      insertMode: b(13),
      cursorKeys: b(14),
      keypad: b(15),
      wrap: p[16] == '' ? true : b(16),
      origin: b(17),
      mouseStandard: b(18),
      mouseButton: b(19),
      mouseAny: b(20),
      mouseUtf8: b(21),
      mouseSgr: b(22),
      active: b(23),
      title: p.length > 25 ? p.sublist(25).join(' ') : '',
    );
  }
}

/// Drives a tmux control-mode (`tmux -CC`) session: consumes the protocol via
/// [TmuxControlParser], keeps one [TmuxWindow] per tmux window with a
/// [Terminal] per pane, routes each pane's output to its terminal, and sends
/// keystrokes, resizes and management commands back through [sendBytes].
///
/// Transport-agnostic (feed [onData], provide a [sendBytes] sink), which also
/// makes it unit-testable with no real connection: the tests drive it with a
/// scripted fake tmux that answers its commands.
///
/// State is never assumed from notifications alone: on attach (and on every
/// session switch) the controller queries sessions, windows, panes and each
/// pane's content, because tmux sends no `%window-add`/`%layout-change` for
/// what already exists. Replies are matched to commands in FIFO order using
/// the flags bit that marks blocks issued by this client.
class TmuxController extends ChangeNotifier {
  TmuxController({
    required this.sendBytes,
    this.scrollback = 5000,
    bool expectMarker = true,
    this.platform = TerminalTargetPlatform.unknown,
    this.pauseAfterSeconds = 8,
    this.log,
  })  : _parser = TmuxControlParser(inband: expectMarker),
        _controlStarted = !expectMarker,
        _phase = expectMarker ? TmuxPhase.waiting : TmuxPhase.connecting;

  /// Writes bytes to the transport (the channel tmux reads its commands from).
  final void Function(List<int> bytes) sendBytes;

  /// Scrollback lines kept per pane, and the most history fetched on attach.
  final int scrollback;

  final TerminalTargetPlatform platform;

  /// Flow control (tmux 3.2+): tmux pauses a pane whose output we are more
  /// than this many seconds behind on, instead of buffering without bound.
  /// 0 disables it.
  final int pauseAfterSeconds;

  /// Diagnostic sink for unhandled notifications and desyncs.
  final void Function(String message)? log;

  /// Bytes that are not control-mode protocol (before the marker, after the
  /// terminator). In-band callers hand them to the normal terminal.
  void Function(Uint8List bytes)? onPassthrough;

  /// Control mode ended and the terminator was consumed: the transport is a
  /// plain shell again.
  VoidCallback? onControlEnd;

  /// A management command failed with a message from tmux (shown to the user).
  void Function(String message)? onError;

  /// A pane rang its bell.
  void Function(TmuxPane pane)? onBell;

  /// A pane emitted an OSC the emulator does not handle itself (OSC 52
  /// clipboard writes reach here: tmux forwards them with `set-clipboard`).
  void Function(String code, List<String> args)? onPrivateOSC;

  /// Decoded output reached a pane's terminal (for the session log).
  void Function(String paneId, String text)? onPaneText;

  /// The person typed into a pane: [data] as it was sent to tmux, [typed]
  /// what they did (a key, text, a paste), to type the same elsewhere.
  void Function(String paneId, String data, TerminalTyped typed)? onPaneTyped;

  final TmuxControlParser _parser;
  final Map<String, TmuxWindow> _windows = {};
  final Map<String, String> _paneToWindow = {};
  final Queue<_Pending> _pending = Queue();
  final List<String> _outbox = [];
  final List<TmuxSessionInfo> _sessions = [];
  final Set<String> _windowSyncs = {};
  final StringBuffer _preControlText = StringBuffer();

  TmuxPhase _phase;
  bool _controlStarted;
  bool _initialised = false;
  bool _sawStartupBlock = false;
  bool _syncedOnce = false;
  bool _exited = false;
  bool _disposed = false;
  bool _dirty = false;
  bool _captureTrailingSpaces = true;
  String? _exitReason;
  String? _startupError;
  String? _activeWindowId;
  String? _currentSessionId;
  String? _currentSessionName;
  String? _lastClientSize;
  int _clientCols = 0;
  int _clientRows = 0;
  int _syncGeneration = 0;
  TmuxVersion _version = TmuxVersion.unknown;
  Timer? _startupFallback;

  // ── Read-only state ──

  TmuxPhase get phase => _phase;
  bool get exited => _exited;
  bool get controlStarted => _controlStarted;
  String? get exitReason => _exitReason ?? _startupError;
  String? get activeWindowId => _activeWindowId;
  String? get currentSessionId => _currentSessionId;
  String? get currentSessionName => _currentSessionName;
  TmuxVersion get version => _version;
  List<TmuxSessionInfo> get sessions => List.unmodifiable(_sessions);

  /// Text that arrived before control mode began (a "command not found" from
  /// the shell, say), for diagnostics when it never begins.
  String get preControlText => _preControlText.toString();

  List<TmuxWindow> get windows {
    final list = _windows.values.toList();
    list.sort((a, b) {
      final c = a.order.compareTo(b.order);
      return c != 0 ? c : _idNumber(a.id).compareTo(_idNumber(b.id));
    });
    return list;
  }

  TmuxWindow? get activeWindow =>
      _activeWindowId == null ? null : _windows[_activeWindowId];

  TmuxWindow? windowOf(String paneId) {
    final wid = _paneToWindow[paneId];
    return wid == null ? null : _windows[wid];
  }

  TmuxPane? pane(String paneId) => windowOf(paneId)?.panes[paneId];

  // ── Formats ──

  /// Space-separated; the name is last because it can contain spaces. Fields
  /// that an old tmux lacks expand to empty strings and keep their slot.
  static const windowFormat =
      '#{window_id} #{window_index} #{window_active} #{window_zoomed_flag} '
      '#{window_layout} #{window_visible_layout} #{window_flags} #{window_name}';

  static const paneFormat =
      '#{pane_id} #{pane_width} #{pane_height} #{cursor_x} #{cursor_y} '
      '#{alternate_on} #{alternate_saved_x} #{alternate_saved_y} '
      '#{history_size} #{pane_dead} #{scroll_region_upper} '
      '#{scroll_region_lower} #{cursor_flag} #{insert_flag} '
      '#{keypad_cursor_flag} #{keypad_flag} #{wrap_flag} #{origin_flag} '
      '#{mouse_standard_flag} #{mouse_button_flag} #{mouse_any_flag} '
      '#{mouse_utf8_flag} #{mouse_sgr_flag} #{pane_active} #{window_id} '
      '#{pane_title}';

  static const sessionFormat =
      '#{session_id} #{session_windows} #{session_attached} '
      '#{session_activity} #{session_created} #{session_name}';

  /// The most of a name or a title a host set that is kept.
  static const int maxNameLength = 120;

  /// A window's or a session's name, or a pane's title, as tmux gave it, as it
  /// is shown in the tabs, the lists and the tooltips: no control characters,
  /// none of the direction overrides or invisible characters that could make
  /// it read other than it is ([cleanServerText]), as a terminal's own title
  /// is. Any program in a pane can set these.
  static String shownName(String name) => cleanServerText(name, maxLength: maxNameLength);

  /// tmux pane/window/session ids are `%<n>` / `@<n>` / `$<n>`. Validate
  /// before interpolating an id into a control-channel command: a malicious or
  /// buggy server could otherwise send a crafted id (containing `;` or
  /// whitespace) that tmux would parse as an extra command.
  static final RegExp _idPattern = RegExp(r'^[%@$][0-9]+$');

  static bool isValidId(String id) => _idPattern.hasMatch(id);
  static bool isPaneId(String id) => id.startsWith('%') && isValidId(id);
  static bool isWindowId(String id) => id.startsWith('@') && isValidId(id);
  static bool isSessionId(String id) => id.startsWith(r'$') && isValidId(id);

  static int _idNumber(String id) =>
      int.tryParse(id.replaceAll(RegExp(r'\D'), '')) ?? 0;

  // ── Argument quoting ──

  /// Single-quote [s] for a tmux command line with control characters
  /// stripped, so a name containing `;`, a quote or a newline cannot become
  /// a second command.
  static String quoteArg(String s) {
    final clean = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    return "'${clean.replaceAll("'", r"'\''")}'";
  }

  /// Like [quoteArg] for arguments tmux expands as formats (window and
  /// session names): `#` is doubled so `#(...)` cannot run a shell command on
  /// the server and `#{...}` is not substituted.
  static String quoteFormatArg(String s) => quoteArg(s.replaceAll('#', '##'));

  /// The command line that starts control mode on the remote side, for the
  /// launcher path (run through `execute`, not typed into a shell). Attaches
  /// to [attachTarget] (a `$N` session id) or creates/attaches [sessionName].
  /// Adds the usual extra install locations to PATH because a non-interactive
  /// login shell often lacks them (Homebrew, /usr/local).
  static String launchCommand({String? attachTarget, String? sessionName}) {
    final String action;
    if (attachTarget != null) {
      if (!isSessionId(attachTarget)) {
        throw ArgumentError.value(attachTarget, 'attachTarget');
      }
      action = 'attach-session -t \\$attachTarget';
    } else {
      action = 'new-session -A -s "${_shellDoubleQuote(sessionName ?? 'main')}"';
    }
    return "sh -c 'PATH=\"\${PATH:-/usr/bin:/bin}:$extraPath\"; export PATH; "
        "exec tmux -u -CC $action'";
  }

  /// The command that lists sessions before attaching (plain exec, no pty).
  static String listSessionsCommand() =>
      "sh -c 'PATH=\"\${PATH:-/usr/bin:/bin}:$extraPath\"; export PATH; "
      'tmux list-sessions -F "$sessionFormat" 2>&1\'';

  /// The command that kills one session from the picker (plain exec, no
  /// pty), by its `$N` id so a renamed session cannot be confused with
  /// another. Null when [sessionId] is not a session id.
  static String? killSessionCommand(String sessionId) {
    if (!isSessionId(sessionId)) return null;
    // Same `\$N` escape as launchCommand: the id must reach tmux literally,
    // not be read as a positional parameter by the sh -c script.
    return "sh -c 'PATH=\"\${PATH:-/usr/bin:/bin}:$extraPath\"; export PATH; "
        "tmux kill-session -t \\$sessionId 2>&1'";
  }

  static const extraPath =
      '/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:/usr/bin:/bin';

  /// Escape for the inside of a double-quoted POSIX sh word that itself sits
  /// inside the single-quoted `sh -c` script: no single quotes can survive,
  /// control characters are dropped, and `#` is doubled for tmux's format
  /// expansion of session names.
  static String _shellDoubleQuote(String s) {
    // Drop rather than escape: the remote login shell parses the outer
    // single quotes and the inner sh parses the double quotes, and their
    // escape rules differ (fish, for one, folds a doubled backslash inside
    // single quotes), so an escaped name can come apart between the two.
    // A name that loses one of these characters was never a usable tmux
    // name anyway.
    return s
        .replaceAll(RegExp(r'[\x00-\x1f\x7f' + "'" + r'"\\$`]'), '')
        .replaceAll('#', '##');
  }

  // ── Transport ──

  /// Type the launch command into a shell on the transport (the in-band way to
  /// start; the launcher uses [launchCommand] with `execute` instead).
  void start({String sessionName = 'zestssh'}) {
    sendBytes(utf8.encode(
        CommandText.entered('tmux -CC new -A -s $sessionName')));
  }

  void onData(List<int> data) {
    if (_disposed) return;
    handleEvents(_parser.addBytes(data));
  }

  /// Feed already-parsed events (the in-band watcher owns the parser then,
  /// because it has to demultiplex the session's byte stream first).
  void handleEvents(Iterable<TmuxEvent> events) {
    if (_disposed) return;
    for (final ev in events) {
      _handle(ev);
    }
    _flushNotify();
  }

  /// The transport closed. Releases held bytes and fails outstanding commands.
  void onTransportClosed() {
    if (_disposed) return;
    for (final ev in _parser.finish()) {
      _handle(ev);
    }
    if (!_exited) {
      _exited = true;
      _phase = TmuxPhase.exited;
      _exitReason ??= _startupError;
      _failAllPending('connection closed');
      _dirty = true;
    }
    _flushNotify();
  }

  void _flushNotify() {
    if (_dirty && !_disposed) {
      _dirty = false;
      notifyListeners();
    }
  }

  /// Tell tmux the client's total size (control mode lays panes out within it).
  /// Deduped so a stream of identical resizes is one command.
  void setClientSize(int cols, int rows) {
    if (_exited || cols <= 0 || rows <= 0) return;
    final size = '$cols,$rows';
    if (size == _lastClientSize) return;
    _lastClientSize = size;
    _clientCols = cols;
    _clientRows = rows;
    run('refresh-client -C $size');
  }

  // ── Command queue ──

  /// Send one tmux command and get its reply. Never throws: a failed or
  /// unanswerable command completes with an error reply. Commands sent before
  /// control mode begins are held and flushed in order once it does.
  Future<TmuxReply> run(String command,
      {void Function(TmuxReply reply)? onReply}) {
    final p = _Pending(command, onReply);
    if (_exited || _disposed) {
      p.completer.complete(
          TmuxReply(-1, true, const ['tmux control mode has ended']));
      return p.completer.future;
    }
    _pending.add(p);
    if (_controlStarted) {
      _write(command);
    } else {
      _outbox.add(command);
    }
    return p.completer.future;
  }

  void _write(String command) {
    sendBytes(utf8.encode('$command\n'));
  }

  void _failAllPending(String reason) {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completer.complete(TmuxReply(-1, true, [reason]));
    }
    _outbox.clear();
  }

  /// Run a user-initiated management command; a failure is reported through
  /// [onError] instead of being silently dropped.
  Future<bool> _runUser(String command) async {
    final r = await run(command);
    if (r.error) {
      final msg = r.lines.join('\n').trim();
      if (msg.isNotEmpty) onError?.call(msg);
      return false;
    }
    return true;
  }

  // ── Event handling ──

  void _handle(TmuxEvent ev) {
    switch (ev) {
      case TmuxPassthrough(:final data):
        if (!_controlStarted && _preControlText.length < 8192) {
          _preControlText.write(utf8.decode(data, allowMalformed: true));
        }
        onPassthrough?.call(data);
      case TmuxControlBegin():
        _onControlStarted();
      case TmuxMarkerHeld():
        // (A parser told to hold at the marker is the watcher's: not this one.)
        break;
      case TmuxControlEnd():
        onControlEnd?.call();
      case TmuxReply():
        _onReply(ev);
      case TmuxStrayLine(:final line):
        // tmux could not parse a command: no guarded block follows, so the
        // head of the queue is the command it belongs to.
        if (_pending.isNotEmpty) {
          _pending.removeFirst().completer.complete(TmuxReply(-1, true, [line]));
        } else {
          log?.call('tmux: stray line: $line');
        }
      case TmuxOutput(:final paneId, :final data):
        _routeOutput(paneId, data);
      case TmuxPause(:final paneId):
        final p = pane(paneId);
        if (p != null) p.paused = true;
        if (isPaneId(paneId)) run('refresh-client -A $paneId:continue');
      case TmuxContinue(:final paneId):
        final p = pane(paneId);
        if (p != null) {
          p.paused = false;
          _resyncPane(p);
        }
      case TmuxWindowAdd(:final windowId):
        if (!isWindowId(windowId)) return;
        if (_ensureWindow(windowId) == null) return;
        _syncWindow(windowId);
        _dirty = true;
      case TmuxWindowClose(:final windowId):
        _removeWindow(windowId);
      case TmuxWindowRenamed(:final windowId, :final name):
        if (!isWindowId(windowId)) return;
        _ensureWindow(windowId)?.name = shownName(name);
        _dirty = true;
      case TmuxWindowPaneChanged(:final windowId, :final paneId):
        // tmux sends this for windows of EVERY session; a window of ours is
        // always learned first through %window-add, %session-window-changed
        // or list-windows, so an unknown one belongs to another session.
        final w = _windows[windowId];
        if (w == null) return;
        // The pane object is created even for an id that fails validation so
        // the model reflects the server; every command path validates the id
        // again before interpolating it.
        if (_ensurePane(w, paneId) != null) w.activePaneId = paneId;
        _dirty = true;
      case TmuxLayoutChange(
          :final windowId,
          :final layout,
          :final paneIds,
          :final visibleLayout,
          :final flags
        ):
        if (!isWindowId(windowId)) return;
        final w = _ensureWindow(windowId);
        if (w == null) return;
        _applyLayout(w, layout, visibleLayout, flags, paneIds);
      case TmuxSessionChanged(:final sessionId, :final name):
        _onSessionChanged(sessionId, name);
      case TmuxSessionRenamed(:final sessionId, :final name):
        if (sessionId == _currentSessionId) _currentSessionName = shownName(name);
        _refreshSessions();
        _dirty = true;
      case TmuxSessionWindowChanged(:final sessionId, :final windowId):
        if (sessionId != _currentSessionId || !isWindowId(windowId)) return;
        if (!_windows.containsKey(windowId)) {
          if (_ensureWindow(windowId) == null) return;
          _syncWindow(windowId);
        }
        _setActiveWindow(windowId);
      case TmuxSessionsChanged():
        _refreshSessions();
      case TmuxExit(:final reason):
        _exited = true;
        _phase = TmuxPhase.exited;
        _exitReason = reason ?? _startupError;
        _startupFallback?.cancel();
        _failAllPending('tmux exited');
        _dirty = true;
      case TmuxPaneModeChanged():
        break;
      case TmuxUnhandled(:final line):
        log?.call('tmux: unhandled: $line');
    }
  }

  void _onControlStarted() {
    if (_initialised) return;
    _initialised = true;
    _controlStarted = true;
    _phase = TmuxPhase.connecting;
    _dirty = true;
    final queued = List.of(_outbox);
    _outbox.clear();
    for (final c in queued) {
      _write(c);
    }
    _queryVersion();
    if (_lastClientSize != null) run('refresh-client -C $_lastClientSize');
    // tmux announces the session with %session-changed on attach; if a build
    // ever does not, sync anyway once the startup block is done.
    _startupFallback = Timer(const Duration(seconds: 2), () {
      if (!_syncedOnce && !_exited && !_disposed && _sawStartupBlock) {
        _resyncSession();
      }
    });
  }

  Future<void> _queryVersion() async {
    final r = await run('display-message -p "#{version}"');
    if (!r.error && r.lines.isNotEmpty) {
      _version = TmuxVersion.parse(r.lines.first.trim());
    }
    if (_version.supportsFlowControl && pauseAfterSeconds > 0) {
      run('refresh-client -f pause-after=$pauseAfterSeconds');
    }
  }

  void _onReply(TmuxReply r) {
    if (!r.issuedByThisClient) {
      // The attach/new command's own block, or a hook run for this client.
      if (!_sawStartupBlock) {
        _sawStartupBlock = true;
        if (r.error) {
          _startupError = r.lines.join('\n').trim();
        }
      }
      return;
    }
    if (_pending.isEmpty) {
      log?.call('tmux: reply #${r.number} with no command outstanding');
      return;
    }
    final p = _pending.removeFirst();
    p.onReply?.call(r);
    p.completer.complete(r);
  }

  void _onSessionChanged(String sessionId, String name) {
    if (!isSessionId(sessionId)) return;
    final changed = sessionId != _currentSessionId;
    _currentSessionId = sessionId;
    _currentSessionName = shownName(name);
    if (changed) {
      for (final w in _windows.values) {
        _disposeWindow(w);
      }
      _windows.clear();
      _paneToWindow.clear();
      _activeWindowId = null;
    }
    _dirty = true;
    _resyncSession();
  }

  // ── Output routing ──

  void _routeOutput(String paneId, List<int> data) {
    final w = windowOf(paneId);
    final p = w?.panes[paneId];
    if (w == null || p == null || data.isEmpty) return;
    if (p.awaitingCapture) {
      if (!p._bufferOutput) {
        // Before the capture reply: these bytes are in the capture.
        return;
      }
      // After the capture reply but before it is applied: keep them, in
      // order, for after the restore.
      if (p._pendingOutput.length + data.length > TmuxPane.maxPendingOutput) {
        p._pendingOverflow = true;
        return;
      }
      p._pendingOutput.add(data);
      return;
    }
    p.feed(data);
    if (w.id != _activeWindowId && !w.hasActivity) {
      w.hasActivity = true;
      _dirty = true;
    }
  }

  // ── Model maintenance ──

  /// The window [id], made if it is new and there is room ([maxWindows]).
  TmuxWindow? _ensureWindow(String id) {
    final known = _windows[id];
    if (known != null) return known;
    if (_windows.length >= maxWindows) return null;
    _activeWindowId ??= id;
    _dirty = true;
    return _windows[id] = TmuxWindow(id, id.replaceAll('@', 'window '), index: _idNumber(id));
  }

  /// Total panes we will mirror. A misbehaving server could otherwise make us
  /// allocate a terminal per fabricated id without bound.
  static const int maxPanes = 512;

  /// Total windows we will show. Each is a tab, and a window has a pane at
  /// least, so a session past [maxPanes] windows could not be shown anyway;
  /// a misbehaving server named them without bound, one more per line.
  static const int maxWindows = 512;

  /// Bounds on a pane size accepted from the host. tmux itself never reports
  /// a pane larger than the client we told it about, so anything past this
  /// is a hostile or broken stream; a terminal buffer is cols x rows cells,
  /// and an unclamped size from the wire would let a server allocate the
  /// app out of memory.
  static const int maxPaneCols = 1024;
  static const int maxPaneRows = 512;

  static int clampCols(int cols) => cols.clamp(1, maxPaneCols);
  static int clampRows(int rows) => rows.clamp(1, maxPaneRows);

  /// Create the pane object if needed. A pane that has not been captured yet
  /// is captured right away unless the caller is about to do so itself with
  /// fuller information ([sync] false).
  TmuxPane? _ensurePane(TmuxWindow w, String paneId, {bool sync = true}) {
    var p = w.panes[paneId];
    if (p == null) {
      // A pane can move between windows (break-pane / join-pane): adopt it
      // instead of losing its terminal.
      for (final other in _windows.values) {
        final moved = other.panes.remove(paneId);
        if (moved != null) {
          p = moved;
          break;
        }
      }
    }
    if (p == null) {
      if (_paneToWindow.length >= maxPanes) return null;
      p = TmuxPane._(paneId, w.id, _newTerminal(paneId));
      p.onText = (text) => onPaneText?.call(paneId, text);
    }
    p.windowId = w.id;
    w.panes[paneId] = p;
    _paneToWindow[paneId] = w.id;
    w.activePaneId ??= paneId;
    _dirty = true;
    if (sync && p.awaitingCapture && !p._captureInFlight) _syncPane(p);
    return p;
  }

  Terminal _newTerminal(String paneId) {
    final t = Terminal(maxLines: scrollback, platform: platform);
    // tmux answers the pane's own queries (device attributes, cursor
    // position); a second answer from us would reach the program as input.
    t.respondToQueries = false;
    // Keys for a pane go to THAT pane. Resize is driven by the whole client
    // (setClientSize) and the layout tmux reports, so no onResize wiring.
    t.onOutput = (data) {
      _sendKeys(paneId, data);
      // What the person typed (not the mouse: the mouse carries nothing
      // typed) is the session's to hand on: a tab that broadcasts types it
      // into its other terminals.
      final typed = t.outputTyped;
      if (typed != null) onPaneTyped?.call(paneId, data, typed);
    };
    t.onBell = () {
      final p = pane(paneId);
      if (p == null) return;
      final w = _windows[p.windowId];
      if (w != null && w.id != _activeWindowId) {
        w.hasBell = true;
        _dirty = true;
        _flushNotify();
      }
      onBell?.call(p);
    };
    t.onTitleChange = (raw) {
      final title = shownName(raw);
      final p = pane(paneId);
      if (p == null || p.title == title) return;
      // The tab label for an idle shell comes from the title the prompt
      // sets (user@host: ~/dir), so a change is worth a repaint.
      p.title = title;
      _dirty = true;
      _flushNotify();
    };
    t.onPrivateOSC = (code, args) => onPrivateOSC?.call(code, args);
    t.onWriteError = (error, _) => log?.call('tmux: a code in pane $paneId was passed over: $error');
    return t;
  }

  void _removeWindow(String windowId) {
    final w = _windows.remove(windowId);
    if (w != null) _disposeWindow(w);
    _paneToWindow.removeWhere((_, v) => v == windowId);
    if (_activeWindowId == windowId) {
      _activeWindowId = _windows.isEmpty ? null : windows.first.id;
    }
    _dirty = true;
  }

  void _disposeWindow(TmuxWindow w) {
    for (final p in w.panes.values) {
      p._dispose();
    }
    w.panes.clear();
  }

  void _setActiveWindow(String windowId) {
    if (_activeWindowId == windowId) return;
    _activeWindowId = windowId;
    final w = _windows[windowId];
    if (w != null) {
      w.hasActivity = false;
      w.hasBell = false;
    }
    _dirty = true;
  }

  void _applyLayout(TmuxWindow w, String layout, String? visibleLayout,
      String flags, List<String> fallbackIds) {
    final tree = parseTmuxLayoutTree(layout);
    w.layout = tree;
    w.flags = flags;
    w.zoomed = flags.contains('Z');
    w.visibleLayout = visibleLayout == null || visibleLayout == layout
        ? null
        : parseTmuxLayoutTree(visibleLayout);
    if (!w.zoomed) w.visibleLayout = null;
    final ids = tree?.paneIds ?? fallbackIds;
    for (final id in ids) {
      _ensurePane(w, id);
    }
    // Prune terminals for panes that left the layout (a pane was closed or
    // moved away).
    final keep = ids.toSet();
    final gone = w.panes.keys.where((p) => !keep.contains(p)).toList();
    for (final id in gone) {
      w.panes.remove(id)?._dispose();
      if (_paneToWindow[id] == w.id) _paneToWindow.remove(id);
    }
    _applyPaneSizes(w);
    if (w.activePaneId == null || !keep.contains(w.activePaneId)) {
      w.activePaneId = ids.isNotEmpty ? ids.first : null;
    }
    _dirty = true;
  }

  /// Resize each pane's terminal to what the layout says. The zoomed pane's
  /// real size is in the visible layout; the full layout keeps the geometry
  /// it will return to.
  /// The size the window's layout gives [p] now (its zoomed layout where the
  /// window is zoomed), as a pane's terminal takes it; null while the layout
  /// does not know the pane.
  (int, int)? _layoutSizeOf(TmuxPane p) {
    final w = _windows[p.windowId];
    if (w == null) return null;
    TmuxPaneNode? leaf;
    for (final l in w.layout?.leaves ?? const <TmuxPaneNode>[]) {
      if (l.paneId == p.id) leaf = l;
    }
    if (w.zoomed) {
      for (final l in w.visibleLayout?.leaves ?? const <TmuxPaneNode>[]) {
        if (l.paneId == p.id) leaf = l;
      }
    }
    if (leaf == null || leaf.width <= 0 || leaf.height <= 0) return null;
    return (clampCols(leaf.width), clampRows(leaf.height));
  }

  void _applyPaneSizes(TmuxWindow w) {
    final sizes = <String, (int, int)>{};
    for (final leaf in w.layout?.leaves ?? const <TmuxPaneNode>[]) {
      sizes[leaf.paneId] = (leaf.width, leaf.height);
    }
    if (w.zoomed) {
      for (final leaf in w.visibleLayout?.leaves ?? const <TmuxPaneNode>[]) {
        sizes[leaf.paneId] = (leaf.width, leaf.height);
      }
    }
    for (final entry in sizes.entries) {
      final p = w.panes[entry.key];
      if (p == null) continue;
      final (rawCols, rawRows) = entry.value;
      if (rawCols <= 0 || rawRows <= 0) continue;
      final cols = clampCols(rawCols);
      final rows = clampRows(rawRows);
      p.width = cols;
      p.height = rows;
      if (!p.awaitingCapture &&
          (p.terminal.viewWidth != cols || p.terminal.viewHeight != rows)) {
        p.terminal.resize(cols, rows);
      }
    }
  }

  // ── Sync ──

  Future<void> _refreshSessions() async {
    final r = await run('list-sessions -F "$sessionFormat"');
    if (r.error || _disposed) return;
    _sessions
      ..clear()
      ..addAll(r.lines.map(_parseSession).whereType<TmuxSessionInfo>());
    _dirty = true;
    _flushNotify();
  }

  static TmuxSessionInfo? _parseSession(String line) {
    final p = line.split(' ');
    if (p.length < 6 || !isSessionId(p[0])) return null;
    DateTime? ts(String s) {
      final n = int.tryParse(s);
      return n == null || n <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(n * 1000);
    }

    return TmuxSessionInfo(
      id: p[0],
      name: shownName(p.sublist(5).join(' ')),
      windows: int.tryParse(p[1]) ?? 0,
      attached: int.tryParse(p[2]) ?? 0,
      activity: ts(p[3]),
      created: ts(p[4]),
    );
  }

  /// Full sync of the current session: windows, panes and their content.
  Future<void> _resyncSession() async {
    final gen = ++_syncGeneration;
    _syncedOnce = true;
    _phase = TmuxPhase.syncing;
    _dirty = true;
    _flushNotify();
    _refreshSessions();
    if (!await _syncWindowList()) return;
    if (gen != _syncGeneration || _exited || _disposed) return;
    final infos = await _listPanes(null);
    if (gen != _syncGeneration || _exited || _disposed) return;
    await Future.wait(_applyPaneList(infos, allWindows: true));
    if (gen != _syncGeneration || _exited || _disposed) return;
    _phase = TmuxPhase.ready;
    _dirty = true;
    _flushNotify();
  }

  /// A window appeared (or tmux switched to one we do not know): learn its
  /// place in the tab order and its panes.
  Future<void> _syncWindow(String windowId) async {
    // %session-window-changed and %window-add arrive back to back for one
    // new window; one sync covers both.
    if (!_windowSyncs.add(windowId)) return;
    try {
      if (!await _syncWindowList()) return;
      if (!_windows.containsKey(windowId)) return;
      final infos = await _listPanes(windowId);
      if (_exited || _disposed) return;
      await Future.wait(_applyPaneList(infos, allWindows: false));
      _dirty = true;
      _flushNotify();
    } finally {
      _windowSyncs.remove(windowId);
    }
  }

  Future<bool> _syncWindowList() async {
    final r = await run('list-windows -F "$windowFormat"');
    if (r.error || _exited || _disposed) return false;
    final seen = <String>{};
    for (final line in r.lines) {
      final p = line.split(' ');
      if (p.length < 7 || !isWindowId(p[0])) continue;
      final id = p[0];
      seen.add(id);
      final w = _ensureWindow(id);
      if (w == null) continue;
      w.index = int.tryParse(p[1]) ?? w.index;
      w.name = p.length > 7 ? shownName(p.sublist(7).join(' ')) : '';
      final layout = p[4];
      final visible = p[5].isEmpty ? null : p[5];
      final flags = p[6] + (p[3] == '1' && !p[6].contains('Z') ? 'Z' : '');
      if (layout.isNotEmpty) {
        _applyLayoutSilently(w, layout, visible, flags);
      }
      if (p[2] == '1') _setActiveWindow(id);
    }
    for (final id in _windows.keys.where((k) => !seen.contains(k)).toList()) {
      _removeWindow(id);
    }
    _dirty = true;
    return true;
  }

  /// Layout from a listing: geometry only, no per-pane capture (the caller is
  /// about to list panes with full information).
  void _applyLayoutSilently(
      TmuxWindow w, String layout, String? visible, String flags) {
    final tree = parseTmuxLayoutTree(layout);
    w.layout = tree;
    w.flags = flags;
    w.zoomed = flags.contains('Z');
    w.visibleLayout =
        w.zoomed && visible != null ? parseTmuxLayoutTree(visible) : null;
    for (final id in tree?.paneIds ?? const <String>[]) {
      _ensurePane(w, id, sync: false);
    }
    _applyPaneSizes(w);
  }

  Future<List<_PaneInfo>> _listPanes(String? windowId) async {
    final target = windowId == null ? '-s' : '-t $windowId';
    final r = await run('list-panes $target -F "$paneFormat"');
    if (r.error) return const [];
    return r.lines.map(_PaneInfo.parse).whereType<_PaneInfo>().toList();
  }

  /// Apply a pane listing: create missing panes, drop stale ones, start a
  /// capture for every pane that has not been captured yet. Returns the
  /// captures so the caller can await them.
  List<Future<void>> _applyPaneList(List<_PaneInfo> infos,
      {required bool allWindows}) {
    final captures = <Future<void>>[];
    final seen = <String, Set<String>>{};
    for (final info in infos) {
      if (!isPaneId(info.id) || !isWindowId(info.windowId)) continue;
      final w = _ensureWindow(info.windowId);
      if (w == null) continue;
      seen.putIfAbsent(w.id, () => {}).add(info.id);
      final p = _ensurePane(w, info.id, sync: false);
      if (p == null) continue;
      p.title = shownName(info.title);
      p.dead = info.dead;
      if (info.active) w.activePaneId = info.id;
      if (p.awaitingCapture && !p._captureInFlight) {
        captures.add(_capturePane(p, info));
      }
    }
    // Panes missing from the listing are gone.
    final windowsToCheck =
        allWindows ? _windows.values.toList() : seen.keys.map((k) => _windows[k]!);
    for (final w in windowsToCheck) {
      final keep = seen[w.id] ?? const <String>{};
      for (final id in w.panes.keys.where((k) => !keep.contains(k)).toList()) {
        w.panes.remove(id)?._dispose();
        if (_paneToWindow[id] == w.id) _paneToWindow.remove(id);
      }
      if (w.activePaneId != null && !w.panes.containsKey(w.activePaneId)) {
        w.activePaneId = w.panes.keys.isEmpty ? null : w.panes.keys.first;
      }
    }
    _dirty = true;
    return captures;
  }

  /// A pane we only learned of from a notification: ask tmux about it, then
  /// capture it.
  Future<void> _syncPane(TmuxPane p) async {
    if (!isPaneId(p.id) || p._captureInFlight) return;
    p._captureInFlight = true;
    _PaneInfo? info;
    try {
      final r = await run('display-message -p -t ${p.id} "$paneFormat"');
      if (r.error || p.disposed || _exited || _disposed) return;
      info = r.lines.isEmpty ? null : _PaneInfo.parse(r.lines.first);
      if (info == null) return;
      p.title = shownName(info.title);
      p.dead = info.dead;
    } finally {
      p._captureInFlight = false;
    }
    await _capturePane(p, info);
    _flushNotify();
  }

  /// Throw the pane's terminal away and capture it again (after tmux dropped
  /// output while paused, or on a user-requested resync). A capture already
  /// in flight is abandoned: its generation no longer matches.
  Future<void> _resyncPane(TmuxPane p) async {
    if (p.disposed) return;
    p._generation++;
    p._captureInFlight = false;
    p._sizeRetries = 0;
    p._resetPending();
    p.awaitingCapture = true;
    TmuxPane._detach(p._terminal);
    p._terminal = _newTerminal(p.id);
    p._decoder = TmuxPane._decoderFor(p);
    _dirty = true;
    await _syncPane(p);
  }

  /// Fetch a pane's history and screen (and alternate screen) and restore
  /// them into its terminal, then place the cursor and re-apply its modes.
  ///
  /// Output ordering: everything tmux sent before the capture reply is in the
  /// capture and is dropped; everything after the reply line (which can share
  /// a network read with it) is buffered by [_routeOutput] from the moment
  /// the reply arrives and fed after the restore; then the pane is live.
  Future<void> _capturePane(TmuxPane p, _PaneInfo info) async {
    if (!isPaneId(p.id) || p._captureInFlight) return;
    p._captureInFlight = true;
    final gen = ++p._generation;
    p._resetPending();
    try {
      final t = p.terminal;
      final cols = clampCols(info.width);
      final rows = clampRows(info.height);
      // The layout already says another size than [info] does: a layout
      // change came in the same read as the reply that carried [info]
      // (a reply's continuation runs after everything in its read), so the
      // snapshot is the older of the two. A new session starts at 80 by 24
      // and is sized to the app's panes in the middle of this first sync, so
      // that was its usual order: the old size was written back over the
      // new one, the check below saw no change, and the pane was restored
      // 80 by 24 in a smaller view, its prompt above what the view showed
      // (a new session's pane stayed blank; 21 November 2026). Asked again.
      final laidOut = _layoutSizeOf(p);
      if (laidOut != null && (laidOut.$1 != cols || laidOut.$2 != rows) && p._sizeRetries < 2) {
        p._sizeRetries++;
        p._generation++; // the finally below must not touch the flag
        p._captureInFlight = false;
        p._resetPending();
        unawaited(_syncPane(p));
        return;
      }
      p.width = cols;
      p.height = rows;
      if (t.viewWidth != cols || t.viewHeight != rows) {
        t.resize(cols, rows);
      }
      final id = p.id;
      final wantHistory = math.min(info.historySize, scrollback);
      List<String> main;
      List<String>? alt;
      if (info.alternateOn) {
        // History is frozen while the alternate screen is on (tmux turns the
        // grid's history off), so three commands have no seam between them.
        var history = const <String>[];
        if (wantHistory > 0) {
          final r =
              await run('capture-pane -p -e -t $id -S -$wantHistory -E -1');
          if (gen != p._generation || p.disposed || _disposed) return;
          if (!r.error) history = r.lines;
        }
        final saved = await run('capture-pane -p -e -a -q -t $id');
        if (gen != p._generation || p.disposed || _disposed) return;
        main = [...history, ...saved.lines];
        alt = await _captureScreen(p);
      } else {
        // One command for history plus screen: no line can scroll off
        // between two captures. All the scrollback this mirror keeps is
        // asked for, not the history size [info] reported: a pane still
        // printing has more history by now than when it was listed, and
        // asking for the listed count left out the lines that scrolled off
        // in between (tmux stops at the top of what it has).
        main = await _captureScreen(p, history: scrollback) ?? const [];
      }
      if (gen != p._generation || p.disposed || _disposed) return;
      // A layout change landed while capturing: the content has the new
      // geometry but the info snapshot has the old one. Capture again.
      if ((p.width != info.width || p.height != info.height) &&
          p._sizeRetries < 2) {
        p._sizeRetries++;
        p._generation++; // the finally below must not touch the flag
        p._captureInFlight = false;
        p._resetPending();
        unawaited(_syncPane(p));
        return;
      }
      _restorePane(p, info, main, alt);
      p._sizeRetries = 0;
      final overflow = p._pendingOverflow;
      final pending = p._pendingOutput.takeBytes();
      p._resetPending();
      p.awaitingCapture = false;
      // The size the layout has now, where a change was passed over while
      // the capture ran ([_applyPaneSizes] leaves a pane that awaits its
      // capture alone).
      final laidOutNow = _windows[p.windowId];
      if (laidOutNow != null) _applyPaneSizes(laidOutNow);
      if (overflow) {
        // Too much arrived in between to replay faithfully: start over.
        unawaited(_resyncPane(p));
      } else if (pending.isNotEmpty) {
        p.feed(pending);
      }
      _dirty = true;
    } catch (e) {
      log?.call('tmux: capture of ${p.id} failed: $e');
      // Go live anyway rather than mirror a blank pane forever.
      if (gen == p._generation && !p.disposed) {
        p._resetPending();
        p.awaitingCapture = false;
      }
    } finally {
      if (gen == p._generation) p._captureInFlight = false;
    }
  }

  /// The final capture of a pane: its screen, optionally preceded by
  /// [history] lines of scrollback in the same reply. From the moment this
  /// reply arrives, output for the pane is buffered rather than dropped.
  Future<List<String>?> _captureScreen(TmuxPane p, {int history = 0}) async {
    final range = history > 0 ? ' -S -$history' : '';
    void hook(TmuxReply r) {
      if (!r.error) p._bufferOutput = true;
    }

    if (_captureTrailingSpaces) {
      final r =
          await run('capture-pane -p -e -N -t ${p.id}$range', onReply: hook);
      if (!r.error) return r.lines;
      // Old tmux: -N unknown.
      if (r.lines.any((l) => l.contains('usage'))) {
        _captureTrailingSpaces = false;
      } else {
        return null;
      }
    }
    final r = await run('capture-pane -p -e -t ${p.id}$range', onReply: hook);
    return r.error ? null : r.lines;
  }

  void _restorePane(
      TmuxPane p, _PaneInfo info, List<String> main, List<String>? alt) {
    final sb = StringBuffer();
    // History then the (saved) main screen. Lines are separated, not
    // terminated, so the last one does not scroll the screen.
    sb.write(main.join('\r\n'));
    if (alt != null) {
      sb.write('\x1b[${info.savedY + 1};${info.savedX + 1}H');
      sb.write('\x1b[?1049h');
      sb.write(alt.join('\r\n'));
    }
    // Scroll margins belong to the screen that is showing (they are per
    // buffer), and go before the cursor placement because DECSTBM homes the
    // cursor on a real terminal.
    if (info.scrollBottom >= 0 &&
        (info.scrollTop > 0 || info.scrollBottom < info.height - 1)) {
      sb.write('\x1b[${info.scrollTop + 1};${info.scrollBottom + 1}r');
    }
    sb.write('\x1b[${info.cursorY + 1};${info.cursorX + 1}H');
    if (!info.cursorVisible) sb.write('\x1b[?25l');
    if (info.insertMode) sb.write('\x1b[4h');
    if (info.cursorKeys) sb.write('\x1b[?1h');
    if (info.keypad) sb.write('\x1b=');
    if (!info.wrap) sb.write('\x1b[?7l');
    if (info.origin) sb.write('\x1b[?6h');
    if (info.mouseAny) {
      sb.write('\x1b[?1003h');
    } else if (info.mouseButton) {
      sb.write('\x1b[?1002h');
    } else if (info.mouseStandard) {
      sb.write('\x1b[?1000h');
    }
    if (info.mouseUtf8) sb.write('\x1b[?1005h');
    if (info.mouseSgr) sb.write('\x1b[?1006h');
    p.terminal.write(sb.toString());
  }

  // ── Input ──

  /// Keystrokes travel as `send-keys -H` hex bytes, chunked so a large paste
  /// does not become one enormous command line.
  void _sendKeys(String paneId, String data) {
    if (_exited || !isPaneId(paneId) || data.isEmpty) return;
    final bytes = utf8.encode(data);
    const chunk = 512;
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = math.min(bytes.length, i + chunk);
      final hex = [
        for (var j = i; j < end; j++) bytes[j].toRadixString(16).padLeft(2, '0')
      ].join(' ');
      run('send-keys -t $paneId -H $hex');
    }
  }

  /// Send text to a pane as if typed (used by the UI for pastes and snippets).
  void sendText(String paneId, String text) => _sendKeys(paneId, text);

  // ── Management API ──

  /// Focus a window: local state first so the UI is instant, then tmux, which
  /// echoes %session-window-changed.
  void selectWindow(String windowId) {
    if (!_windows.containsKey(windowId) || !isWindowId(windowId)) return;
    if (_activeWindowId != windowId) {
      _setActiveWindow(windowId);
      _flushNotify();
    }
    _runUser('select-window -t $windowId');
  }

  void selectNextWindow() => _selectRelative(1);
  void selectPreviousWindow() => _selectRelative(-1);

  void _selectRelative(int delta) {
    final list = windows;
    if (list.isEmpty || _activeWindowId == null) return;
    final i = list.indexWhere((w) => w.id == _activeWindowId);
    if (i < 0) return;
    selectWindow(list[(i + delta) % list.length].id);
  }

  /// Focus a pane within a window: routes keys there and tells tmux, so the two
  /// stay in agreement.
  void selectPane(String windowId, String paneId) {
    final w = _windows[windowId];
    if (w == null || !w.panes.containsKey(paneId)) return;
    if (w.activePaneId == paneId) return;
    w.activePaneId = paneId;
    if (isPaneId(paneId)) _runUser('select-pane -t $paneId');
    _dirty = true;
    _flushNotify();
  }

  Future<bool> newWindow({String? name}) => _runUser(
      'new-window${name == null || name.isEmpty ? '' : ' -n ${quoteFormatArg(name)}'}');

  Future<bool> closeWindow(String windowId) =>
      isWindowId(windowId) ? _runUser('kill-window -t $windowId') : Future.value(false);

  Future<bool> renameWindow(String windowId, String name) =>
      isWindowId(windowId) && name.isNotEmpty
          ? _runUser('rename-window -t $windowId ${quoteFormatArg(name)}')
          : Future.value(false);

  /// Move a window to tab position [index] (a `#{window_index}` slot).
  Future<bool> moveWindow(String windowId, int index) =>
      isWindowId(windowId) && index >= 0
          ? _runUser('move-window -s $windowId -t :$index')
          : Future.value(false);

  /// Swap two windows' positions.
  Future<bool> swapWindows(String a, String b) => isWindowId(a) && isWindowId(b)
      ? _runUser('swap-window -s $a -t $b')
      : Future.value(false);

  Future<bool> splitPane(String paneId, {required bool horizontal}) =>
      isPaneId(paneId)
          ? _runUser('split-window -t $paneId ${horizontal ? '-h' : '-v'}')
          : Future.value(false);

  Future<bool> closePane(String paneId) =>
      isPaneId(paneId) ? _runUser('kill-pane -t $paneId') : Future.value(false);

  Future<bool> toggleZoom(String paneId) =>
      isPaneId(paneId) ? _runUser('resize-pane -Z -t $paneId') : Future.value(false);

  /// Resize a pane to an absolute size in cells (either dimension optional).
  Future<bool> resizePane(String paneId, {int? width, int? height}) {
    if (!isPaneId(paneId) || (width == null && height == null)) {
      return Future.value(false);
    }
    final args = [
      if (width != null && width > 0) '-x $width',
      if (height != null && height > 0) '-y $height',
    ].join(' ');
    return _runUser('resize-pane -t $paneId $args');
  }

  /// Grow or shrink a pane by [cells] in a direction: `L`, `R`, `U` or `D`.
  Future<bool> resizePaneBy(String paneId, String direction, int cells) {
    if (!isPaneId(paneId) ||
        !const {'L', 'R', 'U', 'D'}.contains(direction) ||
        cells <= 0) {
      return Future.value(false);
    }
    return _runUser('resize-pane -t $paneId -$direction $cells');
  }

  static const layoutPresets = [
    'even-horizontal',
    'even-vertical',
    'main-horizontal',
    'main-vertical',
    'tiled',
  ];

  Future<bool> selectLayout(String windowId, String preset) =>
      isWindowId(windowId) && layoutPresets.contains(preset)
          ? _runUser('select-layout -t $windowId $preset')
          : Future.value(false);

  Future<bool> swapPanes(String a, String b) => isPaneId(a) && isPaneId(b)
      ? _runUser('swap-pane -s $a -t $b')
      : Future.value(false);

  /// Move a pane out into its own window.
  Future<bool> breakPane(String paneId) =>
      isPaneId(paneId) ? _runUser('break-pane -s $paneId') : Future.value(false);

  Future<bool> setSynchronizePanes(String windowId, bool on) =>
      isWindowId(windowId)
          ? _runUser(
              'set-window-option -t $windowId synchronize-panes ${on ? 'on' : 'off'}')
          : Future.value(false);

  /// Whether a window has synchronize-panes on (queried, not cached).
  Future<bool> isSynchronizePanes(String windowId) async {
    if (!isWindowId(windowId)) return false;
    final r = await run(
        'display-message -p -t $windowId "#{pane_synchronized}"');
    return !r.error && r.lines.isNotEmpty && r.lines.first.trim() == '1';
  }

  /// Create a new session and switch this client to it.
  Future<bool> newSession(String name) async {
    if (name.isEmpty) return false;
    final r = await run(
        'new-session -d -s ${quoteFormatArg(name)} -P -F "#{session_id}"');
    if (r.error) {
      onError?.call(r.lines.join('\n').trim());
      return false;
    }
    final id = r.lines.isEmpty ? '' : r.lines.first.trim();
    if (!isSessionId(id)) return false;
    return _runUser('switch-client -t $id');
  }

  Future<bool> switchSession(String sessionId) => isSessionId(sessionId)
      ? _runUser('switch-client -t $sessionId')
      : Future.value(false);

  Future<bool> renameSession(String sessionId, String name) =>
      isSessionId(sessionId) && name.isNotEmpty
          ? _runUser('rename-session -t $sessionId ${quoteFormatArg(name)}')
          : Future.value(false);

  Future<bool> killSession(String sessionId) => isSessionId(sessionId)
      ? _runUser('kill-session -t $sessionId')
      : Future.value(false);

  /// Detach every other client from the current session ("take over").
  Future<bool> detachOtherClients() => _runUser('detach-client -a');

  /// Detach this client; tmux answers with %exit.
  void detach() {
    if (!_exited) run('detach-client');
  }

  /// Ask tmux to end control mode unconditionally: an empty line detaches
  /// the control client even when the command queue is wedged.
  void forceExit() {
    if (!_exited) sendBytes(const [0x0a]);
  }

  /// Re-fetch every pane's content (a manual "resync" for the rare case the
  /// mirror drifts from the server).
  Future<void> resyncAll() async {
    final panes = [for (final w in _windows.values) ...w.panes.values];
    await Future.wait(panes.map(_resyncPane));
    _flushNotify();
  }

  /// The client size last reported to tmux, in cells.
  (int, int)? get clientSize =>
      _clientCols > 0 && _clientRows > 0 ? (_clientCols, _clientRows) : null;

  @override
  void dispose() {
    _disposed = true;
    _startupFallback?.cancel();
    _failAllPending('disposed');
    for (final w in _windows.values) {
      _disposeWindow(w);
    }
    _windows.clear();
    _paneToWindow.clear();
    super.dispose();
  }
}
