import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart' show saidByApp;

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A host key that the SSH core refuses by itself, before anybody is asked
/// about it, as the app's own SSH service meets it (3.0, from the SSH
/// core's audit): a key that did not sign the exchange it came with, and a
/// key of another kind than was agreed on.
///
/// The first is the one thing a host key is there to tell: whoever shows a
/// host's key and cannot sign with it is not that host. With an Ed25519
/// key, which most hosts have, the core ended such a connection as a packet
/// that could not be read: the app did not take it for a matter of the
/// host's key, said an unexpected error, and tried again by itself where it
/// tries again.
///
/// What the core found is in the connection's log in its own words, once:
/// the sentence of a key that is no key says that the log has it.
///
/// The host is played by the test.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);

  setUp(() => L10nGlobal.update(en));

  SSHKeyPair fromFile(String path) =>
      SSHKeyPair.fromPem(File('packages/zest_ssh_core/test/fixtures/$path').readAsStringSync()).single;

  /// What the app's own service ends with when a played host shows it
  /// [hostKey], how often its person was asked about the key (who answers
  /// with [answer], yes where none is given), and what the connection's log
  /// says of a key that was refused.
  Future<({Object failure, int asked, List<String> refusedInLog})> shown(
    PlayedHostKey hostKey, {
    Future<bool> Function()? answer,
  }) async {
    final server = PlayedServer(hostKey: hostKey);
    var asked = 0;
    final log = <String>[];
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async {
        asked++;
        return answer == null ? true : await answer();
      },
      tunnelSocket: server.socket,
      onLog: log.add,
    );
    addTearDown(ssh.disconnect);
    final connecting = ssh.connect().timeout(patience);
    // The played host waits for the app's new keys, which do not come.
    unawaited(server.exchangeKeys().then((_) {}, onError: (_) {}));
    Object? failure;
    try {
      await connecting;
    } catch (error) {
      failure = error;
    }
    expect(failure, isNotNull, reason: 'the connection was made');
    // What ends the connection is written a moment after the try has ended.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (
      failure: failure!,
      asked: asked,
      refusedInLog: [
        for (final line in log)
          if (line.startsWith('ssh_hostkey: ') && line.contains('REJECTED')) line,
      ],
    );
  }

  void expectAHostKeyThatWasNotAccepted(
      ({Object failure, int asked, List<String> refusedInLog}) outcome, String theCoreSays, String theAppSays) {
    expect(outcome.asked, 0, reason: 'a key that is refused is not put to its person');
    // In the log once, in the core's own words, and not as a key that failed when new keys were taken.
    expect(outcome.refusedInLog, hasLength(1));
    expect(outcome.refusedInLog.single, startsWith('ssh_hostkey: Host key REJECTED - '));
    expect(outcome.refusedInLog.single, contains(theCoreSays));
    expect(hostKeyNotAccepted(outcome.failure),
        isA<SSHHostkeyError>().having((e) => e.message, 'what the core says', contains(theCoreSays)));
    expect(connectionFailureText(outcome.failure), saidByApp(theAppSays));
    expect(reconnectCannotHelp(outcome.failure), isTrue, reason: 'the next try would be shown the same key');
  }

  test('a host that shows an Ed25519 key and cannot sign with it: said as a key it could not prove to be its own, '
      'nobody asked, and not tried again', () async {
    final pair = fromFile('ssh-ed25519/ssh_host_ed25519_key');
    final outcome = await shown(PlayedHostKey(
      'ssh-ed25519',
      pair.toPublicKey().encode(),
      // The key's signature of something else: what whoever has only the key's public half can send.
      (hash) => pair.sign(Uint8List.fromList(hash.reversed.toList())).encode(),
    ));
    expectAHostKeyThatWasNotAccepted(outcome, 'Signature verification failed', en.connHostKeyNotSigned);
  });

  test('a host that agreed on one kind of key and shows another: said as no key a host can have', () async {
    final pair = fromFile('ecdsa-sha2-nistp256/ssh_host_ecdsa_key');
    final outcome = await shown(PlayedHostKey.of(pair, algorithm: 'ecdsa-sha2-nistp521'));
    expectAHostKeyThatWasNotAccepted(outcome, 'ecdsa-sha2-nistp256', en.connHostKeyNoKey);
  });

  test('a host that shows bytes that are no key: the same sentence', () async {
    final pair = fromFile('ssh-ed25519/ssh_host_ed25519_key');
    final outcome = await shown(PlayedHostKey(
      'ssh-ed25519',
      Uint8List.fromList([0, 0, 0, 200, 1, 2, 3]),
      (hash) => pair.sign(hash).encode(),
    ));
    expectAHostKeyThatWasNotAccepted(outcome, 'could not be read', en.connHostKeyNoKey);
  });

  test('a key that the SSH core has nothing against and that its person, or the check of the app, does not '
      'accept: in the log once, as before', () async {
    final declined = await shown(PlayedHostKey.ed25519(), answer: () async => false);
    expect(declined.asked, 1);
    expect(declined.refusedInLog, ['ssh_hostkey: Host key REJECTED']);
    expect(hostKeyNotAccepted(declined.failure), isA<SSHHostkeyError>().having((e) => e.fault, 'fault', isNull));

    final pinned = await shown(
      PlayedHostKey.ed25519(),
      answer: () async =>
          throw HostKeyNotAccepted(HostKeyRefusal.pinnedOther, host: 'web-01.example.com', port: 22, crate: 'Web'),
    );
    expect(pinned.asked, 1);
    expect(pinned.refusedInLog, ['ssh_hostkey: Host key REJECTED (pinnedOther)']);
    expect(hostKeyNotAccepted(pinned.failure), isA<HostKeyNotAccepted>().having((e) => e.fault, 'fault', isNull));
  });

  // The sentences of a key that is refused at the start say that nothing was
  // sent to the host. That is not so once a host key was accepted: a host
  // that asks for new keys while it is being signed in to has been sent what
  // a sign-in sends.
  test('a host that asks for new keys while it is being signed in to, and cannot sign with its key then: said as a '
      'key that failed when new keys were taken, and not as a connection that was sent nothing', () async {
    final pair = fromFile('ssh-ed25519/ssh_host_ed25519_key');
    final server = PlayedServer(hostKey: PlayedHostKey.of(pair, algorithm: 'ssh-ed25519'));
    final log = <String>[];
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
      onLog: log.add,
    );
    addTearDown(ssh.disconnect);
    Object? failure;
    final tried = ssh.connect().timeout(patience).then((_) {}, onError: (Object error) {
      failure = error;
    });
    // The key exchange and the service: the app asks to be signed in, and is asked for new keys.
    await server.greet();
    await server
        .rekey(
          hostKey: PlayedHostKey(
            'ssh-ed25519',
            pair.toPublicKey().encode(),
            (hash) => pair.sign(Uint8List.fromList(hash.reversed.toList())).encode(),
          ),
        )
        .then((_) {}, onError: (_) {});
    await tried;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(failure, isNotNull, reason: 'the connection was made');
    expect(asked, 1, reason: 'the key of the first exchange was put to its person, and accepted');
    expect(
      hostKeyNotAccepted(failure!),
      isA<SSHHostkeyError>()
          .having((e) => e.fault, 'what was wrong', SSHHostkeyFault.notSigned)
          .having((e) => e.duringRekey, 'during a re-key', isTrue),
    );
    expect(connectionFailureText(failure!), saidByApp(en.connHostKeyFailedAtNewKeys));
    expect(en.connHostKeyFailedAtNewKeys, isNot(contains('Nothing was sent')));
    expect(reconnectCannotHelp(failure!), isTrue);
    expect(
      [
        for (final line in log)
          if (line.startsWith('ssh_hostkey: ') && line.contains('REJECTED')) line,
      ],
      ['ssh_hostkey: Host key REJECTED when new keys were taken - Signature verification failed'],
    );
  });
}
