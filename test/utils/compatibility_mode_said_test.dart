import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../helpers/editor_test_said.dart';

/// What the app says of Compatibility mode where it is what a host needs
/// (3.0, found while the SSH core's audit was at RSA keys).
///
/// Three things were wrong. The tip of a failed connection, and the
/// sentence of a key that was not offered, said that the switch is under
/// "Advanced": on a computer the editor has a tab of that name, and the
/// switch is not on it (it is under "Auth" where the editor has tabs, and
/// behind "Show advanced options" where it has none, which on a computer
/// it also has not when it is opened as a page of its own). The tip and the
/// switch's own note said that the
/// mode offers "DH group-1", which it does not. And the editor's own
/// connection test said of a host that has nothing in common with the app
/// "Auth aborted: Connection closed before authentication", with nothing of
/// the mode.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  SSHAuthAbortError cutOff(String found) =>
      SSHAuthAbortError('Connection closed before authentication', SSHHandshakeError(found));

  // The place as a computer is told it, and as a phone is.
  const computer = 'Auth / Show advanced options';
  // A phone's form folds the switch under "Advanced options" (4.0).
  const phone = 'Advanced options';

  test('where the switch is: behind the advanced options on a phone; on a computer under the tab for the sign-in, '
      'or behind the advanced options where the editor is opened without tabs, and both are named', () {
    expect(compatibilityModePlace(en, onAComputer: true), 'Auth / Show advanced options');
    expect(compatibilityModePlace(en, onAComputer: false), 'Advanced options');
    expect(en.connectionEditRailAuth, 'Auth');
    expect(en.connectionEditShowAdvanced, 'Show advanced options');
    // A phone is told its form's fold in every language.
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect(compatibilityModePlace(l10n, onAComputer: false), l10n.hostFormAdvancedOptions, reason: '$locale');
    }
    // Unless a test says otherwise it is what this device is: the tests run on a computer.
    expect(compatibilityModePlace(en), computer);
  });

  test('which kind of algorithm the two have none in common of, by the SSH core\'s words', () {
    expect(algorithmKindNotInCommon(en, 'SSHHandshakeError(No matching key exchange algorithm)'), 'key exchange');
    expect(algorithmKindNotInCommon(en, 'No matching host key algorithm'), 'host key');
    expect(algorithmKindNotInCommon(en, 'No matching client cipher algorithm'), 'cipher');
    expect(algorithmKindNotInCommon(en, 'No matching server cipher algorithm'), 'cipher');
    expect(algorithmKindNotInCommon(en, 'No matching client MAC algorithm'), 'MAC');
    expect(algorithmKindNotInCommon(en, 'No matching server MAC algorithm'), 'MAC');
    expect(algorithmKindNotInCommon(en, 'No matching compression algorithm'), 'encryption');
    expect(algorithmKindNotInCommon(en, 'Strict KEX violation'), isNull);
    expect(algorithmKindNotInCommon(en, 'No matching host'), isNull);
    expect(algorithmKindNotInCommon(en, 'An algorithm was refused'), isNull);
  });

  test('a failed connection: the tip names the switch and where it is on this device', () {
    final shown = ConnectionError.translate('SSHHandshakeError(No matching server cipher algorithm)',
        host: 'web-01', port: 22, username: 'deploy');
    expect(shown.type, ConnectionErrorType.algorithmMismatch);
    expect(shown.description, en.errAlgorithmMismatchDesc('cipher', 'web-01'));
    expect(shown.tip, en.errAlgorithmMismatchTip(computer));
    // The place is this device's unless it is said. (A text that says nothing of what each side offered, as
    // this one, is given the tip: whether the mode has anything for the server is not known of it. What is
    // said where that is known: test/services/ssh_nothing_in_common_test.dart.)
    const raw = 'SSHHandshakeError(No matching server cipher algorithm)';
    expect(ConnectionError.translate(raw, host: 'web-01', onAComputer: false).tip, en.errAlgorithmMismatchTip(phone));
    expect(ConnectionError.translate(raw, host: 'web-01', onAComputer: true).tip, en.errAlgorithmMismatchTip(computer));
  });

  test('the editor\'s connection test: nothing in common with the host is said as a failed connection says it, with '
      'the switch and where it is', () {
    final nothing = cutOff('No matching server cipher algorithm');
    final said = en.errAlgorithmMismatchDesc('cipher', '192.168.10.21');
    expect(editorTestSaid(en, nothing, host: '192.168.10.21', onAComputer: true),
        '$said\n\n${en.errAlgorithmMismatchTip(computer)}');
    expect(editorTestSaid(en, nothing, host: '192.168.10.21', onAComputer: false),
        '$said\n\n${en.errAlgorithmMismatchTip(phone)}');
    expect(editorTestSaid(en, nothing, host: '192.168.10.21'), '$said\n\n${en.errAlgorithmMismatchTip(computer)}');
    // With no host to name, and for another kind.
    expect(editorTestSaid(en, cutOff('No matching key exchange algorithm')),
        '${en.errAlgorithmMismatchDesc('key exchange', 'the server')}\n\n${en.errAlgorithmMismatchTip(computer)}');
    // Another failure of a key exchange is said as a failed connection says it: an error in the handshake.
    expect(editorTestSaid(en, cutOff('The server sent NEWKEYS without an answer to a key exchange.')),
        '${en.errSshProtocolDesc('the server')}\n\n${en.errSshProtocolTip}');
  });

  test('the tip and the sentence of a key that was not offered, word for word', () {
    expect(
      en.errAlgorithmMismatchTip('Auth'),
      'Edit this host and turn on "Compatibility mode" (under "Auth"), then try again. That tells ZestSSH to '
      'also offer what older servers need (CBC ciphers, hmac-md5, key exchanges and RSA signatures with SHA-1). '
      'Modern algorithms stay preferred, so enabling this never weakens a connection to a modern server. The older '
      'algorithms are less secure, so turn the mode on only for servers that cannot be updated.',
    );
    expect(
      en.errSignInRsaOnlySha1('Show advanced options'),
      'This server takes an RSA key only with the first kind of RSA signature (ssh-rsa, made with SHA-1), which '
      'this app makes in Compatibility mode only. Your RSA key was not offered to it. Edit this host and turn '
      'on Compatibility mode (under "Show advanced options"), or sign in with a key of another kind. Signatures made '
      'with SHA-1 are less secure, so turn the mode on only for servers that cannot be updated.',
    );
    expect(rsaKeyPassedOverText(en, const ['ssh-rsa'], onAComputer: true), en.errSignInRsaOnlySha1(computer));
    expect(rsaKeyPassedOverText(en, const ['ssh-rsa'], onAComputer: false), en.errSignInRsaOnlySha1(phone));
    expect(rsaKeyPassedOverText(en, const ['ssh-rsa']), en.errSignInRsaOnlySha1(computer));
    expect(rsaKeyPassedOverText(en, const ['ssh-ed25519'], onAComputer: false), en.errSignInRsaNotTaken);
    // The switch says that it is not recommended, and for old servers only: its
    // label and the first words of its note.
    expect(en.connectionEditCompatibilityModeLabel, 'Compatibility mode (old servers only)');
    expect(
      en.connectionEditCompatibilityModeNote,
      'Not recommended. This is for old servers that refuse modern SSH algorithms (Proxmox LXC, OpenWrt, or any '
      'OpenSSH below 7.6). It adds CBC ciphers, hmac-md5, key exchanges and RSA signatures with SHA-1, and key '
      'exchange groups of 1024 bits, and takes an RSA host key shorter than 2048 bits, which some old devices have. '
      'All of this is less secure than what modern servers use: turn the mode on only for a server that cannot be '
      'updated.',
    );
  });

  test('in every language: the switch\'s label starts with the name the other messages give the mode and says it '
      'is for old servers only, and its note says first that it is not recommended', () {
    // "Not recommended", as each language's note starts.
    const notRecommended = {
      'en': 'Not recommended.',
      'de': 'Nicht empfohlen.',
      'es': 'No recomendado.',
      'fr': 'Déconseillé.',
      'it': 'Sconsigliato.',
      'pt': 'Não recomendado.',
      'ru': 'Не рекомендуется.',
      'ar': 'غير مستحسن.',
      'hi': 'अनुशंसित नहीं।',
      'ja': '非推奨です。',
      'ko': '권장하지 않습니다.',
      'zh': '不推荐。',
    };
    expect(notRecommended.keys.toSet(), {for (final l in AppLocalizations.supportedLocales) l.languageCode});
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final reason = '$locale';
      expect(l10n.connectionEditCompatibilityModeLabel, startsWith(l10n.connectionEditCompatibilityMode),
          reason: reason);
      expect(l10n.connectionEditCompatibilityModeLabel.length, greaterThan(l10n.connectionEditCompatibilityMode.length),
          reason: reason);
      expect(l10n.connectionEditCompatibilityModeNote, startsWith(notRecommended[locale.languageCode]!),
          reason: reason);
      // The groups of 1024 bits it now takes, and the RSA host key under 2048 bits (since 3.3.0).
      expect('1024'.allMatches(l10n.connectionEditCompatibilityModeNote), hasLength(1), reason: reason);
      expect('2048'.allMatches(l10n.connectionEditCompatibilityModeNote), hasLength(1), reason: reason);
      if (locale.languageCode == 'en') continue;
      expect(l10n.connectionEditCompatibilityModeLabel, isNot(en.connectionEditCompatibilityModeLabel),
          reason: reason);
    }
  });

  test('in every language: the tip and the sentence name the switch as the editor shows it and the place they are '
      'given, once; neither they nor the note name a group the mode does not offer', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final reason = '$locale';
      for (final place in [
        compatibilityModePlace(l10n, onAComputer: true),
        compatibilityModePlace(l10n, onAComputer: false),
      ]) {
        for (final said in [l10n.errAlgorithmMismatchTip(place), l10n.errSignInRsaOnlySha1(place)]) {
          expect(said, contains(l10n.connectionEditCompatibilityMode), reason: reason);
          expect(place.allMatches(said), hasLength(1), reason: reason);
          expect(said, isNot(contains('{where}')), reason: reason);
          expect(said, contains('SHA-1'), reason: reason);
          expect(said, isNot(contains('group-1')), reason: reason);
        }
      }
      expect(l10n.errAlgorithmMismatchTip('X'), contains('CBC'), reason: reason);
      expect(l10n.errAlgorithmMismatchTip('X'), contains('hmac-md5'), reason: reason);
      expect(l10n.errAlgorithmMismatchTip('X'), contains('RSA'), reason: reason);
      expect(l10n.connectionEditCompatibilityModeNote, isNot(contains('group-1')), reason: reason);
      expect(l10n.connectionEditCompatibilityModeNote, contains('SHA-1'), reason: reason);
      // And that the mode takes a short RSA host key, which is what an RSA key that is too short is told.
      expect(l10n.connectionEditCompatibilityModeNote, contains('2048'), reason: reason);
      if (locale.languageCode == 'en') continue;
      expect(l10n.errAlgorithmMismatchTip('X'), isNot(en.errAlgorithmMismatchTip('X')), reason: reason);
      expect(l10n.errSignInRsaOnlySha1('X'), isNot(en.errSignInRsaOnlySha1('X')), reason: reason);
    }
  });

  test('in every language: where the mode is offered, it is said that what it adds is less secure, and to keep it for '
      'servers that cannot be updated ("older, less secure")', () {
    // "Less secure", as each language says it.
    const lessSecure = {
      'en': 'less secure',
      'de': 'weniger sicher',
      'es': 'menos segur',
      'fr': 'moins sûr',
      'it': 'meno sicur',
      'pt': 'menos segur',
      'ru': 'менее безопасн',
      'ar': 'أقل أمانًا',
      'hi': 'कम सुरक्षित',
      'ja': '安全性が低',
      'ko': '보안이 약하',
      'zh': '安全性',
    };
    expect(lessSecure.keys.toSet(), {for (final l in AppLocalizations.supportedLocales) l.languageCode});
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final words = lessSecure[locale.languageCode]!;
      for (final said in [
        l10n.errAlgorithmMismatchTip('X'),
        l10n.errSignInRsaOnlySha1('X'),
        l10n.connectionEditCompatibilityModeNote,
      ]) {
        expect(said, contains(words), reason: '$locale: $said');
      }
    }
    expect(en.errAlgorithmMismatchTip('X'), endsWith('turn the mode on only for servers that cannot be updated.'));
  });
}
