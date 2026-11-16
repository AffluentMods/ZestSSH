import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// A key as a host shows it is not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/hostkey/hostkey_rsa.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart' show saidByApp;

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A host, or whoever answers in its place, that shows an RSA key of a size
/// no key has, as the app's own SSH service meets it (3.0, from the SSH
/// core's audit).
///
/// The signature that comes with a host's key is checked before anybody is
/// asked whether they trust the key, and for an RSA key the time that takes
/// is for whoever sends the key to choose. The SSH core checked a key of any
/// size: more than ten minutes of a busy processor for the longest one
/// packet holds, in which the whole app stands still, before the sign-in,
/// for anyone between this device and the host. It refuses such a key now
/// without computing anything with it.
///
/// And an RSA key that is too short (the user's decision of 12 October
/// 2026): under 2048 bits it is not taken (since 3.3.0; OpenSSH's floor is 1024), and said
/// as that with both lengths; Compatibility mode, which is for the old
/// devices that have such a key, takes it as every version before did.
///
/// The host is played by the test.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);

  setUp(() => L10nGlobal.update(en));

  /// An odd number of exactly [bits] bits.
  BigInt odd(int bits) => (BigInt.one << (bits - 1)) | (BigInt.one << (bits ~/ 2)) | BigInt.one;

  /// What the app's own service ends with when a played host shows it a
  /// made-up RSA key, how long that took, and how often its person was
  /// asked about the key.
  Future<({Object failure, Duration took, int asked})> shown(BigInt n, BigInt e) async {
    final server = PlayedServer(
      hostKey: PlayedHostKey(
        'rsa-sha2-256',
        SSHRsaPublicKey(e, n).encode(),
        // (Not noughts: nought to any power is nought, and takes no time.)
        (hash) => SSHRsaSignature(SSHRsaSignatureType.sha256, Uint8List(256)..fillRange(1, 256, 0x5A)).encode(),
      ),
    );
    var asked = 0;
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async {
        asked++;
        return true;
      },
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    final watch = Stopwatch()..start();
    final connecting = ssh.connect().timeout(patience);
    // The played host waits for the app's new keys, which do not come.
    unawaited(server.exchangeKeys().then((_) {}, onError: (_) {}));
    Object? failure;
    try {
      await connecting;
    } catch (error) {
      failure = error;
    }
    watch.stop();
    expect(failure, isNotNull, reason: 'the connection was made');
    return (failure: failure!, took: watch.elapsed, asked: asked);
  }

  test('the longest RSA key one packet holds, with an exponent as long: refused at once, nobody asked, said as no '
      'key a host can have, and not tried again', () async {
    final outcome = await shown(odd(131072), odd(131072));
    expect(outcome.took, lessThan(const Duration(seconds: 10)), reason: 'nothing is computed with such a key');
    expect(outcome.asked, 0, reason: 'a key that is refused is not put to its person');
    final refused = hostKeyNotAccepted(outcome.failure);
    expect(refused, isA<SSHHostkeyError>().having((e) => e.message, 'what the core says', contains('131072 bits')));
    expect(connectionFailureText(outcome.failure), saidByApp(en.connHostKeyNoKey));
    expect(reconnectCannotHelp(outcome.failure), isTrue, reason: 'the next try would be shown the same key');
  });

  test('a key of a usual length with an exponent as long as the key: refused for the exponent, and said as no key '
      'a host can have', () async {
    final outcome = await shown(odd(4096), odd(4096));
    expect(outcome.asked, 0);
    expect(hostKeyNotAccepted(outcome.failure),
        isA<SSHHostkeyError>().having((e) => e.message, 'what the core says', contains('exponent of 4096 bits')));
    expect(connectionFailureText(outcome.failure), saidByApp(en.connHostKeyNoKey));
    expect(reconnectCannotHelp(outcome.failure), isTrue);
  });

  test('an RSA key of 768 bits: refused at once, nobody asked, said with both lengths and that Compatibility mode '
      'takes such a key, and not tried again', () async {
    final outcome = await shown(odd(768), BigInt.from(65537));
    expect(outcome.asked, 0, reason: 'a key that is refused is not put to its person');
    expect(
      hostKeyNotAccepted(outcome.failure),
      isA<SSHHostkeyError>()
          .having((e) => e.fault, 'what was wrong', SSHHostkeyFault.tooShort)
          .having((e) => e.bits, 'how long it is', 768)
          .having((e) => e.shortestTaken, 'the shortest taken', 2048),
    );
    expect(connectionFailureText(outcome.failure), saidByApp(en.connHostKeyTooShort(768, 2048)));
    expect(
      en.connHostKeyTooShort(768, 2048),
      'The host showed an RSA key of 768 bits, and none under 2048 bits is taken, so the connection was '
      'not made. Nothing was sent to the host. A key that short can be worked out by whoever has the '
      'means, and whoever has done so can answer in the host\'s place. The host needs a longer key, which '
      'its SSH server can make. For an old device that cannot have one, Compatibility mode, turned on for '
      'this host, takes such a key.',
    );
    expect(reconnectCannotHelp(outcome.failure), isTrue, reason: 'the next try would be shown the same key');
    // A key of 2048 bits is not refused for its length (this one signs nothing, and is refused for that).
    final longEnough = await shown(odd(2048), BigInt.from(65537));
    expect(hostKeyNotAccepted(longEnough.failure)?.fault, isNot(SSHHostkeyFault.tooShort));
  });

  test('a key of 768 bits that signs as a key does: with Compatibility mode off it is refused and nobody is asked, '
      'with the mode on it is put to its person as any other key', () async {
    final pair = SSHKeyPair.fromPem(
      File('packages/zest_ssh_core/test/fixtures/ssh-rsa/short_rsa_768_key').readAsStringSync(),
    ).single;
    for (final compatibility in [false, true]) {
      final why = 'Compatibility mode: $compatibility';
      final server = PlayedServer(hostKey: PlayedHostKey.of(pair, algorithm: 'rsa-sha2-256'));
      var asked = 0;
      final ssh = SshService(
        host: 'switch-01.example.com',
        port: 22,
        username: 'admin',
        password: 'not-a-real-one',
        keepAliveSeconds: 0,
        compatibilityMode: compatibility,
        onHostKeyVerify: (_, _, _) async {
          asked++;
          return true;
        },
        tunnelSocket: server.socket,
      );
      addTearDown(ssh.disconnect);
      Object? failure;
      final connecting = ssh.connect().timeout(patience).then((_) {}, onError: (Object error) {
        failure = error;
      });
      // The played host has the app's new keys only where its key was taken.
      final exchanged = server.exchangeKeys().then((_) => true, onError: (Object _) => false);
      final taken = await Future.any([exchanged, connecting.then((_) => false)]);
      expect(taken, compatibility, reason: why);
      expect(asked, compatibility ? 1 : 0, reason: why);
      if (!compatibility) {
        expect(hostKeyNotAccepted(failure!)?.fault, SSHHostkeyFault.tooShort, reason: why);
        expect(connectionFailureText(failure!), saidByApp(en.connHostKeyTooShort(768, 2048)), reason: why);
      }
      await ssh.disconnect();
    }
  });

  test('what the app takes as the shortest RSA host key: 2048 bits, and any length with Compatibility mode', () {
    expect(SshService.buildAlgorithms(compatibility: false).minRsaHostKeyBits, 2048);
    expect(SshService.buildAlgorithms(compatibility: true).minRsaHostKeyBits, 0);
  });
}
