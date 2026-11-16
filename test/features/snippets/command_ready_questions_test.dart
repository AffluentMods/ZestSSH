import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/paste_question.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// What the person is asked on the way a snippet, a run from History and Run on
/// hosts all take ([commandReadyToRun]): the two levels hold on it, what a value
/// fills in is read inside its quotes, and the command shown is what it is.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<Future<({String command, List<String> secrets, String shown})?>> ask(
    WidgetTester tester,
    String command, {
    bool confirmFirst = false,
    bool literal = false,
  }) async {
    SharedPreferences.setMockInitialValues({'dangerous_command_protection': true});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Future<({String command, List<String> secrets, String shown})?> asked;
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () {
                asked = commandReadyToRun(context, ref, command: command, confirmFirst: confirmFirst, literal: literal);
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return asked;
  }

  ZestDialogTone toneOf(WidgetTester tester) => tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone;

  testWidgets('a command only worth a look gets the quiet question, and runs on Run it', (tester) async {
    final asked = await ask(tester, "docker exec frigate sh -c 'ls /media/frigate'");
    expect(find.text(en.dangerLookTitle), findsOneWidget);
    expect(find.text(en.dangerCommandTitle), findsNothing);
    expect(toneOf(tester), ZestDialogTone.neutral);
    expect(find.byKey(const ValueKey('danger-dont-ask-again')), findsNothing);
    await tester.tap(find.text(en.dangerLookRun));
    await tester.pumpAndSettle();
    expect((await asked)?.command, "docker exec frigate sh -c 'ls /media/frigate'");
  });

  for (final command in [
    "sh -c 'rm -rf /'",
    'bash -c "rm -rf ~"',
    "docker exec web sh -c 'rm -rf /*'",
    "ssh prod sh -c 'rm -rf /etc'",
    "python -c 'import os; os.system(\"rm -rf /\")'",
    "sh -c 'mkfs -t ext4 /dev/sda'",
    'dd if=/dev/zero of=/etc/fstab',
    r'dd if=/dev/zero of=$DISK',
  ]) {
    testWidgets('$command gets the red question, and Cancel runs nothing', (tester) async {
      final asked = await ask(tester, command);
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(find.text(en.dangerLookTitle), findsNothing);
      expect(toneOf(tester), ZestDialogTone.destructive);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(await asked, isNull);
    });
  }

  testWidgets('a value filled into a shell string is read for what it does', (tester) async {
    final asked = await ask(tester, r"sh -c 'rm -rf ${DIR:-/}'");
    expect(find.text(en.dangerCommandTitle), findsOneWidget);
    expect(toneOf(tester), ZestDialogTone.destructive);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(await asked, isNull);
  });

  testWidgets('a snippet\'s own confirm shows the command as it is, cut between characters', (tester) async {
    final command = 'echo \u202e${'x' * 120}😀 tail';
    final asked = await ask(tester, command, confirmFirst: true, literal: true);
    final shown = tester
        .widgetList<Text>(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .firstWhere((t) => t.startsWith('echo'));
    expect(shown, startsWith(r'echo \u202e'));
    expect(shown, endsWith('…'));
    expect(shown.runes.where((r) => r >= 0xd800 && r <= 0xdfff), isEmpty, reason: 'half an emoji');
    expect(shown.runes, isNot(contains(0x202e)));
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    await asked;
  });

  testWidgets('the question before a paste of lines shows them on their lines, a bidi control by its number',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })),
    ));
    unawaited(showPasteQuestion(context, 'ls \u202e-la\nuptime', runs: true));
    await tester.pumpAndSettle();
    expect(find.text('ls \\u202e-la\nuptime'), findsOneWidget);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
  });
}
