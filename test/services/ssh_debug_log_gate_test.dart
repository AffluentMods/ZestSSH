import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source gates for the SSH protocol-trace flood fix (folder-upload lag).
///
/// The core's `printDebug` trace used to be forwarded into the user-visible
/// connection log for the whole life of a session, and the core emitted trace
/// lines on per-packet hot paths. Each forwarded line republished the entire
/// session state. These gates fail loudly if either side regresses.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('ssh_service forwards the core trace only until authentication', () {
    final src = read('lib/services/ssh_service.dart');
    expect(src.contains('if (!forwardDebugToLog) return;'), isTrue,
        reason: 'printDebug closure must be gated by forwardDebugToLog');
    expect(src.contains('forwardDebugToLog = false;'), isTrue,
        reason: 'onAuthenticated must switch the trace forwarding off');
  });

  test('core emits no trace lines on the per-packet hot paths', () {
    final channel = read('packages/zest_ssh_core/lib/src/ssh_channel.dart');
    final transport =
        read('packages/zest_ssh_core/lib/src/ssh_transport.dart');
    const hot = <String, String>{
      'SSHChannel._uploadLoop: len=': 'channel upload loop',
      'SSHChannel._handleDataMessage: len=': 'channel data receive',
      'SSHChannel._handleWindowAdjustMessage:': 'window adjust receive',
      "'SSHChannel._sendWindowAdjustIfNeeded'": 'window adjust send',
    };
    hot.forEach((needle, what) {
      expect(channel.contains(needle), isFalse,
          reason: 'per-packet trace line is back in the $what path');
    });
    const hotTransport = <String>[
      "'SSHTransport._processPackets'",
      "'SSHTransport._consumeClearTextPacket'",
      "'SSHTransport._consumeEncryptedPacket'",
    ];
    for (final needle in hotTransport) {
      expect(transport.contains(needle), isFalse,
          reason: 'per-packet trace line is back in the transport: $needle');
    }
  });
}
