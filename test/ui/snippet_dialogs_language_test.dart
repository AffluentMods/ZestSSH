import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_variable_dialog.dart';

/// The snippet editor and the variable dialog speak the app's language
/// (3.0): they were written in English only.
void main() {
  final de = lookupAppLocalizations(const Locale('de'));

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        builder: (context, child) {
          L10nGlobal.update(AppLocalizations.of(context)!);
          return child!;
        },
        home: home,
      );

  testWidgets('the editor, in German', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: app(const Scaffold(body: SnippetEditor(initialCommand: r'docker logs ${CONTAINER}'))),
    ));
    await tester.pump();
    expect(find.text(de.snippetEditDisplayName), findsOneWidget);
    expect(find.text(de.snippetsCommand), findsOneWidget);
    expect(find.text(de.snippetsCategory), findsOneWidget);
    expect(find.text(de.snippetEditConfirmBeforeRun), findsOneWidget);
    for (final english in ['Display name', 'Category', 'Command', 'Confirm before run', 'Cancel', 'Create']) {
      expect(find.text(english), findsNothing, reason: '"$english" is shown in German');
    }
  });

  testWidgets('the variable dialog, in German', (tester) async {
    await tester.pumpWidget(app(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => showVariableInputDialog(
            context: context,
            variables: const [],
            snippetLabel: 'Logs',
            command: r'ssh ${USER}@$[alpha,beta]',
          ),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(de.snippetVarStep(1, 2)), findsOneWidget);
    expect(find.text(de.snippetVarEnterValueFor('USER')), findsOneWidget);
    expect(find.text(de.next), findsOneWidget);
    for (final english in ['Step 1 of 2', 'Enter value for USER', 'Next', 'Cancel']) {
      expect(find.text(english), findsNothing, reason: '"$english" is shown in German');
    }
  });
}
