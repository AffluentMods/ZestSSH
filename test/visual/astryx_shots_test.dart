import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/assistant/assistant_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/ask_astryx_screen.dart';

import 'shots_util.dart';

/// Ask Astryx (4.0), as pictures to hold against its design mockup:
///   flutter test --no-pub --dart-define=ZEST_SHOTS=true test/visual/astryx_shots_test.dart
/// Pictures land in build/shots/astryx_*. Everything on them is made up.
void main() {
  // A one-pixel PNG drawn wide stands in for the redacted capture.
  final png = Uint8List.fromList(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));

  Map<String, dynamic> status({bool available = true, String? reason, int left = 8}) => {
        'preview': true,
        'available': available,
        'reason': reason,
        'daily_limit': 10,
        'left_today': left,
        'limits': {'question_max': 4000, 'images_max': 3, 'image_max_bytes': 2621440},
      };

  final answer = {
    'status': 'ok',
    'answer': '**Connection refused** means the NAS answered but nothing is listening on port 22. Check these in order:\n\n'
        '1. SSH is turned on in the NAS settings (many NAS systems turn it off after an update).\n'
        '2. The port: some NAS use `2222`. Set it under the host\'s **Port**.\n'
        '3. If it still fails, try **Compatibility mode** on the host.',
    'sources': [
      'https://docs.zestssh.com/troubleshooting/connection-errors/',
      'https://docs.zestssh.com/features/compatibility-mode/',
    ],
    'model': 'haiku',
    'escalated': false,
    'left_today': 7,
    'daily_limit': 10,
    'images': {'read': true, 'note': '', 'refused': <String>[], 'secrets': <String>[]},
  };

  Future<GlobalKey> desktop(WidgetTester tester, Map<String, dynamic> st, {HelpPage page = HelpPage.askAstryx}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite'});
    final prefs = await SharedPreferences.getInstance();
    AppColors.applyTheme(BuiltInThemes.getById('graphite').colorScheme);
    final client = MockClient((r) async => r.url.path.endsWith('/status')
        ? http.Response(jsonEncode(st), 200)
        : http.Response(jsonEncode(answer), 200));
    final key = GlobalKey();
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        helpDockProvider.overrideWith((_) => page),
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
        appVersionLabelProvider.overrideWith((_) async => '4.0.0'),
        assistantServiceProvider.overrideWithValue(
            AssistantService(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'tok')),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById('graphite').toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            backgroundColor: AppColors.v3Background,
            body: Row(children: [
              const Expanded(child: SizedBox()),
              HelpDock(
                captureScreenshot: ({required bool redacted}) async => png,
                onCopyRedactedScreenshot: () {},
                onOpenShortcuts: () {},
                onAbout: () {},
              ),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('the Help panel: the row, asking, an answer, a state', (tester) async {
    var key = await desktop(tester, status(), page: HelpPage.home);
    await saveShot(tester, key, 'astryx_1_help_home');

    key = await desktop(tester, status());
    await tester.enterText(find.byType(TextField).first,
        'Backups to my NAS stopped working. The terminal says Connection refused on port 22. What should I check?');
    await tester.tap(find.byKey(const ValueKey('astryx-attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).feedbackWhatIsSent));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'astryx_2_ask');

    await tester.tap(find.byKey(const ValueKey('astryx-ask')));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'astryx_3_answer');

    key = await desktop(tester, status(available: false, reason: 'free'));
    await saveShot(tester, key, 'astryx_4_free');
    key = await desktop(tester, status(available: false, reason: 'daily_limit', left: 0));
    await saveShot(tester, key, 'astryx_5_daily_limit');
    plainShadows();
  }, skip: !shotsEnabled);

  testWidgets('on a phone', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite'});
    final prefs = await SharedPreferences.getInstance();
    AppColors.applyTheme(BuiltInThemes.getById('graphite').colorScheme);
    final client = MockClient((r) async => r.url.path.endsWith('/status')
        ? http.Response(jsonEncode(status()), 200)
        : http.Response(jsonEncode({...answer, 'model': 'sonnet'}), 200));
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        assistantServiceProvider.overrideWithValue(
            AssistantService(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'tok')),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById('graphite').toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: AskAstryxScreen(onOpenTicket: () {}, onSearchGuides: () {}, onContactSupport: () {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'How do I use my YubiKey to sign in to a server from my phone?');
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'astryx_6_phone_ask', pixelRatio: 2);
    await tester.tap(find.byKey(const ValueKey('astryx-ask')));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'astryx_7_phone_answer', pixelRatio: 2);
    plainShadows();
  }, skip: !shotsEnabled);
}
