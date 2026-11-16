// One X program running on its SSH host (4.0): the exec channel that
// runs the host script ([xProgramScript]), read until its first `ZSX` line.
// Then [socketPath] is the private Xvnc's VNC socket to open on the same
// connection, and [exited] completes with the program's exit status. Closing
// the channel ([close]) ends the program and its Xvnc on the host, and
// removes their folder.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zest_ssh_core/dartssh2.dart' show SSHClient, SSHSession;
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart';

class XProgramRun {
  XProgramRun._(this._session, this.socketPath, this.display, this._exited, this._stderr);

  /// How long the host script is given to say its first line: Xvnc itself
  /// gives up after 10 s on the host.
  static const readyTimeout = Duration(seconds: 20);

  /// The most of what the host prints before its first `ZSX` line (a login
  /// banner, a shell's noise) that is read; more is a failure.
  static const maxStdoutBytes = 64 * 1024;

  /// How much of the program's output (the channel's stderr) is kept: its
  /// last lines, for what is said when it ends as it starts.
  static const stderrTailBytes = 4096;

  final SSHSession _session;

  /// The private Xvnc's VNC socket on the host, in its 0700 folder.
  final String socketPath;

  /// The X display Xvnc took.
  final int display;
  final Completer<int?> _exited;
  final _StderrTail _stderr;
  int? _status;

  /// The program's exit status once it ended (null where the channel ended
  /// without saying, or while it runs).
  int? get exitStatus => _status;

  /// Completes when the host script ends: with the program's exit status,
  /// or null where the channel closed without one.
  Future<int?> get exited => _exited.future;

  /// The last lines the program printed (its stdout and stderr).
  String get output => _stderr.text;

  /// Ends it on the host: the script's stdin ends, and it stops the program
  /// and the Xvnc and removes their folder.
  void close() => _session.close();

  /// Runs [program] in a private Xvnc of [width] by [height] on [client]'s
  /// host, signed in already. [host] is what the host is called, for what is
  /// said when it fails ([ScreenFailure]); [onLog] is told what happened, with
  /// the program's name only, never its arguments.
  static Future<XProgramRun> start(
    SSHClient client, {
    required String program,
    required int width,
    required int height,
    String? host,
    Duration timeout = readyTimeout,
    void Function(String line)? onLog,
  }) async {
    final name = xProgramName(program);
    onLog?.call('xprogram: Starting $name in a private X server on the host (${width}x$height)');
    final SSHSession session;
    try {
      session = await client.execute(xProgramCommand(program, width, height));
    } on ScreenFailure {
      rethrow;
    } catch (e) {
      throw ScreenFailure(ScreenFailureKind.xProgramFailed, 'the SSH host refused to run the script ($e)', carrier: host);
    }
    final stderr = _StderrTail(stderrTailBytes);
    final ready = Completer<XProgramLine>();
    final exited = Completer<int?>();
    int? status;
    session.stderr.listen(stderr.add, onError: (Object _) {});
    final pending = BytesBuilder(copy: false);
    var seen = 0;
    late final StreamSubscription<Uint8List> out;
    void said(XProgramLine line) {
      if (line is XProgramExited) {
        status = line.status;
        if (!exited.isCompleted) exited.complete(line.status);
      }
      if (!ready.isCompleted) ready.complete(line);
    }

    out = session.stdout.listen((data) {
      seen += data.length;
      var start = 0;
      for (var i = 0; i < data.length; i++) {
        if (data[i] != 0x0a) continue;
        pending.add(Uint8List.sublistView(data, start, i));
        start = i + 1;
        final line = XProgramLine.parse(utf8.decode(pending.takeBytes(), allowMalformed: true).trimRight());
        if (line != null) said(line);
      }
      if (start < data.length) pending.add(Uint8List.sublistView(data, start));
      // Before the ready line, a host that only talks is stopped; after it,
      // only the exit line is waited for, and nothing is kept but a line.
      if (!ready.isCompleted && seen > maxStdoutBytes) {
        ready.completeError(ScreenFailure(ScreenFailureKind.xProgramFailed,
            'the host printed more than ${maxStdoutBytes ~/ 1024} KB before the script answered',
            carrier: host));
      } else if (pending.length > 4096) {
        pending.clear();
      }
    }, onError: (Object _) {}, onDone: () {
      if (!ready.isCompleted) {
        final said = stderr.lastLines(3);
        ready.completeError(ScreenFailure(ScreenFailureKind.xProgramFailed,
            said.isEmpty ? 'the host script ended without a word' : 'the host script ended: $said',
            carrier: host));
      }
      if (!exited.isCompleted) exited.complete(status);
    });

    final XProgramLine first;
    try {
      first = await ready.future.timeout(timeout, onTimeout: () {
        throw ScreenFailure(ScreenFailureKind.xProgramFailed,
            'no answer from the host script within ${timeout.inSeconds} s', carrier: host);
      });
    } catch (_) {
      session.close();
      unawaited(out.cancel());
      rethrow;
    }
    switch (first) {
      case XProgramReady():
        onLog?.call('xprogram: $name started on display :${first.display}; its X server listens only on a private '
            'socket');
        final run = XProgramRun._(session, first.socket, first.display, exited, stderr);
        // The exit line, when it comes, is the run's.
        run._status = status;
        run._watch(exited.future);
        return run;
      case XProgramError():
        session.close();
        if (first.toolMissing) {
          final tool = first.error == 'no-xvnc' ? 'Xvnc' : 'xauth';
          onLog?.call('xprogram: The host has no $tool (package manager: ${first.pm ?? 'none known'})');
          throw ScreenFailure(ScreenFailureKind.xProgramToolsMissing, 'the host has no $tool',
              carrier: host, hint: xProgramInstallCommand(first.pm));
        }
        final more = stderr.lastLines(3);
        throw ScreenFailure(ScreenFailureKind.xProgramFailed, more.isEmpty ? first.error : '${first.error}: $more',
            carrier: host);
      case XProgramExited():
        session.close();
        final more = stderr.lastLines(3);
        onLog?.call('xprogram: $name ended as it started (exit status ${first.status})'
            '${more.isEmpty ? '' : ': $more'}');
        throw ScreenFailure(ScreenFailureKind.xProgramEnded, 'exit status ${first.status}',
            carrier: host, hint: name, exitStatus: first.status);
    }
  }

  void _watch(Future<int?> done) {
    unawaited(done.then((s) => _status = s ?? _status));
  }
}

/// The last [max] bytes of a stream, kept as they come.
class _StderrTail {
  _StderrTail(this.max);
  final int max;
  final _bytes = <int>[];

  void add(Uint8List data) {
    _bytes.addAll(data.length > max ? Uint8List.sublistView(data, data.length - max) : data);
    if (_bytes.length > max) _bytes.removeRange(0, _bytes.length - max);
  }

  String get text => utf8.decode(_bytes, allowMalformed: true);

  /// The last [n] lines, joined with " / ", at most 300 characters.
  String lastLines(int n) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final last = lines.length > n ? lines.sublist(lines.length - n) : lines;
    final joined = last.join(' / ');
    return joined.length > 300 ? joined.substring(joined.length - 300) : joined;
  }
}
