import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/widgets/tab_focus_traversal.dart';
import 'package:zestssh/utils/help_links.dart';

/// The Help panel: the FAQ block
/// sits above the three action rows, a type pushes a second level in the
/// same pane with a back chevron, and the form states that the post is
/// public and shows the payload preview before Send.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Widget harness(HelpPage page, {List<String>? log}) => ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          helpDockProvider.overrideWith((_) => page),
          // No network in tests: the footer shows a healthy service.
          cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
          appVersionLabelProvider.overrideWith((_) async => '1.9.7'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // The same Tab handling the real app installs in MaterialApp.builder.
          builder: (context, child) => TabMovesFocus(child: child!),
          home: Scaffold(
            body: Row(
              children: [
                const Expanded(child: SizedBox()),
                HelpDock(
                  captureScreenshot: ({required bool redacted}) async =>
                      Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]),
                  onCopyRedactedScreenshot: () => log?.add('copy'),
                  onOpenShortcuts: () => log?.add('shortcuts'),
                  onAbout: () => log?.add('about'),
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('the common questions sit above the three action rows',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(harness(HelpPage.home));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
        tester.element(find.byType(HelpDock)))!;

    expect(find.text(l10n.helpGroupCommonQuestions.toUpperCase()), findsOneWidget);
    for (final faq in [
      l10n.helpFaqImport,
      l10n.helpFaqKeyRejected,
      l10n.helpFaqSyncHosts,
    ]) {
      expect(find.text(faq), findsOneWidget);
    }
    final faqY = tester.getTopLeft(find.text(l10n.helpFaqSyncHosts)).dy;
    // (3.4: one way into the Support Hub for a ticket, a
    // bug or an idea, then My tickets and the Ideas board.)
    for (final row in [l10n.helpContactSupport, l10n.ticketsTitle, l10n.helpIdeasBoard]) {
      expect(tester.getTopLeft(find.text(row)).dy, greaterThan(faqY),
          reason: '$row must sit below the FAQ block');
    }
    expect(find.text(l10n.helpContactSupportSub), findsOneWidget);
    // No back chevron on the home level.
    expect(find.bySemanticsLabel(l10n.back), findsNothing);
  });

  testWidgets('Report a bug is a form in the same pane with a back chevron',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    // (3.4: the home's rows open the Support Hub; the panel's own form is
    // reached from the places that ask for it, the shortcuts and the menus.)
    await tester.pumpWidget(harness(HelpPage.reportBug));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
        tester.element(find.byType(HelpDock)))!;

    // Same pane: the home rows are gone, the form is here, with a back chevron.
    expect(find.text(l10n.helpFaqImport), findsNothing);
    expect(find.bySemanticsLabel(l10n.back), findsOneWidget);
    expect(find.text(l10n.reportBugWhatHappened), findsOneWidget);
    expect(find.text(l10n.reportBugWhatExpected), findsOneWidget);
    expect(find.text(l10n.feedbackPublicNotice), findsOneWidget);
    expect(find.text(l10n.feedbackAnonymous), findsOneWidget);
    expect(find.text(l10n.feedbackWhatIsSent), findsOneWidget);
    expect(find.text(l10n.feedbackSend), findsOneWidget);
    // The screenshot is offered (desktop bug report) and off by default.
    expect(find.text(l10n.feedbackAttach), findsOneWidget);

    // Back returns to the home level.
    await tester.tap(find.bySemanticsLabel(l10n.back));
    await tester.pumpAndSettle();
    expect(find.text(l10n.helpFaqImport), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.back), findsNothing);
  });

  testWidgets('the payload preview shows the exact context and nothing else',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(harness(HelpPage.suggest));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
        tester.element(find.byType(HelpDock)))!;

    expect(find.text(l10n.reportSuggestWhat), findsOneWidget);
    expect(find.text(l10n.reportBugWhatHappened), findsNothing);

    // The category chips are the forum's public tags, sent as a value.
    await tester.ensureVisible(find.text(l10n.reportCategoryNewFeature));
    await tester.tap(find.text(l10n.reportCategoryNewFeature));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text(l10n.feedbackWhatIsSent));
    await tester.tap(find.text(l10n.feedbackWhatIsSent));
    await tester.pumpAndSettle();

    final preview =
        tester.widget<SelectableText>(find.byType(SelectableText).first).data!;
    for (final key in [
      '"type": "suggestion"', '"category": "new_feature"', '"app_version"',
      '"build"', '"platform"', '"os_version"', '"locale"', '"tier"',
      '"contact": null', '"nonce"',
    ]) {
      expect(preview, contains(key));
    }
    for (final forbidden in ['uid', 'email', 'install', 'hosts', 'log']) {
      expect(preview, isNot(contains('"$forbidden"')));
    }
  });

  testWidgets('Tab walks every field of the bug form, multi-line ones included',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(harness(HelpPage.reportBug));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
        tester.element(find.byType(HelpDock)))!;

    // Fields in visual order: title, body, expected, steps.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(4));
    await tester.tap(fields.at(0));
    await tester.pumpAndSettle();

    TextField focusedField() {
      final editable = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .firstWhere((e) => e.focusNode.hasFocus);
      return tester.widget<TextField>(find.ancestor(
          of: find.byWidget(editable), matching: find.byType(TextField)));
    }

    expect(focusedField().decoration?.hintText, l10n.reportTitleHint);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focusedField().minLines, 4, reason: 'title -> what happened');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focusedField().minLines, 2,
        reason: 'what happened (multi-line) -> what you expected');
    expect(focusedField().controller?.text, isEmpty,
        reason: 'Tab moved focus instead of inserting a tab character');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(focusedField().minLines, 4, reason: 'Shift+Tab walks back');
  });

  testWidgets('Get help shows Discord and the email address with a copy button',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpWidget(harness(HelpPage.support));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
        tester.element(find.byType(HelpDock)))!;

    expect(find.text(l10n.helpSupportBody), findsOneWidget);
    expect(find.text(l10n.helpOpenDiscord), findsOneWidget);
    expect(find.text(kZestSupportEmail), findsOneWidget);
    expect(find.byTooltip(l10n.copy), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.back), findsOneWidget);
  });
}
