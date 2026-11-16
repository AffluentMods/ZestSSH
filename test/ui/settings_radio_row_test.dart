import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';

/// A Settings pick-one list (showSettingsChoice, every row a SettingsRadioRow)
/// is picked by its row: a tap anywhere on the row, the dot included, or Enter
/// or Space on it; the up and down arrows move between rows and pick nothing.
/// A tap on the dot of the choice already picked did nothing and the dialog
/// stayed open; with a dot focused, an arrow key picked the next choice and
/// closed the dialog (Language: Tab then Down switched the language) (a UI
/// review found both).
void main() {
  const choices = [('a', 'Alpha'), ('b', 'Bravo'), ('c', 'Charlie')];

  /// A computer's Settings dialog with [current] picked; what it answers goes in [answers].
  Future<void> open(WidgetTester tester, List<(String,)?> answers, {String current = 'a'}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => answers.add(await showSettingsChoice<String>(context,
                  title: 'Pick one', choices: choices, current: current, keyOf: (v) => ValueKey('row-$v'))),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('row-b')), findsOneWidget);
  }

  Finder dotOf(String v) =>
      find.descendant(of: find.byKey(ValueKey('row-$v')), matching: find.byWidgetPredicate((w) => w is Radio));

  testWidgets('a tap on the dot of the choice already picked answers it and closes the dialog', (tester) async {
    final answers = <(String,)?>[];
    await open(tester, answers);
    // The dot takes no pointer of its own: the tap where it is drawn is the row's.
    await tester.tap(dotOf('a'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(answers, [('a',)]);
    expect(find.byKey(const ValueKey('row-a')), findsNothing);
  });

  testWidgets("a tap on another choice's dot picks it", (tester) async {
    final answers = <(String,)?>[];
    await open(tester, answers);
    await tester.tap(dotOf('c'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(answers, [('c',)]);
  });

  testWidgets('from the keyboard: Tab reaches a row, the arrows move and pick nothing, Enter picks', (tester) async {
    final answers = <(String,)?>[];
    await open(tester, answers);
    // Tab until a row has the focus, never a dot.
    Element? focusedRow() {
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus == null) return null;
      for (final v in ['a', 'b', 'c']) {
        final row = find.byKey(ValueKey('row-$v'));
        if (row.evaluate().isEmpty) continue;
        final rowElement = row.evaluate().single;
        var inside = false;
        focus.visitAncestorElements((e) {
          if (e == rowElement) inside = true;
          return !inside;
        });
        if (inside || focus == rowElement) return rowElement;
      }
      return null;
    }

    String? focusedValue() {
      final row = focusedRow();
      if (row == null) return null;
      return ((row.widget.key as ValueKey<String>).value).substring(4);
    }

    for (var i = 0; i < 12 && focusedValue() == null; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    final first = focusedValue();
    expect(first, isNotNull, reason: 'Tab reaches a row');

    // Down moves to the next row and picks nothing: the dialog stays open.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(answers, isEmpty, reason: 'an arrow key picks nothing');
    expect(find.byKey(const ValueKey('row-b')), findsOneWidget, reason: 'the dialog stays open');
    final second = focusedValue();
    expect(second, isNot(first), reason: 'the arrow moved to another row');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(answers, isEmpty);
    expect(focusedValue(), first);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(answers, [(second!,)]);
  });

  testWidgets('to a screen reader a row is one choice: its words, checked or not, in a group of one pick',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester, <(String,)?>[], current: 'b');
    expect(tester.getSemantics(dotOf('b')),
        isSemantics(label: 'Bravo', isChecked: true, isInMutuallyExclusiveGroup: true, hasTapAction: true));
    expect(tester.getSemantics(dotOf('a')),
        isSemantics(label: 'Alpha', isChecked: false, isInMutuallyExclusiveGroup: true, hasTapAction: true));
    semantics.dispose();
  });
}
