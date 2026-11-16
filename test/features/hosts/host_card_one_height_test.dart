import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/models/host_card_settings.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';

import '../../visual/shots_util.dart';

/// Every host card is one height, whatever it has (host cards seemed to
/// grow taller at random). A card's health warnings and tags
/// had a line of their own, and the page gave every card of the grid that
/// line the moment any host had one, so all the cards grew when a server's
/// memory ran high and shrank when it came down. Now they ride on the
/// address's line, as many as fit.
void main() {
  Future<double> heightOf(WidgetTester tester,
      {List<HostHealthChip> health = const [],
      List<String> tags = const [],
      Color? groupColor,
      HostCardSettings settings = const HostCardSettings()}) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({'host_card_settings': jsonEncode(settings.toJson())});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      // A new container each time: the settings are read once per container.
      key: UniqueKey(),
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: HostCard(
                data: HostCardData(
                  id: 'h1',
                  name: 'hypervisor-a',
                  subtitle: 'root@192.168.20.11',
                  osId: null,
                  status: HostStatus.offline,
                  hasActiveSession: false,
                  healthChips: health,
                  tags: tags,
                  groupColor: groupColor,
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: 'nothing runs over');
    return tester.getSize(find.byType(HostCard)).height;
  }

  testWidgets('a card with a warning or tags is as tall as one without, and shows them', (tester) async {
    final plain = await heightOf(tester);
    const ram = HostHealthChip(label: 'RAM 72%', critical: false, tooltip: 'Memory is 72% used');
    final warned = await heightOf(tester, health: const [ram]);
    expect(warned, plain);
    expect(find.text('RAM 72%'), findsOneWidget);
    // Tags where Settings has them on cards (off by default since 4.0).
    const withTags = HostCardSettings(showTags: true);
    final tagged = await heightOf(tester, health: const [ram], tags: const ['prod', 'db'], settings: withTags);
    expect(tagged, plain);
    expect(find.byKey(const ValueKey('host-card-chips-h1')), findsOneWidget);
    expect(find.text('prod'), findsOneWidget);
    expect(find.text('root@192.168.20.11'), findsOneWidget, reason: 'the address stays');
  });

  testWidgets("a group's colour is the card's edge where Settings has it: its icon and name stand where a card "
      'without one has them', (tester) async {
    const hostColour = HostCardSettings(accentMode: HostCardAccentMode.group);
    await heightOf(tester, settings: hostColour);
    expect(find.byKey(const ValueKey('host-card-rail')), findsNothing);
    final plain = tester.getTopLeft(find.text('hypervisor-a')).dx;
    await heightOf(tester, groupColor: const Color(0xFF2E9E8F), settings: hostColour);
    expect(find.byKey(const ValueKey('host-card-rail')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('host-card-rail'))).width, 3);
    // They sat 3px further in (found in a design review).
    expect(tester.getTopLeft(find.text('hypervisor-a')).dx, plain);
  });

  testWidgets('by default (4.0) a card in a group with a colour has no stripe', (tester) async {
    await heightOf(tester, groupColor: const Color(0xFF2E9E8F));
    expect(find.byKey(const ValueKey('host-card-rail')), findsNothing);
  });
}
