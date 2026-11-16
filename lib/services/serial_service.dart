import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/utils/logger.dart';

/// Serial port parity settings.
///
/// Controls the parity bit used for error detection in serial
/// communication. Most modern devices use [none].
enum SerialParity {
  /// No parity bit (most common).
  none,

  /// Odd parity - parity bit set so total 1-bits is odd.
  odd,

  /// Even parity - parity bit set so total 1-bits is even.
  even,

  /// Mark parity - parity bit is always 1.
  mark,

  /// Space parity - parity bit is always 0.
  space,
}

/// Serial port flow control settings.
///
/// Controls how the sender and receiver coordinate data transfer
/// to prevent buffer overflows.
enum SerialFlowControl {
  /// No flow control (most common for short cables).
  none,

  /// Hardware flow control using RTS/CTS lines.
  /// Preferred for high-speed or long-distance connections.
  hardware,

  /// Software flow control using XON/XOFF characters.
  /// Works over any connection but reserves two byte values.
  software,
}

/// Configuration for a serial port connection.
///
/// Encapsulates all the settings needed to open a serial port:
/// baud rate, data bits, parity, stop bits, and flow control.
///
/// Use the named constructors for common device presets:
/// ```dart
/// final config = SerialConfig.cisco(); // 9600 8N1
/// final config = SerialConfig.custom(baudRate: 115200);
/// ```
class SerialConfig {
  /// The serial port name (e.g., 'COM3' on Windows, '/dev/ttyUSB0' on Linux,
  /// '/dev/tty.usbserial' on macOS).
  final String portName;

  /// Baud rate in bits per second.
  ///
  /// Common values: 9600, 19200, 38400, 57600, 115200.
  final int baudRate;

  /// Number of data bits per frame (typically 7 or 8).
  final int dataBits;

  /// Parity setting for error detection.
  final SerialParity parity;

  /// Number of stop bits (1 or 2).
  final int stopBits;

  /// Flow control method.
  final SerialFlowControl flowControl;

  const SerialConfig({
    required this.portName,
    this.baudRate = 9600,
    this.dataBits = 8,
    this.parity = SerialParity.none,
    this.stopBits = 1,
    this.flowControl = SerialFlowControl.none,
  });

  /// Preset for Cisco IOS devices.
  ///
  /// Standard console settings: 9600 baud, 8 data bits, no parity,
  /// 1 stop bit, no flow control (8N1).
  static SerialConfig cisco({String portName = ''}) => SerialConfig(
        portName: portName,
        baudRate: 9600,
        dataBits: 8,
        parity: SerialParity.none,
        stopBits: 1,
        flowControl: SerialFlowControl.none,
      );

  /// Preset for Juniper JUNOS devices.
  ///
  /// Standard console settings: 9600 baud, 8N1, no flow control.
  static SerialConfig juniper({String portName = ''}) => SerialConfig(
        portName: portName,
        baudRate: 9600,
        dataBits: 8,
        parity: SerialParity.none,
        stopBits: 1,
        flowControl: SerialFlowControl.none,
      );

  /// Preset for MikroTik RouterOS devices.
  ///
  /// Standard console settings: 115200 baud, 8N1, no flow control.
  static SerialConfig mikrotik({String portName = ''}) => SerialConfig(
        portName: portName,
        baudRate: 115200,
        dataBits: 8,
        parity: SerialParity.none,
        stopBits: 1,
        flowControl: SerialFlowControl.none,
      );

  /// Preset for Arista EOS devices.
  ///
  /// Standard console settings: 9600 baud, 8N1, no flow control.
  static SerialConfig arista({String portName = ''}) => SerialConfig(
        portName: portName,
        baudRate: 9600,
        dataBits: 8,
        parity: SerialParity.none,
        stopBits: 1,
        flowControl: SerialFlowControl.none,
      );

  /// Preset for HP/Aruba ProCurve switches.
  ///
  /// Standard console settings: 9600 baud, 8N1,
  /// with XON/XOFF flow control.
  static SerialConfig hpProcurve({String portName = ''}) => SerialConfig(
        portName: portName,
        baudRate: 9600,
        dataBits: 8,
        parity: SerialParity.none,
        stopBits: 1,
        flowControl: SerialFlowControl.software,
      );

  /// Custom configuration with sensible defaults.
  ///
  /// Only [baudRate] is required; all other parameters default to
  /// standard 8N1 settings.
  static SerialConfig custom({
    String portName = '',
    required int baudRate,
    int dataBits = 8,
    SerialParity parity = SerialParity.none,
    int stopBits = 1,
    SerialFlowControl flowControl = SerialFlowControl.none,
  }) =>
      SerialConfig(
        portName: portName,
        baudRate: baudRate,
        dataBits: dataBits,
        parity: parity,
        stopBits: stopBits,
        flowControl: flowControl,
      );

  /// Human-readable summary, e.g. "9600 8N1".
  String get summary {
    final parityChar = switch (parity) {
      SerialParity.none => 'N',
      SerialParity.odd => 'O',
      SerialParity.even => 'E',
      SerialParity.mark => 'M',
      SerialParity.space => 'S',
    };
    return '$baudRate $dataBits$parityChar$stopBits';
  }

  /// Common baud rates for UI dropdowns.
  static const List<int> commonBaudRates = [
    300,
    1200,
    2400,
    4800,
    9600,
    19200,
    38400,
    57600,
    115200,
    230400,
    460800,
    921600,
  ];

  @override
  String toString() => 'SerialConfig($portName, $summary)';
}

/// Serial-over-SSH service implementing [ShellService].
///
/// Connects to serial console servers (terminal servers / console
/// concentrators) via SSH, which bridge SSH connections to physical
/// serial ports on network equipment.
///
/// This is the most common way network engineers access serial consoles
/// remotely - devices like Opengear, Avocent, Digi, and Cisco terminal
/// servers expose serial ports over SSH on specific TCP ports.
///
/// ## How It Works
///
/// Instead of connecting directly to a serial port, this service:
/// 1. Establishes an SSH connection to the console server host
/// 2. Opens a PTY shell session (the console server bridges this to
///    the physical serial port)
/// 3. Provides transparent terminal I/O as if directly connected
///    to the serial device
///
/// ## Common Console Server Port Mappings
///
/// - **Opengear**: `ssh -p 3001 user@console-server` (port 300x = serial x)
/// - **Avocent ACS**: `ssh user@console-server:port_name`
/// - **Digi Passport**: `ssh -p 7001 user@console-server`
/// - **Cisco 2901/2951**: `telnet console-server 200x` (or reverse SSH)
///
/// ## Usage
///
/// ```dart
/// final service = SerialOverSshService(
///   host: 'console-server.example.com',
///   port: 3001, // Maps to serial port 1 on the console server
///   username: 'admin',
///   password: 'secret',
///   serialConfig: SerialConfig.cisco(),
///   onHostKeyVerify: (host, port, key) async => true,
/// );
/// await service.connect();
/// ```
class SerialOverSshService implements ShellService {
  /// Console server hostname or IP address.
  final String host;

  /// Console server SSH port (often maps to a specific serial port).
  ///
  /// Common mappings:
  /// - Opengear: 3001-3048 (serial ports 1-48)
  /// - Digi: 7001-7048
  /// - Generic: 2001-2048
  final int port;

  /// SSH username for the console server.
  final String username;

  /// SSH key pairs for authentication.
  final List<SSHKeyPair>? keyPairs;

  /// SSH password for authentication.
  final String? password;

  /// Fetches the password saved with the key, for a console server that
  /// does not take the key and takes passwords (3.0, accounts per host):
  /// called only then, and at most once.
  final Future<String?> Function()? passwordAfterKey;

  /// Serial configuration metadata (used for display/logging only -
  /// the actual serial parameters are configured on the console server).
  final SerialConfig serialConfig;

  /// Host key verification callback.
  final HostKeyVerifyCallback onHostKeyVerify;

  /// Optional connection progress logger.
  final ConnectionLogCallback? onLog;

  /// Shows the console server's keyboard-interactive questions to the
  /// person; null answers them empty (fails closed).
  final ServerQuestionAsker? onServerQuestion;

  /// Shows the console server's login banner with a link in it to the
  /// person while the sign-in waits on it ([SignInLinkBanners]), as a
  /// host's is shown. Null for a connection nobody is watching.
  final SignInNoticeShower? onSignInNotice;

  SSHClient? _client;

  /// The connection to the console server, for tests (which look at whether
  /// it was closed).
  @visibleForTesting
  SSHClient? get debugClient => _client;

  SSHSession? _shell;
  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  bool _isConnected = false;
  bool _disposed = false;

  SerialOverSshService({
    required this.host,
    required this.port,
    required this.username,
    this.keyPairs,
    this.password,
    this.passwordAfterKey,
    required this.serialConfig,
    required this.onHostKeyVerify,
    this.onLog,
    this.onServerQuestion,
    this.onSignInNotice,
    this.compatibilityMode = false,
    this.connectTimeout = const Duration(seconds: 15),
  });

  /// How long the connection to the console server may take to open
  /// (Settings).
  final Duration connectTimeout;

  /// Whether Compatibility mode is on for the console server: with it the
  /// app also offers what an old server needs ([SshService.buildAlgorithms]),
  /// and a console server is often an old one.
  final bool compatibilityMode;

  @override
  Future<void> connect() async {
    AppLogger.info(
      'Serial-over-SSH connecting to $username@$host:$port '
      '(${serialConfig.summary})',
    );
    onLog?.call(
      'serial: Connecting to console server $host:$port '
      '(serial config: ${serialConfig.summary})',
    );

    onLog?.call('Resolving $host...');
    final socket = await openSshSocket(host, port, connectTimeout);
    onLog?.call('tcp_connect: Connected to $host:$port');

    onLog?.call('ssh_session: Starting SSH-2.0 protocol negotiation');

    final laterPassword = passwordAfterKey;
    final authMethod = keyPairs != null && keyPairs!.isNotEmpty
        ? (laterPassword != null ? 'publickey, then the password saved with the key' : 'publickey')
        : (password != null ? 'password' : 'none');
    onLog?.call('ssh_auth: Authenticating as $username ($authMethod)');

    // Keyboard-interactive through the shared answerer: the password only
    // for a real password prompt, once; a 2FA code from the person when
    // someone is watching, empty otherwise. The auth clock stops while they
    // answer. The server's text is never logged (log injection).
    final deadline = AuthDeadline();
    final questionsWithdrawn = Completer<void>();
    final serverQuestion = onServerQuestion;
    final answerer = KeyboardInteractiveAnswerer(
      password: password,
      // The clock stops while it is fetched: that can ask the person.
      passwordAfterKey: laterPassword == null ? null : () => deadline.whileAsking(laterPassword),
      ask: serverQuestion == null
          ? null
          : (question) => deadline.whileAsking(() => serverQuestion(question)),
      withdrawn: questionsWithdrawn.future,
      onServerActive: () => deadline.relax(kServerQuestionPatience),
      onLog: onLog,
    );
    final links = SignInLinkBanners(onSignInNotice, deadline: deadline, withdrawn: questionsWithdrawn.future, onLog: onLog);

    _client = SSHClient(
      socket,
      username: username,
      identities: signingOffTheClock(keyPairs, deadline),
      algorithms: SshService.buildAlgorithms(compatibility: compatibilityMode),
      onPasswordRequest: password != null
          ? () => password!
          // Asked only once the console server did not take the key.
          : laterPassword != null
              ? () => sendPasswordAfterKey(answerer, onLog)
              : null,
      onUserInfoRequest: answerer.handler,
      onUserauthBanner: (message) {
        onLog?.call('ssh_auth: Server sent a login banner');
        links.banner(message);
      },
      onVerifyHostKey: (String type, Uint8List keyBlob) async {
        onLog?.call('ssh_hostkey: Verifying host key ($type)');
        final sshHostKey = SSHHostKey(type: type, bytes: keyBlob);
        // (The clock stops while its person is asked about this key, as in
        // SshService for a host: it ran, and whoever read a fingerprint for
        // longer than a server is given had the sign-in time out.)
        final bool accepted;
        try {
          accepted = await deadline.whileAsking(() => onHostKeyVerify(host, port, sshHostKey));
        } on HostKeyNotAccepted catch (e) {
          onLog?.call('ssh_hostkey: Host key REJECTED (${e.why.name})');
          rethrow;
        }
        onLog?.call(accepted
            ? 'ssh_hostkey: Host key accepted'
            : 'ssh_hostkey: Host key REJECTED');
        return accepted;
      },
      onAuthenticated: () {
        AppLogger.info('Serial-over-SSH authenticated to $host:$port');
        onLog?.call('ssh_auth: SSH_AUTH_SUCCESS - authenticated');
      },
      keepAliveInterval: const Duration(seconds: 15),
    );

    try {
      await deadline.wait(links.orCancelled(_client!.authenticated));
    } catch (e) {
      _client?.close();
      _client = null;
      if (answerer.cancelled || links.cancelled) throw const SshPromptCancelled();
      // What stopped the password saved with the key from going, or a
      // question (a run with nobody there to answer it): said as that.
      final stopped = answerer.stoppedBy;
      if (stopped != null) throw stopped;
      rethrow;
    } finally {
      if (!questionsWithdrawn.isCompleted) questionsWithdrawn.complete();
    }

    onLog?.call('serial: Opening serial console session (xterm-256color)');
    try {
      _shell = await _client!.shell(
        pty: const SSHPtyConfig(type: 'xterm-256color'),
      );
    } catch (e) {
      // Signed in, and then no console session. As for a host
      // (SshService.connect): nothing would hold the connection after the
      // failure, so it is closed here, where it stayed open.
      onLog?.call('serial: No session - $e');
      await disconnect();
      final noSession = SshNoSessionException.of(e);
      if (noSession != null) throw noSession;
      rethrow;
    }

    _isConnected = true;
    _connectionStateController.add(true);
    onLog?.call(
      'serial: Console session established - '
      'connected to ${serialConfig.portName.isNotEmpty ? serialConfig.portName : "serial port"} '
      'via $host:$port',
    );
    AppLogger.info('Serial-over-SSH connected to $host:$port');

    _stdoutSubscription = _shell!.stdout.listen(
      (data) => _stdoutController.add(data),
      onDone: _onDisconnected,
      onError: (error) {
        AppLogger.error('Serial-over-SSH stdout error', error);
        _onDisconnected();
      },
    );

    _stderrSubscription = _shell!.stderr.listen(
      (data) => _stderrController.add(data),
    );
  }

  void _onDisconnected() {
    if (_isConnected) {
      _isConnected = false;
      _connectionStateController.add(false);
      AppLogger.info('Serial-over-SSH disconnected from $host:$port');
    }
  }

  @override
  void write(Uint8List data) => _shell?.write(data);

  @override
  void resize(int width, int height) {
    _shell?.resizeTerminal(width, height);
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _disposed = true;
    AppLogger.info('Serial-over-SSH disconnecting from $host:$port');
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _shell?.close();
    _client?.close();
    _onDisconnected();
    _stdoutController.close();
    _stderrController.close();
    _connectionStateController.close();
  }

  @override
  bool get isConnected => _isConnected;

  // A serial port closing is the session ending - close, don't reconnect.
  @override
  bool get exitedCleanly => true;

  // Serial-over-SSH is encrypted, but historically shows no padlock / SSH
  // affordances (it is not an SshService). Keep that behaviour unchanged.
  @override
  bool get isEncryptedSsh => false;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;

  /// Send a break signal by writing the SSH break request.
  ///
  /// Some console servers translate this to a serial break signal,
  /// which is useful for operations like Cisco password recovery.
  /// The actual behavior depends on the console server's configuration.
  void sendBreak() {
    if (_shell != null) {
      // Send Ctrl+Break / telnet-style break sequence
      // Most console servers interpret \x1b\x42 or ~B as break
      _shell!.write(Uint8List.fromList([0x1b, 0x42])); // ESC B
      AppLogger.debug('Serial-over-SSH: Break signal sent');
      onLog?.call('serial: Break signal sent');
    }
  }
}

/// Serial port connection service.
///
/// Provides methods for connecting to serial devices via SSH console
/// servers (terminal servers / serial concentrators).
///
/// For direct USB serial access, the `flutter_libserialport` package
/// would be required. This implementation focuses on the most common
/// enterprise use case: remote serial console access via SSH.
///
/// ## Supported Console Servers
///
/// - Opengear (CM7100, OM2200, etc.)
/// - Avocent ACS (6000, 8000 series)
/// - Digi Passport / Connect
/// - Cisco terminal servers (reverse SSH/telnet)
/// - Lantronix SLC
/// - Any SSH-accessible serial concentrator
///
/// ## Port Mapping Convention
///
/// Console servers typically map serial ports to TCP ports:
/// ```
/// Serial Port 1 → SSH port 3001 (Opengear) / 7001 (Digi) / 2001 (generic)
/// Serial Port 2 → SSH port 3002 / 7002 / 2002
/// ...
/// ```
class SerialService {
  /// Well-known console server port ranges for auto-detection.
  static const Map<String, int> consoleServerBasePort = {
    'opengear': 3000,
    'digi': 7000,
    'avocent': 3000,
    'lantronix': 10001,
    'generic': 2000,
  };

  /// Create a [SerialOverSshService] for connecting to a serial device
  /// through a console server via SSH.
  ///
  /// [host] is the console server hostname/IP.
  /// [port] is the SSH port on the console server that maps to the
  /// desired serial port.
  /// [serialConfig] describes the serial parameters (for display only -
  /// actual serial settings are configured on the console server).
  static SerialOverSshService createSshSession({
    required String host,
    required int port,
    required String username,
    String? password,
    List<SSHKeyPair>? keyPairs,
    required SerialConfig serialConfig,
    required HostKeyVerifyCallback onHostKeyVerify,
    ConnectionLogCallback? onLog,
    ServerQuestionAsker? onServerQuestion,
    bool compatibilityMode = false,
  }) {
    return SerialOverSshService(
      host: host,
      port: port,
      username: username,
      password: password,
      keyPairs: keyPairs,
      serialConfig: serialConfig,
      onHostKeyVerify: onHostKeyVerify,
      onLog: onLog,
      onServerQuestion: onServerQuestion,
      compatibilityMode: compatibilityMode,
    );
  }

  /// Calculate the SSH port for a given serial port number on a
  /// console server, using the vendor's base port convention.
  ///
  /// Example:
  /// ```dart
  /// final port = SerialService.consolePort('opengear', 5);
  /// // Returns 3005 (Opengear base 3000 + serial port 5)
  /// ```
  static int consolePort(String vendor, int serialPortNumber) {
    final base = consoleServerBasePort[vendor.toLowerCase()];
    if (base == null) {
      throw ArgumentError(
        'Unknown console server vendor: $vendor. '
        'Known vendors: ${consoleServerBasePort.keys.join(", ")}',
      );
    }
    return base + serialPortNumber;
  }

  /// List common device presets for the UI.
  ///
  /// Returns a map of preset name to [SerialConfig] for use in
  /// dropdown menus when configuring a serial connection.
  static Map<String, SerialConfig> get devicePresets => {
        'Cisco IOS (9600 8N1)': SerialConfig.cisco(),
        'Juniper JUNOS (9600 8N1)': SerialConfig.juniper(),
        'MikroTik RouterOS (115200 8N1)': SerialConfig.mikrotik(),
        'Arista EOS (9600 8N1)': SerialConfig.arista(),
        'HP/Aruba ProCurve (9600 8N1 XON/XOFF)': SerialConfig.hpProcurve(),
        'Custom': SerialConfig.custom(baudRate: 9600),
      };
}
