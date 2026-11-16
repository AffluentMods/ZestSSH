import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import '../helpers/dart_calls.dart';

/// Words that said what the app does not do (the docs audit of 18 October
/// 2026): a changed host key is not "always refused" (it stops the
/// connection until the person checks it, and they may trust the new one);
/// the sync messages name the Account page and its "Sync now", in each
/// language as the page and the button are called there; the key generator
/// names ECDSA too; an identity's password is in the device's secure
/// storage; and Settings counts the shortcuts its page lists.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test('the host key setting says what a changed key does', () {
    expect(en.settingsInlineUnknownHostKeysAskDesc, 'A changed key always stops the connection until you check it.');
    expect(en.settingsInlineUnknownHostKeysTofuDesc,
        'New hosts are trusted without asking. A changed key still stops the connection until you check it.');
  });

  for (final locale in AppLocalizations.supportedLocales) {
    test('$locale: the sync messages name the Account page and its button, and the keys and the password are right',
        () {
      final t = lookupAppLocalizations(locale);
      for (final s in [t.syncCannotDecrypt, t.syncKeysNoLongerMatch]) {
        expect(s, contains(t.accountTitle), reason: s);
        expect(s, contains(t.accountSyncNow), reason: s);
      }
      expect(t.identityGenerateNewKeyDesc, allOf(contains('Ed25519'), contains('ECDSA'), contains('RSA')));
      if (locale.languageCode != 'en') {
        expect(t.identityPasswordStoredInfo, isNot(en.identityPasswordStoredInfo));
        expect(t.settingsInlineUnknownHostKeysAskDesc, isNot(en.settingsInlineUnknownHostKeysAskDesc));
      }
    });
  }

  // (The page lists what shortcutActionsOffered gives: Speech to text only
  // where something listens, 4.0.)
  test('Settings counts the shortcuts the page lists', () {
    final source = File('lib/ui/screens/desktop/widgets/settings_inline_view.dart').readAsStringSync();
    final calls = callsIn(source, RegExp(r'settingsLinkShortcutsHelp\('));
    expect(calls, isNotEmpty);
    for (final c in calls) {
      expect(c.args.trim(), 'shortcutActionsOffered(voice: ref.watch(voiceInputSupportedProvider)).length',
          reason: 'line ${c.line}');
    }
    expect(ShortcutAction.values.length, greaterThan(20));
  });
}
