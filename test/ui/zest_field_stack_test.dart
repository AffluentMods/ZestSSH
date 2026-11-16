import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';

import '../helpers/dart_calls.dart';

/// A form's field stands its name above its value where beside it a name or
/// the value would be cut (3.0): where a word of one of the
/// form's names is longer than its column holds, where a name needs more than
/// two lines there, or where the value beside the column would keep less than
/// 140 at the text size the app is drawn at. A field under no form keeps its
/// name beside, as before.
void main() {
  const above = ValueKey('zest-field-name-above');

  Future<void> form(WidgetTester tester, List<String> labels,
      {double width = 360, double scale = 1, bool scoped = true, String group = 'Address'}) async {
    final fields = Column(children: [
      for (final l in labels) ZestField(label: l, controller: TextEditingController()),
      ZestFieldGroup(
        label: group,
        fields: [
          Flexible(child: ZestField.grouped(label: 'Host', controller: TextEditingController())),
          SizedBox(width: kZestPortSegmentWidth, child: ZestField.grouped(label: 'Port', controller: TextEditingController())),
        ],
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SizedBox(
            width: width,
            child: scoped ? ZestFieldLabels(labels: [...labels, group], child: fields) : fields,
          ),
        ),
      ),
    ));
  }

  bool nameAbove(WidgetTester tester, String label) =>
      find.ancestor(of: find.text(label), matching: find.byKey(above)).evaluate().isNotEmpty;

  testWidgets('beside the value where the names hold in the column and the value keeps its room', (tester) async {
    await form(tester, ['Name', 'Note']);
    expect(nameAbove(tester, 'Name'), isFalse);
    expect(nameAbove(tester, 'Address'), isFalse, reason: 'a group too');
  });

  testWidgets('above every value of the form where a word of one name is longer than the column holds', (tester) async {
    // In the test's font every letter is as wide as it is tall: 20 letters
    // of 12 are wider than a column of at most 42% of 360, less its room.
    await form(tester, ['Name', 'Supercalifragilistic']);
    expect(nameAbove(tester, 'Supercalifragilistic'), isTrue);
    expect(nameAbove(tester, 'Name'), isTrue, reason: 'the whole form, so its fields stay alike');
    expect(nameAbove(tester, 'Address'), isTrue);
    final name = tester.getRect(find.text('Name'));
    final field = tester.getRect(find.byType(ZestField).first);
    expect(name.left, closeTo(field.left + 11, 1), reason: 'the name in the band across the top');
  });

  testWidgets('above where a name would need more than two lines in the column', (tester) async {
    await form(tester, ['Name', 'A b c d e f g h i j k l m n o p q r s t u v w x y z']);
    expect(nameAbove(tester, 'Name'), isTrue);
  });

  testWidgets('above where the value beside the column would keep less than 140, at the size the app is drawn at '
      'and more as the text grows', (tester) async {
    // Short names, which hold in the column: the value's room alone decides.
    await form(tester, ['Name'], group: 'Port', width: 220);
    expect(nameAbove(tester, 'Name'), isTrue, reason: 'beside a column of 88 the value would keep 131');
    await form(tester, ['Name'], group: 'Port', width: 240);
    expect(nameAbove(tester, 'Name'), isFalse, reason: 'it keeps 151');
    await form(tester, ['Name'], group: 'Port', width: 250, scale: 1.5);
    expect(nameAbove(tester, 'Name'), isTrue, reason: 'at 1.5 times it would keep less than 210');
  });

  testWidgets('a field under no form keeps its name beside, however narrow', (tester) async {
    await form(tester, ['Name', 'Supercalifragilistic'], width: 200, scoped: false);
    expect(find.byKey(above), findsNothing);
  });

  testWidgets('its value is still typed into above or beside', (tester) async {
    for (final width in [360.0, 220.0]) {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: Scaffold(
            body: SizedBox(
              width: width,
              child: ZestFieldLabels(labels: const ['Name'], child: ZestField(label: 'Name', controller: controller)),
            ),
          ),
        ),
      ));
      await tester.enterText(find.byType(TextField), 'web-01');
      expect(controller.text, 'web-01', reason: '${width.toInt()} wide');
    }
  });
  test("no form of the app gives its names a fixed width: each measures its names' column from its names", () {
    final call = RegExp(r'\b(ZestField|ZestField\.custom|RecordingMaskedField|PasswordRefEditor|ZestFieldGroup)\s*\(');
    final fixed = RegExp(r'^(\d+(\.\d+)?|_?k[A-Z]\w*)$');
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      for (final c in callsIn(file.readAsStringSync(), call)) {
        final width = namedArg(c.args, 'labelWidth');
        if (width != null && fixed.hasMatch(width)) found.add('$path:${c.line} labelWidth: $width');
      }
    }
    expect(found, isEmpty, reason: 'zestFieldLabelWidth (at least the width it had), or a ZestFieldLabels around the form');
    expect(fixed.hasMatch('_kPfLabelWidth') && fixed.hasMatch('104') && !fixed.hasMatch('labelWidth'), isTrue);
  });
}
