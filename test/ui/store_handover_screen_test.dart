import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/error/store_handover_screen.dart';

/// The question the Store copy asks before anything opens, where it and the
/// copy from zestssh.com hold different data (store_handover.dart). Seen in
/// Windows Sandbox with the default dark theme's purple on
/// its buttons: it wears the app's orange.
void main() {
  Future<List<bool>> pump(WidgetTester tester) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      StoreHandoverQuestionApp(onAnswer: answers.add, language: 'en'),
    );
    await tester.pumpAndSettle();
    return answers;
  }

  testWidgets('keeping this app\'s data answers false, in the app\'s orange', (
    tester,
  ) async {
    final answers = await pump(tester);
    expect(find.text('Two sets of ZestSSH data on this PC'), findsOneWidget);
    final keep = find.widgetWithText(FilledButton, "Keep this app's data");
    final fill = Theme.of(tester.element(keep)).colorScheme.primary;
    expect(fill, AppColors.orange);
    await tester.tap(keep);
    expect(answers, [false]);
  });

  // A hand-over left
  // waiting can be weeks old; the person sees which set is the newer.
  testWidgets('under each choice, when that data was last used', (
    tester,
  ) async {
    await tester.pumpWidget(
      StoreHandoverQuestionApp(
        onAnswer: (_) {},
        language: 'en',
        storeLastUsed: DateTime(2026, 11, 4, 18, 40),
        websiteLastUsed: DateTime(2026, 10, 2, 9, 15),
      ),
    );
    await tester.pumpAndSettle();
    final store = find.text('Last used Nov 4, 2026, 6:40 PM');
    final website = find.text('Last used Oct 2, 2026, 9:15 AM');
    expect(store, findsOneWidget);
    expect(website, findsOneWidget);
    // Each under its own button.
    final keepStore = find.widgetWithText(FilledButton, "Keep this app's data");
    final keepWebsite = find.widgetWithText(
      OutlinedButton,
      "Keep the zestssh.com app's data",
    );
    expect(tester.getTopLeft(store).dy, greaterThan(tester.getBottomLeft(keepStore).dy));
    expect(tester.getTopLeft(store).dy, lessThan(tester.getTopLeft(keepWebsite).dy));
    expect(tester.getTopLeft(website).dy, greaterThan(tester.getBottomLeft(keepWebsite).dy));
    expect(
      find.textContaining('set aside on this PC for 30 days, then deleted'),
      findsOneWidget,
    );
  });

  testWidgets('keeping the zestssh.com app\'s data answers true', (
    tester,
  ) async {
    final answers = await pump(tester);
    await tester.tap(
      find.widgetWithText(OutlinedButton, "Keep the zestssh.com app's data"),
    );
    expect(answers, [true]);
  });
}
