import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:zestssh/services/shell_client_missing.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/tool_path.dart';
import 'package:zestssh/utils/windows_programs.dart';
import 'package:zestssh/utils/wsl_key_file.dart';

/// The commands that install the Eternal Terminal client on [os] ('macos',
/// 'linux' or 'windows'), one to a line as they are typed in a terminal, in
/// the order they are run; the system a Linux line is for follows it in
/// parentheses. On Windows it runs through WSL: WSL first, then et inside it.
/// Shown when an Eternal Terminal host is opened where the client is not
/// installed ([shellClientMissingText]).
List<String> etInstallCommands(String os) => switch (os) {
      'macos' => const ['brew install MisterTea/et/et'],
      'linux' => const [
          'sudo apt install et   (Ubuntu, Debian)',
          'sudo dnf install et   (Fedora)',
          'sudo pacman -S eternalterminal   (Arch)',
        ],
      'windows' => const ['wsl --install', 'wsl sudo apt install et'],
      _ => const [],
    };

/// Eternal Terminal (ET) protocol service: a remote shell that survives
/// network drops, sleep and roaming, reconnecting to the SAME session with
/// its scrollback intact. Shipped the way Mosh is: the system `et` client
/// runs as a subprocess (through WSL on Windows) and its I/O is piped to
/// the terminal; a session stays alive on the server between reconnects.
///
/// `et` authenticates over SSH first (it runs `etterminal` on the host to
/// exchange a per-session passkey), then talks its own TCP protocol to
/// `etserver` on [etPort] (2022 by default). The connection's port is the
/// SSH port and reaches `ssh` as `-oPort=`; an SSH key reaches it as
/// `-oIdentityFile=`. `et` executes ssh with an argv (no shell), so those
/// values are passed verbatim.
class EternalTerminalService implements ShellService {
  final String host;

  /// The SSH port used for the handshake (the connection's port).
  final int port;
  final String username;
  final String? sshIdentityPath;

  /// The etserver port on the remote host.
  final int etPort;

  Process? _process;
  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  bool _isConnected = false;
  bool _disposed = false;

  EternalTerminalService({
    required this.host,
    this.port = 22,
    required this.username,
    this.sshIdentityPath,
    this.etPort = defaultEtPort,
  });

  /// etserver's default listening port.
  static const int defaultEtPort = 2022;

  /// Check whether the `et` client is available on this platform.
  ///
  /// macOS / Linux look on PATH; Windows needs WSL with `et` installed in
  /// it; mobile never has it.
  static Future<bool> isAvailable() async {
    if (Platform.isAndroid || Platform.isIOS) return false;
    try {
      if (Platform.isWindows) {
        if (!File(windowsSystemProgram('wsl.exe')).existsSync()) {
          AppLogger.debug('EternalTerminalService: WSL not found');
          return false;
        }
        final et = await Process.run(windowsSystemProgram('wsl.exe'), wslExecArguments('which', ['et']));
        AppLogger.debug(
            'EternalTerminalService: et in WSL available=${et.exitCode == 0}');
        return et.exitCode == 0;
      }
      // Where package managers put it too (toolPath).
      final available = findTool('et') != null;
      AppLogger.debug('EternalTerminalService: et available=$available');
      return available;
    } catch (e) {
      AppLogger.error('EternalTerminalService: availability check failed', e);
      return false;
    }
  }

  @override
  Future<void> connect() async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw const ShellClientMissing(ShellClient.eternalTerminal, onPhone: true);
    }

    AppLogger.info(
        'EternalTerminalService: Connecting to $username@$host (ssh :$port, et :$etPort)');
    final args = buildArgs();

    if (Platform.isWindows) {
      _process = await Process.start(
        windowsSystemProgram('wsl.exe'),
        windowsArguments(args),
        mode: ProcessStartMode.normal,
      );
    } else {
      _process = await Process.start(
        findTool('et') ?? 'et',
        args,
        mode: ProcessStartMode.normal,
        environment: {
          ...Platform.environment,
          'PATH': toolPath(),
          'TERM': 'xterm-256color',
        },
      );
    }

    _isConnected = true;
    _connectionStateController.add(true);

    _process!.stdout.listen(
      (data) => _stdoutController.add(Uint8List.fromList(data)),
      onDone: _onDisconnected,
      onError: (Object error) {
        AppLogger.error('EternalTerminalService: stdout error', error);
        _onDisconnected();
      },
    );
    _process!.stderr.listen((data) {
      _stderrController.add(Uint8List.fromList(data));
      // et prints its connection progress and errors on stderr; the user
      // needs to see those in the terminal.
      _stdoutController.add(Uint8List.fromList(data));
    });
    _process!.exitCode.then((code) {
      AppLogger.info('EternalTerminalService: et exited with code $code');
      _onDisconnected();
    });
    AppLogger.info('EternalTerminalService: et started (pid=${_process!.pid})');
  }

  /// The `et` argv. Host and username are validated against a strict
  /// character set first: `et` execs ssh without a shell, so this is about
  /// never letting a stray option-looking value reach either binary.
  List<String> buildArgs() {
    final safeHost = RegExp(r'^[a-zA-Z0-9._:\[\]-]+$');
    final safeUser = RegExp(r'^[a-zA-Z0-9._-]+$');
    if (!safeHost.hasMatch(host) || host.startsWith('-')) {
      throw ArgumentError('Invalid hostname: contains unsafe characters');
    }
    if (!safeUser.hasMatch(username) || username.startsWith('-')) {
      throw ArgumentError('Invalid username: contains unsafe characters');
    }
    if (port < 1 || port > 65535) throw ArgumentError('Invalid port: $port');
    if (etPort < 1 || etPort > 65535) {
      throw ArgumentError('Invalid etserver port: $etPort');
    }

    final args = <String>['--port', '$etPort'];
    if (port != 22) args.addAll(['--ssh-option', 'Port=$port']);
    final key = sshIdentityPath;
    if (key != null && key.isNotEmpty) {
      args.addAll(['--ssh-option', 'IdentityFile=$key']);
      // The key is the one this connection is meant to use: do not let ssh
      // wander through ~/.ssh looking for others first.
      args.addAll(['--ssh-option', 'IdentitiesOnly=yes']);
    }
    // Explicit: the destination is the host, never a ~/.ssh/config alias.
    args.add('$username@$host');
    return args;
  }

  /// wsl.exe's arguments on Windows: `et` with [args] ([buildArgs] by
  /// default), started in WSL by `--exec`, never through the Linux
  /// account's shell ([wslExecArguments]).
  List<String> windowsArguments([List<String>? args]) => wslExecArguments('et', args ?? buildArgs());

  void _onDisconnected() {
    if (_isConnected) {
      _isConnected = false;
      _connectionStateController.add(false);
      AppLogger.info('EternalTerminalService: Disconnected from $host');
    }
  }

  @override
  void write(Uint8List data) {
    _process?.stdin.add(data);
  }

  @override
  void resize(int width, int height) {
    // Same limitation as Mosh: the child runs on pipes, not a PTY, so there
    // is no SIGWINCH to send; et's own terminal sync copes with most
    // resizes once the remote shell redraws.
    AppLogger.debug('EternalTerminalService: resize request ${width}x$height');
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _disposed = true;
    AppLogger.info('EternalTerminalService: Disconnecting from $host');

    // EOF first so the remote shell exits cleanly and et ends the session
    // on the server, then escalate.
    try {
      _process?.stdin.add(Uint8List.fromList([0x04]));
      await _process?.stdin.flush();
      await _process?.stdin.close();
    } catch (_) {
      // The process may already be gone.
    }

    final exitCode = await _process?.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _process?.kill();
        return _process!.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            if (!Platform.isWindows) _process?.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      },
    );
    AppLogger.debug('EternalTerminalService: et exited with code $exitCode');

    await _cleanupTempKeyFile();
    _onDisconnected();
    _stdoutController.close();
    _stderrController.close();
    _connectionStateController.close();
  }

  /// Remove the temporary SSH key file (and its directory) written for the
  /// handshake, the same way the Mosh service does.
  Future<void> _cleanupTempKeyFile() async {
    final path = sshIdentityPath;
    if (path == null) return;
    // On Windows the key is in WSL, where et ran (wsl_key_file.dart).
    if (Platform.isWindows) return removeKeyInWsl(path);
    try {
      final keyFile = File(path);
      if (await keyFile.exists()) {
        final parentDir = keyFile.parent;
        await keyFile.delete();
        if (parentDir.path.contains('zestssh_mosh_')) {
          await parentDir.delete();
        }
      }
    } catch (e) {
      AppLogger.warning(
          'EternalTerminalService: failed to clean up temp key file: $e');
    }
  }

  @override
  bool get isConnected => _isConnected;

  // ET reconnects on its own; a drop is never a clean exit, so the app's
  // reconnect path stays in charge, as with Mosh.
  @override
  bool get exitedCleanly => false;

  @override
  bool get isEncryptedSsh => false;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;
}
