import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_close_button.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';

// With the app's strings, as every screen of the app has them: the question about
// unsaved changes is the app's own dialog, whose close button is named by them.
Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(body: child),
    );

ZestButton? _saveButton(WidgetTester tester) {
  final saves = tester
      .widgetList<ZestButton>(find.byType(ZestButton))
      .where((b) => b.label == 'Save');
  return saves.isEmpty ? null : saves.single;
}

void main() {
  group('ZestDetailScaffold', () {
    testWidgets('Save is disabled when not dirty, enabled when dirty',
        (tester) async {
      await tester.pumpWidget(_host(const ZestDetailScaffold(
        title: 'Detail',
        isDirty: false,
        body: SizedBox(height: 40),
      )));
      // onPressed wired to `isDirty ? onSave : null` - null == disabled.
      expect(_saveButton(tester)!.onPressed, isNull);

      await tester.pumpWidget(_host(ZestDetailScaffold(
        title: 'Detail',
        isDirty: true,
        onSave: () {},
        body: const SizedBox(height: 40),
      )));
      expect(_saveButton(tester)!.onPressed, isNotNull);
    });

    testWidgets('the close X calls onClose', (tester) async {
      var closed = 0;
      await tester.pumpWidget(_host(ZestDetailScaffold(
        title: 'Detail',
        onClose: () => closed++,
        body: const SizedBox(height: 40),
      )));
      await tester.tap(find.byType(ZestCloseButton));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('footer renders footerLeading and Save, and no Cancel (the X closes)', (tester) async {
      await tester.pumpWidget(_host(const ZestDetailScaffold(
        title: 'Detail',
        body: SizedBox(height: 40),
        footerLeading: Text('RUN'),
      )));
      expect(find.text('RUN'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Save'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    });

    testWidgets('shows the dirty dot and title when dirty', (tester) async {
      await tester.pumpWidget(_host(const ZestDetailScaffold(
        title: 'My Editor',
        isDirty: true,
        body: SizedBox(height: 40),
      )));
      expect(find.text('My Editor'), findsOneWidget);
      // The dirty dot carries the unsaved tooltip.
      expect(find.byType(Tooltip), findsWidgets);
    });
  });

  group('showZestDiscardDialog', () {
    Future<DiscardChoice> open(
      WidgetTester tester,
      String tapLabel, {
      bool dismiss = false,
    }) async {
      late DiscardChoice result;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        return TextButton(
          onPressed: () async => result = await showZestDiscardDialog(context),
          child: const Text('open'),
        );
      })));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      if (dismiss) {
        // Tap the barrier outside the dialog.
        await tester.tapAt(const Offset(5, 5));
      } else {
        await tester.tap(find.text(tapLabel));
      }
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('returns save for the Save action', (tester) async {
      expect(await open(tester, 'Save'), DiscardChoice.save);
    });

    testWidgets('returns discard for the Discard action', (tester) async {
      expect(await open(tester, 'Discard'), DiscardChoice.discard);
    });

    testWidgets('returns cancel for the Cancel action', (tester) async {
      expect(await open(tester, 'Cancel'), DiscardChoice.cancel);
    });

    testWidgets('it is the dialog of the app, with its three choices and no plain dialog', (tester) async {
      await tester.pumpWidget(_host(Builder(builder: (context) {
        return TextButton(onPressed: () => showZestDiscardDialog(context), child: const Text('open'));
      })));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      final l10n = lookupAppLocalizations(const Locale('en'));
      for (final words in [l10n.zestDiscardTitle, l10n.zestDiscardBody, l10n.zestDiscardSave, l10n.zestDiscardDiscard, l10n.zestDiscardCancel]) {
        expect(find.text(words), findsOneWidget, reason: words);
      }
      // Escape is a way of leaving the question: nothing is saved and nothing thrown away.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsNothing);
    });

    testWidgets('returns cancel when dismissed', (tester) async {
      expect(
        await open(tester, '', dismiss: true),
        DiscardChoice.cancel,
      );
    });
  });
}
