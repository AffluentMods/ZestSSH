import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/assistant/assistant_service.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/ask_astryx_screen.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/widgets/tab_focus_traversal.dart';

/// Where Ask Astryx is in the desktop Help panel (4.0): its own row at the top
/// with the Preview label, a level of the panel, and "Open a ticket with this"
/// landing on the filled-in support form inside the same panel, whose Back
/// returns to the conversation.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    forgetContactSupportDraft();
  });

  Widget harness(HelpPage page) {
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/assistant/status')) {
        return http.Response(
            jsonEncode({'preview': true, 'available': true, 'reason': null, 'daily_limit': 10, 'left_today': 10}), 200);
      }
      return http.Response(
          jsonEncode({
            'status': 'ok',
            'answer': 'Use Compatibility mode on the host.',
            'sources': ['https://docs.zestssh.com/features/compatibility/'],
            'model': 'sonnet',
            'escalated': true,
            'left_today': 9,
            'daily_limit': 10,
          }),
          200);
    });
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        helpDockProvider.overrideWith((_) => page),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
        appVersionLabelProvider.overrideWith((_) async => '4.0.0'),
        assistantServiceProvider.overrideWithValue(
            AssistantService(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'tok')),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => TabMovesFocus(child: child!),
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: SizedBox()),
              HelpDock(
                captureScreenshot: ({required bool redacted}) async => Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]),
                onCopyRedactedScreenshot: () {},
                onOpenShortcuts: () {},
                onAbout: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('Help has an Ask Astryx row with the Preview label, above the common questions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness(HelpPage.home));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('help-ask-astryx'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.byType(AstryxPreviewBadge)), findsOneWidget);
    expect(find.text(en.astryxRowSub), findsOneWidget);
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.text(en.helpFaqImport)).dy));
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(AskAstryxScreen), findsOneWidget);
    expect(find.text(en.astryxLeftToday(10, 10)), findsOneWidget);
  });

  testWidgets('"Open a ticket with this" opens the filled-in form in the panel; Back returns', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness(HelpPage.askAstryx));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'my NAS refuses SSH');
    await tester.tap(find.byKey(const ValueKey('astryx-ask')));
    await tester.pumpAndSettle();
    expect(find.text(en.astryxAnsweredBy('Claude Sonnet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('astryx-open-ticket')));
    await tester.pumpAndSettle();
    expect(find.byType(ContactSupportScreen), findsOneWidget);
    expect(find.text(en.astryxTicketFilledIn), findsOneWidget);
    expect(find.text('my NAS refuses SSH'), findsWidgets);
    await tester.tap(find.bySemanticsLabel(en.back).first);
    await tester.pumpAndSettle();
    expect(find.byType(AskAstryxScreen), findsOneWidget);
  });

  // A build made without ZEST_OFFICIAL=true: no account service,
  // docs site or Discord, so the panel offers none of what needs them.
  testWidgets('a community build: the Help panel has no Ask Astryx, no questions into the docs, no tickets, '
      'Support Hub or Discord, and no search of the guides; recording mode and the shortcuts stay', (tester) async {
    debugZestOfficial = false;
    addTearDown(() => debugZestOfficial = true);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness(HelpPage.home));
    await tester.pumpAndSettle();
    for (final key in const ['help-ask-astryx', 'help-open-hub', 'help-my-tickets', 'help-ideas']) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    for (final words in [en.helpFaqImport, en.helpFaqKeyRejected, en.helpDiscord, en.helpAllDocs, en.guidesSearchHint]) {
      expect(find.text(words), findsNothing, reason: words);
    }
    expect(find.text(en.recModeName), findsOneWidget);
    expect(find.text(en.helpShortcuts), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
