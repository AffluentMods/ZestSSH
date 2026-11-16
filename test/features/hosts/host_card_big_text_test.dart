import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/features/hosts/models/host_card_settings.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';

import '../../visual/shots_util.dart';

/// A host's card at a larger text size (3.0): each card had
/// the height of its density whatever the text size, so at a size a person's
/// computer can be set to (1.25 times) its second line was cut off, by 9
/// pixels on a computer's Hosts page. Now it grows by as much as its two
/// lines grow, and at the size the app is drawn at it keeps its height. And a
/// compact card cut its second line off by 5 pixels at that size too: it has
/// less room above and below its lines.
void main() {
  Future<void> show(WidgetTester tester, HostCardDensity density, double scale) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({
      'host_card_settings': jsonEncode(HostCardSettings(density: density).toJson()),
    });
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: HostCard(
                data: HostCardData(
                  id: 'h1',
                  name: 'web-01',
                  subtitle: 'deploy@192.0.2.10',
                  osId: null,
                  status: HostStatus.offline,
                  hasActiveSession: false,
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  for (final density in HostCardDensity.values) {
    for (final scale in [1.25, 1.5, 2.0]) {
      testWidgets('${density.name}, text at $scale times: both lines are shown whole', (tester) async {
        await show(tester, density, scale);
        expect(tester.takeException(), isNull, reason: 'nothing is cut off');
        expect(find.text('web-01'), findsOneWidget);
        expect(find.text('deploy@192.0.2.10'), findsOneWidget);
      });
    }

    testWidgets('${density.name}, text as the app draws it: the card is as tall as before', (tester) async {
      await show(tester, density, 1);
      expect(tester.takeException(), isNull);
      final box = find.descendant(
          of: find.byType(HostCard),
          matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == density.cardHeight));
      expect(box, findsOneWidget, reason: "the card's own box has the density's height");
    });
  }

  test('the height at no scaling is the density\'s own, and it grows with the text', () {
    for (final density in HostCardDensity.values) {
      expect(density.heightFor(TextScaler.noScaling), density.cardHeight);
      expect(density.heightFor(const TextScaler.linear(1.5)), greaterThan(density.cardHeight));
    }
  });
}
