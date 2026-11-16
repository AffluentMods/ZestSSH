import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The shell's choice and its work under way (the dialog rules of 3.4):
/// a choice was a Material SimpleDialog, and work under way an AlertDialog
/// with a spinner, neither of which kept the rules.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<BuildContext> host(WidgetTester tester, {bool phone = false}) async {
    tester.view.physicalSize = phone ? const Size(390, 844) : const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(builder: (ctx) {
        context = ctx;
        return const Scaffold();
      }),
    ));
    return context;
  }

  group('a choice', () {
    for (final phone in [false, true]) {
      testWidgets('is the shell: rows with dot radios, the one in use picked, a tap chooses and closes, Cancel in the footer '
          '(${phone ? "a phone's sheet" : "a computer"})', (tester) async {
        if (phone) debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final context = await host(tester, phone: phone);
          String? chosen = 'unset';
          showZestChoice<String>(context,
              title: 'Pause sync',
              subtitle: 'How long for',
              selected: 'day',
              choices: const [
                ZestChoice(value: 'hour', label: 'For 1 hour', key: ValueKey('c-hour')),
                ZestChoice(value: 'day', label: 'For 1 day', key: ValueKey('c-day')),
              ]).then((v) => chosen = v);
          await tester.pumpAndSettle();
          expect(find.byType(ZestDialogShell), findsOneWidget);
          expect(find.byType(SimpleDialog), findsNothing);
          expect(find.byKey(const ValueKey('zest-dialog-secondary')), findsOneWidget);
          expect(find.byKey(const ValueKey('zest-dialog-primary')), findsNothing, reason: 'a row chooses: no main button');
          // A dot radio for one of a few,
          // the one in use picked; no tick.
          final day = find.descendant(of: find.byKey(const ValueKey('c-day')), matching: find.byType(Radio<String>));
          final hour = find.descendant(of: find.byKey(const ValueKey('c-hour')), matching: find.byType(Radio<String>));
          expect(day, findsOneWidget);
          expect(tester.getSemantics(day), isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true));
          expect(tester.getSemantics(hour), isSemantics(isChecked: false));
          expect(find.byIcon(LucideIcons.check), findsNothing);
          await tester.tap(find.byKey(const ValueKey('c-hour')));
          await tester.pumpAndSettle();
          expect(chosen, 'hour');
          expect(find.byType(ZestDialogShell), findsNothing);

          showZestChoice<String>(context,
              title: 'Pause sync', choices: const [ZestChoice(value: 'hour', label: 'For 1 hour')]).then((v) => chosen = v);
          await tester.pumpAndSettle();
          await tester.tap(find.text(l10n.cancel));
          await tester.pumpAndSettle();
          expect(chosen, isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  group('work under way', () {
    testWidgets('shows what is being done, is not closed by Escape, says it as it changes, and its closer closes it '
        'once', (tester) async {
      final context = await host(tester);
      final words = ValueNotifier('Deleting 3 hosts');
      addTearDown(words.dispose);
      final close = showZestBusy(context, label: words.value, updates: words);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('zest-busy')), findsOneWidget);
      expect(find.text('Deleting 3 hosts'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('zest-busy')), findsOneWidget, reason: 'Escape leaves it');

      words.value = 'Deleting 2 hosts';
      await tester.pump();
      expect(find.text('Deleting 2 hosts'), findsOneWidget);

      close();
      close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('zest-busy')), findsNothing);
      expect(find.byType(Scaffold), findsOneWidget, reason: 'the page under it stays');
    });

    testWidgets('closes the dialog it opened, not one opened over it since; a cancel button does what it says',
        (tester) async {
      final context = await host(tester);
      var cancelled = false;
      final close = showZestBusy(context, label: 'Scanning', cancel: (label: 'Stop', onPressed: () => cancelled = true));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('zest-busy-cancel')));
      expect(cancelled, isTrue);
      expect(find.byKey(const ValueKey('zest-busy')), findsOneWidget, reason: 'stopping the work does not close it');

      ZestConfirmDialog.show(context, tone: ZestDialogTone.neutral, title: 'Over it', body: '', confirmLabel: 'Go');
      await tester.pump(const Duration(milliseconds: 400));
      close();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('zest-busy')), findsNothing);
      expect(find.text('Over it'), findsOneWidget, reason: 'the dialog over it stays');
    });
  });
}
