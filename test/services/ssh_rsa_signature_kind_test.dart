import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The messages a played server reads and sends are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/hostkey/hostkey_rsa.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_ext_info.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/editor_test_said.dart';

/// An RSA key of the app's signs in with the kind of signature the host
/// takes, and where the host takes none the app may make, the app says so
/// (3.0, from the SSH core's audit).
///
/// An RSA key makes three kinds of signature, and a host says which it
/// takes. The app signed with SHA-256 whatever the host had said: an RSA
/// key was refused by a host that takes only SHA-512, and by one that knows
/// only the first kind (with SHA-1), and what was shown was a key the
/// server had rejected, with a tip to look at the server's authorized_keys.
///
/// The host is played by the test, and keeps what it is asked and sent.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 15);
  const sha512 = 'rsa-sha2-512';
  const sha256 = 'rsa-sha2-256';
  const sha1 = 'ssh-rsa';

  setUp(() => L10nGlobal.update(en));
  tearDown(() => AuthDeadline.debugPatience = null);

  final rsa =
      SSHKeyPair.fromPem(File('packages/zest_ssh_core/test/fixtures/ssh-rsa/ssh_host_rsa_key').readAsStringSync())
          .single;

  /// The app's own service signs in to a played host with an RSA key, and
  /// with [password] besides where one is given. The host says that it
  /// takes [takes] of the kinds of signature (null: it says nothing); it
  /// says yes to a key it is asked about unless that is as one of
  /// [refusedAs], lets in whatever signs, and refuses a password.
  ///
  /// How the try ended (null: connected), the kinds the key was asked about
  /// as, the kinds of the signatures the host was sent, and whether the
  /// password was sent.
  Future<({Object? failure, List<String> askedAs, List<String> signedAs, bool passwordSent})> signIn({
    required List<String>? takes,
    bool compatibilityMode = false,
    SSHKeyPair? key,
    String? password,
    List<String> refusedAs = const [],
  }) async {
    final server = PlayedServer();
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      keyPairs: [key ?? rsa],
      password: password,
      compatibilityMode: compatibilityMode,
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
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
    await server.greet(afterNewKeys: [
      if (takes != null) SSH_Message_ExtInfo({'server-sig-algs': latin1.encode(takes.join(','))}).encode(),
    ]);
    final ways = ['publickey', if (password != null) 'password'];
    Uint8List refusal() => SSH_Message_Userauth_Failure(methodsLeft: ways).encode();
    final first = SSH_Message_Userauth_Request.decode(await server.next(SSH_Message_Userauth_Request.messageId));
    expect(first.methodName, 'none');
    server.send([refusal()]);
    final askedAs = <String>[];
    final signedAs = <String>[];
    var passwordSent = false;
    var letIn = false;
    final clock = Stopwatch()..start();
    while (!ended && !letIn && clock.elapsed < patience) {
      for (final payload in server.takeSent()) {
        if (payload[0] != SSH_Message_Userauth_Request.messageId) continue;
        final request = SSH_Message_Userauth_Request.decode(payload);
        if (request.methodName == 'password') {
          passwordSent = true;
          server.send([refusal()]);
        } else if (request.signature == null) {
          askedAs.add(request.publicKeyAlgorithm!);
          if (refusedAs.contains(request.publicKeyAlgorithm)) {
            server.send([refusal()]);
          } else {
            server.takesKey(request);
          }
        } else {
          signedAs.add(SSHRsaSignature.decode(request.signature!).type);
          expect(request.publicKeyAlgorithm, signedAs.last);
          letIn = true;
        }
      }
      if (!letIn) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (letIn) {
      server.send([SSH_Message_Userauth_Success().encode()]);
      final channel = await server.confirmChannel();
      expect((await channel.nextRequest()).requestType, 'pty-req');
      server.send([channel.success]);
      expect((await channel.nextRequest()).requestType, 'shell');
      server.send([channel.success]);
    }
    await tried;
    return (failure: failure, askedAs: askedAs, signedAs: signedAs, passwordSent: passwordSent);
  }

  ConnectionError said(Object e) =>
      ConnectionError.translate(connectionFailureText(e), host: 'web-01', port: 22, username: 'deploy');

  test('a host that takes both kinds with SHA-2: the app\'s key is asked about and signs as rsa-sha2-512', () async {
    final outcome = await signIn(takes: ['ssh-ed25519', sha512, sha256]);
    expect(outcome.failure, isNull);
    expect(outcome.askedAs, [sha512]);
    expect(outcome.signedAs, [sha512]);
  });

  test('a host that takes only rsa-sha2-256: asked about and signed as that', () async {
    final outcome = await signIn(takes: ['ssh-ed25519', sha256]);
    expect(outcome.failure, isNull);
    expect(outcome.askedAs, [sha256]);
    expect(outcome.signedAs, [sha256]);
  });

  test('a host that takes only the first kind, with SHA-1: the key is not offered to it, and the app says that, '
      'and that Compatibility mode is what makes such a signature', () async {
    final outcome = await signIn(takes: ['ssh-ed25519', sha1]);
    expect(outcome.askedAs, isEmpty);
    expect(outcome.signedAs, isEmpty);
    expect(outcome.failure, isA<SSHAuthFailError>());
    final shown = said(outcome.failure!);
    expect(shown.type, ConnectionErrorType.authKeyRejected);
    expect(shown.title, en.errKeyAuthFailedTitle);
    // (The tests run on a computer, which is told both places of the switch.)
    expect(shown.description, '${en.errSignInRsaOnlySha1('Auth / Show advanced options')} (deploy@web-01)');
    expect(shown.tip, isNull, reason: 'the sentence says what to do, and the server\'s authorized_keys is not it');
  });

  test('the same host with Compatibility mode on: the key is asked about and signs as ssh-rsa', () async {
    final outcome = await signIn(takes: ['ssh-ed25519', sha1], compatibilityMode: true);
    expect(outcome.failure, isNull);
    expect(outcome.askedAs, [sha1]);
    expect(outcome.signedAs, [sha1]);
  });

  test('Compatibility mode on, and a host that takes a kind with SHA-2: the key signs with that, and not with SHA-1',
      () async {
    final outcome = await signIn(takes: [sha1, sha256, sha512], compatibilityMode: true);
    expect(outcome.failure, isNull);
    expect(outcome.signedAs, [sha512]);
  });

  test('a host that takes no RSA key at all: the key is not offered to it, and the app says that', () async {
    for (final compatibilityMode in [false, true]) {
      final outcome = await signIn(takes: ['ssh-ed25519', 'ecdsa-sha2-nistp256'], compatibilityMode: compatibilityMode);
      expect(outcome.askedAs, isEmpty);
      final shown = said(outcome.failure!);
      expect(shown.type, ConnectionErrorType.authKeyRejected);
      expect(shown.description, '${en.errSignInRsaNotTaken} (deploy@web-01)');
      expect(shown.tip, isNull);
    }
  });

  test('with a password that the host refuses besides: what was tried is said first, and the key that was not '
      'offered after it', () async {
    final outcome = await signIn(takes: ['ssh-ed25519'], password: 'not-a-real-one');
    expect(outcome.askedAs, isEmpty);
    expect(outcome.passwordSent, isTrue);
    final shown = said(outcome.failure!);
    expect(shown.type, ConnectionErrorType.authPasswordFailed);
    expect(
      shown.description,
      '${en.errIncorrectPasswordDesc('web-01')} ${en.errSignInAlsoTakes(en.errSignInWayKey)} '
      '${en.errSignInRsaNotTaken}',
    );
  });

  test('a host that says nothing of what it takes: the key is asked about as rsa-sha2-256, as before; refused as '
      'that, it is asked about as ssh-rsa with Compatibility mode on, and in no other way with it off', () async {
    final asBefore = await signIn(takes: null);
    expect(asBefore.failure, isNull);
    expect(asBefore.signedAs, [sha256]);

    final old = await signIn(takes: null, compatibilityMode: true, refusedAs: [sha256]);
    expect(old.failure, isNull);
    expect(old.askedAs, [sha256, sha1]);
    expect(old.signedAs, [sha1]);

    final refused = await signIn(takes: null, refusedAs: [sha256]);
    expect(refused.askedAs, [sha256]);
    expect(refused.failure, isA<SSHAuthFailError>());
    // A key the host refused, and none that was passed over: said as it was.
    expect(said(refused.failure!).description, '${en.errKeyAuthFailedDesc} (deploy@web-01)');
    expect(said(refused.failure!).tip, en.errKeyAuthFailedTip);
  });

  test('a key that takes a person\'s time to sign (a hardware key) is waited for when it signs with another kind '
      'than its own', () async {
    // The host gets one second; the key signs after three.
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    final waited = Stopwatch()..start();
    final outcome = await signIn(takes: [sha512], key: _SlowRsa(rsa, const Duration(seconds: 3)));
    expect(outcome.failure, isNull);
    expect(outcome.signedAs, [sha512]);
    expect(waited.elapsed, greaterThan(const Duration(seconds: 3)));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('what stands for a key of the app\'s while it signs in says of RSA signatures what the key says', () {
    final deadline = AuthDeadline();
    final ed25519 = SSHKeyPair.fromPem(
            File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/ssh_host_ed25519_key').readAsStringSync())
        .single;
    final wrapped = signingOffTheClock([rsa, ed25519], deadline);
    expect(wrapped[0], isA<SSHRsaSignatureChoice>());
    expect((wrapped[0] as SSHRsaSignatureChoice).rsaSignatureTypes, [sha512, sha256, sha1]);
    for (final kind in [sha512, sha256, sha1]) {
      final signing = (wrapped[0] as SSHRsaSignatureChoice).signingAsRsa(kind);
      expect(signing.type, kind);
      expect(signing.runtimeType, wrapped[0].runtimeType, reason: 'it is waited for as the key it was made of');
      expect(signing.toPublicKey().encode(), rsa.toPublicKey().encode());
    }
    expect((wrapped[1] as SSHRsaSignatureChoice).rsaSignatureTypes, isEmpty);
    expect(wrapped[1].type, 'ssh-ed25519');
  });

  group('what is said, by itself', () {
    SSHAuthFailError refused({
      List<String> tried = const [],
      List<String> passedOver = const ['ssh-rsa'],
      List<String>? signatures = const ['ssh-ed25519', 'ssh-rsa'],
    }) =>
        SSHAuthFailError(
          'All authentication methods failed',
          methodsTried: tried,
          serverTakes: const ['publickey'],
          keysPassedOver: passedOver,
          serverSignatureAlgorithms: signatures,
        );

    test('the failure, as it is kept as text: the keys that were passed over and what the server takes, before '
        'what was tried; names only; and nothing where no key was passed over', () {
      expect(
        connectionFailureText(refused()),
        'SSHAuthFailError(All authentication methods failed) [keys passed over: ssh-rsa] '
        '[signatures the server takes: ssh-ed25519,ssh-rsa] [tried: ] [the server takes: publickey]',
      );
      expect(signaturesKeysWerePassedOverFor(connectionFailureText(refused())), ['ssh-ed25519', 'ssh-rsa']);
      expect(signInWaysOf(connectionFailureText(refused()))!.tried, isEmpty);
      expect(signInWaysOf(connectionFailureText(refused()))!.takes, ['publickey']);
      // A server that takes no signature at all, and one that had said nothing (which passes no key over by itself).
      expect(signaturesKeysWerePassedOverFor(connectionFailureText(refused(signatures: const []))), isEmpty);
      expect(signaturesKeysWerePassedOverFor(connectionFailureText(refused(signatures: null))), isEmpty);
      // No key passed over: the text is what it was.
      final asItWas = connectionFailureText(refused(passedOver: const [], tried: const ['publickey']));
      expect(asItWas, 'SSHAuthFailError(All authentication methods failed) [tried: publickey] [the server takes: publickey]');
      expect(signaturesKeysWerePassedOverFor(asItWas), isNull);
      // What is no name is not kept, of either list.
      final odd = withKeysPassedOver('x', ['ssh-rsa', 'with a blank', 'a]b'], ['ssh-rsa', 'two words', '[tried: ]']);
      expect(odd, 'x [keys passed over: ssh-rsa] [signatures the server takes: ssh-rsa]');
      // At most forty of what a server takes are kept.
      final many = withKeysPassedOver('x', ['ssh-rsa'], [for (var i = 0; i < 60; i++) 'kind-$i']);
      expect(signaturesKeysWerePassedOverFor(many), hasLength(40));
    });

    test('the editor\'s connection test says what a failed connection says of it: the key that was not offered, '
        'by itself where nothing else was tried, and after the refusal where something was', () {
      expect(editorTestSaid(en, refused(), onAComputer: true), en.errSignInRsaOnlySha1('Auth / Show advanced options'));
      expect(editorTestSaid(en, refused(signatures: const ['ssh-ed25519'])), en.errSignInRsaNotTaken);
      // A password that was refused, and the key: what was refused, what else the server takes, then the key,
      // then what to look at.
      expect(
        editorTestSaid(en, refused(tried: const ['password'], signatures: const ['ssh-ed25519']),
            host: 'web-01.example.com'),
        '${en.errIncorrectPasswordDesc('web-01.example.com')} ${en.errSignInAlsoTakes(en.errSignInWayKey)} '
        '${en.errSignInRsaNotTaken}\n\n${en.errIncorrectPasswordTip}',
      );
      // A key that was offered and refused, with none passed over: the key the server rejected.
      expect(
        editorTestSaid(en, refused(passedOver: const [], tried: const ['publickey'])),
        '${en.errKeyAuthFailedDesc}\n\n${en.errKeyAuthFailedTip}',
      );
    });

    test('the editor says a refused sign-in as it says every failure of its tests (read from its file: no test '
        'signs in with an RSA key through the editor)', () {
      final source = File('lib/features/hosts/host_tester.dart').readAsStringSync();
      expect(
        source.replaceAll('\r\n', '\n'),
        contains('    } on SSHAuthFailError catch (e) {\n'
            '      stopwatch.stop();\n'
            '      return _failed(l10n, e, cfg);\n'),
      );
    });

    test('the two sentences, word for word', () {
      expect(
        en.errSignInRsaOnlySha1('Auth'),
        'This server takes an RSA key only with the first kind of RSA signature (ssh-rsa, made with SHA-1), which '
        'this app makes in Compatibility mode only. Your RSA key was not offered to it. Edit this host and '
        'turn on Compatibility mode (under "Auth"), or sign in with a key of another kind. Signatures made with '
        'SHA-1 are less secure, so turn the mode on only for servers that cannot be updated.',
      );
      expect(
        en.errSignInRsaNotTaken,
        'This server has said which kinds of key it takes, and an RSA key is not among them. Your RSA key was not '
        'offered to it. Sign in with a key of another kind, an Ed25519 key for example.',
      );
    });

    test('in every language: each sentence its own, the first with the name the editor shows for Compatibility '
        'mode, and the note of that switch saying what it lets an RSA key make (where the switch is said to be: '
        'test/utils/compatibility_mode_said_test.dart)', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        final reason = '$locale';
        final onlySha1 = l10n.errSignInRsaOnlySha1(l10n.connectionEditRailAuth);
        expect(onlySha1, contains(l10n.connectionEditCompatibilityMode), reason: reason);
        for (final sentence in [onlySha1, l10n.errSignInRsaNotTaken]) {
          expect(sentence, contains('RSA'), reason: reason);
        }
        expect(onlySha1, contains('ssh-rsa'), reason: reason);
        expect(onlySha1, contains('SHA-1'), reason: reason);
        expect(l10n.errSignInRsaNotTaken, contains('Ed25519'), reason: reason);
        expect(l10n.errSignInRsaNotTaken, isNot(contains('SHA-1')), reason: reason);
        expect(onlySha1, isNot(l10n.errSignInRsaNotTaken), reason: reason);
        expect(l10n.connectionEditCompatibilityModeNote, contains('RSA'), reason: reason);
        expect(l10n.connectionEditCompatibilityModeNote, contains('SHA-1'), reason: reason);
        if (locale.languageCode == 'en') continue;
        expect(l10n.errSignInRsaOnlySha1('X'), isNot(en.errSignInRsaOnlySha1('X')), reason: reason);
        expect(l10n.errSignInRsaNotTaken, isNot(en.errSignInRsaNotTaken), reason: reason);
        expect(l10n.connectionEditCompatibilityModeNote, isNot(en.connectionEditCompatibilityModeNote), reason: reason);
      }
    });
  });
}

/// An RSA key that signs only after [_takes], as a key on a hardware key
/// does that waits for its person's touch, and that says of the kinds of
/// RSA signature what the key it wraps says.
class _SlowRsa extends SSHKeyPair implements SSHRsaSignatureChoice {
  _SlowRsa(this._key, this._takes);

  final SSHKeyPair _key;
  final Duration _takes;

  @override
  List<String> get rsaSignatureTypes => (_key as SSHRsaSignatureChoice).rsaSignatureTypes;

  @override
  SSHKeyPair signingAsRsa(String type) => _SlowRsa((_key as SSHRsaSignatureChoice).signingAsRsa(type), _takes);

  @override
  String get name => _key.name;

  @override
  String get type => _key.type;

  @override
  core_hk.SSHHostKey toPublicKey() => _key.toPublicKey();

  @override
  SSHSignature sign(Uint8List data) => _key.sign(data);

  @override
  Future<SSHSignature> signAsync(Uint8List data) async {
    await Future<void>.delayed(_takes);
    return _key.sign(data);
  }

  @override
  String toPem() => _key.toPem();
}
