import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/ui/screens/automation/automation_history_screen.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

class _Locked implements Exception {
  const _Locked();
  @override
  String toString() => 'SqliteException(5): database is locked';
}

/// The automation history that could not be read (3.0): said so
/// in the person's language, with Try again and Copy details, as the other
/// lists say it. It said "Failed to load history:" and the error as the
/// program writes it.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets('the automation history that cannot be read: said so, with Try again and its details', (tester) async {
    var asked = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        automationLogProvider.overrideWith((ref) {
          asked++;
          return Stream.error(const _Locked());
        }),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AutomationHistoryScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(en.automationRunsNotLoaded), findsOneWidget);
    expect(find.textContaining('database is locked'), findsNothing, reason: 'the error is not the sentence');
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    final before = asked;
    await tester.tap(find.text(en.retry));
    await tester.pumpAndSettle();
    expect(asked, greaterThan(before), reason: 'Try again reads it again');
  });
}
