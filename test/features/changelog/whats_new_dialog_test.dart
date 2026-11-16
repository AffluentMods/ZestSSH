import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/changelog/changelog_data.dart';
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';

/// The in-app "What's new" changelog: opening it shows the current release,
/// the "Current" marker, categorised notes, and closes cleanly. The notes
/// text mirrors zestssh.com/changelog and stays English on every locale;
/// only the chrome (title, category labels, Current) is localised.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A note's tier badge is the plan's chip (PlanChip, a ConsumerWidget), so
  // the dialog stands in a ProviderScope, as it always does in the app; the
  // account's own plan is held to Free here.
  Widget harness() => ProviderScope(
        overrides: [accountPlanProvider.overrideWithValue(AccountPlan.free)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showWhatsNewDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('opens to the current release and dismisses on close',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final l10n =
        AppLocalizations.of(tester.element(find.text('open')))!;

    // The changelog data is the whole release history, newest first.
    expect(kChangelog.length, greaterThan(20));
    final current = kChangelog.first;

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Header title, the current version's badge and tag, the Current marker.
    expect(find.text(l10n.helpWhatsNew), findsOneWidget);
    expect(find.text(current.version), findsOneWidget);
    if (current.tag != null) {
      expect(find.text(current.tag!), findsOneWidget);
    }
    expect(find.text(l10n.changelogCurrent.toUpperCase()), findsOneWidget);

    // The first category of the current release is rendered with its label.
    final firstCat = current.sections.first.category;
    final label = switch (firstCat) {
      ChangelogCategory.breaking => l10n.changelogCategoryBreaking,
      ChangelogCategory.security => l10n.changelogCategorySecurity,
      ChangelogCategory.features => l10n.changelogCategoryFeatures,
      ChangelogCategory.improvements => l10n.changelogCategoryImprovements,
      ChangelogCategory.fixes => l10n.changelogCategoryFixes,
    };
    // At least once: a short release leaves the next one's heading of the same
    // kind in view as well (3.2.3, a single fix above 3.2.2's fixes).
    expect(find.text(label.toUpperCase()), findsWidgets);

    // Close returns to the page; the dialog title is gone.
    await tester.tap(find.byTooltip(l10n.close));
    await tester.pumpAndSettle();
    expect(find.text(l10n.helpWhatsNew), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
