import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/button_box.dart';

import '../helpers/dart_calls.dart';
import '../helpers/words_cut.dart';

/// A button's box (3.0). Sixteen buttons of the app stood
/// in a box of a fixed height, which cut their words at their top and bottom
/// where they took two lines: key generation's "Generate key pair" in Russian
/// from 1.5 times the text size and in five more languages at twice it, and
/// the Upgrade page's buy button from 1.3 times. Each stands in a ButtonBox:
/// as tall as the box was where its words take a line, taller where they take
/// more, and its tap target the box, as it was.
void main() {
  const label = 'Generate the key pair';
  final sizedBox = RegExp(r'\bSizedBox\s*\(');
  final buttonBox = RegExp(r'\bButtonBox\s*\(');
  final button = RegExp(r'^(?:[^()?]*\?\s*)?(const\s+)?(FilledButton|ElevatedButton|OutlinedButton|TextButton)'
      r'(\.\w+)?\s*\(');

  /// "file:line" of each button in [files] in a SizedBox of a height, and of
  /// each one in a ButtonBox lower than a button's own least height (40)
  /// whose style does not give it a least height.
  List<String> fixed(Map<String, String> files) {
    final found = <String>[];
    for (final MapEntry(key: path, value: text) in files.entries) {
      for (final call in callsIn(text, sizedBox)) {
        final child = namedArg(call.args, 'child');
        if (namedArg(call.args, 'height') != null && child != null && button.hasMatch(child)) {
          found.add('$path:${call.line}');
        }
      }
      for (final call in callsIn(text, buttonBox)) {
        final height = double.tryParse(namedArg(call.args, 'height') ?? '');
        final child = namedArg(call.args, 'child') ?? '';
        if (height != null && height < 40 && !child.contains('minimumSize:')) found.add('$path:${call.line} low');
      }
    }
    return found..sort();
  }

  test("no button of the app stands in a box of a fixed height, and one in a ButtonBox lower than a button's own "
      'least height is given that height', () {
    final files = {
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && !file.path.replaceAll('\\', '/').contains('/generated/'))
          file.path.replaceAll('\\', '/'): file.readAsStringSync(),
    };
    final boxes = [for (final text in files.values) ...callsIn(text, buttonBox)];
    expect(boxes.length, greaterThanOrEqualTo(17), reason: 'the buttons that were in a box of a fixed height');
    expect(fixed(files), isEmpty);
  });

  test('the check finds them where they are written, past comments and strings', () {
    expect(
      fixed({
        'a.dart': "SizedBox(\n  // it's 48\n  height: 48,\n  child: FilledButton(onPressed: null, child: x),\n)",
        'b.dart': 'x\nSizedBox(width: 200, height: 44, child: TextButton.icon(onPressed: f, label: y))',
        'c.dart': 'SizedBox(height: 28, child: on\n    ? OutlinedButton(onPressed: f, child: a)\n    : FilledButton(child: b))',
        'd.dart': 'ButtonBox(height: 28, child: TextButton(style: TextButton.styleFrom(), child: x))',
      }),
      ['a.dart:1', 'b.dart:2', 'c.dart:1', 'd.dart:1 low'],
    );
    expect(
      fixed({
        'e.dart': 'SizedBox(height: 48, child: Row(children: [FilledButton(child: x)]))',
        'f.dart': 'SizedBox(width: 48, child: FilledButton(child: x))',
        'g.dart': '// SizedBox(height: 48, child: FilledButton(child: x))',
        'h.dart': 'ButtonBox(height: 28, child: TextButton(style: TextButton.styleFrom(minimumSize: s), child: x))',
        'i.dart': 'ButtonBox(height: 48, child: FilledButton(child: x))',
      }),
      isEmpty,
    );
  });

  Future<void> pump(WidgetTester tester, Widget box, {double scale = 1, ThemeData? theme}) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: box)),
    ));
  }

  Finder theButton() => find.byWidgetPredicate((w) => w is ButtonStyleButton);
  Finder itsMaterial() => find.descendant(of: theButton(), matching: find.byType(Material)).first;

  testWidgets('a button whose words take a line: its box, the button and its tap target are as they were in a box of '
      'a fixed height, on a phone and on a computer', (tester) async {
    final desktop = ThemeData(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final cases = <(String, double, double?, Widget, ThemeData?)>[
      ('a full-width button 48 tall', 48, 300, FilledButton(onPressed: () {}, child: const Text('Save')), null),
      ('a text button 44 tall', 44, 300, TextButton(onPressed: () {}, child: const Text('Done')), null),
      (
        'a button 36 tall, its least height in its style',
        36,
        null,
        FilledButton.icon(
          onPressed: () {},
          icon: const Icon(LucideIcons.plus, size: 16),
          label: const Text('Add a host'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 36)),
        ),
        null,
      ),
      (
        "a computer's button 28 tall",
        28,
        null,
        TextButton(
          onPressed: () {},
          style: TextButton.styleFrom(minimumSize: const Size(64, 28), padding: const EdgeInsets.symmetric(horizontal: 10)),
          child: const Text('Create'),
        ),
        desktop,
      ),
    ];
    for (final (name, height, width, child, theme) in cases) {
      await pump(tester, SizedBox(height: height, width: width, child: child), theme: theme);
      final box = tester.getRect(theButton());
      final material = tester.getRect(itsMaterial());
      await pump(tester, ButtonBox(height: height, width: width, child: child), theme: theme);
      expect(tester.getRect(theButton()), box, reason: name);
      expect(tester.getRect(itsMaterial()), material, reason: name);
      expect(tester.getSize(find.byType(ButtonBox)), box.size, reason: name);
    }
  });

  testWidgets('words of more than a line: the box grows and they are whole, where a box of a fixed height cut them',
      (tester) async {
    Widget child() => FilledButton(onPressed: () {}, child: const Text(label, textAlign: TextAlign.center));
    await pump(tester, SizedBox(height: 48, width: 160, child: child()), scale: 1.5);
    expect(cutTopAndBottom(tester.renderObject<RenderParagraph>(find.text(label))), isNotNull);
    await pump(tester, ButtonBox(height: 48, width: 160, child: child()), scale: 1.5);
    expect(cutTopAndBottom(tester.renderObject<RenderParagraph>(find.text(label))), isNull);
    expect(tester.getSize(find.byType(ButtonBox)).height, greaterThan(48));
    expect(tester.getSize(find.byType(ButtonBox)).width, 160);
  });

  testWidgets("the box is the button's tap target, as a fixed one was: a tap under it is not the button's",
      (tester) async {
    var taps = 0;
    await pump(
      tester,
      ButtonBox(height: 44, width: 200, child: TextButton(onPressed: () => taps++, child: const Text('Done'))),
    );
    expect(tester.getSize(find.byType(ButtonBox)), const Size(200, 44));
    final top = tester.getTopLeft(find.byType(ButtonBox));
    await tester.tapAt(top + const Offset(100, 42));
    expect(taps, 1);
    await tester.tapAt(top + const Offset(100, 46));
    expect(taps, 1);
  });
}
