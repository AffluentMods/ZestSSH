import 'dart:typed_data';

import 'package:xterm/xterm.dart';
import 'package:zestssh/features/tmux/tmux_control_parser.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';

/// Whether [line], a command line as it was typed or as the app types it, asks
/// for tmux's control mode: an option word with `CC` in it (`tmux -CC`,
/// `tmux -uCC attach`, `ssh host -t "tmux -CC"`) or `-C` given twice.
bool asksForControlMode(String line) => _controlModeOption.hasMatch(line);

final _controlModeOption = RegExp(r'''(?:^|[\s'"])-[A-Za-z0-9]*C(?:C|[A-Za-z0-9]*\s+-[A-Za-z0-9]*C)''');

/// Watches a session's own byte stream for tmux control mode started
/// in-band (the user typed `tmux -CC`, possibly through a jump host, a
/// nested ssh or a `docker exec`). Outside control mode every chunk is
/// handed straight back through [onPassthrough]: one byte scan, no copies,
/// the terminal sees exactly what it would have seen. On the `ESC P 1000 p`
/// marker a [TmuxController] is created on the same channel and fed the
/// parsed events; on `%exit` + `ESC \` the bytes flow to the terminal again.
///
/// The marker is seven bytes any output can hold: a `cat` of a file, a line of
/// a log. Taken at its word it had the app type tmux commands into whatever
/// the channel was reading, and draw a workspace the rest of the file could
/// fill with fake prompts, while the person's keys went to the shell as
/// command lines, into its history, in hex (found in a hostile server
/// review). So it starts control mode by itself only just after a line that
/// asked for it was entered ([lineEntered]), in the session by the person or
/// the app. Otherwise the person is asked ([onAsking], [answer]): nothing is
/// typed and what follows the marker waits, until they say yes. Without a yes
/// it is output like any other, as with this watcher switched off.
class TmuxInbandWatcher {
  TmuxInbandWatcher({
    required this.sendBytes,
    required this.onPassthrough,
    required this.onEnter,
    required this.onExit,
    this.onAsking,
    this.scrollback = 5000,
    this.platform = TerminalTargetPlatform.unknown,
    this.log,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Writes to the session's shell channel (tmux reads its commands there).
  final void Function(List<int> bytes) sendBytes;

  /// Bytes for the normal terminal pipeline.
  final void Function(Uint8List bytes) onPassthrough;

  /// Control mode began: the caller shows the workspace for [controller].
  final void Function(TmuxController controller) onEnter;

  /// Control mode ended (cleanly, or forced); the controller is disposed
  /// right after this returns.
  final void Function(TmuxController controller) onExit;

  /// The question whether to start control mode is up (true), or is no longer
  /// (false). With nobody to ask, a marker nothing asked for is plain output.
  final void Function(bool asking)? onAsking;

  final int scrollback;
  final TerminalTargetPlatform platform;
  final void Function(String message)? log;
  final DateTime Function() _clock;

  /// How long a line that asked for control mode goes on counting: it may have
  /// to get through a jump host and a password first. Past this it is asked.
  static const Duration askedForLasts = Duration(minutes: 1);

  /// The most kept of what follows a marker while the person is asked. tmux
  /// says little until it is answered; past this the stream is no control mode
  /// that can still be picked up, and goes on as the output it may well be.
  static const int maxHeldBytes = 1024 * 1024;

  final TmuxControlParser _parser = TmuxControlParser(inband: true, holdAtMarker: true);
  TmuxController? _controller;
  bool _disposed = false;

  /// Until when a marker counts as asked for, by the last line that did.
  DateTime? _askedForUntil;

  /// The question is up.
  bool _asking = false;

  /// It was asked since the last line entered: more markers, in the same file
  /// or in a loop of a host's, ask nothing more.
  bool _asked = false;

  /// The live controller while in control mode.
  TmuxController? get controller => _controller;

  /// Between the marker and the terminator.
  bool get inControl => _controller != null;

  /// The question whether to start control mode is up.
  bool get asking => _asking;

  /// A line was entered in the session: typed there, or typed by the app for
  /// the person (a host's start-up command, a snippet). One that asks for
  /// control mode makes the next marker its answer. Any line ends a question
  /// still up, as a no: the person went on without it.
  void lineEntered(String line) {
    if (_disposed) return;
    _asked = false;
    if (asksForControlMode(line)) _askedForUntil = _clock().add(askedForLasts);
    if (_asking) answer(false);
  }

  /// The person answered the question.
  void answer(bool start) {
    if (_disposed || !_asking) return;
    _asking = false;
    onAsking?.call(false);
    _handle(start ? _parser.acceptMarker() : _parser.declineMarker());
  }

  /// Feed a chunk from the session's stdout. With [enabled] false and no
  /// control session in progress the chunk bypasses the parser entirely.
  void addBytes(Uint8List data, {bool enabled = true}) {
    if (_disposed) return;
    if (!enabled && !inControl) {
      // Release anything the parser was holding back (a partial marker)
      // before bypassing it.
      answer(false);
      for (final ev in _parser.finish()) {
        if (ev is TmuxPassthrough) onPassthrough(ev.data);
      }
      onPassthrough(data);
      return;
    }
    _handle(_parser.addBytes(data));
    if (_asking && _parser.heldBytes > maxHeldBytes) answer(false);
  }

  void _handle(List<TmuxEvent> events) {
    for (final ev in events) {
      switch (ev) {
        case TmuxPassthrough(:final data):
          onPassthrough(data);
        case TmuxMarkerHeld():
          _atMarker();
        case TmuxControlBegin():
          // (The parser begins a stream once; nothing makes a second one.)
          if (_controller != null) continue;
          final c = TmuxController(
            sendBytes: sendBytes,
            expectMarker: false,
            scrollback: scrollback,
            platform: platform,
            log: log,
          );
          _controller = c;
          c.handleEvents(const [TmuxControlBegin()]);
          onEnter(c);
        case TmuxControlEnd():
          _end(ev);
        default:
          _controller?.handleEvents([ev]);
      }
    }
  }

  /// At a marker, with what follows it held.
  void _atMarker() {
    final until = _askedForUntil;
    _askedForUntil = null;
    if (until != null && _clock().isBefore(until)) {
      _handle(_parser.acceptMarker());
      return;
    }
    final ask = onAsking;
    if (ask == null || _asked) {
      _handle(_parser.declineMarker());
      return;
    }
    _asked = true;
    _asking = true;
    ask(true);
  }

  /// The stream closed: release held bytes and end any control session.
  void finish() {
    if (_disposed) return;
    answer(false);
    for (final ev in _parser.finish()) {
      if (ev is TmuxPassthrough) onPassthrough(ev.data);
    }
    if (inControl) {
      _controller?.onTransportClosed();
      _end(null);
    }
  }

  /// Abandon control mode now (tmux wedged or dead): the terminal shows the
  /// raw stream again from the next byte.
  void forcePassthrough() {
    if (_disposed || !inControl) return;
    _parser.forcePassthrough();
    _end(null);
  }

  void _end(TmuxControlEnd? ev) {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    if (ev != null) c.handleEvents([ev]);
    onExit(c);
    c.dispose();
  }

  void dispose() {
    if (_disposed) return;
    if (_asking) onAsking?.call(false);
    _asking = false;
    _disposed = true;
    final c = _controller;
    _controller = null;
    c?.dispose();
  }
}
