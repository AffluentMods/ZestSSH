// A phone's selection bar (Copy, Share, Snippet) speaks the person's language
// (found by a scan of lib/ for English written into the
// screens): its three buttons were English in every language, and a screen
// reader heard each as "Copy button button", the word written in its name
// and the role said again.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_selection_toolbar.dart';

void main() {
  testWidgets("the selection bar's buttons in the person's language, each named once as what it does",
      (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    final names = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: Scaffold(
        body: Center(
          child: TerminalSelectionToolbar(
            selectedText: 'uptime',
            onCopy: () {},
            onSaveAsSnippet: () {},
            onDismiss: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    for (final word in [de.copy, de.homeShare, de.autoWizSnippet]) {
      expect(find.text(word), findsOneWidget, reason: word);
      expect(find.bySemanticsLabel(word), findsOneWidget, reason: '$word, as a screen reader hears it');
    }
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Share'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('button')), findsNothing);
    names.dispose();
  });
}
