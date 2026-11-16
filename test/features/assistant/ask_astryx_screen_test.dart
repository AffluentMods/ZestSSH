import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/assistant/assistant_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/help/ask_astryx_screen.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../../a11y/a11y_checks.dart';

/// Ask Astryx in Help (4.0): what the panel shows for each answer of ZestSSH
/// Cloud, that what goes is the redacted question the person saw, that a
/// screenshot is the redacted capture, that an answer brings its doc links and
/// can be carried into a private ticket, and the accessibility pass. A stand-in
/// server; nothing leaves the test.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final png = Uint8List.fromList(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
    forgetContactSupportDraft();
  });

  Map<String, dynamic> statusBody({bool available = true, String? reason, int left = 8}) => {
        'preview': true,
        'available': available,
        'reason': reason,
        'daily_limit': 10,
        'left_today': left,
        'resets_at': '2026-11-14T00:00:00.000Z',
        'cap_resets_at': reason == 'cap_reached' ? '2026-12-01T00:00:00.000Z' : null,
        'limits': {'question_max': 4000, 'history_max': 6, 'images_max': 3, 'image_max_bytes': 2621440},
      };

  final answerBody = {
    'status': 'ok',
    'answer': '**Connection refused** means nothing listens on port 22.\n\n1. Turn SSH on in the NAS settings.\n2. Try Compatibility mode.',
    'sources': ['https://docs.zestssh.com/troubleshooting/connection-errors/'],
    'model': 'haiku',
    'escalated': false,
    'removed_secrets': <String>[],
    'left_today': 7,
    'daily_limit': 10,
    'preview': true,
  };

  /// The panel against a stand-in server; [asked] collects what POST /ask got.
  Future<List<Map<String, dynamic>>> pump(
    WidgetTester tester, {
    Map<String, dynamic>? status,
    http.Response Function(Map<String, dynamic> body)? onAsk,
    String? token = 'tok',
    bool screenshots = true,
    VoidCallback? onOpenTicket,
    Size size = const Size(420, 900),
  }) async {
    final asked = <Map<String, dynamic>>[];
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/assistant/status')) {
        return http.Response(jsonEncode(status ?? statusBody()), 200);
      }
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      asked.add(body);
      return onAsk?.call(body) ?? http.Response(jsonEncode(answerBody), 200);
    });
    final service = AssistantService(client: client, baseUrl: 'https://api.test/v1', bearer: () async => token);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        assistantServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: AskAstryxScreen(
            embedded: true,
            captureScreenshot: screenshots ? ({required bool redacted}) async => redacted ? png : null : null,
            onOpenTicket: onOpenTicket ?? () {},
            onSearchGuides: () {},
            onContactSupport: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return asked;
  }

  Future<void> ask(WidgetTester tester, String question) async {
    await tester.enterText(find.byType(TextField).first, question);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('astryx-ask')));
    await tester.pumpAndSettle();
  }

  testWidgets('a paid account sees how many are left, the privacy line and the field', (tester) async {
    await pump(tester);
    expect(find.text(en.astryxLeftToday(8, 10)), findsOneWidget);
    expect(find.text(en.astryxIntro), findsOneWidget);
    expect(find.text(en.astryxPrivacy), findsOneWidget);
    expect(find.text(en.astryxAttach), findsOneWidget);
    expect(find.byKey(const ValueKey('astryx-ask')), findsOneWidget);
  });

  testWidgets('what is sent is shown before it goes, redacted, and is exactly what goes', (tester) async {
    final asked = await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'sync fails, password=hunter22 on deploy@192.168.10.40');
    await tester.pump();
    await tester.tap(find.text(en.feedbackWhatIsSent));
    await tester.pumpAndSettle();
    final preview = tester.widget<SelectableText>(
        find.descendant(of: find.byKey(const ValueKey('astryx-payload')), matching: find.byType(SelectableText)));
    final shown = preview.data!;
    expect(shown, isNot(contains('hunter22')));
    expect(shown, isNot(contains('192.168.10.40')));
    expect(shown, contains('sync fails'));
    await tester.tap(find.byKey(const ValueKey('astryx-ask')));
    await tester.pumpAndSettle();
    expect(asked.single['question'], isNot(contains('hunter22')));
    expect(shown, contains(asked.single['question'] as String));
  });

  testWidgets('the question field is masked in recording mode', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, 'web-01 refuses me');
    final container = ProviderScope.containerOf(tester.element(find.byType(AskAstryxScreen)));
    container.read(recordingModeProvider.notifier).state = true;
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect((field.controller! as dynamic).masked as bool, isTrue);
    container.read(recordingModeProvider.notifier).state = false;
    await tester.pumpAndSettle();
  });

  testWidgets('a screenshot is the redacted capture, shown, and goes as base64', (tester) async {
    final asked = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('astryx-attach')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('astryx-screenshot')), findsOneWidget);
    expect(find.text(en.feedbackAttachRedacted), findsOneWidget);
    await ask(tester, 'what does this error mean?');
    final images = asked.single['images'] as List;
    expect(base64Decode((images.single as Map)['data'] as String), png);
  });

  testWidgets('a phone takes no screenshot and says to type the error', (tester) async {
    await pump(tester, screenshots: false);
    expect(find.byKey(const ValueKey('astryx-attach')), findsNothing);
    expect(find.text(en.astryxPhoneNoScreenshot), findsOneWidget);
  });

  testWidgets('an answer shows who wrote it, its doc links, the new count, and the ticket handoff', (tester) async {
    await pump(tester);
    await ask(tester, 'backups to my NAS stopped, connection refused');
    expect(find.byKey(const ValueKey('astryx-answer')), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsWidgets);
    expect(find.text(en.astryxAnsweredBy('Claude Haiku')), findsOneWidget);
    expect(find.text('Connection errors'), findsOneWidget);
    expect(find.text(en.astryxLeftToday(7, 10)), findsOneWidget);
    expect(find.byKey(const ValueKey('astryx-open-ticket')), findsOneWidget);
    // The follow-up field takes the next question.
    expect(find.text(en.astryxFollowUpHint), findsOneWidget);
  });

  testWidgets('a follow-up sends the earlier turn with it', (tester) async {
    final asked = await pump(tester);
    await ask(tester, 'first question');
    await tester.enterText(find.byType(TextField).last, 'and then?');
    await tester.tap(find.byKey(const ValueKey('astryx-ask')));
    await tester.pumpAndSettle();
    final history = asked.last['history'] as List;
    expect(history, hasLength(2));
    expect((history.first as Map)['content'], 'first question');
    expect((history.last as Map)['role'], 'assistant');
  });

  testWidgets('"Open a ticket with this" fills a private support ticket with the question and the answer', (tester) async {
    var opened = 0;
    await pump(tester, onOpenTicket: () => opened++);
    await ask(tester, 'backups to my NAS stopped');
    await tester.tap(find.byKey(const ValueKey('astryx-open-ticket')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    // The support form opens filled in, and says so.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: ContactSupportScreen(embedded: true, onDone: (_) {})),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(en.astryxTicketFilledIn), findsOneWidget);
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].controller!.text, 'backups to my NAS stopped');
    final message = fields[1].controller!.text;
    expect(message, startsWith('backups to my NAS stopped'));
    expect(message, contains(en.astryxTicketAnswerHeading('Claude Haiku')));
    expect(message, contains('Connection refused'));
    expect(message, contains(en.astryxTicketTriedHeading));
  });

  group('when it cannot answer', () {
    testWidgets('not signed in: sign in, nothing asked', (tester) async {
      final asked = await pump(tester, token: null);
      expect(find.text(en.astryxSignInTitle), findsOneWidget);
      expect(find.text(en.profileSignIn), findsOneWidget);
      expect(find.byKey(const ValueKey('astryx-ask')), findsNothing);
      expect(asked, isEmpty);
    });

    testWidgets('a free account: who it is for, no price, guides and support', (tester) async {
      await pump(tester, status: statusBody(available: false, reason: 'free'));
      expect(find.text(en.astryxPaidTitle), findsOneWidget);
      expect(find.text(en.guidesSearchHint), findsOneWidget);
      expect(find.text(en.helpContactSupport), findsOneWidget);
      expect(find.textContaining(r'$'), findsNothing);
      expect(find.byKey(const ValueKey('astryx-ask')), findsNothing);
    });

    testWidgets('today\'s questions used, the month\'s cap, switched off: each with its code', (tester) async {
      for (final (reason, title, code) in [
        ('daily_limit', en.astryxLimitTitle, 'ZS-1964'),
        ('cap_reached', en.astryxCapTitle, 'ZS-1965'),
        ('off', en.astryxOffTitle, 'ZS-1962'),
        ('plan_unknown', en.astryxPlanUnknownTitle, 'ZS-1967'),
      ]) {
        await pump(tester, status: statusBody(available: false, reason: reason, left: 0));
        expect(find.text(title), findsOneWidget, reason: reason);
        expect(find.textContaining(code), findsOneWidget, reason: reason);
        expect(find.byKey(const ValueKey('astryx-ask')), findsNothing, reason: reason);
      }
    });

    testWidgets('ZestSSH Cloud not responding: SSH unaffected, Try again, Copy details', (tester) async {
      await pump(tester, onAsk: (_) => http.Response('bad gateway', 503));
      await ask(tester, 'q');
      expect(find.text(en.astryxCloudTitle), findsOneWidget);
      expect(find.textContaining('ZS-110'), findsOneWidget);
      expect(find.text(en.astryxTryAgain), findsOneWidget);
      // The question stays in the box to ask again.
      expect(find.text('q'), findsOneWidget);
    });

    testWidgets('Astryx not answering: ZS-1966, Try again, or a ticket', (tester) async {
      await pump(tester,
          onAsk: (_) => http.Response(jsonEncode({'error': 'x', 'code': 'assistant-timeout'}), 504));
      await ask(tester, 'why does sync stall?');
      expect(find.text(en.astryxNotAnsweringTitle), findsOneWidget);
      expect(find.textContaining('ZS-1966'), findsOneWidget);
      expect(find.text(en.astryxOpenTicket), findsOneWidget);
    });

    testWidgets('the docs Astryx found when no model answered', (tester) async {
      await pump(tester,
          onAsk: (_) => http.Response(
              jsonEncode({
                'status': 'degraded',
                'answer': '',
                'docs': [
                  {'title': 'Compatibility mode', 'url': 'https://docs.zestssh.com/features/compatibility/', 'text': 'x'},
                ],
                'left_today': 8,
              }),
              200));
      await ask(tester, 'cannot connect');
      expect(find.text(en.astryxDocsInstead), findsNothing); // said with its code
      expect(find.textContaining(en.astryxDocsInstead), findsOneWidget);
      expect(find.text('Compatibility mode'), findsOneWidget);
      expect(find.text(en.astryxLeftToday(8, 10)), findsOneWidget);
    });

    testWidgets('a removed secret and a secret in the screenshot are told plainly', (tester) async {
      await pump(tester,
          onAsk: (_) => http.Response(
              jsonEncode({
                ...answerBody,
                'removed_secrets': ['password'],
                'images': {'read': true, 'note': '', 'refused': <String>[], 'secrets': ['private key']},
              }),
              200));
      await ask(tester, 'help');
      expect(find.text(en.astryxRemovedSecrets('password')), findsOneWidget);
      expect(find.text(en.astryxImageSecrets('private key')), findsOneWidget);
    });

    testWidgets('the daily limit reached while asking stops the field', (tester) async {
      await pump(tester,
          onAsk: (_) => http.Response(jsonEncode({'error': 'x', 'code': 'assistant-daily-limit'}), 429));
      await ask(tester, 'q');
      expect(find.text(en.astryxLimitTitle), findsOneWidget);
      expect(find.text(en.astryxLeftToday(0, 10)), findsOneWidget);
    });
  });

  group('accessibility', () {
    testWidgets('on a computer: names, 32 targets, contrast', (tester) async {
      await pump(tester);
      await expectA11y(tester, computer: true, where: 'Ask Astryx, before asking');
      await ask(tester, 'backups to my NAS stopped');
      await expectA11y(tester, computer: true, where: 'Ask Astryx, an answer');
    });

    testWidgets('on a phone: names, 48 targets, contrast', (tester) async {
      debugTouchLayout = true;
      try {
        await pump(tester, screenshots: false, size: const Size(390, 844));
        await expectA11y(tester, computer: false, where: 'Ask Astryx on a phone');
        await ask(tester, 'backups to my NAS stopped');
        await expectA11y(tester, computer: false, where: 'Ask Astryx on a phone, an answer');
      } finally {
        debugTouchLayout = null;
      }
    });

    testWidgets('the states read well too', (tester) async {
      await pump(tester, status: statusBody(available: false, reason: 'free'));
      await expectA11y(tester, computer: true, where: 'Ask Astryx, free account');
      await pump(tester, token: null);
      await expectA11y(tester, computer: true, where: 'Ask Astryx, signed out');
    });
  });
}
