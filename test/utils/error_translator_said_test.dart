import 'dart:io' show SocketException;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart'
    show HostSkippedOnNetworkException, SSHAuthFailedException, connectionFailureText;
import 'package:zestssh/utils/error_translator.dart';

/// What the app itself said about a failed connection is shown as it said
/// it (3.0). A sign-in the app could not start has a reason
/// the app wrote for the person, in their language: a certificate that
/// waits for an owner, a password manager that gave nothing, a key that is
/// not there, a host it was told to skip. Kept as plain text, that reason
/// went through the translator made for the SSH library's errors, matched
/// nothing it knows in any language, and came out as "An unexpected error
/// occurred while connecting", with the reason only under the details. It
/// is marked where it is kept now, and shown as it is.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  test('in every language the app\'s own reason is shown as the app wrote it', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      for (final said in [
        l10n.teamCertWaitingForOwner,
        l10n.teamCertNotAsked,
        l10n.teamCertHeldBack,
        l10n.teamCertNoAuthority,
        l10n.teamCertNoAccess,
        l10n.teamCertNoUserNames,
        l10n.teamCertNotThisUserName('root', 'deploy'),
        l10n.pmFailed,
        // What an Orchard's rules refuse at a sign-in, and a Crate closed
        // on this device by its own offline limit.
        l10n.watchedKeyOtherHost,
        l10n.watchedHostNoJump('web-01'),
        l10n.watchedNobodyToAsk('Production'),
        l10n.watchedNobodyJoined,
        l10n.watchedNotReady,
        l10n.orchardPasswordWrongHost,
        l10n.orchardPasswordNotConfirmed,
        l10n.pmNotAllowed,
        l10n.crateClosedOfflineError('Production'),
        l10n.crateClosedOfflineCloud('Production'),
      ]) {
        final shown = ConnectionError.translate(saidByApp(said), host: 'web-01', port: 22, username: 'deploy');
        expect(shown.type, ConnectionErrorType.saidByApp, reason: '$locale');
        expect(shown.description, said, reason: '$locale');
        expect(shown.title, l10n.errConnectionFailedTitle, reason: '$locale');
        expect(shown.tip, isNull, reason: 'the reason itself says what to do');
        expect(shown.rawError, '$kSaidByApp$said', reason: 'the report says who is speaking');
      }
    }
  });

  test('only what starts with the mark is the app speaking', () {
    // What a library or the system says is put into the app's words as ever.
    final refused = ConnectionError.translate(
        'SocketException: Connection refused (OS Error: Connection refused, errno = 111)',
        host: 'web-01',
        port: 22);
    expect(refused.type, ConnectionErrorType.refused);
    expect(refused.tip, isNotNull);
    // The mark in the middle of something is not the mark.
    for (final raw in [
      'SSHAuthAbortError(ZestSSH: nothing of the kind)',
      ' ZestSSH: a space too early',
      'zestssh: in small letters',
      'ZestSSH:without the space',
    ]) {
      expect(ConnectionError.translate(raw).type, isNot(ConnectionErrorType.saidByApp), reason: raw);
    }
    // The mark with nothing after it is the app saying nothing, not an error of the SSH library's.
    expect(ConnectionError.translate(kSaidByApp).description, isEmpty);
    expect(saidByApp('Something.'), 'ZestSSH: Something.');
  });

  test('a failure is kept as the app\'s own words exactly when the app wrote them', () {
    expect(connectionFailureText(const SSHAuthFailedException('Your certificate is waiting.')),
        'ZestSSH: Your certificate is waiting.');
    expect(connectionFailureText(const HostSkippedOnNetworkException('Skipped on this network.')),
        'ZestSSH: Skipped on this network.');
    // What an Orchard's rules refuse is the app speaking too (a watched
    // Crate's key sent elsewhere, nobody there to watch, a password that
    // was not confirmed): kept as a bare sentence, each of these was shown
    // as "An unexpected error occurred while connecting".
    expect(connectionFailureText(const OrchardAccessRefused('This key signs in to its own hosts only.')),
        'ZestSSH: This key signs in to its own hosts only.');
    // And a Crate closed on this device by its own offline limit.
    expect(
        connectionFailureText(
            const CrateClosedOffline(crateId: 'c', hours: 24, message: 'Production is closed on this device.')),
        'ZestSSH: Production is closed on this device.');
    // What something else threw stays as it said it, whatever it says.
    const refused = SocketException('Connection refused');
    expect(connectionFailureText(refused), '$refused');
    expect(connectionFailureText(StateError('ZestSSH: not the app')), 'Bad state: ZestSSH: not the app');
  });
}
