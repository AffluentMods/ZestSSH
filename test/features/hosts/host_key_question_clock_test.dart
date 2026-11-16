import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Reading a host key's fingerprint is the person's time, not the server's:
/// every place that asks whether to trust one during a sign-in stops the
/// sign-in's clock while it asks (AuthDeadline.whileAsking). The host
/// editor's Test full connection asked without it, so a fingerprint read for
/// more than 8 seconds failed the test as "Auth timed out after 8s" (found
/// on an emulator).
void main() {
  test('every host key question during a sign-in stops the clock while it asks', () {
    const asks = {
      'lib/features/hosts/host_tester.dart': 'deadline.whileAsking(() => _confirmHostKey(',
      'lib/services/ssh_service.dart': 'deadline.whileAsking(() => onHostKeyVerify(',
      'lib/services/serial_service.dart': 'deadline.whileAsking(() => onHostKeyVerify(',
      'lib/providers/terminal_providers.dart': 'hopDeadline.whileAsking(() => hostKeyVerifier(',
    };
    for (final MapEntry(key: path, value: call) in asks.entries) {
      expect(File(path).readAsStringSync(), contains(call), reason: path);
    }
    // The test asks in that one place: its call and its declaration.
    final tester = File('lib/features/hosts/host_tester.dart').readAsStringSync();
    expect('_confirmHostKey('.allMatches(tester).length, 2);
  });
}
