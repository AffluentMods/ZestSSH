import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';

/// Words and a control in a row (3.0): the control beside
/// the words where they keep their room, under them where they would not; and
/// a form's label column measured from its own names.
void main() {
  const words = Key('words');
  const control = Key('control');

  Future<int> pump(WidgetTester tester, {required double width, double scale = 1, TextDirection direction = TextDirection.ltr}) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 600), textScaler: TextScaler.linear(scale)),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: BesideOrUnder(
                  words: const Text('Encrypted on this device with a master password.', key: words),
                  control: SizedBox(
                    key: control,
                    width: 80,
                    height: 32,
                    child: TextButton(onPressed: () => taps++, child: const Text('Set up')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    return taps;
  }

  bool beside(WidgetTester tester) => tester.renderObject<RenderBesideOrUnder>(find.byType(BesideOrUnder)).controlBeside;

  testWidgets('beside the words where they keep 200 of room, the two centred on each other', (tester) async {
    await pump(tester, width: 300);
    expect(beside(tester), isTrue);
    final w = tester.getRect(find.byKey(words));
    final c = tester.getRect(find.byKey(control));
    expect(w.left, 0);
    expect(w.width, 300 - 80 - 12);
    expect(c.right, 300);
    expect(c.center.dy, closeTo(w.center.dy, 0.5));
  });

  testWidgets('under the words, at the start, where they would keep less', (tester) async {
    await pump(tester, width: 280);
    expect(beside(tester), isFalse);
    final w = tester.getRect(find.byKey(words));
    final c = tester.getRect(find.byKey(control));
    expect(w.width, 280);
    expect(c.left, 0);
    expect(c.top, w.bottom + 8);
    expect(tester.getSize(find.byType(BesideOrUnder)).height, w.height + 8 + 32);
  });

  testWidgets("the words' room grows with the text: under them at 1.5 times where beside them at 1", (tester) async {
    await pump(tester, width: 340);
    expect(beside(tester), isTrue);
    await pump(tester, width: 340, scale: 1.5);
    expect(beside(tester), isFalse);
  });

  testWidgets('right to left: beside them on the left, under them on the right', (tester) async {
    await pump(tester, width: 300, direction: TextDirection.rtl);
    expect(tester.getRect(find.byKey(control)).left, 0);
    expect(tester.getRect(find.byKey(words)).right, 300);
    await pump(tester, width: 280, direction: TextDirection.rtl);
    expect(tester.getRect(find.byKey(control)).right, 280);
  });

  testWidgets('the control is pressed beside the words and under them', (tester) async {
    for (final width in [300.0, 280.0]) {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: BesideOrUnder(
              words: const Text('Encrypted on this device with a master password.'),
              control: SizedBox(width: 80, height: 32, child: TextButton(onPressed: () => taps++, child: const Text('Set up'))),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Set up'));
      expect(taps, 1, reason: '${width.toInt()} wide');
    }
  });

  testWidgets('it can be asked its sizes before it is laid out (in an IntrinsicHeight)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 280,
          child: IntrinsicHeight(
            child: _Measured(),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(BesideOrUnder)).height, greaterThan(32));
  });

  group("a form's label column", () {
    Future<void> form(WidgetTester tester, List<String> labels, {double width = 360, double scale = 1}) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: ZestFieldLabels(
              labels: labels,
              child: Column(children: [
                for (final l in labels) ZestField(label: l, controller: TextEditingController()),
              ]),
            ),
          ),
        ),
      ));
    }

    double cell(WidgetTester tester, String label) =>
        tester.getSize(find.ancestor(of: find.text(label), matching: find.byType(SizedBox)).first).width;

    testWidgets('as wide as its longest name, and the same for each field', (tester) async {
      await form(tester, ['Name', 'Soprannome']);
      final long = cell(tester, 'Soprannome');
      expect(long, greaterThan(88));
      expect(cell(tester, 'Name'), long, reason: 'the inputs stay on one rule');
      final painter = TextPainter(
        text: const TextSpan(text: 'Soprannome', style: TextStyle(fontSize: 12, height: 1.2)),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(long, greaterThanOrEqualTo(painter.width + 22), reason: 'the name holds on one line');
      painter.dispose();
    });

    testWidgets('at least 88, and wider at a larger text size', (tester) async {
      await form(tester, ['Name', 'Host']);
      expect(cell(tester, 'Name'), 88);
      // A wide page, where the values keep their room beside the column.
      await form(tester, ['Name', 'Nickname'], width: 900, scale: 1.6);
      expect(cell(tester, 'Name'), greaterThan(88));
    });

    testWidgets('at most 42% of the screen: a longer name wraps to a second line there', (tester) async {
      // Two lines in the column (a name needing more stands above its value).
      const long = 'Long label words';
      await form(tester, [long]);
      expect(cell(tester, long), closeTo(360 * 0.42, 0.5));
      final paragraph = tester.renderObject<RenderParagraph>(find.text(long));
      expect(paragraph.size.height, greaterThan(12 * 1.2 * 1.5), reason: 'two lines');
    });

    testWidgets('a field without a form: 88, as before', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ZestField(label: 'Nickname', controller: TextEditingController())),
      ));
      expect(cell(tester, 'Nickname'), 88);
    });
  });
}

class _Measured extends StatelessWidget {
  const _Measured();

  @override
  Widget build(BuildContext context) => BesideOrUnder(
        words: const Text('Encrypted on this device with a master password.'),
        control: const SizedBox(width: 80, height: 32),
      );
}
