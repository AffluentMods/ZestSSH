import 'dart:async';
import 'dart:convert';

import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';

/// A scripted stand-in for a tmux server in control mode. It answers the
/// commands the controller sends from a small model of sessions, windows and
/// panes, and emits the notifications a real tmux 3.6 emits (sequence and
/// flags taken from recorded transcripts). Replies are delivered on a
/// microtask so the controller sees them the way a network read arrives:
/// never re-entrantly from inside its own write.
class FakeTmux {
  FakeTmux({this.version = '3.6', this.flowControl = true});

  final String version;

  /// Whether `refresh-client -f pause-after` is accepted (tmux 3.2+).
  final bool flowControl;

  late TmuxController controller;

  /// Every command line the controller wrote, in order.
  final List<String> commands = [];

  /// Bytes the controller sent to panes with `send-keys -H`, per pane.
  final Map<String, List<int>> typed = {};

  /// Set to make every `send-keys` echo its bytes back as `%output`.
  bool echoKeys = false;

  final List<FakeSession> sessions = [];
  final Map<String, FakeWindow> windows = {};
  final Map<String, FakePane> panes = {};
  String? currentSession;
  int clientWidth = 80;
  int clientHeight = 24;
  int _number = 200;
  int _nextWindow = 0;
  int _nextPane = 0;
  int _nextSession = 0;
  bool exited = false;
  bool extendedOutput = false;

  // ── Model building ──

  FakeSession addSession(String name) {
    final s = FakeSession('\$${_nextSession++}', name);
    sessions.add(s);
    return s;
  }

  /// Add a window with one pane; returns the window. [screen] is what the
  /// pane shows, [history] its scrollback.
  FakeWindow addWindow(
    FakeSession s,
    String name, {
    List<String> screen = const ['\$ '],
    List<String> history = const [],
    int width = 80,
    int height = 24,
    int cursorX = 2,
    int cursorY = 0,
  }) {
    final w = FakeWindow('@${_nextWindow++}', name, s.windows.length);
    final p = _newPane(w.id,
        width: width,
        height: height,
        screen: screen,
        history: history,
        cursorX: cursorX,
        cursorY: cursorY);
    w.paneIds.add(p.id);
    w.activePaneId = p.id;
    windows[w.id] = w;
    s.windows.add(w.id);
    s.activeWindowId ??= w.id;
    return w;
  }

  /// Add a second pane beside the first one (a `{}` split).
  FakePane splitRight(FakeWindow w, {List<String> screen = const ['\$ ']}) {
    final first = panes[w.paneIds.first]!;
    final left = first.width ~/ 2;
    first.width = left;
    final p = _newPane(w.id,
        width: first.width - 1, height: first.height, screen: screen);
    w.paneIds.add(p.id);
    return p;
  }

  FakePane _newPane(
    String windowId, {
    int width = 80,
    int height = 24,
    List<String> screen = const ['\$ '],
    List<String> history = const [],
    int cursorX = 2,
    int cursorY = 0,
  }) {
    final p = FakePane('%${_nextPane++}', windowId)
      ..width = width
      ..height = height
      ..screen = List.of(screen)
      ..history = List.of(history)
      ..cursorX = cursorX
      ..cursorY = cursorY;
    panes[p.id] = p;
    return p;
  }

  String layoutOf(FakeWindow w) {
    final ps = w.paneIds.map((id) => panes[id]!).toList();
    if (ps.length == 1) {
      final p = ps.single;
      return 'aaaa,${p.width}x${p.height},0,0,${p.id.substring(1)}';
    }
    final totalW = ps.fold<int>(0, (a, p) => a + p.width) + ps.length - 1;
    final h = ps.first.height;
    var x = 0;
    final parts = <String>[];
    for (final p in ps) {
      parts.add('${p.width}x${p.height},$x,0,${p.id.substring(1)}');
      x += p.width + 1;
    }
    return 'bbbb,${totalW}x$h,0,0{${parts.join(',')}}';
  }

  String visibleLayoutOf(FakeWindow w) {
    if (w.zoomedPaneId == null) return layoutOf(w);
    final p = panes[w.zoomedPaneId]!;
    return 'cccc,${clientWidth}x$clientHeight,0,0,${p.id.substring(1)}';
  }

  String flagsOf(FakeWindow w) {
    final s = _session(currentSession);
    return (s?.activeWindowId == w.id ? '*' : '-') +
        (w.zoomedPaneId != null ? 'Z' : '');
  }

  FakeSession? _session(String? id) =>
      sessions.where((s) => s.id == id).firstOrNull;

  // ── Stream from the "server" ──

  void emit(String line) {
    controller.onData(utf8.encode('$line\n'));
  }

  void emitRaw(List<int> bytes) => controller.onData(bytes);

  /// What the tmux client prints when attaching to [s].
  void attach(FakeSession s) {
    currentSession = s.id;
    emitRaw(TmuxControlParser.marker);
    final n = _number++;
    emit('%begin 1 $n 0');
    emit('%end 1 $n 0');
    emit('%session-changed ${s.id} ${s.name}');
  }

  /// What the tmux client prints when the attach fails.
  void attachError(String message) {
    emitRaw(TmuxControlParser.marker);
    final n = _number++;
    emit('%begin 1 $n 0');
    emit(message);
    emit('%error 1 $n 0');
    emit('%exit');
    emitRaw(TmuxControlParser.terminator);
    exited = true;
  }

  void _exit([String? reason]) {
    exited = true;
    emit(reason == null ? '%exit' : '%exit $reason');
    emitRaw(TmuxControlParser.terminator);
  }

  /// Pane output as tmux would send it (octal escapes for control bytes and
  /// the backslash, raw UTF-8 otherwise).
  void output(String paneId, List<int> bytes) {
    final wire = <int>[
      ...utf8.encode(
          extendedOutput ? '%extended-output $paneId 0 : ' : '%output $paneId '),
    ];
    for (final b in bytes) {
      if (b < 0x20 || b == 0x5c) {
        wire.addAll('\\${b.toRadixString(8).padLeft(3, '0')}'.codeUnits);
      } else {
        wire.add(b); // raw, including UTF-8 sequences, as tmux does
      }
    }
    wire.add(0x0a);
    emitRaw(wire);
  }

  // ── Input from the controller ──

  final StringBuffer _inbox = StringBuffer();

  void receive(List<int> bytes) {
    _inbox.write(utf8.decode(bytes));
    var s = _inbox.toString();
    while (true) {
      final nl = s.indexOf('\n');
      if (nl < 0) break;
      final line = s.substring(0, nl);
      s = s.substring(nl + 1);
      commands.add(line);
      scheduleMicrotask(() => _handleLine(line));
    }
    _inbox
      ..clear()
      ..write(s);
  }

  void _handleLine(String line) {
    if (exited) return;
    if (line.isEmpty) {
      _exit();
      return;
    }
    final n = _number++;
    final after = <void Function()>[];
    List<String> lines;
    bool error;
    try {
      lines = _run(line, after);
      error = false;
    } on _CmdError catch (e) {
      lines = [e.message];
      error = true;
    }
    emit('%begin 1 $n 1');
    for (final l in lines) {
      emit(l);
    }
    emit(error ? '%error 1 $n 1' : '%end 1 $n 1');
    for (final f in after) {
      f();
    }
  }

  /// Minimal tmux command-line tokenizer: single/double quotes, backslash
  /// escapes outside quotes, and the '\'' idiom inside single quotes.
  static List<String> tokenize(String line) {
    final out = <String>[];
    final cur = StringBuffer();
    var inWord = false;
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (c == ' ') {
        if (inWord) {
          out.add(cur.toString());
          cur.clear();
          inWord = false;
        }
        i++;
      } else if (c == "'") {
        inWord = true;
        i++;
        while (i < line.length && line[i] != "'") {
          cur.write(line[i++]);
        }
        i++;
      } else if (c == '"') {
        inWord = true;
        i++;
        while (i < line.length && line[i] != '"') {
          if (line[i] == '\\' && i + 1 < line.length) i++;
          cur.write(line[i++]);
        }
        i++;
      } else if (c == '\\' && i + 1 < line.length) {
        inWord = true;
        cur.write(line[i + 1]);
        i += 2;
      } else {
        inWord = true;
        cur.write(c);
        i++;
      }
    }
    if (inWord) out.add(cur.toString());
    return out;
  }

  /// Expand the formats the controller uses, the way tmux would for [p].
  String _format(String fmt, {FakePane? p, FakeWindow? w, FakeSession? s}) {
    w ??= p == null ? null : windows[p.windowId];
    s ??= _session(currentSession);
    return fmt.replaceAllMapped(RegExp(r'#\{([a-z_]+)\}'), (m) {
      switch (m.group(1)) {
        case 'version':
          return version;
        case 'session_id':
          return s?.id ?? '';
        case 'session_name':
          return s?.name ?? '';
        case 'session_windows':
          return '${s?.windows.length ?? 0}';
        case 'session_attached':
          return s?.id == currentSession ? '1' : '0';
        case 'session_activity':
          return '1790000000';
        case 'session_created':
          return '1789999000';
        case 'window_id':
          return w?.id ?? '';
        case 'window_index':
          return '${w?.index ?? 0}';
        case 'window_name':
          return w?.name ?? '';
        case 'window_active':
          return s?.activeWindowId == w?.id ? '1' : '0';
        case 'window_zoomed_flag':
          return w?.zoomedPaneId != null ? '1' : '0';
        case 'window_layout':
          return w == null ? '' : layoutOf(w);
        case 'window_visible_layout':
          return w == null ? '' : visibleLayoutOf(w);
        case 'window_flags':
          return w == null ? '' : flagsOf(w);
        case 'pane_id':
          return p?.id ?? '';
        case 'pane_width':
          return '${p?.width ?? 0}';
        case 'pane_height':
          return '${p?.height ?? 0}';
        case 'cursor_x':
          return '${p?.cursorX ?? 0}';
        case 'cursor_y':
          return '${p?.cursorY ?? 0}';
        case 'alternate_on':
          return p?.alt != null ? '1' : '0';
        case 'alternate_saved_x':
          return '${p?.savedX ?? 0}';
        case 'alternate_saved_y':
          return '${p?.savedY ?? 0}';
        case 'history_size':
          return '${p?.listedHistorySize ?? p?.history.length ?? 0}';
        case 'pane_dead':
          return '0';
        case 'scroll_region_upper':
          return '${p?.scrollTop ?? 0}';
        case 'scroll_region_lower':
          return '${p?.scrollBottom ?? ((p?.height ?? 24) - 1)}';
        case 'cursor_flag':
          return p?.cursorVisible == false ? '0' : '1';
        case 'insert_flag':
          return '0';
        case 'keypad_cursor_flag':
          return p?.cursorKeys == true ? '1' : '0';
        case 'keypad_flag':
          return '0';
        case 'wrap_flag':
          return '1';
        case 'origin_flag':
          return '0';
        case 'mouse_standard_flag':
        case 'mouse_button_flag':
        case 'mouse_utf8_flag':
          return '0';
        case 'mouse_any_flag':
          return p?.mouseAny == true ? '1' : '0';
        case 'mouse_sgr_flag':
          return p?.mouseAny == true ? '1' : '0';
        case 'pane_active':
          return w?.activePaneId == p?.id ? '1' : '0';
        case 'pane_title':
          return p?.title ?? '';
        case 'pane_synchronized':
          return w?.synchronized == true ? '1' : '0';
        default:
          return '';
      }
    });
  }

  FakePane _pane(String id) {
    final p = panes[id];
    if (p == null) throw _CmdError("can't find pane: $id");
    return p;
  }

  FakeWindow _window(String id) {
    final w = windows[id];
    if (w == null) throw _CmdError("can't find window: $id");
    return w;
  }

  String _target(List<String> t, String flag) {
    final i = t.indexOf(flag);
    if (i < 0 || i + 1 >= t.length) throw _CmdError('usage: target required');
    return t[i + 1];
  }

  String? _optTarget(List<String> t, String flag) {
    final i = t.indexOf(flag);
    return i < 0 || i + 1 >= t.length ? null : t[i + 1];
  }

  List<String> _run(String line, List<void Function()> after) {
    final t = tokenize(line);
    if (t.isEmpty) return const [];
    final cmd = t.first;
    final s = _session(currentSession);
    switch (cmd) {
      case 'display-message':
        final fmt = t.last;
        final target = _optTarget(t, '-t');
        if (target == null) return [_format(fmt)];
        if (target.startsWith('%')) return [_format(fmt, p: _pane(target))];
        if (target.startsWith('@')) return [_format(fmt, w: _window(target))];
        throw _CmdError("can't find pane: $target");
      case 'list-sessions':
        final fmt = _target(t, '-F');
        return [for (final x in sessions) _format(fmt, s: x)];
      case 'list-windows':
        final fmt = _target(t, '-F');
        return [
          for (final id in s?.windows ?? const <String>[])
            _format(fmt, w: windows[id])
        ];
      case 'list-panes':
        final fmt = _target(t, '-F');
        final ids = t.contains('-s')
            ? [for (final w in s?.windows ?? const <String>[]) ...windows[w]!.paneIds]
            : _window(_target(t, '-t')).paneIds;
        return [for (final id in ids) _format(fmt, p: panes[id])];
      case 'capture-pane':
        final p = _pane(_target(t, '-t'));
        if (t.contains('-N') && !version.startsWith('3')) {
          throw _CmdError('usage: capture-pane [-aepPqCJ] ...');
        }
        if (t.contains('-a')) {
          if (p.alt == null) {
            if (t.contains('-q')) return const [];
            throw _CmdError('no alternate screen');
          }
          return _padded(p.screen, p.height);
        }
        final si = t.indexOf('-S');
        if (si >= 0) {
          final n = -int.parse(t[si + 1]);
          final ei = t.indexOf('-E');
          final hist = p.history.length <= n
              ? p.history
              : p.history.sublist(p.history.length - n);
          if (ei >= 0 && t[ei + 1] == '-1') return List.of(hist);
          return [...hist, ..._padded(p.alt ?? p.screen, p.height)];
        }
        return _padded(p.alt ?? p.screen, p.height);
      case 'refresh-client':
        if (t.contains('-C')) {
          final size = _target(t, '-C').split(RegExp('[x,]'));
          clientWidth = int.parse(size[0]);
          clientHeight = int.parse(size[1]);
          for (final id in s?.windows ?? const <String>[]) {
            final w = windows[id]!;
            if (w.paneIds.length == 1) {
              final p = panes[w.paneIds.single]!;
              p.width = clientWidth;
              p.height = clientHeight;
            }
            after.add(() => emit(
                '%layout-change ${w.id} ${layoutOf(w)} ${visibleLayoutOf(w)} ${flagsOf(w)}'));
          }
          return const [];
        }
        if (t.contains('-f')) {
          if (!flowControl) throw _CmdError('usage: refresh-client [-cDflLRSU]');
          extendedOutput = true;
          return const [];
        }
        if (t.contains('-A')) {
          final spec = _target(t, '-A');
          final parts = spec.split(':');
          if (parts[1] == 'continue') {
            after.add(() => emit('%continue ${parts[0]}'));
          } else if (parts[1] == 'pause') {
            emit('%pause ${parts[0]}');
          }
          return const [];
        }
        return const [];
      case 'send-keys':
        final p = _pane(_target(t, '-t'));
        final hi = t.indexOf('-H');
        final bytes = [
          for (final h in t.sublist(hi + 1)) int.parse(h, radix: 16)
        ];
        typed.putIfAbsent(p.id, () => []).addAll(bytes);
        if (echoKeys) after.add(() => output(p.id, bytes));
        return const [];
      case 'select-window':
        final w = _window(_target(t, '-t'));
        s!.activeWindowId = w.id;
        after.add(() => emit('%session-window-changed ${s.id} ${w.id}'));
        return const [];
      case 'select-pane':
        final p = _pane(_target(t, '-t'));
        windows[p.windowId]!.activePaneId = p.id;
        after.add(() => emit('%window-pane-changed ${p.windowId} ${p.id}'));
        return const [];
      case 'new-window':
        final name = _optTarget(t, '-n') ?? 'bash';
        final w = addWindow(s!, name, width: clientWidth, height: clientHeight);
        s.activeWindowId = w.id;
        final p = panes[w.paneIds.single]!;
        after.add(() {
          emit('%session-window-changed ${s.id} ${w.id}');
          emit('%window-add ${w.id}');
          output(p.id, utf8.encode('\x1b[?2004h\$ '));
        });
        return const [];
      case 'kill-window':
        final w = _window(_target(t, '-t'));
        _removeWindow(w);
        after.add(() => emit('%unlinked-window-close ${w.id}'));
        return const [];
      case 'rename-window':
        final w = _window(_target(t, '-t'));
        w.name = t.last.replaceAll('##', '#');
        after.add(() => emit('%window-renamed ${w.id} ${w.name}'));
        return const [];
      case 'split-window':
        final p = _pane(_target(t, '-t'));
        final w = windows[p.windowId]!;
        final np = splitRight(w);
        w.activePaneId = np.id;
        after.add(() {
          emit('%window-pane-changed ${w.id} ${np.id}');
          emit('%layout-change ${w.id} ${layoutOf(w)} ${visibleLayoutOf(w)} ${flagsOf(w)}');
          output(np.id, utf8.encode('\x1b[?2004h\$ '));
        });
        return const [];
      case 'kill-pane':
        final p = _pane(_target(t, '-t'));
        final w = windows[p.windowId]!;
        if (w.paneIds.length == 1) {
          _removeWindow(w);
          after.add(() => emit('%unlinked-window-close ${w.id}'));
          return const [];
        }
        w.paneIds.remove(p.id);
        panes.remove(p.id);
        final rest = panes[w.paneIds.first]!;
        rest.width = clientWidth;
        if (w.activePaneId == p.id) w.activePaneId = rest.id;
        after.add(() {
          emit('%window-pane-changed ${w.id} ${rest.id}');
          emit('%layout-change ${w.id} ${layoutOf(w)} ${visibleLayoutOf(w)} ${flagsOf(w)}');
        });
        return const [];
      case 'resize-pane':
        final p = _pane(_target(t, '-t'));
        final w = windows[p.windowId]!;
        if (t.contains('-Z')) {
          w.zoomedPaneId = w.zoomedPaneId == null ? p.id : null;
          after.add(() => emit(
              '%layout-change ${w.id} ${layoutOf(w)} ${visibleLayoutOf(w)} ${flagsOf(w)}'));
        }
        return const [];
      case 'new-session':
        final name = _target(t, '-s');
        final ns = addSession(name.replaceAll('##', '#'));
        addWindow(ns, 'bash', width: clientWidth, height: clientHeight);
        after.add(() => emit('%sessions-changed'));
        return t.contains('-P') ? [ns.id] : const [];
      case 'switch-client':
        final id = _target(t, '-t');
        final ns = _session(id);
        if (ns == null) throw _CmdError("can't find session: $id");
        currentSession = ns.id;
        after.add(() => emit('%session-changed ${ns.id} ${ns.name}'));
        return const [];
      case 'rename-session':
        final ns = _session(_target(t, '-t'));
        if (ns == null) throw _CmdError("can't find session");
        ns.name = t.last.replaceAll('##', '#');
        after.add(() => emit('%session-renamed ${ns.id} ${ns.name}'));
        return const [];
      case 'kill-session':
        final ns = _session(_target(t, '-t'));
        if (ns == null) throw _CmdError("can't find session");
        sessions.remove(ns);
        after.add(() => emit('%sessions-changed'));
        return const [];
      case 'detach-client':
        if (!t.contains('-a')) after.add(() => _exit('detached'));
        return const [];
      case 'set-window-option':
        final w = _window(_target(t, '-t'));
        w.synchronized = t.last == 'on';
        return const [];
      case 'select-layout':
      case 'swap-pane':
      case 'swap-window':
      case 'move-window':
      case 'break-pane':
        return const [];
      default:
        throw _CmdError('unknown command: $cmd');
    }
  }

  void _removeWindow(FakeWindow w) {
    for (final id in w.paneIds) {
      panes.remove(id);
    }
    windows.remove(w.id);
    for (final s in sessions) {
      s.windows.remove(w.id);
      if (s.activeWindowId == w.id) {
        s.activeWindowId = s.windows.isEmpty ? null : s.windows.first;
      }
    }
  }

  static List<String> _padded(List<String> lines, int height) =>
      [...lines, for (var i = lines.length; i < height; i++) ''];
}

class _CmdError implements Exception {
  final String message;
  _CmdError(this.message);
}

class FakeSession {
  final String id;
  String name;
  final List<String> windows = [];
  String? activeWindowId;
  FakeSession(this.id, this.name);
}

class FakeWindow {
  final String id;
  String name;
  int index;
  final List<String> paneIds = [];
  String? activePaneId;
  String? zoomedPaneId;
  bool synchronized = false;
  FakeWindow(this.id, this.name, this.index);
}

class FakePane {
  final String id;
  String windowId;
  int width = 80;
  int height = 24;
  List<String> screen = ['\$ '];
  List<String> history = [];

  /// What a listing says the history size is when it is not [history]'s
  /// length: a pane still printing was listed before these lines scrolled
  /// off its screen.
  int? listedHistorySize;

  /// Non-null when the alternate screen is active: its content.
  List<String>? alt;
  int cursorX = 2;
  int cursorY = 0;
  int savedX = 0;
  int savedY = 0;
  int scrollTop = 0;
  int? scrollBottom;
  bool cursorVisible = true;
  bool cursorKeys = false;
  bool mouseAny = false;
  String title = '';
  FakePane(this.id, this.windowId);
}
