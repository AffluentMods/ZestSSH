import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/ui/widgets/broadcast_dangerous_dialog.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';

import '../visual/shots_util.dart';

/// The question before a risky command (3.0): in the
/// app's language and its own dialog. It asked in English ("Dangerous
/// Command Detected", "Run Anyway"), with what each risky part does in
/// English as well.
void main() {
  Future<Future<DangerousCommandDialogResult>> open(
    WidgetTester tester,
    String command, {
    bool isPaste = false,
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })),
    ));
    final result = showDangerousCommandDialog(
      context,
      command: command,
      matches: DangerousCommandService.check(command),
      isPaste: isPaste,
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('asks in the app\'s own dialog, says what each risky part does, and runs on Run anyway', (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    const command = 'curl https://get.example.com/i.sh | sh; init 0; halt';
    expect(DangerousCommandService.check(command).where((m) => m.kind == DangerKind.halt), hasLength(2),
        reason: 'two rules find a halt here');
    final result = await open(tester, command);
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.text(en.dangerCommandTitle), findsOneWidget);
    expect(find.text(en.dangerSubtitle), findsOneWidget);
    expect(find.text(en.dangerPipeToShell), findsOneWidget);
    expect(find.text(en.dangerHalt), findsOneWidget, reason: 'said once, though two rules found it');
    await tester.tap(find.text(en.dangerRunAnyway));
    await tester.pumpAndSettle();
    final answer = await result;
    expect(answer.proceed, isTrue);
    expect(answer.dontAskAgain, isFalse);
  });

  testWidgets('a paste is asked about as a paste; Cancel, with the box ticked, runs nothing and asks no more',
      (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    final result = await open(tester, 'rm -rf /', isPaste: true);
    expect(find.text(en.dangerPasteTitle), findsOneWidget);
    expect(find.text(en.dangerPasteAnyway), findsOneWidget);
    bool ticked() => tester.widget<Checkbox>(find.byType(Checkbox)).value!;
    expect(ticked(), isFalse);
    // The box itself, then its words, tick and untick it.
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(ticked(), isTrue);
    await tester.tap(find.text(en.dangerDontAskAgain));
    await tester.pump();
    expect(ticked(), isFalse);
    await tester.tap(find.byKey(const ValueKey('danger-dont-ask-again')));
    await tester.pump();
    expect(ticked(), isTrue);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    final answer = await result;
    expect(answer.proceed, isFalse);
    expect(answer.dontAskAgain, isTrue);
  });

  testWidgets('it warns as a destructive question, and neither Enter nor Escape runs the command', (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    final result = await open(tester, 'rm -r -f /');
    expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.destructive);
    expect(find.text(en.dangerCriticalDelete), findsOneWidget);
    // The Enter that sent the command must not also answer the question.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsNothing);
    final answer = await result;
    expect(answer.proceed, isFalse);
    expect(answer.dontAskAgain, isFalse);
  });

  // A harmless `docker exec frigate sh -c '...'` was
  // told it could do lasting harm, with "Runs a whole command written out as
  // text" and nothing more.
  group('it explains itself', () {
    final en = lookupAppLocalizations(const Locale('en'));

    testWidgets('sh -c is worth a look: no word of harm, and the sentence says what runs', (tester) async {
      const command = "docker exec frigate sh -c 'ls /media/frigate'";
      final result = await open(tester, command, isPaste: true);
      expect(find.text(en.dangerLookTitle), findsOneWidget);
      expect(find.text(en.dangerLookSubtitle), findsOneWidget);
      expect(find.text(en.dangerPasteTitle), findsNothing);
      expect(find.text(en.dangerSubtitle), findsNothing);
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.neutral);
      expect(find.text(en.dangerShellString), findsOneWidget);
      expect(find.text(en.dangerExplainShellString('sh -c').replaceAll('`', ''), findRichText: true), findsOneWidget,
          reason: 'the part found, quoted');
      expect(find.text(en.dangerLookPaste), findsOneWidget);
      expect(find.text(en.dangerPasteAnyway), findsNothing);
      await tester.tap(find.text(en.dangerLookPaste));
      await tester.pumpAndSettle();
      expect((await result).proceed, isTrue);
    });

    testWidgets('run rather than pasted, the button says so', (tester) async {
      await open(tester, 'python3 -c "print(1)"');
      expect(find.text(en.dangerLookTitle), findsOneWidget);
      expect(find.text(en.dangerLookRun), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    testWidgets('a harmful part makes the whole question harmful, inside the quotes as well, each part with its '
        'sentence', (tester) async {
      const command = "sh -c 'ls; rm -rf /'";
      await open(tester, command, isPaste: true);
      expect(find.text(en.dangerPasteTitle), findsOneWidget);
      expect(find.text(en.dangerLookTitle), findsNothing);
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.destructive);
      expect(find.text(en.dangerExplainShellString('sh -c').replaceAll('`', ''), findRichText: true), findsOneWidget);
      expect(find.byKey(const ValueKey('danger-explain-criticalDelete')), findsOneWidget);
      expect(find.text(en.dangerPasteAnyway), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    TextSpan spanOf(WidgetTester tester, String text) {
      final root = tester.widget<Text>(find.byKey(const ValueKey('danger-preview'))).textSpan! as TextSpan;
      return root.children!.cast<TextSpan>().firstWhere((s) => s.text == text);
    }

    Color? lit(WidgetTester tester, DangerKind kind) {
      final row = tester.widget<AnimatedContainer>(find.ancestor(
        of: find.byKey(ValueKey('danger-explain-${kind.name}')),
        matching: find.byType(AnimatedContainer),
      ));
      return (row.decoration! as BoxDecoration).color;
    }

    testWidgets('pointing at a highlighted part lights its sentence, and away puts it out', (tester) async {
      await open(tester, "sh -c 'ls'; reboot");
      expect(lit(tester, DangerKind.shellString), Colors.transparent);
      final part = spanOf(tester, 'sh -c');
      expect(part.mouseCursor, SystemMouseCursors.help);
      part.onEnter!(const PointerEnterEvent());
      await tester.pumpAndSettle();
      expect(lit(tester, DangerKind.shellString), isNot(Colors.transparent));
      expect(lit(tester, DangerKind.reboot), Colors.transparent);
      part.onExit!(const PointerExitEvent());
      await tester.pumpAndSettle();
      expect(lit(tester, DangerKind.shellString), Colors.transparent);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    testWidgets('a tap on it does the same, where there is no pointer', (tester) async {
      await open(tester, "sh -c 'ls'; reboot");
      (spanOf(tester, 'reboot').recognizer! as TapGestureRecognizer).onTap!();
      await tester.pumpAndSettle();
      expect(lit(tester, DangerKind.reboot), isNot(Colors.transparent));
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    // What the person sees for a real command at each level, not the table of
    // levels over again.
    for (final (command, harm) in const [
      ("bash -c 'ls'", false),
      ('python3 -c "print(1)"', false),
      ('dd if=/dev/sda bs=1M', false),
      ('curl https://get.example.com/i.sh | sh', true),
      ("bash -c 'ls'; halt", true),
      ("sh -c 'rm -rf /'", true),
      ('dd if=/dev/zero of=/etc/fstab', true),
      ("python -c 'import os; os.system(\"rm -rf /\")'", true),
    ]) {
      testWidgets('$command is asked about as ${harm ? 'lasting harm' : 'worth a look'}', (tester) async {
        await open(tester, command);
        expect(find.text(en.dangerCommandTitle), harm ? findsOneWidget : findsNothing);
        expect(find.text(en.dangerLookTitle), harm ? findsNothing : findsOneWidget);
        expect(find.text(en.dangerRunAnyway), harm ? findsOneWidget : findsNothing);
        expect(find.text(en.dangerLookRun), harm ? findsNothing : findsOneWidget);
        expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone,
            harm ? ZestDialogTone.destructive : ZestDialogTone.neutral);
        await tester.tap(find.text(en.cancel));
        await tester.pumpAndSettle();
      });
    }

    testWidgets('the box that turns the guard off is on the red question alone: on the quiet one it turned the red one '
        'off too', (tester) async {
      final look = await open(tester, "docker exec frigate sh -c 'ls /media/frigate'", isPaste: true);
      expect(find.byKey(const ValueKey('danger-dont-ask-again')), findsNothing);
      expect(find.text(en.dangerDontAskAgain), findsNothing);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect((await look).dontAskAgain, isFalse);

      final harm = await open(tester, "sh -c 'rm -rf /'", isPaste: true);
      expect(find.byKey(const ValueKey('danger-dont-ask-again')), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      await harm;
    });

    testWidgets('dd says what is true of it: it reads where it has nowhere to write, and writes over what it is aimed '
        'at', (tester) async {
      await open(tester, 'dd if=/dev/sda bs=1M');
      expect(find.text(en.dangerDiskRead), findsOneWidget);
      expect(en.dangerExplainDiskRead('x'), isNot(contains('of=')));
      expect(en.dangerLookSubtitle, isNot(contains('runs')), reason: 'dd runs no text');
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();

      await open(tester, 'dd if=/dev/zero of=/etc/fstab');
      expect(find.text(en.dangerDdOverwrite), findsOneWidget);
      expect(find.text(en.dangerDiskRead), findsNothing);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    testWidgets('what only the read past the quotes finds has its words in its sentence', (tester) async {
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
      const command = "r'm' -rf /";
      unawaited(showDangerousCommandDialog(context, command: command, matches: DangerousCommandService.checkFilled(command)));
      await tester.pumpAndSettle();
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(find.text(en.dangerExplainCriticalDelete('rm -rf /').replaceAll('`', ''), findRichText: true), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    Future<void> openAsked(WidgetTester tester, List<CommandAsked> commands, {int hosts = 2}) async {
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
      unawaited(showWorkflowDangerDialog(context, commands: commands, hosts: hosts));
      await tester.pumpAndSettle();
    }

    Future<void> openWorkflow(WidgetTester tester, List<String> commands, {int hosts = 2}) =>
        openAsked(tester, [for (final c in commands) (runs: c, shown: c)], hosts: hosts);

    testWidgets('before a workflow: only worth a look, it says so for all of them, and has no box', (tester) async {
      await openWorkflow(tester, const ["sh -c 'ls'", 'python3 -c "print(1)"']);
      expect(find.text(en.dangerLookTitleMany), findsOneWidget);
      expect(find.text(en.dangerLookSubtitle), findsOneWidget);
      expect(find.text(en.wfDangerCommandsTitle), findsNothing);
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.neutral);
      expect(find.byKey(const ValueKey('danger-dont-ask-again')), findsNothing);
      expect(find.byKey(const ValueKey('danger-explain-shellString')), findsOneWidget);
      expect(find.byKey(const ValueKey('danger-explain-interpreterOneLiner')), findsOneWidget);
      expect(find.byKey(const ValueKey('danger-preview')), findsNWidgets(2));
      expect(find.text(en.dangerLookRun), findsOneWidget);
      expect(find.byKey(const ValueKey('danger-on-hosts')), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();

      await openWorkflow(tester, const ["sh -c 'ls'"]);
      expect(find.text(en.dangerLookTitle), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    testWidgets('before a workflow: one that does harm, in quotes or filled in, makes it the red question, every part '
        'with its sentence quoting its own command', (tester) async {
      await openWorkflow(tester, const ["sh -c 'ls'", "sh -c 'rm -rf /'", "r'e'boot"]);
      expect(find.text(en.wfDangerCommandsTitle), findsOneWidget);
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.destructive);
      expect(find.text(en.dangerRunAnyway), findsOneWidget);
      expect(find.byKey(const ValueKey('danger-dont-ask-again')), findsOneWidget);
      expect(find.text(en.dangerExplainCriticalDelete('rm -rf /').replaceAll('`', ''), findRichText: true), findsOneWidget);
      expect(find.text(en.dangerExplainReboot('reboot').replaceAll('`', ''), findRichText: true), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    testWidgets('before a workflow: a value typed with dots that alone makes it red is asked in red, and stays dots, '
        'in the preview and in the sentence that quotes it', (tester) async {
      const dots = '••••••';
      await openAsked(tester, const [
        (runs: "rm -rf '/etc/hunter22'", shown: "rm -rf '$dots'"),
        (runs: "sudo reboot 'hunter22'", shown: "sudo reboot\u202e '$dots'"),
      ]);
      expect(find.text(en.wfDangerCommandsTitle), findsOneWidget);
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.destructive);
      expect(find.byKey(const ValueKey('danger-dont-ask-again')), findsOneWidget);
      expect(find.text(en.dangerExplainCriticalDelete("rm -rf '$dots'").replaceAll('`', ''), findRichText: true), findsOneWidget);
      expect(find.text(en.dangerExplainReboot('reboot').replaceAll('`', ''), findRichText: true), findsOneWidget);
      final previews = [
        for (final t in tester.widgetList<Text>(find.byKey(const ValueKey('danger-preview')))) t.textSpan!.toPlainText(),
      ];
      expect(previews, ["rm -rf '$dots'", "sudo reboot\\u202e '$dots'"], reason: 'what would draw it wrongly by its number');
      final drawn = [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
      ].join('\n');
      expect(drawn, isNot(contains('hunter')));
      expect(drawn, isNot(contains('/etc')));
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    // Text with no space in it is laid out letter by letter: a megabyte stood the
    // window still for 17 seconds, and every text that long is asked about now.
    testWidgets('a text as long as a clipboard can be draws what fits, cut, in the time of a frame or so', (tester) async {
      final command = 'a' * (1 << 20);
      final matches = DangerousCommandService.checkFilled(command);
      expect(matches.map((m) => m.kind), [DangerKind.tooLong]);
      final clock = Stopwatch()..start();
      final result = await open(tester, command);
      expect(clock.elapsedMilliseconds, lessThan(5000));
      final shown = tester.widget<Text>(find.byKey(const ValueKey('danger-preview'))).textSpan!.toPlainText();
      expect(shown, hasLength(kMaxCommandShown + 1));
      expect(shown, endsWith('…'));
      expect(find.text(en.dangerTooLong), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect((await result).proceed, isFalse);
    });

    testWidgets('a bidi control or a C1 control in the command shows in the preview, the highlight in its place',
        (tester) async {
      const command = 'echo \u202eevil\u202c\u0085 \u200b; reboot';
      await open(tester, command);
      final root = tester.widget<Text>(find.byKey(const ValueKey('danger-preview'))).textSpan! as TextSpan;
      final shown = root.children!.cast<TextSpan>().map((s) => s.text).join();
      expect(shown, r'echo \u202eevil\u202c\u0085 \u200b; reboot');
      expect(root.children!.cast<TextSpan>().last.text, 'reboot', reason: 'the highlight follows the original offsets');
      expect(shown.runes.where((r) => r == 0x202e || r == 0x202c || r == 0x85 || r == 0x200b), isEmpty);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
    });

    test('every kind has a sentence of its own in every language, with the part quoted in it', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        final said = [for (final kind in DangerKind.values) kind.explain(t, 'the part')];
        for (final s in said) {
          expect(s, contains('`the part`'), reason: '$locale: $s');
        }
        expect(said.toSet(), hasLength(DangerKind.values.length), reason: '$locale: two kinds said alike');
      }
    });

    test('what is quoted is short, on one line, and has nothing unprintable in it', () {
      final long = 'rm -rf ${'x' * 200} /';
      final quoted = DangerousCommandService.check(long).first.quotedIn(long);
      expect(quoted.length, DangerousCommandMatch.kMaxQuoted);
      expect(quoted, endsWith('…'));
      const smuggled = 'sh\t-c\n\x1b[31mls';
      expect(const DangerousCommandMatch('', DangerKind.shellString, start: 0, end: 11).quotedIn(smuggled), 'sh -c [31m');
      expect(const DangerousCommandMatch('', DangerKind.shellString).quotedIn('sh -c'), '');
    });
  });

  testWidgets('in another language, every word of it is that language\'s', (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    final result = await open(tester, 'mkfs.ext4 /dev/sdb1', locale: const Locale('de'));
    expect(find.text(de.dangerCommandTitle), findsOneWidget);
    expect(find.text(de.dangerFormatDisk), findsOneWidget);
    expect(find.text(de.dangerDontAskAgain), findsOneWidget);
    expect(find.textContaining('Dangerous'), findsNothing);
    await tester.tap(find.text(de.cancel));
    await tester.pumpAndSettle();
    expect((await result).proceed, isFalse);
  });

  testWidgets('before a broadcast, what each risky part does is said in the app\'s language, once, beside every host',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fr'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })),
    ));
    const command = 'init 0; halt; reboot';
    final result = showBroadcastDangerousDialog(
      context,
      command: command,
      matches: DangerousCommandService.check(command),
      targetHostNames: const ['web-01', 'web-02'],
    );
    await tester.pumpAndSettle();
    final fr = lookupAppLocalizations(const Locale('fr'));
    expect(find.text(fr.dangerHalt), findsOneWidget, reason: 'said once, though two rules found it');
    expect(find.text(fr.dangerReboot), findsOneWidget);
    expect(find.text('web-01'), findsOneWidget);
    expect(find.text('web-02'), findsOneWidget);
    await tester.tap(find.text(fr.broadcastDangerousCancel));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  group('before a broadcast', () {
    final en = lookupAppLocalizations(const Locale('en'));
    Future<Future<bool>> ask(WidgetTester tester, String command) async {
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
      final result = showBroadcastDangerousDialog(
        context,
        command: command,
        matches: DangerousCommandService.checkFilled(command),
        targetHostNames: const ['web-01', 'web-02'],
      );
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('what does harm, in quotes as well, is called destructive', (tester) async {
      final result = await ask(tester, "sh -c 'rm -rf /'");
      expect(find.text(en.broadcastDangerousTitle), findsOneWidget);
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.destructive);
      await tester.tap(find.text(en.broadcastDangerousCancel));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    testWidgets('what is only worth a look is asked about too, and not called destructive', (tester) async {
      final result = await ask(tester, "sh -c 'ls'");
      expect(find.text(en.broadcastLookTitle), findsOneWidget);
      expect(find.text(en.broadcastDangerousTitle), findsNothing);
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.neutral);
      expect(find.text(en.dangerShellString), findsOneWidget);
      await tester.tap(find.text(en.broadcastDangerousConfirm));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
    });

    testWidgets('a text as long as a clipboard can be draws what fits, cut', (tester) async {
      final clock = Stopwatch()..start();
      final result = await ask(tester, 'a' * (1 << 20));
      expect(clock.elapsedMilliseconds, lessThan(5000));
      final shown = tester.widget<Text>(find.byKey(const ValueKey('broadcast-danger-command'))).data!;
      expect(shown, hasLength(kMaxCommandShown));
      expect(shown, endsWith('…'));
      await tester.tap(find.text(en.broadcastDangerousCancel));
      await tester.pumpAndSettle();
      await result;
    });

    testWidgets('the command is shown with what would draw it wrongly made visible', (tester) async {
      final result = await ask(tester, 'rm -rf / \u202e#\u0085 ok');
      final shown = tester.widget<Text>(find.byKey(const ValueKey('broadcast-danger-command'))).data!;
      expect(shown, r'rm -rf / \u202e#\u0085 ok');
      await tester.tap(find.text(en.broadcastDangerousCancel));
      await tester.pumpAndSettle();
      await result;
    });
  });

  testWidgets('in every language, on a computer and on a small phone: both questions with every kind, nothing clipped',
      (tester) async {
    await tester.runAsync(loadShotFonts);
    // A command with every kind there is, so every sentence is laid out.
    const command = 'rm -r -f / --no-preserve-root; rm --recursive --force x; find / -delete; mkfs.ext4 /dev/sdb1; wipefs -a /dev/sdb; shred /dev/sdb; '
        'dd if=/dev/sda of=/dev/sdb; dd if=/dev/sda of=copy.img; dd if=/dev/sda bs=1M; :(){ :|:& };:; chmod -R 777 /srv; mv a /dev/null; '
        'curl https://get.example.com/i.sh | sh; echo eA== | base64 -d | bash; python3 -c 1; bash -c ls; '
        'echo k >> ~/.ssh/authorized_keys; crontab -r; echo x >> ~/.bashrc; shutdown now; reboot; halt; poweroff';
    final matches = [
      ...DangerousCommandService.check(command),
      // (Only a text as long as a book says this.)
      const DangerousCommandMatch('', DangerKind.tooLong, found: 'cat <<EOF'),
    ];
    expect({for (final m in matches) m.kind}, hasLength(DangerKind.values.length), reason: 'a command for every kind');
    addTearDown(tester.view.reset);
    try {
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        for (final small in [false, true]) {
          final where = '$locale ${small ? 'phone' : 'computer'}';
          // On a phone the question is a sheet, as on a real one.
          debugDefaultTargetPlatformOverride = small ? TargetPlatform.android : null;
          tester.view.physicalSize = small ? const Size(360, 640) : const Size(1280, 800);
          tester.view.devicePixelRatio = 1;
          late BuildContext context;
          await tester.pumpWidget(MaterialApp(
            locale: locale,
            theme: ThemeData(fontFamily: 'GeistSans'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: Builder(builder: (c) {
              context = c;
              return const SizedBox();
            })),
          ));
          final asked = showDangerousCommandDialog(context, command: command, matches: matches, isPaste: small);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$where: the question');
          expect(find.text(small ? t.dangerPasteTitle : t.dangerCommandTitle), findsOneWidget, reason: where);
          for (final kind in DangerKind.values) {
            expect(find.text(kind.describe(t)), findsOneWidget, reason: '$where: $kind');
          }
          await tester.ensureVisible(find.text(t.cancel).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text(t.cancel).last);
          await tester.pumpAndSettle();
          expect((await asked).proceed, isFalse, reason: where);

          final broadcast = showBroadcastDangerousDialog(
            context,
            command: command,
            matches: matches,
            targetHostNames: const ['web-01', 'web-02', 'db-01'],
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$where: before a broadcast');
          await tester.ensureVisible(find.text(t.broadcastDangerousCancel));
          await tester.pumpAndSettle();
          await tester.tap(find.text(t.broadcastDangerousCancel));
          await tester.pumpAndSettle();
          expect(await broadcast, isFalse, reason: where);
        }
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
