import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Telnet implementation of [ShellService].
///
/// dartssh2 does not support Telnet, so this is a raw TCP socket
/// implementation with basic Telnet option negotiation (RFC 854).
class TelnetService implements ShellService {
  final String host;
  final int port;

  Socket? _socket;
  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  bool _isConnected = false;

  // Telnet commands
  static const int _iac = 255; // Interpret As Command
  static const int _will = 251;
  static const int _wont = 252;
  static const int _do = 253;
  static const int _dont = 254;
  static const int _sb = 250; // Sub-negotiation Begin
  static const int _se = 240; // Sub-negotiation End
  static const int _naws = 31; // Negotiate About Window Size

  int _termWidth = 80;
  int _termHeight = 24;

  /// How long the connection may take before it is given up: the app's
  /// Connection timeout setting, as for SSH and serial (it was the system's
  /// own, which waits some twenty seconds or more for a host that does not
  /// answer, whatever the setting said).
  final Duration connectTimeout;

  TelnetService({required this.host, this.port = 23, this.connectTimeout = const Duration(seconds: 15)});

  /// How the socket is opened; a test stands in for it to see the timeout.
  @visibleForTesting
  static Future<Socket> Function(String host, int port, {Duration? timeout}) openSocket = Socket.connect;

  @override
  Future<void> connect() async {
    AppLogger.warning(
      'Telnet connection to $host:$port - all traffic including '
      'credentials will be transmitted in PLAINTEXT. Use SSH when possible.',
    );
    AppLogger.info('Telnet connecting to $host:$port');
    _socket = await openSocket(host, port, timeout: connectTimeout);
    _isConnected = true;
    _connectionStateController.add(true);

    _socket!.listen(
      _handleData,
      onDone: () {
        _isConnected = false;
        _connectionStateController.add(false);
        AppLogger.info('Telnet disconnected from $host:$port');
      },
      onError: (error) {
        _isConnected = false;
        _connectionStateController.add(false);
        AppLogger.error('Telnet error', error);
      },
    );

    AppLogger.info('Telnet connected to $host:$port');
  }

  /// Process incoming data, stripping Telnet control sequences.
  void _handleData(Uint8List data) {
    final output = <int>[];
    var i = 0;

    while (i < data.length) {
      if (data[i] == _iac && i + 1 < data.length) {
        final cmd = data[i + 1];
        if (cmd == _will || cmd == _wont || cmd == _do || cmd == _dont) {
          if (i + 2 < data.length) {
            _handleOption(cmd, data[i + 2]);
            i += 3;
            continue;
          }
        } else if (cmd == _sb) {
          // Skip sub-negotiation
          final seIndex = _findSE(data, i + 2);
          i = seIndex + 1;
          continue;
        } else if (cmd == _iac) {
          // Escaped IAC → literal 255
          output.add(_iac);
          i += 2;
          continue;
        }
      }
      output.add(data[i]);
      i++;
    }

    if (output.isNotEmpty) {
      _stdoutController.add(Uint8List.fromList(output));
    }
  }

  int _findSE(Uint8List data, int start) {
    for (var i = start; i < data.length - 1; i++) {
      if (data[i] == _iac && data[i + 1] == _se) return i + 1;
    }
    return data.length;
  }

  void _handleOption(int command, int option) {
    if (command == _do && option == _naws) {
      // Server asks us to negotiate window size - accept and send
      _socket?.add(Uint8List.fromList([_iac, _will, _naws]));
      _sendNaws();
    } else if (command == _will || command == _do) {
      // Refuse everything else
      final response = command == _will ? _dont : _wont;
      _socket?.add(Uint8List.fromList([_iac, response, option]));
    }
  }

  void _sendNaws() {
    final data = <int>[_iac, _sb, _naws];
    for (final b in [
      (_termWidth >> 8) & 0xFF, _termWidth & 0xFF,
      (_termHeight >> 8) & 0xFF, _termHeight & 0xFF,
    ]) {
      data.add(b);
      if (b == _iac) data.add(_iac);
    }
    data.addAll([_iac, _se]);
    _socket?.add(Uint8List.fromList(data));
  }

  @override
  void write(Uint8List data) => _socket?.add(data);

  @override
  void resize(int width, int height) {
    _termWidth = width;
    _termHeight = height;
    if (_isConnected) _sendNaws();
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> disconnect() async {
    AppLogger.info('Telnet disconnecting from $host:$port');
    _socket?.destroy();
    _isConnected = false;
    _connectionStateController.add(false);
  }

  @override
  bool get isConnected => _isConnected;

  // A telnet close means the remote side ended the session - close the
  // tab rather than reconnect into a dead host.
  @override
  bool get exitedCleanly => true;

  @override
  bool get isEncryptedSsh => false;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;
}
