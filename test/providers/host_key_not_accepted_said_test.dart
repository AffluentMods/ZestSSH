import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart'
    show connectionFailureText, hostKeyDeclinedByItsPerson, hostKeyNotAccepted, jumpHostFailureText, reconnectCannotHelp;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';

/// What is said of a host's key that was not accepted, by why (3.0, the SSH
/// core's audit). Each of these was "Authentication Failed: The server
/// closed the connection before completing login.", with a tip to check the
/// sign-in details: nothing had been sent to the host, and the server had
/// closed nothing. (Through a session, against a real server:
/// host_key_not_accepted_test.dart.) A key that a run with nobody there
/// met (automation, 3.0) is said as automation's own runs say it, and
/// nobody was shown it.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  // What a run with nobody there refuses by itself: nobody was shown these.
  const byARun = {HostKeyRefusal.unknownUnattended, HostKeyRefusal.changedUnattended};

  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  HostKeyNotAccepted unaccepted(HostKeyRefusal why, {String? crate}) =>
      HostKeyNotAccepted(why, host: '192.0.2.10', port: 22, crate: crate);

  /// As a session has it: the sign-in was cut off, for [reason].
  SSHAuthAbortError cutOff(SSHError reason) => SSHAuthAbortError('Connection closed before authentication', reason);

  ConnectionError said(Object e) =>
      ConnectionError.translate(connectionFailureText(e), host: 'web-01', port: 22, username: 'deploy');

  test('each kind says what it was: where its person was shown the key, with the address that showed it and that '
      "nothing was sent; a run's, as automation's own runs say it", () {
    final sentences = {
      HostKeyRefusal.declinedNew:
          'The key that 192.0.2.10 showed was not accepted, so the connection was not made. Nothing was sent to it.',
      HostKeyRefusal.declinedChanged:
          '192.0.2.10 showed another key than the one this device trusts for it, and that key was not accepted. '
              "Nothing was sent to it. A host's key changes when the host is set up anew, and when something stands "
              'between this device and the host: check the key before you accept it.',
      // What the question about such a key says, and who can do something about it.
      HostKeyRefusal.pinnedOther:
          'Everyone in Production trusts another key for 192.0.2.10. The host key may have been replaced on purpose, '
              'or someone may be in the way. Nobody connects with this key until someone checks it. Someone who may '
              'edit Production checks the key on the host itself and replaces the team\'s pin.',
      // A run with nobody there: as automation's own runs say it.
      HostKeyRefusal.unknownUnattended:
          "This device does not know the host's key yet, and a new key is not accepted when nobody is there to check "
              'it. Connect to the host in the app once and accept its key; after that this will run.',
      HostKeyRefusal.changedUnattended:
          "The host's key is not the one this device knows, so it was not signed in to and nothing was run. Connect "
              'to the host in the app to see what changed.',
    };
    expect(sentences.keys.toSet(), HostKeyRefusal.values.toSet());
    sentences.forEach((why, sentence) {
      final error = unaccepted(why, crate: why == HostKeyRefusal.pinnedOther ? 'Production' : null);
      // As what ended a sign-in, and by itself.
      for (final failure in <Object>[cutOff(error), error]) {
        final shown = said(failure);
        expect(shown.type, ConnectionErrorType.saidByApp, reason: why.name);
        expect(shown.description, sentence, reason: why.name);
      }
      expect('$error', 'SSHHostkeyError(The host key of 192.0.2.10:22 was not accepted (${why.name}))');
    });
  });

  test('a key of which no more is known than that a check did not accept it is said as that', () {
    for (final failure in <Object>[
      cutOff(SSHHostkeyError('Hostkey verification failed')),
      SSHHostkeyError('Hostkey verification failed'),
    ]) {
      final shown = said(failure);
      expect(shown.type, ConnectionErrorType.saidByApp);
      expect(shown.description,
          "The host's key was not accepted, so the connection was not made. Nothing was sent to the host.");
    }
  });

  // What the SSH core finds wrong with a key by itself, before anybody is
  // asked: each was the sentence above, which says nothing of why.
  test('a key that the SSH core refused by itself is said as what was wrong with it', () {
    final sentences = {
      SSHHostkeyFault.notSigned:
          'The host showed a key and could not prove that the key is its own, so the connection was not made. '
              'Nothing was sent to it. A host that holds its key can always prove that: this happens when something '
              'stands between this device and the host and answers in its place, and with a host whose SSH server is '
              'broken.',
      SSHHostkeyFault.noKey:
          'The host showed something that is not a key a host can have, so the connection was not made. Nothing was '
              'sent to it. The connection log says what was wrong with it. This happens when something stands between '
              'this device and the host and answers in its place, and with a host whose SSH server is broken.',
      // (Made without its lengths, as this loop makes it: said as what it is besides. With them: below.)
      SSHHostkeyFault.tooShort:
          'The host showed something that is not a key a host can have, so the connection was not made. Nothing was '
              'sent to it. The connection log says what was wrong with it. This happens when something stands between '
              'this device and the host and answers in its place, and with a host whose SSH server is broken.',
      SSHHostkeyFault.changed:
          'While this session was open, the host asked for new keys, and the key it showed then was not the one the '
              'session began with, or it could not prove that it was. The session was ended. A host keeps its key '
              'while a session is open: connect again to see which key it shows now, and check it before you accept '
              'it.',
    };
    expect(sentences.keys.toSet(), SSHHostkeyFault.values.toSet());
    sentences.forEach((fault, sentence) {
      final error = SSHHostkeyError('whatever the core says of it', fault: fault);
      // As what ended a sign-in, and by itself.
      for (final failure in <Object>[cutOff(error), error]) {
        final shown = said(failure);
        expect(shown.type, ConnectionErrorType.saidByApp, reason: fault.name);
        expect(shown.description, sentence, reason: fault.name);
      }
      expect(reconnectCannotHelp(error), isTrue, reason: fault.name);
      expect(hostKeyDeclinedByItsPerson(error), isFalse, reason: 'nobody was shown this key');
    });

    // An RSA key that is too short, with its lengths: both are said, and what takes such a key.
    final short = SSHHostkeyError('whatever the core says of it',
        fault: SSHHostkeyFault.tooShort, bits: 768, shortestTaken: 1024);
    for (final failure in <Object>[cutOff(short), short]) {
      final shown = said(failure);
      expect(shown.type, ConnectionErrorType.saidByApp);
      expect(
        shown.description,
        'The host showed an RSA key of 768 bits, and none under 1024 bits is taken, so the connection was '
        'not made. Nothing was sent to the host. A key that short can be worked out by whoever has the '
        'means, and whoever has done so can answer in the host\'s place. The host needs a longer key, which '
        'its SSH server can make. For an old device that cannot have one, Compatibility mode, turned on for '
        'this host, takes such a key.',
      );
    }
    expect(reconnectCannotHelp(short), isTrue);
    expect(hostKeyDeclinedByItsPerson(short), isFalse, reason: 'nobody was shown this key');

    // Refused when new keys were taken on a connection that was open, whatever was wrong with the key then
    // (and where no more is known of it): of that connection it is not true that nothing was sent.
    for (final fault in [...SSHHostkeyFault.values, null]) {
      final later = SSHHostkeyError('whatever the core says of it', fault: fault, duringRekey: true);
      for (final failure in <Object>[cutOff(later), later]) {
        final shown = said(failure);
        expect(shown.type, ConnectionErrorType.saidByApp, reason: '$fault');
        expect(shown.description, sentences[SSHHostkeyFault.changed], reason: '$fault');
        expect(shown.description, isNot(contains('Nothing was sent')), reason: '$fault');
      }
      expect(reconnectCannotHelp(later), isTrue, reason: '$fault');
    }
  });

  test('its person was shown the key, and said no or was told there that nothing can be done; not a run with '
      'nobody there', () {
    for (final why in HostKeyRefusal.values) {
      final shown = !byARun.contains(why);
      expect(hostKeyDeclinedByItsPerson(cutOff(unaccepted(why))), shown, reason: why.name);
      expect(hostKeyDeclinedByItsPerson(unaccepted(why)), shown, reason: why.name);
      // Of a jump host on the way too.
      final atJumpHost = JumpHostFailure(
          label: 'vpn-gateway', host: '192.168.10.23', port: 22, stage: JumpStage.signIn, cause: cutOff(unaccepted(why)));
      expect(hostKeyDeclinedByItsPerson(atJumpHost), shown, reason: why.name);
      expect(hostKeyNotAccepted(atJumpHost), isA<HostKeyNotAccepted>());
      // Connecting again by itself cannot help with any of them.
      expect(reconnectCannotHelp(cutOff(unaccepted(why))), isTrue, reason: why.name);
    }
    // A check that only answered no asked nobody that is known of.
    expect(hostKeyDeclinedByItsPerson(cutOff(SSHHostkeyError('Hostkey verification failed'))), isFalse);
    // And nothing else is a host's key.
    for (final other in <Object>[
      SSHAuthAbortError('Connection closed before authentication'),
      SSHAuthFailError('All authentication methods failed'),
      StateError('anything else'),
    ]) {
      expect(hostKeyNotAccepted(other), isNull, reason: '$other');
      expect(hostKeyDeclinedByItsPerson(other), isFalse, reason: '$other');
    }
  });

  test('of a jump host on the way: under its name, with the address that showed the key', () {
    final failure = JumpHostFailure(
      label: 'vpn-gateway',
      host: '192.168.10.23',
      port: 22,
      stage: JumpStage.signIn,
      cause: cutOff(HostKeyNotAccepted(HostKeyRefusal.declinedChanged, host: '192.168.10.23', port: 22)),
    );
    expect(
      jumpHostFailureText(en, failure),
      'Signing in to the jump host vpn-gateway did not work. 192.168.10.23 showed another key than the one this '
      "device trusts for it, and that key was not accepted. Nothing was sent to it. A host's key changes when the "
      'host is set up anew, and when something stands between this device and the host: check the key before you '
      'accept it.',
    );
  });

  test('while recording, the address is masked', () {
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout;
    addTearDown(() => Redactor.instance
      ..clearNames()
      ..enabled = false);
    for (final why in HostKeyRefusal.values) {
      final sentence = said(cutOff(unaccepted(why, crate: 'Production'))).description;
      expect(sentence, isNot(contains('192.0.2.10')), reason: why.name);
    }
  });

  test('every language says them its own way, with the address', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      final sentences = [
        for (final why in HostKeyRefusal.values) said(cutOff(unaccepted(why, crate: 'Production'))).description,
        said(SSHHostkeyError('Hostkey verification failed')).description,
      ];
      expect(sentences.toSet(), hasLength(6), reason: '$locale');
      for (final why in HostKeyRefusal.values.where((why) => !byARun.contains(why))) {
        expect(sentences[why.index], contains('192.0.2.10'), reason: '$locale');
      }
      expect(sentences[HostKeyRefusal.unknownUnattended.index], l10n.automationSvcHostKeyUnknown, reason: '$locale');
      expect(sentences[HostKeyRefusal.changedUnattended.index], l10n.automationSvcHostKeyChanged, reason: '$locale');
      expect(sentences.last, l10n.connHostKeyNotAcceptedPlain, reason: '$locale');
      // And what the core refused by itself: a sentence each, and none of the others.
      final byTheCore = [
        for (final fault in SSHHostkeyFault.values) said(SSHHostkeyError('x', fault: fault)).description,
      ];
      expect({...sentences, ...byTheCore}, hasLength(9), reason: '$locale');
      // (A key that is too short, made without its lengths, is said as no key a host can have.)
      expect(
        byTheCore,
        [l10n.connHostKeyNotSigned, l10n.connHostKeyFailedAtNewKeys, l10n.connHostKeyNoKey, l10n.connHostKeyNoKey],
        reason: '$locale',
      );
      // With its lengths: a sentence of its own, with both, the kind of key, and the mode as the editor names it.
      final short =
          said(SSHHostkeyError('x', fault: SSHHostkeyFault.tooShort, bits: 768, shortestTaken: 1024)).description;
      expect(short, l10n.connHostKeyTooShort(768, 1024), reason: '$locale');
      for (final part in ['768', '1024', 'RSA']) {
        expect(short, contains(part), reason: '$locale');
      }
      expect(short.toLowerCase(), contains(l10n.connectionEditCompatibilityMode.toLowerCase()), reason: '$locale');
      expect(short, isNot(contains('{')), reason: '$locale');
      expect({...sentences, ...byTheCore, short}, hasLength(10), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      expect(l10n.connHostKeyNotSigned, isNot(en.connHostKeyNotSigned), reason: '$locale');
      expect(l10n.connHostKeyNoKey, isNot(en.connHostKeyNoKey), reason: '$locale');
      expect(l10n.connHostKeyTooShort(768, 1024), isNot(en.connHostKeyTooShort(768, 1024)), reason: '$locale');
      expect(l10n.connHostKeyFailedAtNewKeys, isNot(en.connHostKeyFailedAtNewKeys), reason: '$locale');
      expect(l10n.connHostKeyNotAcceptedPlain, isNot(en.connHostKeyNotAcceptedPlain), reason: '$locale');
      expect(l10n.connHostKeyDeclined('x'), isNot(en.connHostKeyDeclined('x')), reason: '$locale');
      expect(l10n.connHostKeyChangedDeclined('x'), isNot(en.connHostKeyChangedDeclined('x')), reason: '$locale');
    }
  });
}
