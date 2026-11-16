import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/profile/email_auth_screen.dart' show kMinAccountPasswordLength;

/// Words the 3.0 docs check found untrue, each held to
/// what the app does: a scheduled task needs a tap when ZestSSH is not on
/// screen (Android starts no window from the background); a purchase on the
/// website is refunded by email within 30 days (the Terms, section 7), never
/// with a click in the app; an export names alerts, as their page is called
/// in each language; where a leaked API key is revoked and where Sign out
/// everywhere is, on a phone and on a computer, in the words of those pages;
/// the person joining with too many codes is told so in their own words; the
/// app's English is American; a font is named as its makers name it; and a
/// new account's password length is said before it is typed.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final locales = AppLocalizations.supportedLocales;

  test('a scheduled task: it runs by itself while ZestSSH is open, and otherwise asks for a tap', () {
    final s = en.schedTaskBackgroundBanner;
    expect(s, isNot(contains('closed')));
    expect(s, allOf(contains('open'), contains('notification'), contains('tap')));
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      if (locale.languageCode != 'en') expect(t.schedTaskBackgroundBanner, isNot(en.schedTaskBackgroundBanner));
    }
  });

  test('a refund is asked for by email, as the Terms say, and never with a click in the app', () {
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      for (final s in [t.deskUpgAddonFootbarText, t.deskUpgTrust30DayRefundDetail]) {
        expect(s, contains('support@zestssh.com'), reason: '$locale: $s');
      }
    }
    for (final s in [en.deskUpgAddonFootbarText, en.deskUpgTrust30DayRefundDetail]) {
      expect(s, isNot(anyOf(contains('click'), contains('in-app'))));
    }
    // The website's Terms, which the words follow (ZestSSH-Website,
    // src/routes/terms): refunds within 30 days, by email to support.
    expect(en.deskUpgTrust30DayRefund, '30-day refund');
  });

  test('everything that syncs names alerts, as the Alerts page is called', () {
    expect(en.accountExportDescAll, isNot(contains('trigger')));
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.accountExportDescAll.toLowerCase(), contains(t.trgTitle.toLowerCase()), reason: '$locale');
    }
  });

  test('a leaked API key: revoked under Automation, API keys on a computer, deleted in Settings on a phone', () {
    expect(en.autoWizCredentialWarning, contains('under Automation, API keys'));
    expect(en.autoWizCredentialWarning, isNot(contains('Settings')));
    expect(en.autoWizCredentialWarningPhone, contains('in Settings, Automation, API keys'));
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.autoWizCredentialWarning, contains(t.zestAutoSectionApiKeys), reason: '$locale');
      expect(t.autoWizCredentialWarning, contains(t.desktopShellAutomation), reason: '$locale');
      expect(t.autoWizCredentialWarning, isNot(contains(t.settingsTitle)), reason: '$locale');
      expect(t.autoWizCredentialWarningPhone, contains(t.settingsTitle), reason: '$locale');
      expect(t.autoWizCredentialWarningPhone, contains(t.settingsMobAutomation), reason: '$locale');
      expect(t.autoWizCredentialWarningPhone, contains(t.settingsMobApiKeys), reason: '$locale');
    }
  });

  // 4.0: a computer's page is Account too (it was Account and security).
  test('Sign out everywhere: in Settings, Account, on a phone and on a computer', () {
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      for (final s in [t.syncDeviceRoomEmpty, t.syncDeviceRoomEmptyPhone]) {
        expect(s, contains(t.devicesSignOutEverywhere), reason: '$locale: $s');
        expect(s, contains(t.settingsTitle), reason: '$locale: $s');
      }
      expect(t.syncDeviceRoomEmpty, contains(t.settingsAccount), reason: '$locale');
      expect(t.syncDeviceRoomEmptyPhone, contains(t.settingsAccount), reason: '$locale');
    }
  });

  test("too many tries with invite codes are the joiner's own words, not the inviter's", () {
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.joinCodeTooManyTries, isNot(t.orchardInviteErrorRateLimited), reason: '$locale');
    }
    expect(en.joinCodeTooManyTries, 'Too many tries with invite codes. Wait an hour, then try again.');
  });

  test("the app's English is American, Fira Code is named so, and Connect via is in sentence case", () {
    final arb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
    for (final e in arb.entries) {
      if (e.key.startsWith('@')) continue;
      final value = e.value as String;
      expect(value.toLowerCase(), isNot(contains('colour')), reason: e.key);
    }
    expect(en.settingsInlineTerminalColours, 'Terminal colors');
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.settingsMobProgrammingLigaturesDesc, allOf(contains('Fira Code'), isNot(contains('FiraCode'))),
          reason: '$locale');
    }
    expect(en.jumpHostCircle('db', 'bastion'), allOf(contains('Connect via'), isNot(contains('Connect Via'))));
    expect(en.jumpHostGateNoticeBase('db'), allOf(contains('Connect via'), isNot(contains('Connect Via'))));
  });

  test("a new account's shortest password is said before it is typed, in every language, as the check counts it",
      () {
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.emailAuthPasswordMinHint, contains('$kMinAccountPasswordLength'), reason: '$locale');
      expect(t.emailAuthPasswordTooShort, contains('$kMinAccountPasswordLength'), reason: '$locale');
    }
  });

  test('the controls that went have no words left', () {
    final arb = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
    for (final key in ['zestKeysRotate', 'accountComingSoon', 'zestAutoSectionWebhooks', 'automationWebhooksSoonMessage',
        'automationWebhooksSoonTitle']) {
      expect(arb.containsKey(key), isFalse, reason: key);
    }
  });
}
