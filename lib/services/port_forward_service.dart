import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/forward_relay.dart';
import 'package:zestssh/services/socks5_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Type of port forwarding.
enum PortForwardType {
  local, // -L: local port → remote host:port through SSH
  remote, // -R: remote port → local host:port through SSH
  dynamic, // -D: SOCKS5 proxy tunneling all traffic through SSH
}

/// Represents an active or configured port forward.
class PortForward {
  final String id;
  final PortForwardType type;
  final String bindAddress;
  final int bindPort;
  final String remoteHost;
  final int remotePort;
  final bool isActive;
  final String? label;
  final bool autoStart;

  const PortForward({
    required this.id,
    required this.type,
    this.bindAddress = '127.0.0.1',
    required this.bindPort,
    required this.remoteHost,
    required this.remotePort,
    this.isActive = false,
    this.label,
    this.autoStart = false,
  });

  PortForward copyWith({bool? isActive}) => PortForward(
        id: id,
        type: type,
        bindAddress: bindAddress,
        bindPort: bindPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
        isActive: isActive ?? this.isActive,
        label: label,
        autoStart: autoStart,
      );

  /// Human-readable description.
  String get description {
    switch (type) {
      case PortForwardType.local:
        return '$bindAddress:$bindPort → $remoteHost:$remotePort';
      case PortForwardType.remote:
        return '$remoteHost:$remotePort → $bindAddress:$bindPort';
      case PortForwardType.dynamic:
        return 'SOCKS5 on $bindAddress:$bindPort';
    }
  }
}

/// A connection of a running forward that could not be made, and what it
/// failed with: where the host did not open the way an [SSHChannelOpenError]
/// (its reason code, and what the host said), and for a forward from a port
/// on the host a [SocketException], where this device could not connect to
/// what the forward leads to.
///
/// It is said once for a forward, and again when a connection of the
/// forward has been made since, or when the forward was stopped and started
/// again: a program that goes on trying does not make it be said over and
/// over.
class ForwardTrouble {
  const ForwardTrouble(this.forward, this.error);

  /// The forward whose connection it was.
  final PortForward forward;

  final Object error;
}

/// Maximum number of concurrent active port forwards per service instance.
///
/// This prevents resource exhaustion from runaway or misconfigured forward
/// rules. The limit is generous enough for normal use but caps unbounded
/// growth.
const int maxConcurrentForwards = 50;

/// Maximum number of simultaneous tunnelled connections a single forward rule
/// (local `-L` or remote `-R`) will service before it starts rejecting new
/// ones. Prevents a flood of connections from exhausting file descriptors.
const int maxForwardConnectionsPerRule = 128;

/// Addresses considered safe for local-only binding (not network-exposed).
const _safeBindAddresses = {'127.0.0.1', 'localhost', '::1'};

/// Manages SSH port forwarding (local, remote, and dynamic SOCKS5).
///
/// Uses dartssh2's [SSHClient] to create port forward tunnels.
///
/// For local forwards (`-L`), we bind a real TCP [ServerSocket] on the
/// requested address/port and, for every accepted connection, open an
/// SSH `direct-tcpip` channel to the remote target. Data is then relayed
/// bidirectionally between the local socket and the SSH channel.
///
/// dartssh2's [SSHClient.forwardLocal] only opens a single SSH channel -
/// it does **not** bind a local socket. We therefore handle the listening
/// side ourselves, matching the behaviour of OpenSSH's `-L` flag.
///
/// Dynamic forwards use [Socks5ProxyServer] to create a local SOCKS5
/// proxy that tunnels all traffic through the SSH connection.
class PortForwardService {
  final SSHClient _client;
  final Map<String, dynamic> _activeForwards = {};
  final Map<String, Socks5ProxyServer> _socks5Servers = {};
  final Map<String, _LocalForwardServer> _localForwardServers = {};
  final Map<String, _RemoteForwardServer> _remoteForwardServers = {};
  final _statusController =
      StreamController<Map<String, bool>>.broadcast();

  PortForwardService(this._client);

  /// How a remote forward connects to where it hands its connections on to,
  /// on this device or on its network. (A test puts a slow one here.)
  @visibleForTesting
  static Future<Socket> Function(String host, int port) debugLocalDial = _connectTo;

  static Future<Socket> _connectTo(String host, int port) => Socket.connect(host, port);

  /// Stream of forward status changes (id -> isActive).
  Stream<Map<String, bool>> get statusChanges => _statusController.stream;

  final _troubleController = StreamController<ForwardTrouble>.broadcast();

  /// What keeps the connections of a running forward from being made, as it
  /// comes up (see [ForwardTrouble] for how often). A forward that runs and
  /// lets nothing through said nothing: its connections ended, and a line
  /// in the log was all there was of why.
  Stream<ForwardTrouble> get troubles => _troubleController.stream;

  /// The forwards of which it has been said, by their ids: until a
  /// connection of theirs is made, or they are stopped.
  final Set<String> _saidOf = {};

  void _trouble(PortForward forward, Object error) {
    if (_saidOf.add(forward.id)) _troubleController.add(ForwardTrouble(forward, error));
  }

  /// Returns `true` if [bindAddress] is a non-local address that would
  /// expose the forwarded port to the network. Callers should use this
  /// to prompt a confirmation dialog before proceeding.
  static bool isNonLocalBind(String bindAddress) {
    return !_safeBindAddresses.contains(bindAddress.toLowerCase());
  }

  /// Where a saved forward listens on this device: [bindAddress], or every
  /// address of the device (0.0.0.0) where "Allow other devices on my
  /// network" ([gatewayPorts]) is on, as `ssh -g` does (22 October 2026: the
  /// switch changed only the command shown, never the app's own forward).
  /// A forward from a port on the host listens there, not here, so it is
  /// left as it is.
  ///
  /// No address at all (a host file shared or restored without one) is an
  /// address of its own: 0.0.0.0 where other devices are allowed and
  /// 127.0.0.1 where not, as the app shows it (forwardListensOn, in network_bind_confirm.dart). It was
  /// left empty, which the listener took for 127.0.0.1 while the app said
  /// 0.0.0.0 (found in a security review).
  static String bindAddressFor(PortForwardType type, String bindAddress, {required bool gatewayPorts}) {
    if (type == PortForwardType.remote) return bindAddress;
    if (bindAddress.trim().isEmpty) return gatewayPorts ? '0.0.0.0' : '127.0.0.1';
    if (!gatewayPorts) return bindAddress;
    return isNonLocalBind(bindAddress) ? bindAddress : '0.0.0.0';
  }

  /// Where a forward from a port on the host listens there ([remoteHost], the
  /// address it asks the host for): every address of the host where "Let
  /// other machines reach it" ([gatewayPorts]) is on, as
  /// `ssh -R 0.0.0.0:port:...` asks; the host's SSH server decides whether
  /// it may (its GatewayPorts). Other forwards are left as they are.
  static String remoteHostFor(PortForwardType type, String remoteHost, {required bool gatewayPorts}) {
    if (!gatewayPorts || type != PortForwardType.remote) return remoteHost;
    return remoteHost.trim().isEmpty || !isNonLocalBind(remoteHost) ? '0.0.0.0' : remoteHost;
  }

  /// Throws if adding another forward would exceed [maxConcurrentForwards].
  void _checkConcurrentLimit() {
    if (_activeForwards.length >= maxConcurrentForwards) {
      throw StateError(
        'Concurrent port forward limit reached ($maxConcurrentForwards). '
        'Stop an existing forward before starting a new one.',
      );
    }
  }

  /// Start a local port forward.
  ///
  /// Binds a real TCP [ServerSocket] on [forward.bindAddress]:[forward.bindPort]
  /// and tunnels every accepted connection to
  /// [forward.remoteHost]:[forward.remotePort] through the SSH connection
  /// via a `direct-tcpip` channel.
  Future<void> startLocalForward(PortForward forward) async {
    _checkConcurrentLimit();
    if (_activeForwards.containsKey(forward.id)) {
      throw StateError('Forward ${forward.id} is already active');
    }

    if (isNonLocalBind(forward.bindAddress)) {
      AppLogger.warning(
        'Port forward binding to non-local address '
        '"${forward.bindAddress}" - this exposes the tunnel to the network.',
      );
    }

    AppLogger.info(
      'Starting local forward: ${forward.bindPort} → '
      '${forward.remoteHost}:${forward.remotePort}',
    );

    final server = _LocalForwardServer(
      sshClient: _client,
      remoteHost: forward.remoteHost,
      remotePort: forward.remotePort,
      onTrouble: (error) => _trouble(forward, error),
      onConnected: () => _saidOf.remove(forward.id),
    );
    await server.start(
      bindAddress: forward.bindAddress,
      bindPort: forward.bindPort,
    );

    _localForwardServers[forward.id] = server;
    _activeForwards[forward.id] = server;
    _emitStatus();

    AppLogger.info(
      'Local forward started: ${forward.description} '
      '(listening on ${server.bindAddress}:${server.boundPort})',
    );
  }

  /// Start a remote port forward.
  ///
  /// Binds [remotePort] on the SSH server and tunnels connections
  /// back to [bindAddress]:[bindPort] on the local device.
  Future<void> startRemoteForward(PortForward forward) async {
    _checkConcurrentLimit();
    if (_activeForwards.containsKey(forward.id)) {
      throw StateError('Forward ${forward.id} is already active');
    }

    AppLogger.info(
      'Starting remote forward: ${forward.remoteHost}:${forward.remotePort} → '
      '${forward.bindAddress}:${forward.bindPort}',
    );

    final remoteForward = await _client.forwardRemote(
      host: forward.remoteHost,
      port: forward.remotePort,
    );

    // A server that refuses tcpip-forward returns null. Fail loudly instead of
    // registering a phantom "active" forward that binds nothing and relays
    // nothing.
    if (remoteForward == null) {
      throw StateError(
        'Server refused the remote forward for '
        '${forward.remoteHost}:${forward.remotePort}',
      );
    }

    // Relay every inbound channel from the server to a fresh local TCP socket.
    // Without this the core buffers inbound channels in an unread
    // StreamController forever and nothing is ever delivered locally.
    final server = _RemoteForwardServer(
      remoteForward: remoteForward,
      localHost: forward.bindAddress,
      localPort: forward.bindPort,
      onTrouble: (error) => _trouble(forward, error),
      onConnected: () => _saidOf.remove(forward.id),
    );
    server.start();

    _remoteForwardServers[forward.id] = server;
    _activeForwards[forward.id] = server;
    _emitStatus();

    AppLogger.info('Remote forward started: ${forward.description}');
  }

  /// Start a dynamic (SOCKS5) port forward.
  ///
  /// Starts a local SOCKS5 proxy server on [bindAddress]:[bindPort]
  /// that tunnels all CONNECT requests through the SSH connection.
  Future<void> startDynamicForward(PortForward forward) async {
    _checkConcurrentLimit();
    if (_activeForwards.containsKey(forward.id)) {
      throw StateError('Forward ${forward.id} is already active');
    }

    if (isNonLocalBind(forward.bindAddress)) {
      AppLogger.warning(
        'SOCKS5 forward binding to non-local address '
        '"${forward.bindAddress}" - this exposes the proxy to the network.',
      );
    }

    AppLogger.info(
      'Starting dynamic SOCKS5 forward on '
      '${forward.bindAddress}:${forward.bindPort}',
    );

    final proxy = Socks5ProxyServer(onRefusedByHost: (error) => _trouble(forward, error));
    await proxy.start(
      _client,
      bindAddress: forward.bindAddress,
      bindPort: forward.bindPort,
    );

    _socks5Servers[forward.id] = proxy;
    _activeForwards[forward.id] = proxy;
    _emitStatus();

    AppLogger.info('Dynamic SOCKS5 forward started: ${forward.description}');
  }

  /// Start a forward based on its type.
  Future<void> startForward(PortForward forward) async {
    switch (forward.type) {
      case PortForwardType.local:
        return startLocalForward(forward);
      case PortForwardType.remote:
        return startRemoteForward(forward);
      case PortForwardType.dynamic:
        return startDynamicForward(forward);
    }
  }

  /// Stop a port forward by ID.
  Future<void> stopForward(String id) async {
    _saidOf.remove(id);
    // Stop local forward server if this is a local forward
    final localServer = _localForwardServers.remove(id);
    if (localServer != null) {
      await localServer.stop();
    }

    // Stop remote forward server if this is a remote forward. This cancels the
    // inbound-channel subscription and calls SSHRemoteForward.close() so the
    // server actually un-binds the port (previously it stayed bound after Stop).
    final remoteServer = _remoteForwardServers.remove(id);
    if (remoteServer != null) {
      await remoteServer.stop();
    }

    // Stop SOCKS5 server if this is a dynamic forward
    final socks5 = _socks5Servers.remove(id);
    if (socks5 != null) {
      await socks5.stop();
    }

    final forward = _activeForwards.remove(id);
    if (forward != null) {
      try {
        if (forward is SSHForwardChannel) {
          forward.close();
        }
        // Socks5ProxyServer, _LocalForwardServer and _RemoteForwardServer are
        // already stopped above.
      } catch (_) {}
      AppLogger.info('Port forward stopped: $id');
    }
    // Emit unconditionally so the status stream stays truthful even when the id
    // was unknown or the forward failed to register.
    _emitStatus();
  }

  /// Stop all active port forwards.
  Future<void> stopAll() async {
    // Stop all local forward servers
    for (final server in _localForwardServers.values) {
      await server.stop();
    }
    _localForwardServers.clear();

    // Stop all remote forward servers
    for (final server in _remoteForwardServers.values) {
      await server.stop();
    }
    _remoteForwardServers.clear();

    // Stop all SOCKS5 servers
    for (final socks5 in _socks5Servers.values) {
      await socks5.stop();
    }
    _socks5Servers.clear();

    for (final entry in _activeForwards.entries) {
      try {
        if (entry.value is SSHForwardChannel) {
          entry.value.close();
        }
      } catch (_) {}
    }
    _activeForwards.clear();
    _emitStatus();
    AppLogger.info('All port forwards stopped');
  }

  /// Check if a forward is active.
  bool isActive(String id) => _activeForwards.containsKey(id);

  /// Get IDs of all active forwards.
  Set<String> get activeForwardIds => _activeForwards.keys.toSet();

  /// Get the [Socks5ProxyServer] for a dynamic forward, if active.
  Socks5ProxyServer? getSocks5Server(String id) => _socks5Servers[id];

  /// Get the [_LocalForwardServer] for a local forward, if active.
  ///
  /// Useful for reading the actual bound port (when the requested port was 0).
  int? getLocalForwardBoundPort(String id) =>
      _localForwardServers[id]?.boundPort;

  void _emitStatus() {
    final status = <String, bool>{};
    for (final id in _activeForwards.keys) {
      status[id] = true;
    }
    _statusController.add(status);
  }

  /// Clean up resources.
  Future<void> dispose() async {
    await stopAll();
    await _statusController.close();
    await _troubleController.close();
  }
}

/// A local TCP server that accepts connections and tunnels each one through
/// an SSH `direct-tcpip` channel to a fixed remote host:port.
///
/// This is the missing piece that makes `ssh -L` style forwarding work:
/// dartssh2's [SSHClient.forwardLocal] only opens a single SSH channel
/// without binding any local socket. This class handles the listening side.
class _LocalForwardServer {
  final SSHClient _sshClient;
  final String remoteHost;
  final int remotePort;

  ServerSocket? _server;

  /// The connections this device has taken for the forward that are not over
  /// yet, by their sockets: those for which the host is still opening the way
  /// among them.
  final Set<Socket> _connections = {};

  /// Told where the host did not open the way for a connection, with what
  /// it answered, and when it has opened one.
  final void Function(SSHChannelOpenError error) onTrouble;
  final void Function() onConnected;

  _LocalForwardServer({
    required SSHClient sshClient,
    required this.remoteHost,
    required this.remotePort,
    required this.onTrouble,
    required this.onConnected,
  }) : _sshClient = sshClient;

  /// Whether the server is currently listening.
  bool get isRunning => _server != null;

  /// The address the server is bound to, or `null` if not running.
  String? get bindAddress => _server?.address.address;

  /// The port the server is actually bound to, or `null` if not running.
  ///
  /// This may differ from the requested port when port 0 was requested
  /// (OS-assigned ephemeral port).
  int? get boundPort => _server?.port;

  /// Number of currently active tunnelled connections.
  int get activeConnections => _connections.length;

  /// Start listening for incoming TCP connections.
  Future<void> start({
    String bindAddress = '127.0.0.1',
    int bindPort = 0,
  }) async {
    if (_server != null) {
      throw StateError('Local forward server is already running');
    }

    _server = await ServerSocket.bind(forwardListenAddress(bindAddress), bindPort);
    AppLogger.info(
      'Local forward server listening on '
      '${_server!.address.address}:${_server!.port} '
      '→ $remoteHost:$remotePort',
    );

    _server!.listen(
      _handleClient,
      onError: (Object error) {
        AppLogger.error('Local forward server socket error', error);
      },
      onDone: () {
        AppLogger.info('Local forward server socket closed');
      },
    );
  }

  /// Stop the server and close all active connections, those whose way
  /// through the host is still being opened among them.
  Future<void> stop() async {
    AppLogger.info('Local forward server stopping...');

    final server = _server;
    _server = null;
    await server?.close();

    // What hands a connection on ends with its socket, and closes the way on
    // the host.
    for (final socket in _connections.toList()) {
      socket.destroy();
    }

    AppLogger.info('Local forward server stopped');
  }

  /// Handle an incoming client connection by opening an SSH channel
  /// and relaying data bidirectionally.
  Future<void> _handleClient(Socket clientSocket) async {
    // Cap concurrent tunnelled connections per rule to bound resource use.
    if (_connections.length >= maxForwardConnectionsPerRule) {
      AppLogger.warning(
        'Local forward: connection cap ($maxForwardConnectionsPerRule) '
        'reached - rejecting new client',
      );
      clientSocket.destroy();
      return;
    }

    AppLogger.debug(
      'Local forward: new connection from '
      '${clientSocket.remoteAddress.address}:${clientSocket.remotePort}',
    );

    _connections.add(clientSocket);
    final SSHForwardChannel channel;
    try {
      channel = await _sshClient.forwardLocal(remoteHost, remotePort);
    } catch (e, st) {
      AppLogger.error(
        'Local forward: failed to open SSH channel '
        'to $remoteHost:$remotePort',
        e,
        st,
      );
      _connections.remove(clientSocket);
      clientSocket.destroy();
      // A no of the host's is the forward's to say, while it runs. Anything
      // else is the connection to the host having ended, which its session
      // says.
      if (_server != null && e is SSHChannelOpenError) onTrouble(e);
      return;
    }
    onConnected();

    // Where the forward was stopped while the host opened the way, the
    // socket is gone: handing on to it is over at once, and that closes the
    // way on the host.
    ForwardRelay(
      socket: clientSocket,
      channel: channel,
      name: 'Local forward',
      onClosed: () => _connections.remove(clientSocket),
    ).start();
  }
}

/// Services a remote (`-R`) forward: for every inbound [SSHForwardChannel] the
/// server hands us, it dials a fresh local TCP socket and relays bidirectionally
/// (mirroring OpenSSH's `-R`). [stop] calls [SSHRemoteForward.close] so the
/// server actually un-binds the port.
class _RemoteForwardServer {
  final SSHRemoteForward remoteForward;
  final String localHost;
  final int localPort;

  /// The connections that are not over yet, by their sockets on this device.
  final Set<Socket> _connections = {};
  bool _stopped = false;

  /// Told where this device could not connect to what the forward leads
  /// to, with what that failed with, and when it has.
  final void Function(SocketException error) onTrouble;
  final void Function() onConnected;

  _RemoteForwardServer({
    required this.remoteForward,
    required this.localHost,
    required this.localPort,
    required this.onTrouble,
    required this.onConnected,
  });

  void start() {
    remoteForward.connections.listen(
      _handleChannel,
      onError: (Object error) {
        AppLogger.error('Remote forward inbound channel error', error);
      },
      onDone: () {
        AppLogger.info('Remote forward closed by server');
      },
    );
  }

  Future<void> _handleChannel(SSHForwardChannel channel) async {
    // Bound fan-in so a flood of inbound connections can't exhaust local FDs.
    if (_connections.length >= maxForwardConnectionsPerRule) {
      AppLogger.warning(
        'Remote forward: connection cap ($maxForwardConnectionsPerRule) '
        'reached - dropping inbound channel',
      );
      return _refuse(channel);
    }

    final Socket socket;
    try {
      socket = await PortForwardService.debugLocalDial(localHost, localPort);
    } catch (e) {
      AppLogger.warning(
        'Remote forward: local dial to $localHost:$localPort failed: $e',
      );
      if (!_stopped && e is SocketException) onTrouble(e);
      return _refuse(channel);
    }
    onConnected();
    if (_stopped) {
      // The forward was stopped while this end was being connected to.
      socket.destroy();
      return _refuse(channel);
    }

    _connections.add(socket);
    ForwardRelay(
      socket: socket,
      channel: channel,
      name: 'Remote forward',
      onClosed: () => _connections.remove(socket),
    ).start();
  }

  /// A connection the host handed over that leads nowhere is ended both
  /// ways. (Its own side alone was ended: whoever had connected on the host
  /// saw the end of what came, and could go on sending into nothing.)
  void _refuse(SSHForwardChannel channel) => channel.destroy();

  /// Stops the forward. A connection the host had handed over already, and
  /// that nobody has looked at yet, is still looked at, and refused: left
  /// alone it would stay open on the host with nobody at this end.
  Future<void> stop() async {
    _stopped = true;
    for (final socket in _connections.toList()) {
      socket.destroy();
    }
    try {
      remoteForward.close();
    } catch (e) {
      AppLogger.warning('Remote forward close failed: $e');
    }
  }
}
