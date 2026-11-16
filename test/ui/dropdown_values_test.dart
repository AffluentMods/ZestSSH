import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/dropdown_values.dart';

import '../helpers/dart_calls.dart';
import '../helpers/words_cut.dart';

/// A dropdown's value in its field (3.0). Flutter draws the
/// value a dropdown shows in a field a line tall (a dense one, as every
/// DropdownButtonFormField is, or one whose items have a height), and a value
/// that took two lines there lost its second, cut at its top and bottom: in
/// Russian, the host editor's "Use global default" at the size the app is
/// drawn at, and key generation's "Ed25519 (Recommended)" from 1.3 times the
/// text size. Every dropdown of the app is given dropdownValues as its
/// selectedItemBuilder: its value on one line in such a field, ending in an
/// ellipsis, and whole in a field that grows with it. A plain dropdown whose
/// field does not use its items' height (a dense one) or shows no underline
/// gives them none, so the choices of its open menu are as tall as their
/// lines. A hint (the words before anything is chosen) in a field a line
/// tall stands on one line too, ending in an ellipsis: Flutter draws it in a
/// style of its own, which dropdownValues does not reach.
///
/// Since a design review the app draws no Material
/// dropdown at all: its selects are ZestSelect (lib/ui/widgets/zest_select.dart),
/// drawn as its fields are and its menu under the field; a dropdown's filled
/// triangle among the app's icons, and its menu over the field, matched
/// nothing else. The first test finds one brought back. dropdownValues is
/// kept, with its own tests below.
void main() {
  const long = 'Use the global default for every host';
  const typeArgs = r'\s*(<[^>(]*(?:<[^>]*>)?[^>(]*>)?\s*\(';
  final plain = RegExp(r'\bDropdownButton' + typeArgs);
  final formField = RegExp(r'\bDropdownButtonFormField' + typeArgs);
  // Material 3's own.
  final menu = RegExp(r'\bDropdownMenu' + typeArgs);

  /// "file:line" of each Material dropdown made in [files].
  List<String> dropdownsIn(Map<String, String> files) => [
        for (final MapEntry(key: path, value: text) in files.entries)
          for (final call in [...callsIn(text, plain), ...callsIn(text, formField), ...callsIn(text, menu)])
            '$path:${call.line}',
      ]..sort();

  test("the app draws no Material dropdown: its selects are the app's own", () {
    final files = {
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && !file.path.replaceAll('\\', '/').contains('/generated/'))
          file.path.replaceAll('\\', '/'): file.readAsStringSync(),
    };
    expect(files.length, greaterThan(500), reason: "the app's files are read");
    expect(dropdownsIn(files), isEmpty, reason: 'ZestSelect (lib/ui/widgets/zest_select.dart) in its place');
  });

  test('the check finds them where they are written, past comments and strings', () {
    expect(
      dropdownsIn({
        'a.dart': "DropdownButton<int>(\n  // it's the value\n  items: [],\n)",
        'b.dart': 'x\nDropdownButtonFormField<String?>(selectedItemBuilder: (c) => [], items: [])',
        'c.dart': 'DropdownButtonHideUnderline(\n  child: DropdownButton<Map<String, int>>(items: []),\n)',
        'd.dart': 'final m = DropdownMenu<int>(dropdownMenuEntries: [DropdownMenuEntry(value: 1, label: x)]);',
        'e.dart': 'DropdownButton (items: [])',
      }),
      ['a.dart:1', 'b.dart:2', 'c.dart:2', 'd.dart:1', 'e.dart:1'],
    );
    expect(
      dropdownsIn({
        'f.dart': "// DropdownButton<int>(items: [])\nfinal s = 'DropdownButton(items: [])';",
        'g.dart': '/* DropdownMenu<int>() */ ZestSelect<int>(value: 1, items: [], onChanged: null)',
        'h.dart': 'final t = DropdownMenuThemeData(); final i = DropdownMenuItem(value: 1, child: x);',
      }),
      isEmpty,
    );
  });

  Future<void> pump(WidgetTester tester, Widget field, {double scale = 1}) async {
    await tester.pumpWidget(MaterialApp(
      // Over the whole app, its menus too.
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(body: Center(child: SizedBox(width: 200, child: field))),
    ));
  }

  List<DropdownMenuItem<int>> items(String first) => [
        DropdownMenuItem(value: 1, child: Text(first)),
        const DropdownMenuItem(value: 2, child: Text('Off')),
      ];

  RenderParagraph paragraph(WidgetTester tester, String text, {bool last = false}) {
    final found = find.text(text);
    return tester.renderObject<RenderParagraph>(last ? found.last : found.first);
  }

  Widget field({DropdownButtonBuilder? shown, int value = 1}) => DropdownButtonFormField<int>(
        isExpanded: true,
        initialValue: value,
        selectedItemBuilder: shown,
        items: items(long),
        onChanged: (_) {},
      );

  testWidgets('a field a line tall shows a value longer than it on one line, ending in an ellipsis, as tall as one '
      'that fits; its open menu shows the choice whole', (tester) async {
    await pump(tester, field());
    expect(cutTopAndBottom(paragraph(tester, long)), isNotNull, reason: "Flutter's own field cuts the second line");

    await pump(tester, field(shown: dropdownValues, value: 2));
    final oneLine = tester.getSize(find.byType(DropdownButtonFormField<int>));
    await pump(tester, field(shown: dropdownValues));
    final shown = paragraph(tester, long);
    expect(shown.maxLines, 1);
    expect(shown.overflow, TextOverflow.ellipsis);
    expect(shown.didExceedMaxLines, isTrue);
    expect(cutTopAndBottom(shown), isNull);
    expect(tester.getSize(find.byType(DropdownButtonFormField<int>)), oneLine);

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(find.text(long), findsNWidgets(2), reason: 'in the field and in the menu');
    final inMenu = paragraph(tester, long, last: true);
    expect(inMenu.maxLines, isNull);
    expect(inMenu.size.height, greaterThan(shown.size.height * 1.5), reason: 'on more than one line');
    expect(cutTopAndBottom(inMenu), isNull);
  });

  testWidgets('a dropdown not dense whose items have a height (its underline 8 above its foot) shows the value on one '
      'line, and stands where it stood', (tester) async {
    Widget button(DropdownButtonBuilder? shown, String first) => DropdownButton<int>(
          isExpanded: true,
          value: 1,
          selectedItemBuilder: shown,
          items: items(first),
          onChanged: (_) {},
        );
    final underline = find.descendant(of: find.byType(DropdownButton<int>), matching: find.byType(Positioned));
    await pump(tester, button(null, 'Off and on'));
    final before = tester.getRect(find.byType(DropdownButton<int>));
    final underlineBefore = tester.getRect(underline);
    await pump(tester, button(dropdownValues, long));
    expect(tester.getRect(find.byType(DropdownButton<int>)), before);
    expect(tester.getRect(underline), underlineBefore);
    final shown = paragraph(tester, long);
    expect(shown.maxLines, 1);
    expect(shown.didExceedMaxLines, isTrue);
    expect(cutTopAndBottom(shown), isNull);
  });

  testWidgets('a field that grows with its value (not dense, its items given no height) shows it whole', (tester) async {
    await pump(
      tester,
      DropdownButton<int>(
        isExpanded: true,
        itemHeight: null,
        underline: const SizedBox(),
        value: 1,
        selectedItemBuilder: dropdownValues,
        items: items(long),
        onChanged: (_) {},
      ),
    );
    final shown = paragraph(tester, long);
    expect(shown.maxLines, isNull);
    expect(shown.didExceedMaxLines, isFalse);
    expect(cutTopAndBottom(shown), isNull);
    expect(tester.getSize(find.byType(DropdownButton<int>)).height, greaterThan(kMinInteractiveDimension));
  });

  testWidgets('a value that fits is drawn as it was, in a field of a form and in a plain one', (tester) async {
    for (final make in <Widget Function(DropdownButtonBuilder?)>[
      (shown) => DropdownButtonFormField<int>(
          isExpanded: true, initialValue: 2, selectedItemBuilder: shown, items: items(long), onChanged: (_) {}),
      (shown) => DropdownButton<int>(value: 2, selectedItemBuilder: shown, items: items('One'), onChanged: (_) {}),
      (shown) => DropdownButton<int>(
          isDense: true, value: 2, selectedItemBuilder: shown, items: items('One'), onChanged: (_) {}),
    ]) {
      await pump(tester, make(null));
      final before = tester.getRect(find.text('Off'));
      await pump(tester, make(dropdownValues));
      expect(tester.getRect(find.text('Off')), before);
    }
  });

  testWidgets('the open menu of a dense plain dropdown whose items are given no height shows a choice of two lines '
      'whole, at twice the text size', (tester) async {
    for (final (height, whole) in [(kMinInteractiveDimension, false), (null, true)]) {
      await pump(
        tester,
        DropdownButton<int>(
          isExpanded: true,
          isDense: true,
          itemHeight: height,
          value: 2,
          selectedItemBuilder: dropdownValues,
          items: items(long),
          onChanged: (_) {},
        ),
        scale: 2,
      );
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      final inMenu = paragraph(tester, long, last: true);
      expect(cutTopAndBottom(inMenu) == null, whole, reason: 'items ${height ?? 'given no height'}');
      await tester.tap(find.text('Off').last, warnIfMissed: false);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a hint longer than a field a line tall stands on one line, ending in an ellipsis', (tester) async {
    Widget hinted(Text hint) => DropdownButtonFormField<int>(
          isExpanded: true,
          hint: hint,
          selectedItemBuilder: dropdownValues,
          items: items('One'),
          onChanged: (_) {},
        );
    await pump(tester, hinted(const Text(long)));
    expect(cutTopAndBottom(paragraph(tester, long)), isNotNull, reason: "Flutter's own hint takes its lines");
    await pump(tester, hinted(const Text(long, maxLines: 1, overflow: TextOverflow.ellipsis)));
    final shown = paragraph(tester, long);
    expect(shown.didExceedMaxLines, isTrue);
    expect(cutTopAndBottom(shown), isNull);
  });

  testWidgets('it is asked by the dropdown, and says so where anything else asks', (tester) async {
    Object? error;
    await tester.pumpWidget(Builder(builder: (context) {
      try {
        dropdownValues(context);
      } catch (e) {
        error = e;
      }
      return const SizedBox();
    }));
    expect(error, isA<FlutterError>());
    expect('$error', contains('selectedItemBuilder'));
  });
}
