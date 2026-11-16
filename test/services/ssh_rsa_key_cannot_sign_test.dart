import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The messages a played server reads and sends are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/hostkey/hostkey_rsa.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/editor_test_said.dart';

/// A sign-in with an RSA key that cannot make a signature of its own, as
/// the app's own SSH service goes through it (3.0, from the SSH core's
/// audit).
///
/// An RSA signature that comes out wrong gives away the key that made it
/// to whoever sees it and knows what was signed, and the host that is
/// signed in to sees it. A key whose numbers do not fit each other makes
/// such signatures (a key file that is damaged, or was made wrongly), and
/// so does a computation that goes wrong. The app sent whatever came of
/// the computation, and where nothing came of it, it passed the key over
/// without a word and said that the host had refused the sign-in.
///
/// The host is played by the test, and keeps what it is sent.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);

  setUp(() => L10nGlobal.update(en));

  final real = SSHKeyPair.fromPem(
          File('packages/zest_ssh_core/test/fixtures/ssh-rsa/ssh_host_rsa_key').readAsStringSync())
      .single as OpenSSHRsaKeyPair;
  final e = BigInt.from(65537);

  /// A key as something that makes keys wrongly would make it: one of its
  /// two "primes" is a product of two, so one half of every signature it
  /// makes is wrong.
  OpenSSHRsaKeyPair oneHalfWrong() {
    final notAPrime = real.p * BigInt.from(1000003);
    final n = notAPrime * real.q;
    final d = e.modInverse((notAPrime - BigInt.one) * (real.q - BigInt.one));
    return OpenSSHRsaKeyPair(n, e, d, real.q.modInverse(notAPrime), notAPrime, real.q, 'made wrongly');
  }

  /// A key file in which a number was changed: its primes no longer make
  /// its modulus.
  OpenSSHRsaKeyPair damaged() =>
      OpenSSHRsaKeyPair(real.n, real.e, real.d, real.iqmp, real.p, real.q + BigInt.two, 'damaged');

  /// The app's own service signs in to a played host with [key] and nothing
  /// else. The host takes keys only: it says of any key it is asked about
  /// that it would take it, and lets in whatever signs. What the try ended
  /// with (null: it was signed in), and the signature the host was sent, if
  /// any.
  Future<({Object? failure, Uint8List? signatureSent, List<String> log})> signIn(SSHKeyPair key) async {
    final server = PlayedServer();
    final log = <String>[];
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      keyPairs: [key],
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
      onLog: log.add,
    );
    addTearDown(ssh.disconnect);
    Object? failure;
    var ended = false;
    final tried = ssh.connect().timeout(patience).then<void>((_) {
      ended = true;
    }, onError: (Object error) {
      failure = error;
      ended = true;
    });
    await server.greet();
    // The app asks which ways of signing in the host takes: keys only.
    final asked = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(asked.methodName, 'none');
    server.send([SSH_Message_Userauth_Failure(methodsLeft: const ['publickey']).encode()]);
    // Then it asks about its key, and signs in with it once the host has said yes, or it does not.
    Uint8List? signatureSent;
    final clock = Stopwatch()..start();
    while (!ended && signatureSent == null && clock.elapsed < patience) {
      for (final payload in server.takeSent()) {
        if (payload[0] != SSH_Message_Userauth_Request.messageId) continue;
        final request = SSH_Message_Userauth_Request.decode(payload);
        if (request.methodName != 'publickey') continue;
        if (request.signature == null) {
          server.takesKey(request);
        } else {
          signatureSent = request.signature;
        }
      }
      if (signatureSent == null) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (signatureSent != null) {
      // The host takes whatever signs: it is signed in, and its session is started.
      server.send([SSH_Message_Userauth_Success().encode()]);
      final channel = await server.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'pty-req');
      server.send([channel.success]);
      expect((await channel.nextRequest()).requestType, 'shell');
      server.send([channel.success]);
    }
    await tried;
    return (failure: failure, signatureSent: signatureSent, log: log);
  }

  test('a key that is real signs in, and what the host is sent is the key\'s own signature', () async {
    final outcome = await signIn(real);
    expect(outcome.failure, isNull);
    expect(outcome.signatureSent, isNotNull);
    expect(SSHRsaSignature.decode(outcome.signatureSent!).type, 'rsa-sha2-256');
  });

  for (final (what, key) in [
    ('a key of which one half is wrong, so that its signatures give the key away', oneHalfWrong),
    ('a key file in which a number was changed', damaged),
  ]) {
    test('$what: the host is sent no signature, and the app says that the key could not sign', () async {
      final outcome = await signIn(key());
      expect(outcome.signatureSent, isNull, reason: 'the host was sent a signature');
      expect(
        outcome.failure,
        isA<SSHAuthAbortError>()
            .having((e) => e.message, 'what it says', 'The key could not sign')
            .having((e) => e.reason, 'why', isA<SSHKeySignError>()),
      );
      final said = connectionFailureText(outcome.failure!);
      expect(said, saidByApp(en.connKeyCouldNotSign));
      // As whatever shows a failed connection shows it: the app's own sentence, and no tip about anything else.
      final shown = ConnectionError.translate(said, host: 'web-01.example.com', port: 22, username: 'deploy');
      expect(shown.type, ConnectionErrorType.saidByApp);
      expect(shown.description, en.connKeyCouldNotSign);
      expect(reconnectCannotHelp(outcome.failure!), isTrue, reason: 'the next try would sign with the same key');
      expect(outcome.log.where((line) => line.contains('SSHKeySignError')), isNotEmpty,
          reason: 'the connection\'s log says what was found');
    });
  }

  test('the sentence, word for word; the error by itself and as what cut a sign-in off; and what the editor\'s '
      'connection test says and keeps of it', () {
    expect(
      en.connKeyCouldNotSign,
      'The key could not be used to sign in: what it signed did not check against the key itself, so it was not '
      'sent to the host. A key file that is damaged, or that was made wrongly, does this. Import the key again from '
      'where it was made, or use another key.',
    );
    final found = SSHKeySignError('The numbers of this RSA key do not fit each other: nothing was signed with it');
    final cutOff = SSHAuthAbortError('The key could not sign', found);
    for (final failure in <Object>[found, cutOff]) {
      expect(connectionFailureText(failure), saidByApp(en.connKeyCouldNotSign));
      expect(reconnectCannotHelp(failure), isTrue);
    }
    expect(editorTestSaid(en, cutOff), en.connKeyCouldNotSign);
    expect(editorTestCutOffBy(en, cutOff),
        'SSHKeySignError(The numbers of this RSA key do not fit each other: nothing was signed with it)');
    // A sign-in that was cut off for another reason is tried again, as it was, and said as a failed connection
    // says it.
    final other = SSHAuthAbortError('Connection closed before authentication', SSHStateError('Transport is closed'));
    expect(reconnectCannotHelp(other), isFalse);
    expect(editorTestSaid(en, other, host: 'web-01.example.com'),
        '${en.errSshProtocolDesc('web-01.example.com')}\n\n${en.errSshProtocolTip}');
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final sentence = lookupAppLocalizations(locale).connKeyCouldNotSign;
      expect(sentence, isNotEmpty, reason: '$locale');
      expect(sentence, isNot(contains('{')), reason: '$locale');
      if (locale.languageCode != 'en') expect(sentence, isNot(en.connKeyCouldNotSign), reason: '$locale');
    }
  });
}
