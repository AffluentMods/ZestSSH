import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/forward_relay.dart';
import 'package:zestssh/utils/logger.dart';

/// SOCKS5 proxy server that tunnels traffic through an SSH connection.
///
/// Implements RFC 1928 (SOCKS Protocol Version 5) with support for the
/// CONNECT command (0x01) and three address types:
/// - IPv4 (0x01)
/// - Domain name (0x03)
/// - IPv6 (0x04)
///
/// Only "no authentication" (method 0x00) is supported, as the proxy
/// is intended for local use only (bound to 127.0.0.1 by default).
///
/// Usage:
/// ```dart
/// final proxy = Socks5ProxyServer();
/// await proxy.start(sshClient, bindPort: 1080);
/// // Configure browser/app to use SOCKS5 proxy at 127.0.0.1:1080
/// // ...
/// await proxy.stop();
/// ```
/// Maximum simultaneous client connections a single SOCKS5 proxy will service
/// before it starts rejecting new ones (bounds resource use under a flood).
const int maxSocks5Connections = 128;

class Socks5ProxyServer {
  Socks5ProxyServer({this.onRefusedByHost});

  /// Told where the host answered that it passes no connections on at all,
  /// which is the proxy's own trouble. (A place the host could not connect
  /// to is that place's, and the program that asked for it is told.)
  final void Function(SSHChannelOpenError error)? onRefusedByHost;

  ServerSocket? _server;
  SSHClient? _client;
  final Set<_Socks5Connection> _connections = {};
  int _totalBytesTransferred = 0;

  // SOCKS5 protocol constants
  static const int _socks5Version = 0x05;
  static const int _authNone = 0x00;
  static const int _authNoAcceptable = 0xFF;
  static const int _cmdConnect = 0x01;
  static const int _atypIpv4 = 0x01;
  static const int _atypDomain = 0x03;
  static const int _atypIpv6 = 0x04;

  // SOCKS5 reply codes (RFC 1928 Section 6)
  // Full set: 0x00 succeeded, 0x01 general failure,
  // 0x02 connection not allowed, 0x03 network unreachable,
  // 0x04 host unreachable, 0x05 connection refused,
  // 0x06 TTL expired, 0x07 command not supported,
  // 0x08 address type not supported
  static const int _repSucceeded = 0x00;
  static const int _repGeneralFailure = 0x01;
  static const int _repNotAllowed = 0x02;
  static const int _repHostUnreachable = 0x04;
  static const int _repCommandNotSupported = 0x07;
  static const int _repAddressTypeNotSupported = 0x08;

  /// How long a program has to say where it wants to be connected to, from
  /// when it connects. (A test makes it short.)
  @visibleForTesting
  static Duration debugHandshakeWithin = const Duration(seconds: 30);

  /// Whether the SOCKS5 proxy server is currently running.
  bool get isRunning => _server != null;

  /// Number of currently active client connections being proxied.
  int get activeConnections => _connections.length;

  /// Total bytes transferred through the proxy since it was started.
  int get bytesTransferred => _totalBytesTransferred;

  /// The address the server is bound to, or `null` if not running.
  String? get bindAddress => _server?.address.address;

  /// The port the server is bound to, or `null` if not running.
  int? get bindPort => _server?.port;

  /// Start the SOCKS5 proxy server.
  ///
  /// Binds a local [ServerSocket] and tunnels all incoming SOCKS5
  /// CONNECT requests through [client] via SSH direct-tcpip channels.
  ///
  /// [bindAddress] defaults to `'127.0.0.1'` for security. Binding to
  /// `'0.0.0.0'` would expose the proxy to the local network.
  ///
  /// [bindPort] defaults to `1080`, the standard SOCKS port.
  ///
  /// Throws [StateError] if already running.
  Future<void> start(
    SSHClient client, {
    String bindAddress = '127.0.0.1',
    int bindPort = 1080,
  }) async {
    if (_server != null) {
      throw StateError('SOCKS5 proxy is already running');
    }

    _client = client;
    _totalBytesTransferred = 0;

    // An empty bind address is this device's loopback, never "any address"
    // (security review: port_forward_service.dart forwardListenAddress).
    _server = await ServerSocket.bind(forwardListenAddress(bindAddress), bindPort);
    AppLogger.info(
      'SOCKS5 proxy started on ${_server!.address.address}:${_server!.port}',
    );

    _server!.listen(
      _handleClient,
      onError: (Object error) {
        AppLogger.error('SOCKS5 server socket error', error);
      },
      onDone: () {
        AppLogger.info('SOCKS5 server socket closed');
      },
    );
  }

  /// Stop the SOCKS5 proxy server and close all active connections, those
  /// that are still saying where they want to go, or waiting for the host
  /// to connect there, among them.
  Future<void> stop() async {
    AppLogger.info('SOCKS5 proxy stopping...');

    final server = _server;
    _server = null;
    _client = null;
    await server?.close();

    for (final connection in _connections.toList()) {
      connection.close();
    }

    AppLogger.info('SOCKS5 proxy stopped');
  }

  /// Handle an incoming client connection.
  void _handleClient(Socket clientSocket) {
    if (_client == null) {
      clientSocket.destroy();
      return;
    }

    // Reject at the cap BEFORE opening any SSH channel so a flood can't
    // exhaust resources.
    if (_connections.length >= maxSocks5Connections) {
      AppLogger.warning(
        'SOCKS5: connection cap ($maxSocks5Connections) reached - '
        'rejecting client',
      );
      clientSocket.destroy();
      return;
    }

    // Confused-deputy guard: when bound to loopback, only accept loopback
    // peers. The OS normally enforces this for a 127.0.0.1 bind, but this is
    // cheap defence-in-depth (and rejects odd dual-stack edge cases) so a LAN
    // peer can never pivot through a loopback-bound proxy into the SSH network.
    final bind = _server?.address;
    if (bind != null &&
        bind.isLoopback &&
        !clientSocket.remoteAddress.isLoopback) {
      AppLogger.warning(
        'SOCKS5: rejecting non-loopback peer '
        '${clientSocket.remoteAddress.address} on a loopback bind',
      );
      clientSocket.destroy();
      return;
    }

    final connection = _Socks5Connection(
      clientSocket: clientSocket,
      sshClient: _client!,
      onBytesTransferred: (bytes) => _totalBytesTransferred += bytes,
      onClosed: (conn) => _connections.remove(conn),
      onRefusedByHost: onRefusedByHost,
    );
    _connections.add(connection);

    AppLogger.debug(
      'SOCKS5 new client: '
      '${clientSocket.remoteAddress.address}:${clientSocket.remotePort}',
    );

    unawaited(connection.handle());
  }
}

/// Manages a single SOCKS5 client connection through the proxy.
///
/// Handles the SOCKS5 handshake, opens an SSH direct-tcpip channel to
/// the requested destination, and relays data bidirectionally.
class _Socks5Connection {
  final Socket clientSocket;
  final SSHClient sshClient;
  final void Function(int bytes) onBytesTransferred;
  final void Function(_Socks5Connection connection) onClosed;

  /// Told where the host answered that it passes no connections on.
  final void Function(SSHChannelOpenError error)? onRefusedByHost;

  /// What the program sends. The socket is listened to once, here: it was
  /// listened to anew for each part of what the program says first and
  /// again for what it sends afterwards, which a socket allows once, so no
  /// program ever got further than the proxy's first answer.
  late final _incoming = IncomingBytes(clientSocket);

  bool _closed = false;

  _Socks5Connection({
    required this.clientSocket,
    required this.sshClient,
    required this.onBytesTransferred,
    required this.onClosed,
    required this.onRefusedByHost,
  });

  /// Hears where the program wants to be connected to, has the host connect
  /// there, and from then on hands on what comes from either.
  Future<void> handle() async {
    final tooSlow = Timer(Socks5ProxyServer.debugHandshakeWithin, close);
    final (String, int)? target;
    try {
      target = await _whereTo();
    } finally {
      tooSlow.cancel();
    }
    if (target == null) return close();

    final (host, port) = target;
    AppLogger.debug('SOCKS5 CONNECT $host:$port');

    final SSHForwardChannel channel;
    try {
      channel = await sshClient.forwardLocal(host, port);
    } catch (e) {
      AppLogger.error('SOCKS5 SSH channel open failed', e);
      if (e is SSHChannelOpenError && e.code == 1) onRefusedByHost?.call(e);
      await _reply(_replyFor(e));
      return close();
    }
    await _reply(Socks5ProxyServer._repSucceeded);

    // From here on it is the connection the program asked for. (Where the
    // program has gone meanwhile, or the proxy was stopped, its socket is
    // gone: handing on to it is over at once, and that closes the way on the
    // host.)
    ForwardRelay(
      socket: clientSocket,
      channel: channel,
      name: 'SOCKS5',
      onBytes: onBytesTransferred,
      onClosed: close,
    ).start(fromSocket: _incoming.rest());
  }

  /// What the program says first (RFC 1928): which ways of signing in it
  /// knows, of which the proxy takes "none", and then where it wants to be
  /// connected to. Null where that leads nowhere: what came is no SOCKS 5,
  /// asks for something this proxy does not do, or did not come at all. The
  /// program has been told, where the protocol has a way to tell it.
  Future<(String, int)?> _whereTo() async {
    final greeting = await _incoming.take(2);
    if (greeting == null) return null;
    if (greeting[0] != Socks5ProxyServer._socks5Version) {
      AppLogger.warning('SOCKS5 invalid version: ${greeting[0]}');
      return null;
    }
    final methods = await _incoming.take(greeting[1]);
    if (methods == null) return null;
    if (!methods.contains(Socks5ProxyServer._authNone)) {
      await _say([Socks5ProxyServer._socks5Version, Socks5ProxyServer._authNoAcceptable]);
      return null;
    }
    await _say([Socks5ProxyServer._socks5Version, Socks5ProxyServer._authNone]);

    // VER, CMD, RSV, ATYP; then the address, as long as its kind says, and
    // the port.
    final request = await _incoming.take(4);
    if (request == null) return null;
    if (request[0] != Socks5ProxyServer._socks5Version) {
      await _reply(Socks5ProxyServer._repGeneralFailure);
      return null;
    }
    if (request[1] != Socks5ProxyServer._cmdConnect) {
      AppLogger.warning('SOCKS5 unsupported command: ${request[1]}');
      await _reply(Socks5ProxyServer._repCommandNotSupported);
      return null;
    }
    final String host;
    switch (request[3]) {
      case Socks5ProxyServer._atypIpv4:
        final address = await _incoming.take(4);
        if (address == null) return null;
        host = address.join('.');
      case Socks5ProxyServer._atypDomain:
        final length = await _incoming.take(1);
        final name = length == null ? null : await _incoming.take(length[0]);
        if (name == null) return null;
        host = String.fromCharCodes(name);
      case Socks5ProxyServer._atypIpv6:
        final address = await _incoming.take(16);
        if (address == null) return null;
        // Eight groups of hex digits, with colons between them.
        host = [
          for (var i = 0; i < 16; i += 2) ((address[i] << 8) | address[i + 1]).toRadixString(16),
        ].join(':');
      default:
        AppLogger.warning('SOCKS5 unsupported address type: ${request[3]}');
        await _reply(Socks5ProxyServer._repAddressTypeNotSupported);
        return null;
    }
    final port = await _incoming.take(2);
    if (port == null) return null;
    return (host, (port[0] << 8) | port[1]);
  }

  /// What the program is told where the host did not open the way: that the
  /// host passes no connections on (it answered with the reason code 1),
  /// that it could not connect to where it was asked to (2), and for
  /// anything else (the connection to the host has ended) that it failed.
  static int _replyFor(Object error) {
    if (error is SSHChannelOpenError) {
      if (error.code == 1) return Socks5ProxyServer._repNotAllowed;
      if (error.code == 2) return Socks5ProxyServer._repHostUnreachable;
    }
    return Socks5ProxyServer._repGeneralFailure;
  }

  /// The proxy's answer to the request: VER, REP, RSV, ATYP, BND.ADDR and
  /// BND.PORT, of which the last two are 0.0.0.0 and 0.
  Future<void> _reply(int code) => _say([
        Socks5ProxyServer._socks5Version,
        code,
        0x00,
        Socks5ProxyServer._atypIpv4,
        0, 0, 0, 0,
        0, 0,
      ]);

  /// Sends [bytes] to the program, and waits until they are on their way.
  /// Where they cannot be sent the program has gone, which whatever comes
  /// next finds out by itself.
  Future<void> _say(List<int> bytes) async {
    try {
      await clientSocket.addStream(Stream.value(Uint8List.fromList(bytes)));
    } catch (e) {
      AppLogger.debug('SOCKS5 client socket error: $e');
    }
  }

  /// Close this connection and clean up resources: whoever waits for what
  /// the program says next gets the end of it, and what hands on a
  /// connection that was let through ends with its socket.
  void close() {
    if (_closed) return;
    _closed = true;
    clientSocket.destroy();
    onClosed(this);
  }
}

/// What comes from a socket: a set number of bytes at a time for as long as
/// somebody reads what they say, and from then on as it comes. The socket is
/// listened to once, and read only while somebody waits for what it brings:
/// what a program sends before it has been let through waits where it is.
/// An error of the socket's is the end of what comes from it.
@visibleForTesting
class IncomingBytes {
  IncomingBytes(Stream<Uint8List> socket) {
    _subscription = socket.listen(
      (data) {
        _held.add(data);
        if (_held.length < _wanted) return;
        // No more is read from here on, the end of it neither, until
        // somebody asks again.
        _subscription.pause();
        _wake();
      },
      onError: (Object _) => _wake(),
      onDone: _wake,
    )..pause();
  }

  late final StreamSubscription<Uint8List> _subscription;
  final _held = BytesBuilder(copy: false);

  /// How many bytes whoever waits is waiting for, and what tells them that
  /// those have come, or that no more will.
  var _wanted = 0;
  Completer<void>? _waiting;

  void _wake() {
    _waiting?.complete();
    _waiting = null;
  }

  /// The next [count] bytes, however many pieces they come in; null where
  /// the socket ended before they came.
  Future<Uint8List?> take(int count) async {
    if (_held.length < count) {
      _wanted = count;
      final waiting = _waiting = Completer<void>();
      _subscription.resume();
      await waiting.future;
      if (_held.length < count) return null;
    }
    final held = _held.takeBytes();
    if (held.length > count) _held.add(Uint8List.sublistView(held, count));
    return Uint8List.sublistView(held, 0, count);
  }

  /// What came beyond the bytes that were taken, and whatever comes from
  /// here on, read only as fast as it is taken.
  Stream<Uint8List> rest() {
    final controller = StreamController<Uint8List>();
    controller
      ..onListen = () {
        if (_held.isNotEmpty) controller.add(_held.takeBytes());
        _subscription
          ..onData(controller.add)
          ..onDone(controller.close)
          ..resume();
      }
      ..onPause = _subscription.pause
      ..onResume = _subscription.resume
      ..onCancel = _subscription.cancel;
    return controller.stream;
  }
}
