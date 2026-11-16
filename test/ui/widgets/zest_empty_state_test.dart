import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';

void main() {
  group('ZestEmptyState', () {
    testWidgets('centers vertically in a tall parent', (tester) async {
      // Force a 600 x 1400 surface so the pane is genuinely tall.
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ZestEmptyState(
            icon: LucideIcons.inbox,
            title: 'Nothing here yet',
          ),
        ),
      ));

      // The content column's centre should sit at the pane's vertical middle
      // (1400 / 2 = 700), not parked at an awkward mid-height.
      final columnCenter = tester.getCenter(
        find.descendant(
          of: find.byType(ZestEmptyState),
          matching: find.byType(Column),
        ),
      );
      expect(columnCenter.dy, closeTo(700, 2));
    });

    testWidgets('renders primaryAction and secondaryAction below the message',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ZestEmptyState(
            icon: LucideIcons.inbox,
            title: 'Empty',
            message: 'Add something to get started.',
            primaryAction: Text('PRIMARY'),
            secondaryAction: Text('SECONDARY'),
          ),
        ),
      ));
      expect(find.text('PRIMARY'), findsOneWidget);
      expect(find.text('SECONDARY'), findsOneWidget);
    });

    testWidgets('legacy actionLabel/onAction path still works', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ZestEmptyState(
            icon: LucideIcons.inbox,
            title: 'Empty',
            actionLabel: 'Add host',
            onAction: () => taps++,
          ),
        ),
      ));
      expect(find.text('Add host'), findsOneWidget);
      await tester.tap(find.text('Add host'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('unavailable suppresses all actions', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ZestEmptyState(
            icon: LucideIcons.inbox,
            title: 'Not available',
            unavailable: true,
            primaryAction: Text('PRIMARY'),
          ),
        ),
      ));
      expect(find.text('PRIMARY'), findsNothing);
    });
  });
}
