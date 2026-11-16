import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/profile/recovery_kit.dart';

/// The recovery kit (3.0): the key on one page with which
/// account it is for, when it was made, what it does, how to use it (steps
/// that match the app), where to keep it and how to check or replace it;
/// as text, and as a PDF whose page the app draws itself, so it reads right
/// in every language (the PDF library's own fonts cover Latin letters only).

const key = 'ZEST-ABCD-EFGH-JKMN-PQRS-TUVW';
final made = DateTime(2026, 9, 25, 10, 30);

void main() {
  setUpAll(initializeDateFormatting);

  RecoveryKitText kit(String locale, {String? account = 'owner@example.com'}) =>
      RecoveryKitText.of(lookupAppLocalizations(Locale(locale)), key: key, account: account, made: made);

  test('the text kit names the account, the date, the key, and how to use it in order', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final text = recoveryKitPlainText(kit('en'));
    expect(text, startsWith(l10n.recoveryKitTitle));
    expect(text, contains('${l10n.recoveryKitAccount}: owner@example.com'));
    expect(text, contains('${l10n.recoveryKitMade}: September 25, 2026'));
    expect(text, contains('    $key'));
    final one = text.indexOf('1. ${l10n.recoveryKitStep1Account('owner@example.com')}');
    final two = text.indexOf('2. ${l10n.recoveryKitStep2}');
    final three = text.indexOf('3. ${l10n.recoveryKitStep3}');
    expect(one, greaterThan(0));
    expect(two, greaterThan(one));
    expect(three, greaterThan(two));
    for (final part in [l10n.recoveryKitWhat, l10n.recoveryKitKeep, l10n.recoveryKitCheck, l10n.recoveryKitFooter]) {
      expect(text, contains(part));
    }
    // The steps name what the app shows on the way back in (every language:
    // test/l10n/recovery_kit_steps_test.dart).
    expect(l10n.recoveryKitStep1Storage, contains(l10n.accountSyncSetUp));
    expect(l10n.recoveryKitStep2, contains(l10n.profileForgotUseRecovery));
  });

  test('with no account (the person\'s own storage), it says how to reach the same storage instead', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final t = kit('en', account: null);
    expect(t.steps.first, l10n.recoveryKitStep1Storage);
    // No "Account:" line (the steps name the Account page).
    expect(recoveryKitPlainText(t), isNot(contains('${l10n.recoveryKitAccount}:')));
  });

  test('every language has its own words and the dates of its own calendar; Arabic reads right to left', () {
    final seen = <String>{};
    for (final locale in AppLocalizations.supportedLocales) {
      final t = kit(locale.languageCode);
      expect(seen.add(t.what), isTrue, reason: '${locale.languageCode} has its own words');
      expect(t.key, key, reason: 'the key is the key in every language');
      expect(t.rtl, locale.languageCode == 'ar');
    }
    expect(kit('de').made, '25. September 2026');
  });

  testWidgets('the page draws the key once, left to right, and fits the page in every language', (tester) async {
    tester.view.physicalSize = kRecoveryKitPageSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final locale in AppLocalizations.supportedLocales.map((l) => l.languageCode)) {
      await tester.pumpWidget(Center(child: RecoveryKitPage(text: kit(locale))));
      final keyText = tester.widget<Text>(find.byKey(const ValueKey('recovery-kit-key')));
      expect(keyText.data, key);
      expect(
        Directionality.of(tester.element(find.byKey(const ValueKey('recovery-kit-key')))),
        TextDirection.ltr,
        reason: locale,
      );
      expect(find.text(kit(locale).title), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$locale fits the page');
    }
  });

  testWidgets('the PDF is one A4 page the app drew, in Latin, Arabic and Japanese alike', (tester) async {
    for (final locale in ['en', 'ar', 'ja']) {
      late Uint8List pdf;
      late Uint8List png;
      await tester.runAsync(() async {
        png = await renderOffscreenPng(RecoveryKitPage(text: kit(locale)), size: kRecoveryKitPageSize, pixelRatio: 1.5);
        pdf = await recoveryKitPdf(kit(locale), title: 'Kit', compress: false);
      });
      // A PNG of the whole page at that size.
      expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final bytes = ByteData.sublistView(png);
      expect(bytes.getUint32(16), (kRecoveryKitPageSize.width * 1.5).round(), reason: 'width');
      expect(bytes.getUint32(20), (kRecoveryKitPageSize.height * 1.5).round(), reason: 'height');
      // A PDF of one page holding it as a picture.
      final head = latin1.decode(pdf.sublist(0, 8));
      expect(head, startsWith('%PDF-'));
      final body = latin1.decode(pdf);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(body).length, 1, reason: locale);
      expect(RegExp(r'/Subtype\s*/Image').hasMatch(body), isTrue, reason: 'the page is a picture');
      expect(pdf.length, greaterThan(20000), reason: 'a real page, not an empty one');
    }
  });
}
