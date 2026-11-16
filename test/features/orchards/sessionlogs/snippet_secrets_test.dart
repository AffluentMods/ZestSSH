import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_variable_dialog.dart';
import 'package:zestssh/utils/shell_fill.dart';

/// A masked snippet value (`${VAR:secret}`) typed while a session is logged
/// for its team (3.0) is left out of that log: it is handed to the
/// open logs, and the snippet's other values are not.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) {
          L10nGlobal.update(AppLocalizations.of(context)!);
          return child!;
        },
        home: home,
      );

  Future<Map<String, String>?> run(WidgetTester tester, List<String> typed, {bool cancel = false}) async {
    Map<String, String>? got;
    await tester.pumpWidget(app(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async => got = await showVariableInputDialog(
            context: context,
            variables: const [],
            snippetLabel: 'Database',
            command: r'mysql -u ${USER} -p${PW:secret}',
          ),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (var i = 0; i < typed.length; i++) {
      await tester.enterText(find.byType(TextFormField), typed[i]);
      await tester.pump();
      if (cancel && i == typed.length - 1) {
        await tester.tap(find.text(en.back));
        await tester.pumpAndSettle();
        await tester.tap(find.text(en.cancel));
      } else {
        await tester.tap(find.text(i == typed.length - 1 ? en.snippetVarPaste : en.next));
      }
      await tester.pumpAndSettle();
    }
    return got;
  }

  testWidgets('a masked value is handed to the open team log; the others are not', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    TeamSessionLogs.expect('s1');

    expect(await run(tester, ['deploy', 'hunter22']), {'USER': 'deploy', 'PW': 'hunter22'});
    expect(TeamSessionLogs.secretsKept, 1, reason: 'the masked value only');
  });

  testWidgets('and as it is written in the command: in quotes it does not stand as it was typed', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    TeamSessionLogs.expect('s1');

    const typed = r'pass$word"s';
    expect(await run(tester, ['deploy', typed]), {'USER': 'deploy', 'PW': typed});
    expect(filledForms(typed), contains(r'pass\$word\"s'));
    expect(TeamSessionLogs.secretsKept, filledForms(typed).length);
  });

  testWidgets('with no team log open, nothing is kept; a cancelled snippet keeps nothing', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);

    expect(await run(tester, ['deploy', 'hunter22']), isNotNull);
    expect(TeamSessionLogs.secretsKept, 0, reason: 'no log to keep it from');

    TeamSessionLogs.expect('s1');
    expect(await run(tester, ['deploy', 'hunter22'], cancel: true), isNull);
    expect(TeamSessionLogs.secretsKept, 0, reason: 'cancelled: nothing was used');
  });
}
