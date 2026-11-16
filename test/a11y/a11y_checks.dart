import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;

import '../helpers/painted_contrast.dart';

/// Lets a screen's loads finish (its database, its providers) without
/// waiting on what never settles (a spinner, a clock).
Future<void> settleA11y(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A pointer's least target on a computer (the 4.0 accessibility pass): 32
/// square. A phone's or a tablet's is Android's 48 ([androidTapTargetGuideline]).
const mouseTapTargetGuideline = MinimumTapTargetGuideline(
  size: Size(32, 32),
  link: 'ZestSSH 4.0 accessibility brief: 32 dp minimum with a mouse',
);

/// The screen on show held to the 4.0 accessibility pass's checks: every
/// control a screen reader can press has a name ([labeledTapTargetGuideline]),
/// a pointer's target is 32 square on a computer and 48 on a phone or a
/// tablet, and every text reads at 4.5:1 and every icon at 3:1 on what is
/// painted behind it, worked out from the colours the widgets paint with
/// (painted_contrast.dart; Flutter's textContrastGuideline reads pixels,
/// which at small sizes measures the edges of letters). [except] names words
/// drawn turned off (WCAG asks nothing of those). Every check runs, and all
/// that fail are told together, each with [where].
Future<void> expectA11y(WidgetTester tester,
    {required bool computer, required String where, bool contrast = true, Set<String> except = const {}}) async {
  expect(await a11yCheck(tester, computer: computer, contrast: contrast, except: except), isEmpty, reason: where);
}

/// What [expectA11y] finds wrong, each told by itself.
Future<List<String>> a11yCheck(WidgetTester tester,
    {required bool computer, bool contrast = true, Set<String> except = const {}, String where = ''}) async {
  final failures = a11yFailures(tester, computer: computer, contrast: contrast, except: except);
  // A phone's or a tablet's screen checked at a finger's 48 is drawn touch
  // sized: a theme without ZestDensity(touch: true), on a computer running
  // the tests, draws a mouse's sizes, and the check would hold a screen
  // the app never shows a finger.
  if (!computer) {
    final scaffold = find.byType(Scaffold);
    if (scaffold.evaluate().isNotEmpty && !touchSizedAt(tester.element(scaffold.first))) {
      failures.add("drawn at a mouse's sizes: a phone's or a tablet's guard draws it touch sized "
          '(debugTouchLayout = true before the theme is made, or a theme with ZestDensity(touch: true))');
    }
  }
  final guidelines = <AccessibilityGuideline>[
    labeledTapTargetGuideline,
    computer ? mouseTapTargetGuideline : androidTapTargetGuideline,
  ];
  for (final g in guidelines) {
    final result = await g.evaluate(tester);
    if (!result.passed) {
      for (final line in result.reason!.split('\n')) {
        if (line.trim().isEmpty || line.startsWith('See also')) continue;
        // Selectable words (a read-only field that is long pressed to copy
        // from) are words, not a control.
        if (line.contains('isReadOnly')) continue;
        failures.add(line.replaceAll(RegExp(r'SemanticsNode#\d+'), 'node'));
      }
    }
  }
  return [for (final f in failures) where.isEmpty ? f : '$where: $f'];
}

/// The words and icons on screen that do not read on what is behind them.
List<String> a11yFailures(WidgetTester tester, {required bool computer, bool contrast = true, Set<String> except = const {}}) {
  final failures = <String>[];
  if (!contrast) return failures;
  final scaffold = find.byType(Scaffold);
  final page = scaffold.evaluate().isEmpty
      ? const Color(0xFF000000)
      : Theme.of(tester.element(scaffold.first)).scaffoldBackgroundColor;
  // A field's placeholder (its hint) is held to 3:1, the pass's rule for
  // placeholders.
  final hints = {
    for (final d in tester.widgetList<InputDecorator>(find.byType(InputDecorator)))
      if (d.decoration.hintText != null) d.decoration.hintText!,
  };
  // Words drawn faded under something that takes no pointer (a sample
  // behind a locked page, a turned-off control) are decoration or turned
  // off: WCAG asks nothing of them.
  final inactive = <String>{};
  for (final e in find.byType(RichText).evaluate()) {
    var faded = false, ignored = false;
    e.visitAncestorElements((a) {
      final w = a.widget;
      if (w is Opacity && w.opacity < 1) faded = true;
      if (w is IgnorePointer && w.ignoring) ignored = true;
      return true;
    });
    if (!faded || !ignored) continue;
    final words = (e.widget as RichText).text.toPlainText();
    inactive.add(words);
    if (words.runes.length == 1) inactive.add('icon U+${words.runes.first.toRadixString(16).toUpperCase()}');
  }
  for (final t in paintedTexts(tester, fallbackGround: page)) {
    if (except.contains(t.text) || inactive.contains(t.text)) continue;
    if (hints.contains(t.text) && t.ratio >= 3) continue;
    // An icon or a spinner at 3:1; the words in a field that are not typed
    // (its placeholder) at 3:1 (the pass's rule for placeholders); words at
    // 4.5:1.
    final least = t.text.startsWith('icon ') || t.text == 'spinner' || t.groundBy == 'InputDecorator' ? 3.0 : 4.5;
    if (t.ratio < least) failures.add('under $least: $t');
  }
  return failures;
}
