import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

bool _hasCircle(WidgetTester tester) {
  bool circleIn(Iterable<Decoration?> decorations) => decorations.any(
        (d) => d is BoxDecoration && d.shape == BoxShape.circle,
      );
  final containerShapes =
      tester.widgetList<Container>(find.byType(Container)).map((c) => c.decoration);
  final decoratedShapes = tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .map((d) => d.decoration);
  return circleIn(containerShapes) || circleIn(decoratedShapes);
}

void main() {
  group('ZestSectionHeader', () {
    testWidgets('renders the label uppercased', (tester) async {
      await tester
          .pumpWidget(_host(const ZestSectionHeader(label: 'Connections')));
      expect(find.text('CONNECTIONS'), findsOneWidget);
      expect(find.text('Connections'), findsNothing);
    });

    testWidgets('renders no decorative dot', (tester) async {
      await tester.pumpWidget(_host(const ZestSectionHeader(label: 'General')));
      expect(_hasCircle(tester), isFalse);
    });

    testWidgets('count badge appears only when count is set', (tester) async {
      await tester.pumpWidget(_host(const ZestSectionHeader(label: 'Hosts')));
      expect(find.text('3'), findsNothing);

      await tester
          .pumpWidget(_host(const ZestSectionHeader(label: 'Hosts', count: 3)));
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('trailing action renders', (tester) async {
      await tester.pumpWidget(_host(
        const ZestSectionHeader(
          label: 'Hosts',
          trailing: Icon(LucideIcons.plus),
        ),
      ));
      expect(find.byIcon(LucideIcons.plus), findsOneWidget);
    });

    // A Danger zone is the app's own header, its tick and label in red (it
    // was a red heading in sans of its own).
    testWidgets('a danger header: the same mono capitals, tick and label in red', (tester) async {
      // A computer's look (monospace capitals).
      debugTouchLayout = false;
      addTearDown(() => debugTouchLayout = null);
      Color? tick() =>
          (tester.widget<Container>(find.byKey(const ValueKey('section-tick'))).decoration as BoxDecoration?)?.color;
      TextStyle label(String text) => tester.widget<Text>(find.text(text)).style!;

      await tester.pumpWidget(_host(const ZestSectionHeader(label: 'Hosts')));
      expect(tick(), ZestTokens.brand);
      expect(label('HOSTS').color, ZestTokens.textMuted);

      await tester.pumpWidget(_host(const ZestSectionHeader(label: 'Danger zone', danger: true)));
      expect(tick(), ZestTokens.statusCritical);
      final style = label('DANGER ZONE');
      expect(style.color, ZestTokens.statusCritical);
      expect(style.fontFamily, 'JetBrainsMono', reason: 'the header every section has');
    });

    // The label's cap took no account of the tick and the count beside it: in
    // a narrow list (the hosts beside the host editor) HOSTS and its count ran
    // 1.8 px off the row. Now the label is cut first, and the rule still runs
    // to the end.
    testWidgets('a narrow row cuts the label, never runs off', (tester) async {
      debugTouchLayout = false;
      addTearDown(() => debugTouchLayout = null);
      Widget narrow(double width, Widget header) => MaterialApp(
            home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: header))),
          );

      await tester.pumpWidget(narrow(120, const ZestSectionHeader(label: 'Connections and more', count: 12)));
      expect(tester.takeException(), isNull, reason: 'the label and its count ran off the row');
      expect(find.text('12'), findsOneWidget);
      // (Its paragraph under the label's words for a screen reader.)
      final label = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.text('CONNECTIONS AND MORE'), matching: find.byType(RichText)));
      expect(label.didExceedMaxLines, isTrue, reason: 'cut with its ellipsis');

      await tester.pumpWidget(narrow(
        200,
        const ZestSectionHeader(label: 'Recently connected hosts', trailing: Text('Sort by name')),
      ));
      expect(tester.takeException(), isNull, reason: 'the label and what stands at the end ran off the row');
      // The rule runs up to what stands at the end.
      final rule = tester.getRect(find.byWidgetPredicate((w) => w is ColoredBox && w.color == ZestTokens.borderSubtle));
      expect(rule.right, closeTo(tester.getRect(find.text('Sort by name')).left - 9, 0.01));

      // With room, the label is whole and the rule fills the rest.
      await tester.pumpWidget(narrow(800, const ZestSectionHeader(label: 'Hosts', count: 12)));
      expect(tester.takeException(), isNull);
      expect(tester.renderObject<RenderParagraph>(find.descendant(of: find.text('HOSTS'), matching: find.byType(RichText))).didExceedMaxLines, isFalse);
      final whole = tester.getRect(find.byWidgetPredicate((w) => w is ColoredBox && w.color == ZestTokens.borderSubtle));
      expect(whole.right, closeTo(800, 0.01));
    });
  });
}
