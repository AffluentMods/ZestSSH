import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Two questions of the desktop shell (3.0: plain dialogs made
/// the app's own): closing the window while sessions are connected, and a
/// connection that nothing encrypts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// A page with one button that asks [question]; the answer is in [answer]
  /// once it was given.
  late bool? answer;
  Future<void> ask(WidgetTester tester, Future<bool> Function(BuildContext context) question) async {
    answer = null;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await question(context),
            child: const Text('ask'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
  }

  Finder inDialog(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

  testWidgets('closing with sessions connected: how many end, in the dialog of the app; Close is a yes, Cancel a no, '
      'and so is leaving the question', (tester) async {
    await ask(tester, (context) => confirmCloseWithSessions(context, 3));
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inDialog(l10n.desktopCloseZestssh), findsOneWidget);
    expect(inDialog(l10n.desktopActiveSessionsWillDisconnect(3)), findsOneWidget);
    await tester.tap(inDialog(l10n.close));
    await tester.pumpAndSettle();
    expect(answer, isTrue);

    await ask(tester, (context) => confirmCloseWithSessions(context, 1));
    expect(inDialog(l10n.desktopActiveSessionsWillDisconnect(1)), findsOneWidget);
    await tester.tap(inDialog(l10n.cancel));
    await tester.pumpAndSettle();
    expect(answer, isFalse);

    await ask(tester, (context) => confirmCloseWithSessions(context, 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(answer, isFalse, reason: 'a question that was left is no yes');
  });

  testWidgets('a connection that nothing encrypts: the warning in the dialog of the app; Connect Anyway is a yes, '
      'Cancel a no', (tester) async {
    await ask(tester, confirmUnencryptedConnection);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inDialog(l10n.desktopShellUnencryptedConnection), findsOneWidget);
    expect(inDialog(l10n.desktopShellTelnetWarning), findsOneWidget);
    await tester.tap(inDialog(l10n.desktopShellConnectAnyway));
    await tester.pumpAndSettle();
    expect(answer, isTrue);

    await ask(tester, confirmUnencryptedConnection);
    await tester.tap(inDialog(l10n.cancel));
    await tester.pumpAndSettle();
    expect(answer, isFalse);

    // A warning that was left is no leave to connect.
    await ask(tester, confirmUnencryptedConnection);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(answer, isFalse);
  });

  test('the sentence about the sessions says one session or several, in every language, and never "session(s)"', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final one = l.desktopActiveSessionsWillDisconnect(1);
      final many = l.desktopActiveSessionsWillDisconnect(4);
      for (final said in [one, many]) {
        // The count in brackets is how Russian writes the whole sentence; a
        // bracket after a letter is the "(s)" of a sentence that will not say.
        expect(RegExp(r'\p{L}\(', unicode: true).hasMatch(said), isFalse, reason: '$locale: $said');
      }
      expect(one, contains('1'), reason: '$locale');
      expect(many, contains('4'), reason: '$locale');
    }
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.desktopActiveSessionsWillDisconnect(1), '1 active session will be disconnected.');
    expect(en.desktopActiveSessionsWillDisconnect(4), '4 active sessions will be disconnected.');
    final de = lookupAppLocalizations(const Locale('de'));
    expect(de.desktopActiveSessionsWillDisconnect(1), '1 aktive Sitzung wird getrennt.');
    expect(de.desktopActiveSessionsWillDisconnect(2), '2 aktive Sitzungen werden getrennt.');
    // Six languages have a sentence for one and one for several.
    for (final code in ['en', 'de', 'es', 'fr', 'it', 'pt']) {
      final l = lookupAppLocalizations(Locale(code));
      expect(l.desktopActiveSessionsWillDisconnect(1).replaceAll('1', '4'), isNot(l.desktopActiveSessionsWillDisconnect(4)),
          reason: code);
    }
  });

  test('the shell asks both through these, and goes on only after a yes', () {
    final shell = File('lib/ui/screens/desktop/desktop_shell.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(shell, contains('if (!await confirmCloseWithSessions(context, activeCount)) return false;'));
    expect(shell, contains("if (item.connection.protocol == 'telnet') {\n      if (!await confirmUnencryptedConnection(context)) return;"));
  });
}
