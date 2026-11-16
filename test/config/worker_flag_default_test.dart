import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/config/feature_flags.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Design B (Phase 1) safety gates.
///
/// The worker connection-isolation path is opt-in and must ship dark: a flipped
/// default would silently route every direct terminal session onto a worker
/// isolate in a release build. This test is the tripwire the blueprint requires.
void main() {
  test('kWorkerConnectionIsolation defaults OFF', () {
    // A default build (no --dart-define) must have the worker path disabled.
    // If this fails, someone flipped the default: production would route direct
    // terminal sessions to the worker isolate without the live-host testing the
    // spec mandates. Do NOT change the expectation to make it pass.
    expect(kWorkerConnectionIsolation, isFalse);
  });

  test('ShellService.isEncryptedSsh defaults false for non-SSH transports', () {
    // The Design B capability getter must default false so local-shell / demo /
    // serial transports keep showing no padlock (unchanged behaviour); only the
    // real SSH paths override it to true.
    final shell = _StubShell();
    expect(shell.isEncryptedSsh, isFalse);
  });
}

/// A minimal non-SSH [ShellService] to prove the interface default. Uses
/// `extends` (not `implements`) so it inherits the concrete `=> false` default
/// instead of being forced to declare its own.
class _StubShell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => false;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  // isEncryptedSsh intentionally NOT overridden - inherits the interface
  // default, which this test pins to false.
}
