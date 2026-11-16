import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/serial_service.dart';

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A serial console over SSH on a console server that needs Compatibility
/// mode (3.0, found while the SSH core's audit was at RSA keys).
///
/// A console server is often an old one. Compatibility mode is a switch of
/// the saved host, and a session to a host used it; a serial console to
/// the same kind of host did not, and had no way to be told: it failed at
/// the key exchange whatever the switch said.
///
/// The console server is played on the loopback address, and speaks
/// aes256-cbc and no other cipher.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  /// A serial console to a played console server that speaks only
  /// aes256-cbc: how connecting ended (null: connected), and whether the
  /// server was asked for a sign-in at all.
  Future<({Object? failure, bool askedToSignIn})> connect({required bool compatibilityMode}) async {
    final listener = await PlayedListener.bind();
    var askedToSignIn = false;
    final played = () async {
      final server = PlayedServer(line: await listener.line(), suite: PlayedSuite.cbc);
      await server.letIn();
      askedToSignIn = true;
      final channel = await server.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'pty-req');
      server.send([channel.success]);
      expect((await channel.nextRequest()).requestType, 'shell');
      server.send([channel.success]);
    }();
    final console = SerialOverSshService(
      host: listener.host,
      port: listener.port,
      username: 'deploy',
      password: 'not-a-real-one',
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      compatibilityMode: compatibilityMode,
      onHostKeyVerify: (_, _, _) async => true,
    );
    addTearDown(console.disconnect);
    Object? failure;
    try {
      await console.connect().timeout(const Duration(seconds: 15));
      expect(console.isConnected, isTrue);
    } catch (e) {
      failure = e;
    }
    // What the played server waits for does not come where the console gave up on it.
    await played.timeout(const Duration(seconds: 10)).then((_) {}, onError: (Object _) {});
    return (failure: failure, askedToSignIn: askedToSignIn);
  }

  test('with Compatibility mode on for the console server: the console connects', () async {
    final outcome = await connect(compatibilityMode: true);
    expect(outcome.failure, isNull);
    expect(outcome.askedToSignIn, isTrue);
  });

  test('with it off: nothing in common with such a server, as before, and no sign-in is asked for', () async {
    final outcome = await connect(compatibilityMode: false);
    expect(outcome.failure, isA<SSHAuthAbortError>());
    final found = (outcome.failure! as SSHAuthAbortError).reason;
    expect(found, isA<SSHHandshakeError>());
    expect((found! as SSHHandshakeError).message, 'No matching client cipher algorithm');
    expect(outcome.askedToSignIn, isFalse);
  });

  test('a saved console server is opened with its own setting, and so is one made by name (read from the files: '
      'no test opens a saved console through the session list)', () {
    final sessions = File('lib/providers/terminal_providers.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      sessions,
      contains('        serialConfig: SerialConfig.cisco(), // Default; UI can customize later\n'
          '        compatibilityMode: connection.compatibilityMode,\n'),
    );
    final console = SerialService.createSshSession(
      host: '192.168.10.21',
      port: 22,
      username: 'deploy',
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async => true,
      compatibilityMode: true,
    );
    expect(console.compatibilityMode, isTrue);
    final plain = SerialService.createSshSession(
      host: '192.168.10.21',
      port: 22,
      username: 'deploy',
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async => true,
    );
    expect(plain.compatibilityMode, isFalse);
    // And one that is made with nothing said of the mode has it off.
    final unsaid = SerialOverSshService(
      host: '192.168.10.21',
      port: 22,
      username: 'deploy',
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async => true,
    );
    expect(unsaid.compatibilityMode, isFalse);
  });
}
