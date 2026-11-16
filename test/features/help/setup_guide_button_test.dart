import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/ui/widgets/dock_panel.dart';

/// The prominent labelled "Setup guide" button (field feedback: the old bare
/// "?" icon was too small and missed on most screens). It renders as a real
/// labelled button, and on desktop it opens the guide as a right-docked side
/// panel ([SetupGuideDock]) that stays open while you work, rather than a
/// full-screen route.
void main() {
  testWidgets('opens the guide as a docked side panel for its topic',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Row(
            children: [
              Expanded(child: SetupGuideButton(SetupTopic.serverMonitor)),
              SetupGuideDock(),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final l10n =
        AppLocalizations.of(tester.element(find.byType(SetupGuideButton)))!;

    // It is a real, labelled button, not a bare icon, and the dock is closed.
    expect(find.widgetWithText(OutlinedButton, l10n.setupGuideTitle),
        findsOneWidget);
    expect(find.byType(DockPanel), findsNothing);

    // Tapping docks the guide for this topic (its title + intro render in the
    // panel), and it stays open beside the content.
    await tester.tap(find.byType(SetupGuideButton));
    await tester.pumpAndSettle();
    expect(find.byType(DockPanel), findsOneWidget);
    expect(find.text(l10n.setupGuideMonitorTitle), findsOneWidget);
    expect(find.text(l10n.setupGuideMonitorIntro), findsOneWidget);

    // Closing the panel returns to just the content.
    await tester.tap(find.byTooltip(l10n.close));
    await tester.pumpAndSettle();
    expect(find.byType(DockPanel), findsNothing);
  });
}
