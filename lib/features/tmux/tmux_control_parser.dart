/// Pure, dependency-free parser for the tmux CONTROL MODE protocol (`tmux -CC`).
///
/// In control mode tmux stops drawing a UI and instead emits a line-based
/// protocol on stdout and accepts tmux commands on stdin. Each line is either a
/// `%notification` or, between `%begin`/`%end`, the reply to a command. This
/// parser turns that BYTE stream into typed [TmuxEvent]s; the controller layer
/// decides what to do with them (route pane output to a terminal, add a tab for
/// a window, and so on).
///
/// Everything here was checked against a real tmux 3.6 transcript, so a few
/// facts that shape the design are worth stating:
///
/// * `%output` payloads carry the pane's RAW bytes: control bytes and the
///   backslash are octal-escaped (`\015`, `\134`), everything else, including
///   multi-byte UTF-8, is verbatim. The stream must therefore be handled as
///   bytes end to end and decoded per pane, statefully, at the very last step.
/// * Reply blocks (`capture-pane` output in particular) contain raw bytes too,
///   including raw `ESC \` (an OSC terminator in a hyperlink, say), so a bare
///   `ESC \` is NOT the end of control mode. Control mode ends only with the
///   `ESC \` that the tmux client prints right after `%exit`.
/// * A block is closed only by the `%end`/`%error` line carrying its own
///   number, never by a content line that merely starts with `%end`.
/// * `%begin ... <flags>` has flags bit 0 set when the command was issued by
///   THIS client, which is how replies are correlated with what we sent.
/// * `%pause`/`%continue` are written synchronously by the server and can
///   land INSIDE a reply block.
/// * A tmux parse error (unbalanced quote) yields an unguarded plain line, not
///   a `%error` block; it is surfaced as [TmuxStrayLine].
///
/// The parser also does the in-band demultiplexing: constructed with
/// `inband: true` it starts in passthrough (bytes are for the normal terminal)
/// and only enters control mode on the exact `ESC P 1000 p` marker the tmux
/// client prints, handing the shell its bytes back after the terminator. With
/// `holdAtMarker` it stops at the marker and waits to be told what it is: any
/// output can hold those bytes ([TmuxInbandWatcher] decides).
library;

import 'dart:convert';
import 'dart:typed_data';

sealed class TmuxEvent {
  const TmuxEvent();
}

/// Bytes that are not control-mode protocol: everything before the marker in
/// in-band mode and everything after the terminator. Render them normally.
class TmuxPassthrough extends TmuxEvent {
  final Uint8List data;
  const TmuxPassthrough(this.data);
}

/// The `ESC P 1000 p` marker was consumed: control mode starts here.
class TmuxControlBegin extends TmuxEvent {
  const TmuxControlBegin();
}

/// A parser told to hold at the marker has come to one: what comes after it
/// is kept until [TmuxControlParser.acceptMarker] or
/// [TmuxControlParser.declineMarker] says what it is.
class TmuxMarkerHeld extends TmuxEvent {
  const TmuxMarkerHeld();
}

/// The `ESC \` terminator after `%exit` was consumed: control mode is over and
/// any further bytes are ordinary terminal output again.
class TmuxControlEnd extends TmuxEvent {
  const TmuxControlEnd();
}

/// Output for a pane. [data] is the already-unescaped raw bytes (UTF-8, not
/// yet decoded). [ageMs] is only meaningful for `%extended-output`.
class TmuxOutput extends TmuxEvent {
  final String paneId; // e.g. "%1"
  final List<int> data;
  final int ageMs;
  const TmuxOutput(this.paneId, this.data, {this.ageMs = 0});
}

/// Flow control: tmux stopped sending output for a pane (pause-after).
class TmuxPause extends TmuxEvent {
  final String paneId;
  const TmuxPause(this.paneId);
}

/// Flow control: output for a pane resumes. Output that arrived while paused
/// was dropped by tmux, so the pane must be re-captured.
class TmuxContinue extends TmuxEvent {
  final String paneId;
  const TmuxContinue(this.paneId);
}

class TmuxWindowAdd extends TmuxEvent {
  final String windowId; // e.g. "@2"
  const TmuxWindowAdd(this.windowId);
}

/// `%window-close` or `%unlinked-window-close` (tmux unlinks a window before
/// it closes it, so killing one of our own windows reports the latter).
class TmuxWindowClose extends TmuxEvent {
  final String windowId;
  const TmuxWindowClose(this.windowId);
}

class TmuxWindowRenamed extends TmuxEvent {
  final String windowId;
  final String name;
  const TmuxWindowRenamed(this.windowId, this.name);
}

class TmuxWindowPaneChanged extends TmuxEvent {
  final String windowId;
  final String paneId;
  const TmuxWindowPaneChanged(this.windowId, this.paneId);
}

/// A window's pane layout changed. [paneIds] are the leaf pane ids parsed out
/// of the FULL layout, in layout order. [visibleLayout] differs from [layout]
/// when a pane is zoomed (then it holds just that pane and [flags] has `Z`).
class TmuxLayoutChange extends TmuxEvent {
  final String windowId;
  final String layout;
  final List<String> paneIds;
  final String? visibleLayout;
  final String flags;
  const TmuxLayoutChange(
    this.windowId,
    this.layout,
    this.paneIds, {
    this.visibleLayout,
    this.flags = '',
  });

  bool get zoomed => flags.contains('Z');
}

/// This client's current session changed (also sent once on attach).
class TmuxSessionChanged extends TmuxEvent {
  final String sessionId; // e.g. "$0"
  final String name;
  const TmuxSessionChanged(this.sessionId, this.name);
}

class TmuxSessionRenamed extends TmuxEvent {
  final String sessionId;
  final String name;
  const TmuxSessionRenamed(this.sessionId, this.name);
}

/// The current window of a session changed.
class TmuxSessionWindowChanged extends TmuxEvent {
  final String sessionId;
  final String windowId;
  const TmuxSessionWindowChanged(this.sessionId, this.windowId);
}

/// A session was created, destroyed or renamed somewhere on the server.
class TmuxSessionsChanged extends TmuxEvent {
  const TmuxSessionsChanged();
}

/// A pane entered or left a mode (copy mode, for instance).
class TmuxPaneModeChanged extends TmuxEvent {
  final String paneId;
  const TmuxPaneModeChanged(this.paneId);
}

/// A completed command reply block (%begin..%end / %error).
class TmuxReply extends TmuxEvent {
  final int number;
  final bool error;

  /// Reply lines decoded as UTF-8 (malformed bytes replaced), which is what
  /// every `list-*` and `display-message` consumer wants.
  final List<String> lines;

  /// The same lines as raw bytes, for `capture-pane` content.
  final List<Uint8List> rawLines;

  /// Flags from the `%begin` line. Bit 0 set means the command was issued by
  /// this client.
  final int flags;

  /// The block exceeded [TmuxControlParser.maxBlockBytes] and lines were
  /// dropped; [lines] holds what fit.
  final bool truncated;

  TmuxReply(this.number, this.error, this.lines,
      {List<Uint8List>? rawLines, this.flags = 1, this.truncated = false})
      : rawLines = rawLines ??
            [for (final l in lines) Uint8List.fromList(utf8.encode(l))];

  bool get issuedByThisClient => flags & 1 != 0;
}

/// A plain line outside any reply block. tmux emits one for a command it could
/// not even parse (an unbalanced quote), with no %begin/%error guards.
class TmuxStrayLine extends TmuxEvent {
  final String line;
  const TmuxStrayLine(this.line);
}

/// Control mode is ending (client detached or server exited).
class TmuxExit extends TmuxEvent {
  final String? reason;
  const TmuxExit(this.reason);
}

/// A `%` notification we don't specifically handle (surfaced for logging).
class TmuxUnhandled extends TmuxEvent {
  final String line;
  const TmuxUnhandled(this.line);
}

/// Extract the leaf pane ids from a tmux layout string.
///
/// A layout looks like `bc62,80x24,0,0,0` (one pane, id 0) or
/// `e4f2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}` (panes 1 and 2). A leaf is
/// `WxH,x,y,ID`; a container is `WxH,x,y{...}` / `[...]` with no trailing id.
///
/// A layout past [maxTmuxLayoutLength] is none. Each number is read for at most
/// nine digits: unbounded, a line of digits took this pattern back to every
/// digit from every digit (160 KB of them held the app's only isolate for
/// 12.8 s, and with it every session), and a host can print such a line with
/// no tmux anywhere (a `cat` of the marker and that line).
List<String> parseLayoutPaneIds(String layout) {
  if (layout.length > maxTmuxLayoutLength) return const [];
  return _layoutLeaf.allMatches(layout).map((m) => '%${m.group(1)}').toList();
}

final _layoutLeaf = RegExp(r'\d{1,9}x\d{1,9},\d{1,9},\d{1,9},(\d{1,9})');

/// The longest pane layout that is one. tmux itself writes a layout into a
/// buffer of 8 KB (`layout_dump`) and gives none that does not fit.
const int maxTmuxLayoutLength = 64 * 1024;

// ── Layout geometry tree ────────────────────────────────────────────────────

/// A node in a tmux window's pane layout. Either a [TmuxPaneNode] (a single
/// pane) or a [TmuxSplitNode] (panes arranged side by side or stacked). Every
/// node carries its cell geometry so the UI can render the split exactly.
sealed class TmuxLayoutNode {
  final int width, height, x, y;
  const TmuxLayoutNode(this.width, this.height, this.x, this.y);

  /// Every leaf pane id under this node, left-to-right / top-to-bottom.
  List<String> get paneIds;

  /// Every leaf under this node.
  List<TmuxPaneNode> get leaves;
}

class TmuxPaneNode extends TmuxLayoutNode {
  final String paneId; // "%N"
  const TmuxPaneNode(super.width, super.height, super.x, super.y, this.paneId);
  @override
  List<String> get paneIds => [paneId];
  @override
  List<TmuxPaneNode> get leaves => [this];
}

class TmuxSplitNode extends TmuxLayoutNode {
  /// `{...}` in the layout = children side by side (a horizontal arrangement);
  /// `[...]` = children stacked (a vertical arrangement).
  final bool horizontal;
  final List<TmuxLayoutNode> children;
  const TmuxSplitNode(
    super.width,
    super.height,
    super.x,
    super.y,
    this.horizontal,
    this.children,
  );
  @override
  List<String> get paneIds => [for (final c in children) ...c.paneIds];
  @override
  List<TmuxPaneNode> get leaves => [for (final c in children) ...c.leaves];
}

class _LayoutCursor {
  final String s;
  int i;
  _LayoutCursor(this.s, this.i);
}

/// Parse a tmux layout string into a geometry [TmuxLayoutNode] tree. Returns
/// null on any malformed input so the caller can fall back gracefully.
TmuxLayoutNode? parseTmuxLayoutTree(String layout) {
  if (layout.length > maxTmuxLayoutLength) return null;
  try {
    final firstComma = layout.indexOf(','); // skip the "<checksum>," prefix
    if (firstComma < 0) return null;
    final cur = _LayoutCursor(layout, firstComma + 1);
    final node = _parseLayoutNode(cur, 0);
    return node;
  } catch (_) {
    return null;
  }
}

/// How many splits inside splits a layout has at most. A window of the largest
/// size there is cannot be split deeper for long, and what walks the tree (the
/// widgets that draw it above all) goes as deep as it does.
const int _maxLayoutDepth = 64;

TmuxLayoutNode _parseLayoutNode(_LayoutCursor c, int depth) {
  if (depth > _maxLayoutDepth) throw const FormatException('layout nested too deep');
  final w = _readInt(c);
  _expect(c, 'x');
  final h = _readInt(c);
  _expect(c, ',');
  final x = _readInt(c);
  _expect(c, ',');
  final y = _readInt(c);
  if (c.i < c.s.length) {
    final ch = c.s[c.i];
    if (ch == '{' || ch == '[') {
      final horizontal = ch == '{';
      final close = horizontal ? '}' : ']';
      c.i++;
      final children = <TmuxLayoutNode>[_parseLayoutNode(c, depth + 1)];
      while (c.i < c.s.length && c.s[c.i] == ',') {
        c.i++;
        children.add(_parseLayoutNode(c, depth + 1));
      }
      _expect(c, close);
      return TmuxSplitNode(w, h, x, y, horizontal, children);
    }
    if (ch == ',') {
      c.i++;
      final id = _readInt(c);
      return TmuxPaneNode(w, h, x, y, '%$id');
    }
  }
  throw const FormatException('malformed layout node');
}

int _readInt(_LayoutCursor c) {
  final start = c.i;
  while (c.i < c.s.length &&
      c.s.codeUnitAt(c.i) >= 0x30 &&
      c.s.codeUnitAt(c.i) <= 0x39) {
    c.i++;
  }
  if (c.i == start) throw const FormatException('expected int');
  return int.parse(c.s.substring(start, c.i));
}

void _expect(_LayoutCursor c, String ch) {
  if (c.i >= c.s.length || c.s[c.i] != ch) {
    throw FormatException('expected "$ch"');
  }
  c.i++;
}

// ── Payload un-escaping ─────────────────────────────────────────────────────

/// Unescape a tmux `%output` payload given as raw bytes [s] in [start, end).
/// tmux emits every byte below 0x20 and the backslash as a 3-digit octal
/// escape `\ooo`; everything else (including UTF-8 sequences) is verbatim.
Uint8List unescapeTmuxOutputBytes(List<int> s, [int start = 0, int? end]) {
  end ??= s.length;
  final out = Uint8List(end - start);
  var n = 0;
  var i = start;
  while (i < end) {
    final ch = s[i];
    if (ch == 0x5c /* \ */) {
      if (i + 3 < end &&
          _isOctal(s[i + 1]) &&
          _isOctal(s[i + 2]) &&
          _isOctal(s[i + 3])) {
        out[n++] =
            ((s[i + 1] - 0x30) * 64 + (s[i + 2] - 0x30) * 8 + (s[i + 3] - 0x30)) &
                0xff;
        i += 4;
        continue;
      }
      if (i + 1 < end && s[i + 1] == 0x5c) {
        out[n++] = 0x5c; // literal backslash (defensive; tmux uses \134)
        i += 2;
        continue;
      }
    }
    out[n++] = ch;
    i += 1;
  }
  return n == out.length ? out : Uint8List.sublistView(out, 0, n);
}

/// String convenience over [unescapeTmuxOutputBytes]: [s] is the escaped
/// payload as text (its UTF-8 encoding is what tmux put on the wire).
List<int> unescapeTmuxOutput(String s) =>
    unescapeTmuxOutputBytes(utf8.encode(s));

bool _isOctal(int c) => c >= 0x30 && c <= 0x37;

// ── The parser ──────────────────────────────────────────────────────────────

enum _State { passthrough, held, control, afterExit }

/// Byte-oriented state machine over the control-mode stream.
class TmuxControlParser {
  /// [inband] starts the parser in passthrough, where bytes are handed back as
  /// [TmuxPassthrough] until the `ESC P 1000 p` marker arrives. The default
  /// starts straight in control mode (a leading marker is still tolerated).
  /// With [holdAtMarker] the marker ends no passthrough by itself: see
  /// [TmuxMarkerHeld].
  TmuxControlParser({bool inband = false, this.holdAtMarker = false})
      : _state = inband ? _State.passthrough : _State.control;

  /// Whether the marker waits for [acceptMarker] or [declineMarker].
  final bool holdAtMarker;

  /// `ESC P 1000 p`: printed by the tmux client the instant `-CC` starts.
  static const List<int> marker = [0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70];

  /// `ESC \`: printed by the tmux client right after `%exit`.
  static const List<int> terminator = [0x1b, 0x5c];

  /// A control line longer than this cannot be genuine protocol; the carry is
  /// dropped, with the rest of that line, instead of growing without bound on
  /// a desynced stream.
  static const int maxLineBytes = 8 * 1024 * 1024;

  /// The longest notification read. The longest there is, `%layout-change`,
  /// has two layouts of 8 KB at most ([maxTmuxLayoutLength]); pane output and
  /// reply lines are not notifications, and have [maxLineBytes].
  static const int maxNotificationBytes = 64 * 1024;

  /// Cap on the bytes kept for one reply block. A `capture-pane` of a large
  /// scrollback is a few MB; only a host that opens `%begin` and never
  /// closes it gets near this. Past it, lines are dropped (the reply is
  /// flagged [TmuxReply.truncated]) so a hostile stream cannot grow memory
  /// without bound.
  static const int maxBlockBytes = 32 * 1024 * 1024;

  static const Utf8Decoder _utf8 = Utf8Decoder(allowMalformed: true);

  _State _state;
  final BytesBuilder _carry = BytesBuilder(copy: false);

  /// What came after a marker held ([holdAtMarker]).
  final BytesBuilder _held = BytesBuilder(copy: false);

  /// Control mode has begun on this stream: a marker that comes again is no
  /// new beginning.
  bool _begun = false;

  /// How much of [_carry] is a line already looked at for its end.
  int _carriedLine = 0;

  /// In a line past [maxLineBytes]: nothing is read until its end.
  bool _skippingLine = false;

  bool _inBlock = false;
  int _blockNum = 0;
  int _blockFlags = 0;
  bool _blockError = false;
  final List<Uint8List> _blockLines = [];
  int _blockBytes = 0;
  bool _blockTruncated = false;

  /// Whether we are mid command-reply block (used by tests / diagnostics).
  bool get inBlock => _inBlock;
  bool get lastBlockWasError => _blockError;

  /// Whether the parser is currently in control mode (between the marker and
  /// the terminator).
  bool get inControlMode => _state == _State.control;

  /// Whether a marker is held ([TmuxMarkerHeld]), and how much came after it.
  bool get holdsMarker => _state == _State.held;
  int get heldBytes => _held.length;

  /// The marker held was the start of control mode: it begins here, and what
  /// came after it is read as control mode.
  List<TmuxEvent> acceptMarker() {
    final events = <TmuxEvent>[];
    if (_state != _State.held) return events;
    _state = _State.control;
    _begun = true;
    events.add(const TmuxControlBegin());
    final rest = _held.takeBytes();
    if (rest.isNotEmpty) _process(rest, 0, events);
    return events;
  }

  /// The marker held was output like any other: it goes out with what came
  /// after it, as it came, markers among it too.
  List<TmuxEvent> declineMarker() {
    if (_state != _State.held) return const [];
    _state = _State.passthrough;
    final out = BytesBuilder(copy: false)
      ..add(marker)
      ..add(_held.takeBytes());
    return [TmuxPassthrough(out.takeBytes())];
  }

  /// Feed a chunk of decoded text; returns the events completed by it. Kept
  /// for callers and tests that already have text; the wire is bytes, so
  /// prefer [addBytes].
  List<TmuxEvent> addChunk(String chunk) => addBytes(utf8.encode(chunk));

  /// Feed raw bytes from the wire; returns the events completed by them.
  List<TmuxEvent> addBytes(List<int> chunk) {
    final events = <TmuxEvent>[];
    if (chunk.isEmpty) return events;
    Uint8List buf;
    if (_carry.isNotEmpty) {
      _carry.add(chunk);
      buf = _carry.takeBytes();
    } else {
      buf = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    }
    _process(buf, 0, events);
    return events;
  }

  /// Abandon control mode without waiting for `%exit` and the terminator:
  /// the escape hatch for a wedged tmux (inner host died, channel stuck).
  /// Subsequent bytes are ordinary output again.
  void forcePassthrough() {
    _state = _State.passthrough;
    _carry.clear();
    _held.clear();
    _carriedLine = 0;
    _skippingLine = false;
    _inBlock = false;
    _blockLines.clear();
  }

  /// The stream ended: release anything still held back (a partial marker in
  /// passthrough is ordinary output after all).
  List<TmuxEvent> finish() {
    if (_state == _State.held) return declineMarker();
    final events = <TmuxEvent>[];
    if (_carry.isEmpty) return events;
    final rest = _carry.takeBytes();
    _carriedLine = 0;
    if (_state == _State.passthrough) {
      events.add(TmuxPassthrough(rest));
    } else if (_state == _State.control) {
      _handleLine(rest, 0, rest.length, events);
    }
    return events;
  }

  void _process(Uint8List buf, int start, List<TmuxEvent> events) {
    var i = start;
    while (i < buf.length) {
      switch (_state) {
        case _State.passthrough:
          i = _passthrough(buf, i, events);
        case _State.held:
          _held.add(_slice(buf, i, buf.length));
          i = buf.length;
        case _State.control:
          i = _control(buf, i, events);
        case _State.afterExit:
          i = _afterExit(buf, i, events);
      }
    }
  }

  /// Passthrough: forward bytes until the marker. Returns the index to resume
  /// from (buf.length when everything was consumed).
  int _passthrough(Uint8List buf, int start, List<TmuxEvent> events) {
    final at = _indexOf(buf, marker, start);
    if (at >= 0) {
      if (at > start) events.add(TmuxPassthrough(_slice(buf, start, at)));
      if (holdAtMarker) {
        _state = _State.held;
        events.add(const TmuxMarkerHeld());
      } else {
        _state = _State.control;
        _begun = true;
        events.add(const TmuxControlBegin());
      }
      return at + marker.length;
    }
    // No marker. Hold back a trailing proper prefix of it (a chunk ending in
    // a bare ESC is common: split escape sequences) so a marker straddling two
    // reads is still recognised; everything else is output.
    final held = _suffixPrefixLength(buf, start, marker);
    final end = buf.length - held;
    if (end > start) events.add(TmuxPassthrough(_slice(buf, start, end)));
    if (held > 0) _carry.add(_slice(buf, end, buf.length));
    return buf.length;
  }

  /// Control mode: line framing on LF. Returns the resume index.
  int _control(Uint8List buf, int start, List<TmuxEvent> events) {
    var lineStart = start;
    // (What was carried over holds no line end: looked for again in every
    // chunk, a long line cost its length many times over.)
    var i = start + _carriedLine;
    _carriedLine = 0;
    if (_skippingLine) {
      while (i < buf.length && buf[i] != 0x0a) {
        i++;
      }
      if (i == buf.length) return buf.length;
      _skippingLine = false;
      i++;
      lineStart = i;
    }
    for (; i < buf.length; i++) {
      if (buf[i] == 0x0a) {
        _handleLine(buf, lineStart, i, events);
        lineStart = i + 1;
        if (_state != _State.control) return lineStart;
      }
    }
    if (lineStart < buf.length) {
      if (buf.length - lineStart > maxLineBytes) {
        // Not protocol any more; drop it rather than buffer forever, and what
        // is left of it with it: that is no line of its own.
        _skippingLine = true;
        return buf.length;
      }
      _carriedLine = buf.length - lineStart;
      _carry.add(_slice(buf, lineStart, buf.length));
    }
    return buf.length;
  }

  /// After `%exit`: swallow until the `ESC \` terminator, then passthrough.
  int _afterExit(Uint8List buf, int start, List<TmuxEvent> events) {
    final at = _indexOf(buf, terminator, start);
    if (at >= 0) {
      _state = _State.passthrough;
      events.add(const TmuxControlEnd());
      return at + terminator.length;
    }
    final held = _suffixPrefixLength(buf, start, terminator);
    if (held > 0) _carry.add(_slice(buf, buf.length - held, buf.length));
    return buf.length;
  }

  void _handleLine(Uint8List buf, int start, int end, List<TmuxEvent> events) {
    // Strip a trailing CR (the tmux client's tty is in raw mode but a pty
    // may still add one) and a leading marker (default-mode streams).
    if (end > start && buf[end - 1] == 0x0d) end--;
    // Only the stream's first line can begin it. A marker later on begins
    // nothing: each one made another controller, on the same channel, of which
    // only the last was ever let go of (2000 such lines, 16 KB, made 2001).
    if (end - start >= marker.length && _startsWith(buf, start, marker) && (!_begun || !_inBlock)) {
      start += marker.length;
      if (!_begun) events.add(const TmuxControlBegin());
    }
    _begun = true;

    if (_inBlock) {
      if (_isBlockEnd(buf, start, end)) {
        final error = buf[start + 2] == 0x72 /* r of %error, n of %end */;
        _blockError = error;
        final raw = List<Uint8List>.of(_blockLines);
        events.add(TmuxReply(
          _blockNum,
          error,
          [for (final l in raw) _utf8.convert(l)],
          rawLines: raw,
          flags: _blockFlags,
          truncated: _blockTruncated,
        ));
        _inBlock = false;
        _blockLines.clear();
        _blockBytes = 0;
        _blockTruncated = false;
        return;
      }
      // %pause / %continue are written synchronously by the server and so can
      // land inside a reply; nothing else can.
      final flow = _flowControl(buf, start, end);
      if (flow != null) {
        events.add(flow);
        return;
      }
      final len = end - start;
      if (_blockBytes + len > maxBlockBytes) {
        _blockTruncated = true;
        return;
      }
      _blockBytes += len;
      _blockLines.add(_slice(buf, start, end));
      return;
    }

    if (end == start) return; // blank line
    if (buf[start] != 0x25 /* % */) {
      events.add(TmuxStrayLine(_utf8.convert(buf, start, end)));
      return;
    }

    // Split off the tag.
    var sp = start;
    while (sp < end && buf[sp] != 0x20) {
      sp++;
    }
    final tag = String.fromCharCodes(buf, start, sp);
    final restStart = sp < end ? sp + 1 : end;

    switch (tag) {
      case '%begin':
        // "%begin <timestamp> <number> <flags>"
        final parts = _utf8.convert(buf, restStart, end).split(' ');
        _inBlock = true;
        _blockError = false;
        _blockLines.clear();
        _blockNum = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
        _blockFlags = parts.length > 2 ? (int.tryParse(parts[2]) ?? 1) : 1;
      case '%output':
        // "%output %<pane> <escaped-data>"
        var s2 = restStart;
        while (s2 < end && buf[s2] != 0x20) {
          s2++;
        }
        final pane = String.fromCharCodes(buf, restStart, s2);
        final data = s2 < end
            ? unescapeTmuxOutputBytes(buf, s2 + 1, end)
            : Uint8List(0);
        events.add(TmuxOutput(pane, data));
      case '%extended-output':
        // "%extended-output %<pane> <age-ms> : <escaped-data>"
        var s2 = restStart;
        while (s2 < end && buf[s2] != 0x20) {
          s2++;
        }
        final pane = String.fromCharCodes(buf, restStart, s2);
        var s3 = s2 < end ? s2 + 1 : end;
        var s4 = s3;
        while (s4 < end && buf[s4] != 0x20) {
          s4++;
        }
        final age = int.tryParse(String.fromCharCodes(buf, s3, s4)) ?? 0;
        // Skip " : " (a lone colon token).
        var dataStart = s4;
        if (dataStart < end && buf[dataStart] == 0x20) dataStart++;
        if (dataStart < end && buf[dataStart] == 0x3a) dataStart++;
        if (dataStart < end && buf[dataStart] == 0x20) dataStart++;
        final data = dataStart < end
            ? unescapeTmuxOutputBytes(buf, dataStart, end)
            : Uint8List(0);
        events.add(TmuxOutput(pane, data, ageMs: age));
      case '%exit':
        final reason = _utf8.convert(buf, restStart, end).trim();
        events.add(TmuxExit(reason.isEmpty ? null : reason));
        _state = _State.afterExit;
      default:
        if (end - start > maxNotificationBytes) return;
        _handleNotification(tag, _utf8.convert(buf, restStart, end), buf,
            start, end, events);
    }
  }

  void _handleNotification(String tag, String rest, Uint8List buf, int start,
      int end, List<TmuxEvent> events) {
    switch (tag) {
      case '%pause':
        events.add(TmuxPause(rest.trim()));
      case '%continue':
        events.add(TmuxContinue(rest.trim()));
      case '%window-add':
        events.add(TmuxWindowAdd(rest.trim()));
      case '%window-close':
      case '%unlinked-window-close':
        events.add(TmuxWindowClose(rest.trim()));
      case '%window-renamed':
        final s2 = rest.indexOf(' ');
        if (s2 != -1) {
          events.add(
              TmuxWindowRenamed(rest.substring(0, s2), rest.substring(s2 + 1)));
        }
      case '%window-pane-changed':
        final parts = rest.split(' ');
        if (parts.length >= 2) {
          events.add(TmuxWindowPaneChanged(parts[0], parts[1]));
        }
      case '%layout-change':
        // "%layout-change @<win> <layout> [<visible-layout> [<flags>]]"
        final parts = rest.split(' ');
        if (parts.length >= 2) {
          events.add(TmuxLayoutChange(
            parts[0],
            parts[1],
            parseLayoutPaneIds(parts[1]),
            visibleLayout: parts.length >= 3 && parts[2].isNotEmpty
                ? parts[2]
                : null,
            flags: parts.length >= 4 ? parts[3] : '',
          ));
        }
      case '%session-changed':
        final s2 = rest.indexOf(' ');
        if (s2 != -1) {
          events.add(
              TmuxSessionChanged(rest.substring(0, s2), rest.substring(s2 + 1)));
        }
      case '%session-renamed':
        final s2 = rest.indexOf(' ');
        if (s2 != -1) {
          events.add(
              TmuxSessionRenamed(rest.substring(0, s2), rest.substring(s2 + 1)));
        }
      case '%session-window-changed':
        final parts = rest.split(' ');
        if (parts.length >= 2) {
          events.add(TmuxSessionWindowChanged(parts[0], parts[1]));
        }
      case '%sessions-changed':
        events.add(const TmuxSessionsChanged());
      case '%pane-mode-changed':
        events.add(TmuxPaneModeChanged(rest.trim()));
      default:
        events.add(TmuxUnhandled(_utf8.convert(buf, start, end)));
    }
  }

  /// `%end <time> <num> <flags>` / `%error ...` whose number is ours.
  bool _isBlockEnd(Uint8List buf, int start, int end) {
    const endTag = [0x25, 0x65, 0x6e, 0x64, 0x20]; // "%end "
    const errTag = [0x25, 0x65, 0x72, 0x72, 0x6f, 0x72, 0x20]; // "%error "
    int tagLen;
    if (end - start > endTag.length && _startsWith(buf, start, endTag)) {
      tagLen = endTag.length;
    } else if (end - start > errTag.length && _startsWith(buf, start, errTag)) {
      tagLen = errTag.length;
    } else {
      return false;
    }
    final parts = String.fromCharCodes(buf, start + tagLen, end).split(' ');
    return parts.length > 1 && int.tryParse(parts[1]) == _blockNum;
  }

  /// Exactly `%pause %N` or `%continue %N`, nothing else on the line.
  TmuxEvent? _flowControl(Uint8List buf, int start, int end) {
    const pause = [0x25, 0x70, 0x61, 0x75, 0x73, 0x65, 0x20, 0x25]; // "%pause %"
    const cont = [
      0x25, 0x63, 0x6f, 0x6e, 0x74, 0x69, 0x6e, 0x75, 0x65, 0x20, 0x25
    ]; // "%continue %"
    int tagLen;
    bool isPause;
    if (end - start > pause.length && _startsWith(buf, start, pause)) {
      tagLen = pause.length;
      isPause = true;
    } else if (end - start > cont.length && _startsWith(buf, start, cont)) {
      tagLen = cont.length;
      isPause = false;
    } else {
      return null;
    }
    for (var i = start + tagLen; i < end; i++) {
      if (buf[i] < 0x30 || buf[i] > 0x39) return null;
    }
    final pane = String.fromCharCodes(buf, start + tagLen - 1, end);
    return isPause ? TmuxPause(pane) : TmuxContinue(pane);
  }

  // ── byte helpers ──

  static Uint8List _slice(Uint8List buf, int start, int end) =>
      Uint8List.fromList(Uint8List.sublistView(buf, start, end));

  static bool _startsWith(Uint8List buf, int at, List<int> pattern) {
    if (buf.length - at < pattern.length) return false;
    for (var i = 0; i < pattern.length; i++) {
      if (buf[at + i] != pattern[i]) return false;
    }
    return true;
  }

  static int _indexOf(Uint8List buf, List<int> pattern, int from) {
    final first = pattern[0];
    final last = buf.length - pattern.length;
    for (var i = from; i <= last; i++) {
      if (buf[i] == first && _startsWith(buf, i, pattern)) return i;
    }
    return -1;
  }

  /// Length of the longest suffix of buf[start..] that is a PROPER prefix of
  /// [pattern] (0 when there is none).
  static int _suffixPrefixLength(Uint8List buf, int start, List<int> pattern) {
    final maxLen = pattern.length - 1;
    for (var len = maxLen; len >= 1; len--) {
      final at = buf.length - len;
      if (at < start) continue;
      var ok = true;
      for (var i = 0; i < len; i++) {
        if (buf[at + i] != pattern[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return len;
    }
    return 0;
  }
}
