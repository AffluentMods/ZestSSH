import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:zestssh/services/shell_client_missing.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/tool_path.dart';
import 'package:zestssh/utils/windows_programs.dart';
import 'package:zestssh/utils/wsl_key_file.dart';

/// The commands that install the Mosh client on [os] ('macos', 'linux' or
/// 'windows'), one to a line as they are typed in a terminal, in the order
/// they are run; the system a Linux line is for follows it in parentheses.
/// On Windows Mosh runs through WSL: WSL first, then Mosh inside it, as root
/// (it was `wsl apt install mosh`, which apt refuses without sudo). Shown
/// when a Mosh host is opened where the client is not installed
/// ([shellClientMissingText]).
List<String> moshInstallCommands(String os) => switch (os) {
      'macos' => const ['brew install mosh'],
      'linux' => const [
          'sudo apt install mosh   (Ubuntu, Debian)',
          'sudo dnf install mosh   (Fedora, RHEL)',
          'sudo pacman -S mosh   (Arch)',
        ],
      'windows' => const ['wsl --install', 'wsl sudo apt install mosh'],
      _ => const [],
    };

/// Mosh (Mobile Shell) protocol service.
///
/// On desktop platforms, launches the system `mosh` binary as a subprocess
/// and pipes I/O to the xterm terminal. On Windows, runs mosh through WSL.
///
/// On mobile (Android/iOS), Mosh requires native NDK/framework integration
/// which is not yet implemented. A helpful message is shown instead.
class MoshService implements ShellService {
  final String host;
  final int port;
  final String username;
  final String? sshIdentityPath;
  final String moshPorts;
  final String predict;

  Process? _process;
  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  bool _isConnected = false;
  bool _disposed = false;

  MoshService({
    required this.host,
    this.port = 22,
    required this.username,
    this.sshIdentityPath,
    this.moshPorts = '60000:61000',
    this.predict = 'adaptive',
  });

  /// Check if the `mosh` binary is available on this platform.
  ///
  /// On macOS/Linux, checks PATH for `mosh`.
  /// On Windows, checks if `wsl` is available and `mosh` is installed in WSL.
  /// On mobile, always returns false.
  static Future<bool> isAvailable() async {
    AppLogger.debug('MoshService: Checking mosh availability');

    if (Platform.isAndroid || Platform.isIOS) {
      AppLogger.debug('MoshService: Not available on mobile');
      return false;
    }

    try {
      if (Platform.isWindows) {
        // Check if WSL is available first
        if (!File(windowsSystemProgram('wsl.exe')).existsSync()) {
          AppLogger.debug('MoshService: WSL not found on Windows');
          return false;
        }
        // Check if mosh is installed inside WSL
        final moshResult = await Process.run(
          windowsSystemProgram('wsl.exe'),
          wslExecArguments('which', ['mosh']),
        );
        final available = moshResult.exitCode == 0;
        AppLogger.debug('MoshService: mosh in WSL available=$available');
        return available;
      } else {
        // macOS / Linux: where package managers put it too (toolPath).
        final available = findTool('mosh') != null;
        AppLogger.debug('MoshService: mosh available=$available');
        return available;
      }
    } catch (e) {
      AppLogger.error('MoshService: Error checking availability', e);
      return false;
    }
  }

  @override
  Future<void> connect() async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw const ShellClientMissing(ShellClient.mosh, onPhone: true);
    }

    AppLogger.info('MoshService: Connecting to $username@$host:$port');

    final args = _buildMoshArgs();

    if (Platform.isWindows) {
      // Run mosh through WSL
      AppLogger.info('MoshService: Launching mosh via WSL');
      _process = await Process.start(
        windowsSystemProgram('wsl.exe'),
        windowsArguments(args),
        mode: ProcessStartMode.normal,
      );
    } else {
      // macOS / Linux - run mosh directly, by its full path, with a PATH that
      // has where package managers put it (mosh starts mosh-client by name).
      _process = await Process.start(
        findTool('mosh') ?? 'mosh',
        args,
        mode: ProcessStartMode.normal,
        environment: {
          ...Platform.environment,
          'PATH': toolPath(),
          // Ensure mosh uses the correct terminal type
          'TERM': 'xterm-256color',
        },
      );
    }

    _isConnected = true;
    _connectionStateController.add(true);

    _process!.stdout.listen(
      (data) => _stdoutController.add(Uint8List.fromList(data)),
      onDone: _onDisconnected,
      onError: (error) {
        AppLogger.error('MoshService: stdout error', error);
        _onDisconnected();
      },
    );

    _process!.stderr.listen(
      (data) {
        _stderrController.add(Uint8List.fromList(data));
        // Also forward stderr to stdout so it shows in the terminal
        _stdoutController.add(Uint8List.fromList(data));
      },
    );

    _process!.exitCode.then((code) {
      AppLogger.info('MoshService: Process exited with code $code');
      _onDisconnected();
    });

    AppLogger.info('MoshService: mosh process started (pid=${_process!.pid})');
  }

  /// Build command-line arguments for the `mosh` binary.
  ///
  /// Security: all user-supplied values (host, username, identity path, ports)
  /// are validated against strict patterns before being interpolated into
  /// command arguments. The --ssh value is shell-quoted to prevent injection
  /// since mosh passes it through a shell.
  /// wsl.exe's arguments on Windows: `mosh` with [args] (the ones built
  /// for this session by default), started in WSL by `--exec`, never through
  /// the Linux account's shell ([wslExecArguments]).
  List<String> windowsArguments([List<String>? args]) => wslExecArguments('mosh', args ?? _buildMoshArgs());

  List<String> _buildMoshArgs() {
    // Validate host/username against shell metacharacter injection.
    // Allow alphanumerics, dots, hyphens, underscores, colons (IPv6).
    final safeHostPattern = RegExp(r'^[a-zA-Z0-9._:\[\]-]+$');
    final safeUserPattern = RegExp(r'^[a-zA-Z0-9._-]+$');

    // Nor may either start with a dash: mosh would read it as an option. (A
    // team's host brings its address and its key's user name in its record.)
    if (!safeHostPattern.hasMatch(host) || host.startsWith('-')) {
      throw ArgumentError('Invalid hostname: contains unsafe characters');
    }
    if (!safeUserPattern.hasMatch(username) || username.startsWith('-')) {
      throw ArgumentError('Invalid username: contains unsafe characters');
    }

    final args = <String>[];

    // Build custom --ssh command if we need non-default port or identity.
    // Each component is shell-quoted to prevent injection via the --ssh
    // string which mosh will pass through a shell.
    final sshParts = <String>['ssh'];
    if (port != 22) {
      if (port < 1 || port > 65535) {
        throw ArgumentError('Invalid port: $port');
      }
      sshParts.addAll(['-p', '$port']);
    }
    if (sshIdentityPath != null && sshIdentityPath!.isNotEmpty) {
      // Shell-quote the identity path to handle spaces and special chars
      final quotedPath = _shellQuote(sshIdentityPath!);
      sshParts.addAll(['-i', quotedPath]);
    }
    if (sshParts.length > 1) {
      args.addAll(['--ssh', sshParts.join(' ')]);
    }

    // Mosh UDP port range - validate format and numeric bounds
    final portRangeMatch = RegExp(r'^(\d+):(\d+)$').firstMatch(moshPorts);
    if (portRangeMatch == null) {
      throw ArgumentError('Invalid mosh port range format: $moshPorts');
    }
    final lowPort = int.parse(portRangeMatch.group(1)!);
    final highPort = int.parse(portRangeMatch.group(2)!);
    if (lowPort < 1 || lowPort > 65535 || highPort < 1 || highPort > 65535) {
      throw ArgumentError('Mosh port range out of bounds: $moshPorts');
    }
    args.addAll(['-p', moshPorts]);

    // Prediction mode - only allow known values
    const validPredictions = {'adaptive', 'always', 'never', 'experimental'};
    if (!validPredictions.contains(predict)) {
      throw ArgumentError('Invalid predict mode: $predict');
    }
    args.add('--predict=$predict');

    // Target: user@host
    args.add('$username@$host');

    return args;
  }

  /// Shell-quote a string for safe embedding in a shell command.
  /// Wraps in single quotes and escapes any embedded single quotes.
  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  void _onDisconnected() {
    if (_isConnected) {
      _isConnected = false;
      _connectionStateController.add(false);
      AppLogger.info('MoshService: Disconnected from $host');
    }
  }

  @override
  void write(Uint8List data) {
    _process?.stdin.add(data);
  }

  @override
  void resize(int width, int height) {
    // On Unix, the OS propagates SIGWINCH to the child process automatically
    // when the PTY is resized. Since we use Process.start (which allocates
    // a pipe, not a PTY), we write an xterm resize escape sequence to stdin
    // as a best-effort approach. The mosh-client handles terminal state
    // synchronization, so in practice this works via its SSP protocol.
    //
    // For full PTY resize support, a native PTY wrapper would be needed.
    // This is acceptable for the initial implementation since mosh's own
    // prediction engine handles most resize scenarios.
    AppLogger.debug('MoshService: resize request ${width}x$height');
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _disposed = true;
    AppLogger.info('MoshService: Disconnecting from $host');

    // Send Ctrl+D (EOF) first to allow graceful shutdown
    try {
      _process?.stdin.add(Uint8List.fromList([0x04]));
      await _process?.stdin.flush();
      await _process?.stdin.close();
    } catch (_) {
      // Ignore errors on stdin - process may already be gone
    }

    // Give a moment for graceful exit, then force kill
    final exitCode = await _process?.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        // Process.kill() sends SIGTERM on Unix, terminates on Windows
        _process?.kill();
        return _process!.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            // Force kill as last resort
            if (!Platform.isWindows) {
              _process?.kill(ProcessSignal.sigkill);
            }
            return -1;
          },
        );
      },
    );

    AppLogger.debug('MoshService: Process exited with code $exitCode');

    // Clean up temporary SSH identity file if one was created
    await _cleanupTempKeyFile();

    _onDisconnected();
    _stdoutController.close();
    _stderrController.close();
    _connectionStateController.close();
  }

  /// Remove the temporary SSH key file and its parent directory.
  Future<void> _cleanupTempKeyFile() async {
    if (sshIdentityPath == null) return;
    // On Windows the key is in WSL, where mosh ran (wsl_key_file.dart).
    if (Platform.isWindows) return removeKeyInWsl(sshIdentityPath!);
    try {
      final keyFile = File(sshIdentityPath!);
      if (await keyFile.exists()) {
        final parentDir = keyFile.parent;
        await keyFile.delete();
        // Remove the temp directory if it's now empty
        if (parentDir.path.contains('zestssh_mosh_')) {
          await parentDir.delete();
        }
      }
      AppLogger.debug('MoshService: Cleaned up temp key file');
    } catch (e) {
      AppLogger.warning('MoshService: Failed to clean up temp key file: $e');
    }
  }

  @override
  bool get isConnected => _isConnected;

  // Mosh is built to survive transient drops (roaming), so we don't
  // treat its disconnects as clean exits - the existing reconnect path
  // stays in charge.
  @override
  bool get exitedCleanly => false;

  @override
  bool get isEncryptedSsh => false;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;
}
