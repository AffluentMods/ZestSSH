import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/profile/account_question.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The question the account page asks before signing out, before deleting
/// what is on this device and before deleting the account (3.0:
/// a plain dialog made the app's own).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// A page with one button that asks; [answer] is what came back, and
  /// [answered] says that something did.
  late bool? answer;
  late bool answered;
  Future<void> ask(WidgetTester tester, {required bool destructive}) async {
    answer = null;
    answered = false;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await askAccountQuestion(
                context,
                title: destructive ? l10n.accountDeleteLocal : l10n.profileSignOut,
                message: destructive ? l10n.accountDeleteLocalHelp : l10n.profileSignOutConfirmMsg,
                destructive: destructive,
              );
              answered = true;
            },
            child: const Text('ask'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
  }

  Finder inDialog(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

  testWidgets('signing out: the dialog of the app, with Continue; Continue is a yes, Cancel a no, and a question that was '
      'left is no yes', (tester) async {
    await ask(tester, destructive: false);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inDialog(l10n.profileSignOut), findsOneWidget);
    expect(inDialog(l10n.profileSignOutConfirmMsg), findsOneWidget);
    expect(inDialog(l10n.delete), findsNothing, reason: 'nothing is deleted by signing out');
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.neutral);
    await tester.tap(inDialog(l10n.profileContinue));
    await tester.pumpAndSettle();
    expect(answer, isTrue);

    await ask(tester, destructive: false);
    await tester.tap(inDialog(l10n.cancel));
    await tester.pumpAndSettle();
    expect(answered, isTrue);
    expect(answer, isFalse);

    await ask(tester, destructive: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(answered, isTrue);
    expect(answer, isNot(true));
  });

  testWidgets('deleting: the tone of what cannot be taken back, and Delete on the button; only Delete is a yes',
      (tester) async {
    await ask(tester, destructive: true);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(inDialog(l10n.accountDeleteLocal), findsOneWidget);
    expect(inDialog(l10n.accountDeleteLocalHelp), findsOneWidget);
    expect(inDialog(l10n.profileContinue), findsNothing);
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.destructive);
    await tester.tap(inDialog(l10n.cancel));
    await tester.pumpAndSettle();
    expect(answer, isFalse);

    await ask(tester, destructive: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(answer, isNot(true));

    await ask(tester, destructive: true);
    await tester.tap(inDialog(l10n.delete));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  test('the account page asks its three questions through this, and acts only on a yes', () {
    final page = File('lib/ui/screens/profile/profile_screen.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(page, contains('askAccountQuestion(context, title: title, message: message, destructive: isDestructive)'));
    // Deleting what is on this device, deleting the account, signing out.
    expect(
      page,
      contains('final ok = await _confirmAction(\n      l10n.accountDeleteLocal,\n      l10n.accountDeleteLocalHelp,\n'
          '      isDestructive: true,\n    );\n    if (ok != true || !mounted) return;'),
    );
    expect(
      page,
      contains('final ok = await _confirmAction(\n        l10n.profileDeleteAccount,\n'
          '        l10n.profileDeleteAccountConfirmMsg,\n        isDestructive: true,\n      );\n      return ok == true;'),
    );
    expect(
      page,
      contains('final confirmed = await _confirmAction(\n      l10n.profileSignOut,\n      [\n'),
    );
    expect(
      page,
      contains('if (hosted) l10n.profileSignOutConfirmMsg else if (!profiles.on) l10n.profileSignOutConfirmNotHosted,\n'
          "      ].join('\\n\\n'),\n    );\n"
          '    if (confirmed != true) return;'),
    );
  });
}
