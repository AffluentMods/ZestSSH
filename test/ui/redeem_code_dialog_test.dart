import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/redeem_service.dart';
import 'package:zestssh/ui/widgets/redeem_code_dialog.dart';

/// The Redeem a code dialog (3.0: pop-ups that spoke
/// English only). It was a plain dialog whose title, sentence and buttons
/// were written in English in the code. It is the app's own input dialog
/// now, in the app's language.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The dialog over a page with one button, in [locale]; what it returned is
  /// in [got] once it has closed ([closed]).
  late RedeemResult? got;
  late bool closed;
  Future<void> open(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    required Future<RedeemResult> Function(String code) redeem,
  }) async {
    got = null;
    closed = false;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              got = await showRedeemCodeDialog(context, redeem: redeem);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a code that is redeemed closes the dialog with the result; it is sent as typed, in capitals',
      (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final sent = <String>[];
    await open(tester, redeem: (code) async {
      sent.add(code);
      return const RedeemResult(ok: true, granted: ['pro'], message: 'Your license has been applied.');
    });
    expect(find.text(l10n.settingsMobRedeemCode), findsOneWidget);
    expect(find.text(l10n.redeemDialogBody), findsOneWidget);
    // The shape of a new code (three groups now), as a hint.
    expect(find.text('ZEST-XXXX-XXXX-XXXX'), findsOneWidget, reason: 'the shape of a code, as a hint');
    expect(find.text('ZEST-XXXX-XXXX'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zest-ab12-cd34');
    await tester.pump();
    await tester.tap(find.text(l10n.redeemDialogAction));
    await tester.pumpAndSettle();
    expect(sent, ['ZEST-AB12-CD34']);
    expect(closed, isTrue);
    expect(got?.ok, isTrue);
    expect(got?.granted, ['pro']);
  });

  testWidgets('a code of three groups and one of two, minted before, are both sent as typed', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final sent = <String>[];
    for (final code in ['zest-ab2c-de3f-gh45', 'zest-ab2c-de3f']) {
      await open(tester, redeem: (code) async {
        sent.add(code);
        return const RedeemResult(ok: true, granted: ['pro'], message: 'Your license has been applied.');
      });
      await tester.enterText(find.byType(TextField), code);
      await tester.pump();
      await tester.tap(find.text(l10n.redeemDialogAction));
      await tester.pumpAndSettle();
      expect(closed, isTrue, reason: code);
    }
    expect(sent, ['ZEST-AB2C-DE3F-GH45', 'ZEST-AB2C-DE3F']);
  });

  testWidgets('a code that is not redeemed is said under the field, the dialog stays, and another try goes through',
      (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    var tries = 0;
    await open(tester, redeem: (code) async {
      tries++;
      return tries == 1
          ? const RedeemResult(ok: false, message: 'Could not redeem that code.')
          : const RedeemResult(ok: true, message: 'Your license has been applied.');
    });
    await tester.enterText(find.byType(TextField), 'ZEST-0000-0000');
    await tester.tap(find.text(l10n.redeemDialogAction));
    await tester.pumpAndSettle();
    expect(find.text('Could not redeem that code.'), findsOneWidget);
    expect(closed, isFalse);
    expect(find.text(l10n.settingsMobRedeemCode), findsOneWidget);

    await tester.tap(find.text(l10n.redeemDialogAction));
    await tester.pumpAndSettle();
    expect(tries, 2);
    expect(closed, isTrue);
    expect(got?.ok, isTrue);
  });

  testWidgets('nothing typed is said without asking the service; Cancel returns nothing; while a code is being '
      'redeemed the dialog says so and cannot be sent twice', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    var asked = 0;
    final answer = Completer<RedeemResult>();
    await open(tester, redeem: (code) {
      asked++;
      return answer.future;
    });
    await tester.tap(find.text(l10n.redeemDialogAction));
    await tester.pumpAndSettle();
    expect(asked, 0);
    expect(find.text(l10n.redeemSvcEnterCode), findsOneWidget);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text(l10n.redeemDialogAction));
    await tester.pumpAndSettle();
    expect(asked, 0, reason: 'spaces are no code');

    await tester.enterText(find.byType(TextField), 'ZEST-AAAA-BBBB');
    await tester.tap(find.text(l10n.redeemDialogAction));
    await tester.pump();
    expect(asked, 1);
    expect(find.text(l10n.redeemDialogBusy), findsOneWidget);
    await tester.tap(find.text(l10n.redeemDialogAction), warnIfMissed: false);
    await tester.pump();
    expect(asked, 1, reason: 'not sent twice');
    answer.complete(const RedeemResult(ok: false, message: 'Could not redeem that code.'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);

    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(got, isNull);
  });

  testWidgets('in every language the dialog speaks that language, and its words fit a phone', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      await open(tester, locale: locale, redeem: (_) async => const RedeemResult(ok: false, message: 'x'));
      expect(find.text(l10n.settingsMobRedeemCode), findsOneWidget, reason: '$locale');
      expect(find.text(l10n.redeemDialogBody), findsOneWidget, reason: '$locale');
      expect(find.text(l10n.redeemDialogAction), findsOneWidget, reason: '$locale');
      expect(find.text(l10n.cancel), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(l10n.redeemDialogBody, isNot(en.redeemDialogBody), reason: '$locale');
        expect(l10n.redeemDialogAction, isNot(en.redeemDialogAction), reason: '$locale');
        expect(l10n.redeemDialogBusy, isNot(en.redeemDialogBusy), reason: '$locale');
      }
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
    }
  });

  test('no word of the dialog is written in English in its code', () {
    // (Its comments may name them.)
    final code = File('lib/ui/widgets/redeem_code_dialog.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join(' ');
    for (final word in ['Redeem a code', 'Cancel', "'Redeem'", 'Enter a license', 'AlertDialog']) {
      expect(code, isNot(contains(word)), reason: word);
    }
  });
}
