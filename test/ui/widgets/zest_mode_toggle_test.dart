import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ZestModeToggle', () {
    testWidgets('tapping a segment fires onChanged with its id', (tester) async {
      String? changed;
      await tester.pumpWidget(_host(ZestModeToggle(
        segments: const [
          ZestModeSegment(id: 'simple', label: 'Simple'),
          ZestModeSegment(id: 'advanced', label: 'Advanced'),
        ],
        selectedId: 'simple',
        onChanged: (id) => changed = id,
      )));

      await tester.tap(find.text('Advanced'));
      await tester.pump();
      expect(changed, 'advanced');
    });

    testWidgets('a disabled segment shows a Tooltip and does not fire',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(_host(ZestModeToggle(
        segments: const [
          ZestModeSegment(id: 'simple', label: 'Simple'),
          ZestModeSegment(
            id: 'advanced',
            label: 'Advanced',
            enabled: false,
            disabledReason: 'Upgrade to Pro',
          ),
        ],
        selectedId: 'simple',
        onChanged: (_) => fired++,
      )));

      // Reason is surfaced as a tooltip (never a silent grey).
      expect(find.byTooltip('Upgrade to Pro'), findsOneWidget);

      // Tapping the disabled segment does nothing.
      await tester.tap(find.text('Advanced'), warnIfMissed: false);
      await tester.pump();
      expect(fired, 0);
    });

    testWidgets('a disabled segment falls back to the top-level reason',
        (tester) async {
      await tester.pumpWidget(_host(ZestModeToggle(
        segments: const [
          ZestModeSegment(id: 'simple', label: 'Simple'),
          ZestModeSegment(id: 'advanced', label: 'Advanced', enabled: false),
        ],
        selectedId: 'simple',
        disabledReason: 'Not available here',
        onChanged: (_) {},
      )));
      expect(find.byTooltip('Not available here'), findsOneWidget);
    });

    testWidgets('re-tapping the active segment does not re-fire',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(_host(ZestModeToggle(
        segments: const [
          ZestModeSegment(id: 'simple', label: 'Simple'),
          ZestModeSegment(id: 'advanced', label: 'Advanced'),
        ],
        selectedId: 'simple',
        onChanged: (_) => fired++,
      )));

      await tester.tap(find.text('Simple'));
      await tester.pump();
      expect(fired, 0);
    });
  });
}
