// ZestTextField (found in a code review): it draws one box, its
// own, in every state (the theme's outlines drew a second inside it), its
// box shows the keyboard's focus, and a field of several lines takes Enter
// as a new line, never as a submit, where one line still submits.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

Widget _app(Widget home) => MaterialApp(
      theme: BuiltInThemes.getById('graphite').toThemeData(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

InputDecoration _decorationOf(WidgetTester tester) =>
    tester.widget<InputDecorator>(find.descendant(of: find.byType(ZestTextField), matching: find.byType(InputDecorator))).decoration;

void main() {
  setUp(() => AppColors.applyTheme(BuiltInThemes.getById('graphite').colorScheme));

  testWidgets('the field draws no border of its own in any state: its box is the only one', (tester) async {
    final c = TextEditingController(text: 'prod-db');
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(Scaffold(body: ZestTextField(controller: c, errorText: 'Taken'))));
    await tester.pump();
    final d = _decorationOf(tester);
    for (final b in [d.border, d.enabledBorder, d.focusedBorder, d.disabledBorder, d.errorBorder, d.focusedErrorBorder]) {
      expect(b, InputBorder.none);
    }
    expect(d.filled, isFalse);
  });

  testWidgets('its box turns the accent while typed in, and back when the keyboard leaves', (tester) async {
    final c = TextEditingController();
    final other = FocusNode();
    addTearDown(c.dispose);
    addTearDown(other.dispose);
    await tester.pumpWidget(_app(Scaffold(
      body: Column(children: [
        ZestTextField(controller: c, autofocus: false),
        Focus(focusNode: other, child: const SizedBox(height: 10)),
      ]),
    )));
    Color borderColor() {
      final box = tester.widget<Container>(find
          .descendant(of: find.byType(ZestTextField), matching: find.byType(Container))
          .first);
      // The edge is drawn over the field (its input fills the box: 4.0).
      return ((box.foregroundDecoration! as BoxDecoration).border! as Border).top.color;
    }

    expect(borderColor(), isNot(AppColors.v3AccentPrimary));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(borderColor(), AppColors.v3AccentPrimary);
    other.requestFocus();
    await tester.pump();
    expect(borderColor(), isNot(AppColors.v3AccentPrimary));
  });

  testWidgets('one line: Enter submits, as before', (tester) async {
    var submits = 0;
    final c = TextEditingController();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(Scaffold(body: ZestTextField(controller: c, onSubmit: () => submits++))));
    await tester.pump();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.textInputAction, isNot(TextInputAction.newline));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submits, 1);
  });

  testWidgets('several lines: the keyboard is a multiline one with a new-line key, and Enter does not submit',
      (tester) async {
    var submits = 0;
    var shortcut = 0;
    final c = TextEditingController(text: 'one');
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(Scaffold(
      // An Enter shortcut above the field, as a dialog's submit is.
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter): () => shortcut++},
        child: ZestTextField(
          controller: c,
          minLines: 3,
          maxLines: 6,
          // A caller's one-line keyboard does not make Enter submit here.
          keyboardType: TextInputType.text,
          onSubmit: () => submits++,
        ),
      ),
    )));
    await tester.pump();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.keyboardType, TextInputType.multiline);
    expect(field.textInputAction, TextInputAction.newline);
    expect(field.onSubmitted, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(shortcut, 0, reason: 'Enter went to the shortcut above, not to the text');
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(submits, 0);
  });

  group('in a modal with a submit', () {
    Future<List<int>> open(WidgetTester tester, Widget field) async {
      final submits = <int>[0];
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showZestModal<void>(
              context: context,
              size: ZestModalSize.compact,
              onSubmit: () => submits[0]++,
              child: Material(child: Padding(padding: const EdgeInsets.all(16), child: field)),
            ),
            child: const Text('Open'),
          ),
        ),
      )));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      return submits;
    }

    testWidgets('Enter in a ZestTextField of several lines does not submit the modal', (tester) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      final submits = await open(tester, ZestTextField(controller: c, minLines: 3, maxLines: 6));
      expect(tester.binding.focusManager.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(submits[0], 0);
    });

    testWidgets('Enter in any text field of several lines does not submit the modal either', (tester) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      final submits = await open(tester, TextField(controller: c, autofocus: true, maxLines: 4));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(submits[0], 0);
    });

    testWidgets('Enter in a one-line ZestTextField submits the modal, as before', (tester) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      final submits = await open(tester, ZestTextField(controller: c));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(submits[0], 1);
    });
  });

  testWidgets('a password field is never corrected, suggested from or learnt by the keyboard; any other field is', (tester) async {
    final c = TextEditingController();
    addTearDown(c.dispose);
    for (final (obscure, allowed) in [(true, false), (false, true)]) {
      await tester.pumpWidget(_app(Scaffold(body: ZestTextField(controller: c, obscureText: obscure))));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autocorrect, allowed, reason: 'obscure: $obscure');
      expect(field.enableSuggestions, allowed, reason: 'obscure: $obscure');
      expect(field.enableIMEPersonalizedLearning, allowed, reason: 'obscure: $obscure');
    }
  });
}
