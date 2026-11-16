// The master password of the sync vault, chosen anew, is typed twice and held
// to the rules it is set up under (as every new
// password that locks data away is typed twice):
// changing it asked for the new one in one field, with no length or
// strength asked, so a slip in it made a vault that only the recovery key
// could open. Setting up sync, a restore with the recovery key and a change of
// the password now take it from one dialog.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/profile/master_password_dialog.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<Future<String?>> open(WidgetTester tester, {String? title}) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Future<String?> asked;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => asked = showNewMasterPasswordDialog(context, title: title),
          child: const Text('choose'),
        ),
      ),
    ));
    await tester.tap(find.text('choose'));
    await tester.pumpAndSettle();
    return asked;
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> type(WidgetTester tester, String password, String again) async {
    await tester.enterText(field(en.profileMasterPasswordLabel), password);
    await tester.enterText(field(en.profileConfirmPasswordLabel), again);
    await tester.tap(find.text(en.profileContinue));
    await tester.pumpAndSettle();
  }

  testWidgets('two that differ are said, and nothing is taken; then the same twice is', (tester) async {
    final asked = await open(tester, title: en.profileEnterNewPassword);
    expect(find.text(en.profileEnterNewPassword), findsOneWidget, reason: 'a change says so');
    await type(tester, 'Correct-Horse-Battery-9', 'Correct-Horse-Battery-8');
    expect(find.text(en.profilePasswordsDoNotMatch), findsOneWidget);
    await type(tester, 'Correct-Horse-Battery-9', 'Correct-Horse-Battery-9');
    expect(await asked, 'Correct-Horse-Battery-9');
  });

  testWidgets('one too short, or too weak, is said, and nothing is taken; Cancel takes nothing', (tester) async {
    final asked = await open(tester);
    expect(find.text(en.profileChooseMasterPassword), findsOneWidget, reason: 'setting up says so');
    await type(tester, 'Short-1', 'Short-1');
    expect(find.text(en.profilePasswordTooShort), findsOneWidget);
    await type(tester, 'aaaaaaaaaaaaaaaa', 'aaaaaaaaaaaaaaaa');
    expect(find.text(en.profilePasswordTooWeak), findsOneWidget);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(await asked, isNull);
  });

  test('a password is scored for its strength as before', () {
    expect(masterPasswordStrength(''), 0);
    expect(masterPasswordStrength('aaaaaaaaaaaaaaaa'), 0);
    expect(masterPasswordStrength('Correct-Horse-Battery-9'), 4);
  });

  test('setting up sync, a restore with the recovery key and a change of the password ask through it', () {
    final profile = File('lib/ui/screens/profile/profile_screen.dart').readAsStringSync();
    expect(RegExp(r'showNewMasterPasswordDialog\(context, account: _syncAccountAddress\)').allMatches(profile).length, 2,
        reason: 'setup, restore');
    expect(profile, contains('showNewMasterPasswordDialog(context, title: l10n.profileEnterNewPassword, account: _syncAccountAddress)'),
        reason: 'the change');
  });
}
