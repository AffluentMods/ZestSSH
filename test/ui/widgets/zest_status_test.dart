import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart'
    show HostSeverity;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ZestStatusPill', () {
    // The load-bearing guarantee: a long label renders in FULL, no ellipsis,
    // no overflow - the pill sizes to its content.
    testWidgets('renders a 30-char label in full with no ellipsis', (tester) async {
      const label = 'Needs saved credentials review'; // 30 chars
      expect(label.length, 30);

      await tester.pumpWidget(_host(
        const ZestStatusPill(kind: ZestStatusKind.critical, label: label),
      ));

      // No RenderFlex overflow / layout exception was thrown.
      expect(tester.takeException(), isNull);

      // The FULL string is present (find.text matches the exact Text.data).
      expect(find.text(label), findsOneWidget);

      // And the Text is not configured to ellipsize.
      final text = tester.widget<Text>(find.text(label));
      expect(text.overflow, isNot(TextOverflow.ellipsis));

      // The pill sized to its content and was not clipped to the screen width.
      final pillWidth = tester.getSize(find.byType(ZestStatusPill)).width;
      expect(pillWidth, greaterThan(0));
      expect(pillWidth, lessThan(800)); // fit within the 800px test surface

      // Leading icon is always present (deuteranopia safety).
      expect(
        find.descendant(
          of: find.byType(ZestStatusPill),
          matching: find.byType(Icon),
        ),
        findsOneWidget,
      );
    });

    testWidgets("busy: a spinner in the kind's colour stands in the glyph's place", (tester) async {
      await tester.pumpWidget(_host(
        const ZestStatusPill(kind: ZestStatusKind.pending, label: 'Signing in with the new key', busy: true),
      ));
      final pill = find.byType(ZestStatusPill);
      expect(find.descendant(of: pill, matching: find.byType(Icon)), findsNothing);
      final spinner = tester.widget<CircularProgressIndicator>(
          find.descendant(of: pill, matching: find.byType(CircularProgressIndicator)));
      expect(spinner.color, zestStatusColor(ZestStatusKind.pending));
      expect(find.text('Signing in with the new key'), findsOneWidget);
    });

    testWidgets('honours an explicit icon override', (tester) async {
      await tester.pumpWidget(_host(
        const ZestStatusPill(
          kind: ZestStatusKind.healthy,
          label: 'Connected',
          icon: LucideIcons.zap,
        ),
      ));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(ZestStatusPill),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, LucideIcons.zap);
    });
  });

  group('ZestStatusDot', () {
    testWidgets('is exactly 8px', (tester) async {
      await tester.pumpWidget(_host(
        const ZestStatusDot(kind: ZestStatusKind.healthy),
      ));
      expect(tester.getSize(find.byType(ZestStatusDot)), const Size(8, 8));
    });
  });

  group('ZestStatusBar', () {
    testWidgets('is 3px wide', (tester) async {
      await tester.pumpWidget(_host(
        const SizedBox(
          height: 40,
          child: ZestStatusBar(kind: ZestStatusKind.warning),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(ZestStatusBar)).width, 3);
    });
  });

  group('zestStatusColor', () {
    test('maps every kind to its token role', () {
      expect(zestStatusColor(ZestStatusKind.critical), ZestTokens.statusCritical);
      expect(zestStatusColor(ZestStatusKind.warning), ZestTokens.statusWarning);
      expect(zestStatusColor(ZestStatusKind.healthy), ZestTokens.statusHealthy);
      expect(zestStatusColor(ZestStatusKind.pending), ZestTokens.statusPending);
      expect(zestStatusColor(ZestStatusKind.neutral), ZestTokens.statusNeutral);
      // stale is a dimmed grey, distinct from the solid neutral role.
      expect(
        zestStatusColor(ZestStatusKind.stale),
        isNot(zestStatusColor(ZestStatusKind.neutral)),
      );
    });
  });

  group('zestStatusFromHostStatus', () {
    test('maps legacy HostStatus onto the unified vocabulary', () {
      expect(zestStatusFromHostStatus(HostStatus.online), ZestStatusKind.healthy);
      expect(zestStatusFromHostStatus(HostStatus.connecting), ZestStatusKind.pending);
      expect(
          zestStatusFromHostStatus(HostStatus.disconnected), ZestStatusKind.warning);
      expect(zestStatusFromHostStatus(HostStatus.error), ZestStatusKind.critical);
      expect(zestStatusFromHostStatus(HostStatus.offline), ZestStatusKind.neutral);
      expect(zestStatusFromHostStatus(HostStatus.unknown), ZestStatusKind.neutral);
    });
  });

  group('zestStatusFromSeverity', () {
    test('maps every HostSeverity onto the unified vocabulary', () {
      // offline + critical are both hard failures.
      expect(
          zestStatusFromSeverity(HostSeverity.offline), ZestStatusKind.critical);
      expect(zestStatusFromSeverity(HostSeverity.critical),
          ZestStatusKind.critical);
      expect(
          zestStatusFromSeverity(HostSeverity.warning), ZestStatusKind.warning);
      expect(zestStatusFromSeverity(HostSeverity.stale), ZestStatusKind.stale);
      expect(
          zestStatusFromSeverity(HostSeverity.healthy), ZestStatusKind.healthy);
      // unknown / unmonitored → the neutral baseline.
      expect(
          zestStatusFromSeverity(HostSeverity.unknown), ZestStatusKind.neutral);
    });

    test('covers every enum value (exhaustive)', () {
      for (final s in HostSeverity.values) {
        // Must not throw and must return a real kind for every value.
        expect(ZestStatusKind.values.contains(zestStatusFromSeverity(s)), isTrue);
      }
    });
  });
}
