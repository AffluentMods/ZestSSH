import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:zestssh/features/terminal/terminal_text_filter.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/utils/file_manager.dart' show restrictFileToOwner;

/// Continuous session logging: everything a session shows, written to a
/// plain-text file AS IT HAPPENS (a crash or a dropped link loses at most a
/// second of output). One file per session, opened when the session
/// connects and closed when it ends; a reconnect appends to the same file.
///
/// This is the always-on counterpart of the transcript recorder
/// ([SessionTranscriptService], started by hand, kept in memory, saved
/// encrypted): a session log is unencrypted on purpose, because its job is
/// to be opened in any editor later, which is also why the setting is off
/// by default and its description says a session's secrets end up in the
/// file too.
///
/// Escape sequences are stripped by [TerminalTextFilter], so the file reads
/// like the screen did. tmux panes log through the same writer, with a
/// marker line whenever output switches to another pane.
class SessionLogService {
  SessionLogService._();

  static final Map<String, _SessionLog> _logs = {};

  /// Paths of logs opened this process, kept after close so a reconnect
  /// continues the session's file instead of starting a new one.
  static final Map<String, String> _pathBySession = {};

  /// Called when a session's log stops because a write failed (disk full,
  /// folder removed). The message is for the connection log.
  static void Function(String sessionId, String message)? onError;

  /// Sub-folder of the app documents directory used when no folder is set.
  static const String defaultSubdir = 'ZestSSH/session-logs';

  static bool isLogging(String sessionId) => _logs.containsKey(sessionId);

  /// The file a session is (or was) logging to, or null.
  static String? pathOf(String sessionId) => _pathBySession[sessionId];

  /// The default log folder, created if absent.
  static Future<Directory> defaultDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    // A folder of each profile's own on a computer: plain text by design, so
    // anyone with this OS login can read it, as ever.
    final dir = ProfilePaths.forCurrent(Directory('${docs.path}/$defaultSubdir'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Resolve the folder to write into: [configured] when set and usable,
  /// else the default. Never throws.
  static Future<Directory> resolveDirectory(String configured) async {
    if (configured.trim().isNotEmpty) {
      try {
        final dir = Directory(configured.trim());
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return dir;
      } catch (_) {
        // Fall through to the default.
      }
    }
    return defaultDirectory();
  }

  /// Start logging [sessionId]. [label] names the file, [target] is the
  /// `user@host:port` line in the header. Returns the path, or null when
  /// the file could not be opened (already reported through [onError]).
  static Future<String?> start(
    String sessionId, {
    required String label,
    required String target,
    required String directory,
    required bool timestamps,
    bool? ownerOnly,
  }) async {
    if (_logs.containsKey(sessionId)) return _pathBySession[sessionId];
    try {
      final resumePath = _pathBySession[sessionId];
      final String path;
      if (resumePath != null && File(resumePath).existsSync()) {
        path = resumePath;
      } else {
        final dir = await resolveDirectory(directory);
        path = '${dir.path}${Platform.pathSeparator}'
            '${fileNameFor(label, DateTime.now())}';
      }
      // On Linux and macOS a new file takes the folder's defaults, which
      // usually let every account of the computer read it, and a session log
      // is what was typed and printed, secrets among it: a new log is the
      // person's own to read (found in a security audit). Windows keeps a
      // person's Documents to them already, and a phone keeps an app's files
      // to the app. Where it cannot be done the log is written all the same.
      if ((ownerOnly ?? (Platform.isLinux || Platform.isMacOS)) && !File(path).existsSync()) {
        File(path).createSync();
        await restrictFileToOwner(File(path));
      }
      final sink = File(path).openWrite(mode: FileMode.append);
      final log = _SessionLog(sessionId, path, sink, timestamps: timestamps);
      _logs[sessionId] = log;
      _pathBySession[sessionId] = path;
      if (resumePath == null) {
        log.writeHeader(target, _stamp(DateTime.now()));
      } else {
        log.writeMarker('Reconnected: ${_stamp(DateTime.now())}');
      }
      return path;
    } catch (e) {
      onError?.call(sessionId, 'log: could not open the session log ($e)');
      return null;
    }
  }

  /// Append output for a session (no-op when it is not logging).
  static void append(String sessionId, String text) {
    _logs[sessionId]?.append(text);
  }

  /// Output from a tmux pane of the session: a marker line is written when
  /// the source pane changes, so interleaved panes stay readable.
  static void appendPane(String sessionId, String paneId, String text) {
    _logs[sessionId]?.appendPane(paneId, text);
  }

  /// Finish the session's log: footer, flush, close. Safe to call twice.
  static Future<void> end(String sessionId) async {
    final log = _logs.remove(sessionId);
    if (log == null) return;
    await log.close('Session ended: ${_stamp(DateTime.now())}');
  }

  /// Close every open log (app shutdown).
  static Future<void> endAll() async {
    final ids = _logs.keys.toList();
    for (final id in ids) {
      await end(id);
    }
  }

  /// Forget a session's file so a later [start] with the same id begins a
  /// new file (the session entry was removed, not reconnected).
  static void forget(String sessionId) {
    _pathBySession.remove(sessionId);
  }

  /// `<label>_<yyyy-MM-dd>_<HH-mm-ss>.log`, with the label made safe for
  /// every filesystem (Windows reserved characters, control characters,
  /// trailing dots and spaces) and bounded in length.
  static String fileNameFor(String label, DateTime at) {
    var safe = label
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.length > 60) safe = safe.substring(0, 60).trimRight();
    if (safe.isEmpty) safe = 'session';
    final d = '${at.year.toString().padLeft(4, '0')}-'
        '${_two(at.month)}-${_two(at.day)}';
    final t = '${_two(at.hour)}-${_two(at.minute)}-${_two(at.second)}';
    return '${safe}_${d}_$t.log';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _stamp(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  /// Per-line prefix when timestamps are on.
  static String linePrefix(DateTime t) =>
      '[${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}] ';
}

class _SessionLog {
  _SessionLog(this.sessionId, this.path, this._sink, {required this.timestamps});

  final String sessionId;
  final String path;
  final IOSink _sink;
  final bool timestamps;
  final TerminalTextFilter _filter = TerminalTextFilter();

  /// One filter per tmux pane: each pane is its own byte stream, so a
  /// sequence split across chunks must not be confused with another pane's.
  final Map<String, TerminalTextFilter> _paneFilters = {};
  final StringBuffer _pending = StringBuffer();
  Timer? _flushTimer;

  /// The flush the sink is in, if any. An IOSink takes no write and no close
  /// while a flush runs ("StreamSink is bound to a stream"), so what comes
  /// meanwhile waits in [_pending] and goes when it ends. A write into a
  /// flush stopped the log at the first burst of output (found in a code
  /// review).
  Future<void>? _flushing;
  bool _closing = false;
  bool _atLineStart = true;
  bool _failed = false;
  String? _lastPane;

  /// Output is handed to the OS at most once per second, or sooner once
  /// this much is waiting, so a busy build log does not cost a syscall per
  /// network read.
  static const Duration flushEvery = Duration(seconds: 1);
  static const int flushAtBytes = 16 * 1024;

  void append(String text) {
    if (_failed) return;
    _write(_filter.feed(text));
  }

  void appendPane(String paneId, String text) {
    if (_failed) return;
    final filter = _paneFilters.putIfAbsent(paneId, TerminalTextFilter.new);
    final plain = filter.feed(text);
    if (plain.isEmpty) return;
    if (paneId != _lastPane) {
      _lastPane = paneId;
      if (!_atLineStart) _write('\n');
      _writeRaw('--- pane $paneId ---\n');
      _atLineStart = true;
    }
    _write(plain);
  }

  void writeHeader(String target, String started) {
    if (_failed) return;
    _writeRaw('=== ZestSSH session log ===\n'
        'Connection: $target\n'
        'Started: $started\n\n');
    _atLineStart = true;
    _scheduleFlush();
  }

  /// A `=== text ===` line of its own, separated from the output above.
  void writeMarker(String text) {
    if (_failed) return;
    if (!_atLineStart) _writeRaw('\n');
    _writeRaw('\n=== $text ===\n');
    _atLineStart = true;
    _scheduleFlush();
  }

  /// Plain text after filtering: apply the per-line timestamp, buffer it.
  void _write(String text) {
    if (text.isEmpty) return;
    if (!timestamps) {
      _writeRaw(text);
      _atLineStart = text.endsWith('\n');
      _scheduleFlush();
      return;
    }
    final prefix = SessionLogService.linePrefix(DateTime.now());
    final out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (_atLineStart) {
        out.write(prefix);
        _atLineStart = false;
      }
      out.write(ch);
      if (ch == '\n') _atLineStart = true;
    }
    _writeRaw(out.toString());
    _scheduleFlush();
  }

  void _writeRaw(String text) {
    _pending.write(text);
    if (_pending.length >= flushAtBytes) _flush();
  }

  void _scheduleFlush() {
    if (_closing) return;
    _flushTimer ??= Timer(flushEvery, _flush);
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    // While closing, [close] writes what is left itself.
    if (_failed || _closing || _flushing != null || _pending.isEmpty) return;
    final chunk = _pending.toString();
    _pending.clear();
    try {
      _sink.write(chunk);
      // flush() returns a future that completes when the OS has the bytes;
      // a failure there is the disk telling us to stop.
      _flushing = _sink.flush().then((_) {
        _flushing = null;
        // What came while it ran: now when there is a lot, else within the
        // second.
        if (_pending.length >= flushAtBytes) {
          _flush();
        } else if (_pending.isNotEmpty) {
          _scheduleFlush();
        }
      }, onError: (Object e) {
        _flushing = null;
        _fail(e);
      });
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (_failed) return;
    _failed = true;
    _pending.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    if (identical(SessionLogService._logs[sessionId], this)) {
      SessionLogService._logs.remove(sessionId);
    }
    SessionLogService.onError
        ?.call(sessionId, 'log: session log stopped, write failed ($e)');
    unawaited(_sink.close().catchError((_) {}));
  }

  Future<void> close(String footer) async {
    _closing = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    // The flush in flight ends first: the sink takes nothing until then.
    while (_flushing != null) {
      await _flushing;
    }
    if (_failed) return;
    _write(_filter.finish());
    if (!_atLineStart) _pending.write('\n');
    _pending.write('=== $footer ===\n');
    final chunk = _pending.toString();
    _pending.clear();
    try {
      _sink.write(chunk);
      await _sink.flush();
      await _sink.close();
    } catch (_) {
      // Nothing left to do for a log that is being closed anyway.
    }
  }
}
