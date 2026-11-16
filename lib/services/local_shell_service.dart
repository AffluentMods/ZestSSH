import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Local Android shell implementation of [ShellService].
///
/// Opens `/system/bin/sh` on Android behind a REAL pseudo-terminal (via
/// `flutter_pty`, the forkpty-backed sibling to the vendored xterm), so the
/// shell has a controlling tty. That is the whole difference: interactive line
/// editing + history recall, tab completion, job control, Ctrl-C/Ctrl-Z
/// signals, live window resize, colour, and full-screen TUIs (vi / top / less)
/// all work - the same reasons the SSH terminal looks good, because a real PTY
/// sits behind it.
///
/// The previous pipe-based `Process.start('/system/bin/sh', ['-i'])` had none
/// of that: without a tty `isatty()` is false, so mksh never engaged its line
/// editor (arrow keys did nothing), Ctrl-C was a raw byte into a pipe rather
/// than a SIGINT, resize was a no-op, and TUIs rendered corrupted - hence
/// "barely useful".
///
/// Available on Android and on desktop (Windows / macOS / Linux) - each gets its
/// native shell (PowerShell, or the user's $SHELL). Not available on iOS, whose
/// sandbox forbids spawning processes. The UI must check [isAvailable] first.
class LocalShellService implements ShellService {
  Pty? _pty;
  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  bool _isConnected = false;
  bool _disposed = false;

  // A PTY carries a window size from the moment it starts. Track the terminal's
  // size so a resize that lands before the pty exists is applied at start, and
  // later resizes go straight to the tty (TIOCSWINSZ).
  int _cols = 80;
  int _rows = 25;

  /// Whether local shell is available on this platform: Android + desktop, but
  /// NOT iOS (its sandbox forbids spawning processes).
  static bool get isAvailable => Platform.isAndroid || isDesktopPlatform;

  @override
  Future<void> connect() async {
    if (!isAvailable) {
      throw UnsupportedError(
          'Local shell is not available on this platform (iOS sandbox).');
    }

    AppLogger.info('Opening local shell (PTY)');

    final String exe;
    final List<String> args;
    String? workingDirectory;
    final env = <String, String>{...Platform.environment};

    if (Platform.isAndroid) {
      // Android's process env is near-empty and its CWD (`/`) is unreadable by
      // an app UID, so curate: a terminal type, UTF-8 locale, a prompt, a PATH
      // that reaches the toolbox, and a writable HOME/TMPDIR (the app docs dir).
      exe = '/system/bin/sh';
      args = ['-i'];
      env['TERM'] = 'xterm-256color';
      env['LANG'] = 'C.UTF-8';
      env['PS1'] = r'\w \$ ';
      final existingPath = env['PATH'];
      if (existingPath == null || existingPath.isEmpty) {
        env['PATH'] = '/system/bin:/system/xbin';
      } else if (!existingPath.split(':').contains('/system/bin')) {
        env['PATH'] = '$existingPath:/system/bin:/system/xbin';
      }
      try {
        final h = (await getApplicationDocumentsDirectory()).path;
        env['HOME'] = h;
        env.putIfAbsent('TMPDIR', () => h);
        workingDirectory = h; // '/' is unreadable; start in our own HOME.
      } catch (e) {
        AppLogger.warning('Local shell: could not resolve HOME dir: $e');
      }
    } else {
      // Desktop: use the platform's native shell and inherit the real
      // environment. Do NOT override HOME/PATH/PS1 - desktop shells load their
      // own profile/rc, and clobbering the prompt or paths would break them.
      env['TERM'] = 'xterm-256color';
      if (Platform.isWindows) {
        // Launch PowerShell by ABSOLUTE path, never the relative
        // "powershell.exe": a relative name lets Windows CreateProcess search
        // the launch/current directory ahead of System32, so a planted
        // powershell.exe could be run instead. Fall back to cmd via ComSpec if
        // the canonical PowerShell isn't present. -NoLogo suppresses the banner.
        final sysRoot = Platform.environment['SystemRoot'] ??
            Platform.environment['windir'] ??
            r'C:\Windows';
        final psPath =
            '$sysRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        if (File(psPath).existsSync()) {
          exe = psPath;
          args = ['-NoLogo'];
        } else {
          exe = Platform.environment['ComSpec'] ??
              '$sysRoot\\System32\\cmd.exe';
          args = const [];
        }
        workingDirectory = env['USERPROFILE'];
      } else {
        // macOS / Linux: honor the user's login shell so their aliases and
        // rc/profile load ('-il' = interactive login); sensible fallbacks.
        exe = (env['SHELL'] != null && env['SHELL']!.isNotEmpty)
            ? env['SHELL']!
            : (Platform.isMacOS ? '/bin/zsh' : '/bin/bash');
        args = ['-il'];
        workingDirectory = env['HOME'];
      }
    }

    final pty = Pty.start(
      exe,
      arguments: args,
      environment: env,
      workingDirectory: workingDirectory,
      columns: _cols,
      rows: _rows,
    );
    _pty = pty;

    _isConnected = true;
    _connectionStateController.add(true);

    // A PTY multiplexes stdout AND stderr onto the single master stream - there
    // is no separate stderr to fan in, so the old stdout/stderr-merge hack is
    // gone.
    pty.output.listen(
      (data) {
        if (!_disposed) _stdoutController.add(data);
      },
      onDone: _onDisconnected,
      onError: (Object error) {
        AppLogger.error('Local shell output error', error);
        _onDisconnected();
      },
    );

    // The child exiting (`exit`, or Ctrl-D - which now delivers a real EOF
    // through the tty) ends the session so the tab closes instead of hanging.
    pty.exitCode.then((code) {
      AppLogger.info('Local shell exited (code $code)');
      _onDisconnected();
    });

    AppLogger.info('Local shell opened');
  }

  void _onDisconnected() {
    if (_isConnected) {
      _isConnected = false;
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(false);
      }
      AppLogger.info('Local shell closed');
    }
  }

  @override
  void write(Uint8List data) => _pty?.write(data);

  @override
  void resize(int width, int height) {
    if (width <= 0 || height <= 0) return;
    _cols = width;
    _rows = height;
    // flutter_pty's resize is (rows, columns); the [ShellService] contract is
    // (width = columns, height = rows).
    _pty?.resize(height, width);
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _disposed = true;
    AppLogger.info('Closing local shell');
    try {
      _pty?.kill();
    } catch (_) {
      // Already exited - nothing to signal.
    }
    _onDisconnected();
    await _stdoutController.close();
    await _stderrController.close();
    await _connectionStateController.close();
  }

  @override
  bool get isConnected => _isConnected;

  // A local shell has no transport to "drop" - any exit is the process ending
  // (the user typed `exit` / Ctrl-D), which should close the tab like a clean
  // exit rather than offer a reconnect.
  @override
  bool get exitedCleanly => true;

  @override
  bool get isEncryptedSsh => false;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;
}
