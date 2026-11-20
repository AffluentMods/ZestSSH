import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/assistant/assistant_region.dart';
import 'package:zestssh/features/assistant/assistant_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/ask_astryx_screen.dart';

/// Ask Astryx where it is not offered (4.0.1): an iPhone or iPad whose App Store account is in
/// mainland China. Nothing is asked of ZestSSH Cloud, the screen says so plainly, and the Help
/// panel has no way in. Everywhere else (and on every device that is not an App Store one) it is
/// as before.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test('offered everywhere but a mainland China App Store account', () {
    for (final c in ['CHN', 'chn', 'CN', ' CHN ']) {
      expect(assistantOfferedIn(c), isFalse, reason: c);
    }
    for (final c in [null, '', 'USA', 'HKG', 'TWN', 'MAC', 'SGP', 'DEU']) {
      expect(assistantOfferedIn(c), isTrue, reason: '$c');
    }
  });

  test('a computer or an Android phone has no App Store country', () async {
    expect(await appStoreCountry(), isNull);
  });

  group('the service with a mainland China App Store account', () {
    var calls = 0;
    late AssistantService service;
    setUp(() {
      calls = 0;
      service = AssistantService(
        client: MockClient((r) async {
          calls++;
          return http.Response('{}', 500);
        }),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'tok',
        storeCountry: () async => 'CHN',
      );
    });

    test('status: not available, the region block, and nothing sent', () async {
      final s = await service.status();
      expect(s.available, isFalse);
      expect(s.block, AssistantBlock.region);
      expect(calls, 0);
    });

    test('ask: refused with the region block, and nothing sent', () async {
      await expectLater(
        service.ask(question: 'how do I add a key?'),
        throwsA(isA<AssistantFailure>()
            .having((f) => f.kind, 'kind', AssistantFailureKind.blocked)
            .having((f) => f.block, 'block', AssistantBlock.region)),
      );
      expect(calls, 0);
    });
  });

  group('the Help panel', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Widget harness({required bool offered, HelpPage page = HelpPage.home}) => ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            helpDockProvider.overrideWith((_) => page),
            cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
            appVersionLabelProvider.overrideWith((_) async => '4.0.1'),
            appStoreCountryProvider.overrideWith((_) async => offered ? 'USA' : 'CHN'),
            assistantServiceProvider.overrideWithValue(AssistantService(
              client: MockClient((r) async => http.Response('{}', 500)),
              baseUrl: 'https://api.test/v1',
              bearer: () async => 'tok',
              storeCountry: () async => offered ? 'USA' : 'CHN',
            )),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: Row(
                children: [
                  const Expanded(child: SizedBox()),
                  HelpDock(
                    captureScreenshot: ({required bool redacted}) async => Uint8List.fromList(const [0x89, 0x50]),
                    onCopyRedactedScreenshot: () {},
                    onOpenShortcuts: () {},
                    onAbout: () {},
                  ),
                ],
              ),
            ),
          ),
        );

    testWidgets('no Ask Astryx row for a mainland China App Store account; the rest of Help stays',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(harness(offered: false));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('help-ask-astryx')), findsNothing);
      expect(find.text(en.astryxRowSub), findsNothing);
      expect(find.text(en.helpFaqImport), findsOneWidget);
      expect(find.text(en.helpShortcuts), findsOneWidget);
    });

    testWidgets('the row is there for any other account', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(harness(offered: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('help-ask-astryx')), findsOneWidget);
    });

    testWidgets('reached anyway (a link kept from before), the screen says it is not offered here',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(harness(offered: false, page: HelpPage.askAstryx));
      await tester.pumpAndSettle();
      expect(find.byType(AskAstryxScreen), findsOneWidget);
      expect(find.text(en.astryxRegionTitle), findsWidgets);
      expect(find.text(en.astryxRegionBody), findsOneWidget);
      expect(find.byKey(const ValueKey('astryx-ask')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
