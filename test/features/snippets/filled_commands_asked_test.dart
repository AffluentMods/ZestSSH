import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/snippet_providers.dart' show kMaskedValueShown;
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../../helpers/monitor_table_fixture.dart';

/// What a person is asked before a filled command runs: the check reads past the
/// quotes a value goes in (`rm -rf '/'` passed for harmless with the plain check),
/// and a value typed with dots is not read out in the next question.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  late AppDatabase db;

  Future<void> pump(WidgetTester tester, Widget Function(BuildContext context) child, {List<(String, String, bool)> snippets = const []}) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    await tester.runAsync(() async {
      final at = DateTime(2026);
      for (final (label, command, confirm) in snippets) {
        await db.into(db.snippets).insert(SnippetsCompanion.insert(
            id: label, label: label, command: command, confirmBeforeRun: Value(confirm), createdAt: at, updatedAt: at));
      }
    });
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(fleet.overrides(db, prefs), Builder(builder: child)));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  bool onScreen(WidgetTester tester, String what) => tester
      .widgetList<Text>(find.byType(Text))
      .any((t) => (t.data ?? t.textSpan?.toPlainText() ?? '').contains(what));

  group('a paste', () {
    Future<void> pasted(WidgetTester tester, String text, void Function() check) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final terminal = Terminal();
      await pump(tester, (context) => Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => unawaited(pasteClipboardIntoTerminal(context, ref, terminal)),
              child: const Text('paste'),
            ),
          ));
      await tester.tap(find.text('paste'));
      await settle(tester);
      check();
      await finish(tester);
    }

    testWidgets('of a command with its dangerous part in quotes is asked about', (tester) async {
      await pasted(tester, "rm -rf '/'", () => expect(find.text(en.dangerPasteTitle), findsOneWidget));
    });

    testWidgets('of a harmless one is not', (tester) async {
      await pasted(tester, 'uptime', () => expect(find.text(en.dangerPasteTitle), findsNothing));
    });
  });

  group("a phone's list inside a session", () {
    Future<List<(String, String, List<String>)>> tapSnippet(WidgetTester tester, String label, {String? typed}) async {
      final executed = <(String, String, List<String>)>[];
      await pump(
        tester,
        (_) => Scaffold(body: SnippetsScreen(onExecute: (command, shown, secrets) => executed.add((command, shown, secrets)))),
        snippets: [
          ('Wipe', r'rm -rf ${DIR}', true),
          ('Login', r'login ${PW:secret}', true),
        ],
      );
      await tester.tap(find.text(label).first);
      await settle(tester);
      if (typed != null) {
        await tester.enterText(find.byType(TextFormField), typed);
        await settle(tester);
        await tester.tap(find.text(en.snippetVarPaste));
        await settle(tester);
      }
      return executed;
    }

    Future<void> onPhone(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets("a value that makes it risky: the session's check will ask, so the snippet's own does not", (tester) async {
      await onPhone(() async {
        final executed = await tapSnippet(tester, 'Wipe', typed: '/');
        expect(find.text(en.snippetRunConfirmTitle), findsNothing);
        expect(executed.single.$1, "rm -rf '/'");
        await finish(tester);
      });
    });

    testWidgets('a value typed with dots: not in the question of a snippet that asks, and the real one runs', (tester) async {
      await onPhone(() async {
        final executed = await tapSnippet(tester, 'Login', typed: 'hunter22');
        expect(find.text(en.snippetRunConfirmTitle), findsOneWidget);
        expect(onScreen(tester, 'hunter22'), isFalse);
        expect(onScreen(tester, kMaskedValueShown), isTrue);
        await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
        await settle(tester);
        expect(executed.single.$1, "login 'hunter22'");
        expect(executed.single.$2, "login '$kMaskedValueShown'");
        expect(executed.single.$3, ['hunter22'], reason: 'for what asks before a broadcast, and for history');
        await finish(tester);
      });
    });
  });

  group('commandReadyToRun', () {
    Future<void> ready(
      WidgetTester tester,
      String command,
      Future<void> Function(({String command, List<String> secrets, String shown})? Function() got) check, {
      bool confirmFirst = false,
      String typed = "hunter'22",
    }) async {
      ({String command, List<String> secrets, String shown})? result;
      await pump(tester, (context) => Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async {
                result = await commandReadyToRun(context, ref, command: command, confirmFirst: confirmFirst, doneLabel: 'Go');
              },
              child: const Text('ready'),
            ),
          ));
      await tester.tap(find.text('ready'));
      await settle(tester);
      await tester.enterText(find.byType(TextFormField), typed);
      await settle(tester);
      expect(onScreen(tester, 'hunter'), isFalse, reason: 'its preview');
      await tester.tap(find.text('Go'));
      await settle(tester);
      await check(() => result);
      await finish(tester);
    }

    testWidgets('a risky command with a value typed with dots: masked in the question, real in what runs', (tester) async {
      await ready(tester, r'sudo reboot ${PW:secret}', (got) async {
        expect(find.text(en.dangerCommandTitle), findsOneWidget);
        expect(onScreen(tester, 'hunter'), isFalse);
        expect(onScreen(tester, kMaskedValueShown), isTrue);
        await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
        await settle(tester);
        expect(got()!.command, r"sudo reboot 'hunter'\''22'");
        expect(got()!.secrets, ["hunter'22"]);
        expect(got()!.shown, "sudo reboot '$kMaskedValueShown'");
      });
    });

    testWidgets('what only the value makes risky: the red question, and the value nowhere in it, in the sentence or the preview',
        (tester) async {
      await ready(tester, r'rm -rf ${DIR:secret}', typed: '/etc/hunter22', (got) async {
        expect(find.text(en.dangerCommandTitle), findsOneWidget);
        expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.destructive);
        expect(find.byKey(const ValueKey('danger-dont-ask-again')), findsOneWidget);
        expect(find.text(en.dangerCriticalDelete), findsOneWidget);
        expect(find.text(en.dangerExplainCriticalDelete("rm -rf '$kMaskedValueShown'").replaceAll('`', ''), findRichText: true), findsOneWidget);
        expect(onScreen(tester, 'hunter'), isFalse);
        expect(onScreen(tester, '/etc'), isFalse);
        await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
        await settle(tester);
        expect(got()!.command, "rm -rf '/etc/hunter22'");
      });
    });

    testWidgets('what only reading past the quotes finds in a value: no sentence quotes it', (tester) async {
      await ready(tester, r're${X:secret}', typed: 'boot', (got) async {
        expect(find.text(en.dangerReboot), findsOneWidget);
        expect(find.text(en.dangerExplainReboot("re'$kMaskedValueShown'").replaceAll('`', ''), findRichText: true), findsOneWidget);
        expect(onScreen(tester, 'reboot'), isFalse);
        await tester.tap(find.text(en.cancel));
        await settle(tester);
        expect(got(), isNull);
      });
    });

    testWidgets('what would draw it wrongly shows by its number, and the value is dots beside it', (tester) async {
      await ready(tester, 'sudo\u202e reboot \${PW:secret}', typed: 'hunter\u202e22', (got) async {
        expect(find.text(en.dangerCommandTitle), findsOneWidget);
        final preview = tester.widget<Text>(find.byKey(const ValueKey('danger-preview'))).textSpan!.toPlainText();
        expect(preview, r'sudo\u202e reboot ' "'$kMaskedValueShown'");
        expect(onScreen(tester, 'hunter'), isFalse);
        expect(onScreen(tester, '\u202e'), isFalse, reason: 'no real one is drawn');
        await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
        await settle(tester);
        expect(got()!.command, "sudo\u202e reboot 'hunter\u202e22'", reason: 'what runs is what it is');
      });
    });

    testWidgets("a snippet's own question, the same", (tester) async {
      await ready(tester, r'login ${PW:secret}', confirmFirst: true, (got) async {
        expect(find.text(en.snippetRunConfirmTitle), findsOneWidget);
        expect(onScreen(tester, 'hunter'), isFalse);
        expect(onScreen(tester, kMaskedValueShown), isTrue);
        await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
        await settle(tester);
        expect(got()!.command, r"login 'hunter'\''22'");
      });
    });
  });

  group('a run on hosts', () {
    test('its head shows what it was given to show: a value is not as typed once it is written for its place', () {
      expect(
        const HostsRun(command: r"login 'it'\''s'", secrets: ["it's"], shown: "login '$kMaskedValueShown'", hosts: []).commandShown,
        "login '$kMaskedValueShown'",
      );
      expect(const HostsRun(command: 'login -phunter22', secrets: ['hunter22'], hosts: []).commandShown, 'login -p$kMaskedValueShown');
    });
  });
}
