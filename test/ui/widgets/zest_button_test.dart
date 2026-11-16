import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ZestButton', () {
    testWidgets('renders label and fires onPressed on tap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(ZestButton(
        label: 'Save',
        onPressed: () => taps++,
      )));
      expect(find.text('Save'), findsOneWidget);
      await tester.tap(find.byType(ZestButton));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('disabled (null onPressed) blocks the tap', (tester) async {
      await tester.pumpWidget(_host(const ZestButton(label: 'Save')));
      // Disabled renders dimmed at 0.4 and blocks pointer events.
      final opacities = tester.widgetList<Opacity>(
        find.descendant(
          of: find.byType(ZestButton),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacities.any((o) => o.opacity == 0.4), isTrue);
      expect(
        find.descendant(
          of: find.byType(ZestButton),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
      // Tapping must not throw and there's nothing to fire.
      await tester.tap(find.byType(ZestButton), warnIfMissed: false);
      await tester.pump();
    });

    testWidgets('isLoading shows a spinner and blocks the tap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(ZestButton(
        label: 'Save',
        isLoading: true,
        onPressed: () => taps++,
      )));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(ZestButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0); // loading blocks activation
    });

    testWidgets('primary and secondary both render their label', (tester) async {
      await tester.pumpWidget(_host(
        Column(mainAxisSize: MainAxisSize.min, children: [
          ZestButton(
            label: 'Primary',
            variant: ZestButtonVariant.primary,
            size: ZestButtonSize.large,
            onPressed: () {},
          ),
          ZestButton(
            label: 'Secondary',
            onPressed: () {},
          ),
        ]),
      ));
      expect(find.text('Primary'), findsOneWidget);
      expect(find.text('Secondary'), findsOneWidget);
    });

    // The focus ring's Stack fitted its
    // child loosely, so a button given the whole width drew hugging the
    // top-left corner of it.
    Rect fillOf(WidgetTester tester) => tester.getRect(find
        .descendant(of: find.byType(ZestButton), matching: find.byType(AnimatedContainer))
        .first);

    testWidgets('given the whole width (a stretched column) it fills it, its label centred', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ZestButton(label: 'Continue', variant: ZestButtonVariant.primary, onPressed: () {}),
          ]),
        ),
      ));
      final fill = fillOf(tester);
      expect(fill.width, 400);
      expect(tester.getSize(find.byType(ZestButton)).width, 400);
      final label = tester.getRect(find.text('Continue'));
      expect((label.center.dx - fill.center.dx).abs(), lessThan(1));
    });

    testWidgets('in a SizedBox of infinite width it fills it as well', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: double.infinity,
              child: ZestButton(label: 'Save', onPressed: () {}),
            ),
          ),
        ),
      ));
      expect(fillOf(tester).width, 400);
      final label = tester.getRect(find.text('Save'));
      expect((label.center.dx - 200).abs(), lessThan(1));
    });

    testWidgets('left loose (in a row) it still hugs its label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            ZestButton(label: 'Save', onPressed: () {}),
          ]),
        ),
      ));
      final fill = fillOf(tester);
      final label = tester.getRect(find.text('Save'));
      expect(fill.width, lessThan(120));
      expect(fill.width, greaterThan(label.width));
    });

    testWidgets('a disabled primary is the theme\'s one turned-off fill, not the surface it sits on', (tester) async {
      await tester.pumpWidget(_host(const ZestButton(label: 'Save', variant: ZestButtonVariant.primary)));
      final box = tester.widget<AnimatedContainer>(find
          .descendant(of: find.byType(ZestButton), matching: find.byType(AnimatedContainer))
          .first);
      final deco = box.decoration! as BoxDecoration;
      expect(deco.color, ZestTokens.disabledFill);
      expect(deco.color, isNot(ZestTokens.surfaceRaised));
      expect(tester.widget<Text>(find.text('Save')).style?.color, ZestTokens.disabledInk);
    });
  });
}
