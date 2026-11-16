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

/// One host card (4.0: a card carried a
/// stripe, its tags, a sessions badge, a health badge and a green dot at
/// once): its OS tile, its name and its address, and at its right at most two
/// quiet signals, "Open" or "2 open" while it has sessions and one health
/// chip only where a limit is crossed. The stripe and the tags are off by
/// default; their settings bring them back.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const ram = HostHealthChip(label: 'RAM 97%', critical: true, tooltip: 'Memory is 97% used, past 90%');
  const cpu = HostHealthChip(label: 'CPU 88%', critical: false, tooltip: 'CPU is 88%, past 80%');

  Future<void> show(
    WidgetTester tester, {
    int openSessions = 0,
    List<HostHealthChip> health = const [],
    List<String> tags = const [],
    int tmux = 0,
    bool keyChanged = false,
    Color? groupColor,
    HostCardSettings? settings,
    double width = 320,
    double scale = 1,
  }) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({
      if (settings != null) 'host_card_settings': jsonEncode(settings.toJson()),
    });
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
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: HostCard(
                data: HostCardData(
                  id: 'h1',
                  name: 'web-01',
                  subtitle: 'root@192.168.10.21',
                  osId: 'ubuntu',
                  status: openSessions > 0 ? HostStatus.online : HostStatus.offline,
                  hasActiveSession: openSessions > 0,
                  openSessions: openSessions,
                  healthChips: health,
                  tags: tags,
                  tmuxSessions: tmux,
                  hasChangedHostKey: keyChanged,
                  groupColor: groupColor,
                  groupName: groupColor == null ? null : 'Web',
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: 'nothing runs over');
  }

  final open = find.byKey(const ValueKey('host-card-open-h1'));
  final healthChip = find.byKey(const ValueKey('host-card-health-h1'));
  final keyChip = find.byKey(const ValueKey('host-card-key-changed-h1'));

  testWidgets('a host with no session and no warning: its tile, its name and its address, and nothing else',
      (tester) async {
    await show(tester);
    expect(find.text('web-01'), findsOneWidget);
    expect(find.text('root@192.168.10.21'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-card-signals-h1')), findsNothing);
  });

  testWidgets('one session says Open, two say 2 open, in words with a dot, at the right', (tester) async {
    await show(tester, openSessions: 1);
    expect(find.descendant(of: open, matching: find.text(en.phoneHostsOpen)), findsOneWidget);
    final card = tester.getRect(find.byType(HostCard));
    expect(tester.getRect(open).right, greaterThan(card.right - 40), reason: 'at its right');
    await show(tester, openSessions: 2);
    expect(find.descendant(of: open, matching: find.text(en.hostOpenSessionsCount(2))), findsOneWidget);
    expect(en.hostOpenSessionsCount(2), '2 open');
  });

  testWidgets('one health chip, the worst, whose tooltip says each; under Open where both are', (tester) async {
    await show(tester, openSessions: 2, health: const [ram, cpu]);
    expect(find.descendant(of: healthChip, matching: find.text('RAM 97%')), findsOneWidget);
    expect(find.text('CPU 88%'), findsNothing, reason: 'one chip only');
    final tip = tester.widget<Tooltip>(find.descendant(of: healthChip, matching: find.byType(Tooltip)).first);
    expect(tip.message, '${ram.tooltip}\n${cpu.tooltip}');
    expect(tester.getRect(healthChip).top, greaterThan(tester.getRect(open).bottom - 1), reason: 'one above the other');
    expect(worstHealthChip(const [cpu]), cpu);
  });

  testWidgets('a changed host key takes the chip\'s place, in words', (tester) async {
    await show(tester, health: const [ram], keyChanged: true);
    expect(find.descendant(of: keyChip, matching: find.text(en.hostKeyChangedTitle)), findsOneWidget);
    expect(healthChip, findsNothing);
  });

  testWidgets('no stripe and no tags by default; their settings bring each back', (tester) async {
    await show(tester, tags: const ['prod', 'nginx'], groupColor: const Color(0xFF4FAE78));
    expect(find.byKey(const ValueKey('host-card-rail')), findsNothing);
    expect(find.text('prod'), findsNothing);
    await show(tester,
        tags: const ['prod', 'nginx'],
        groupColor: const Color(0xFF4FAE78),
        settings: const HostCardSettings(accentMode: HostCardAccentMode.group, showTags: true));
    expect(find.byKey(const ValueKey('host-card-rail')), findsOneWidget);
    expect(find.text('prod'), findsOneWidget);
  });

  testWidgets('Show status pill off: the card does not say it is open; its health it still says', (tester) async {
    await show(tester, openSessions: 1, health: const [ram], settings: const HostCardSettings(showStatusPill: false));
    expect(open, findsNothing);
    expect(healthChip, findsOneWidget);
  });

  testWidgets('the tmux badge is not on the card (the list view and the panel have it)', (tester) async {
    await show(tester, tmux: 2);
    expect(find.byType(TmuxSessionsBadge), findsNothing);
  });

  for (final (width, scale) in [(220.0, 1.0), (320.0, 2.0), (260.0, 1.5)]) {
    testWidgets('both signals in a card $width wide at $scale times the text: nothing runs over', (tester) async {
      await show(tester, openSessions: 12, health: const [ram], width: width, scale: scale);
      expect(open, findsOneWidget);
      expect(healthChip, findsOneWidget);
      final card = tester.getRect(find.byType(HostCard));
      expect(card.contains(tester.getRect(healthChip).bottomRight - const Offset(1, 1)), isTrue);
    });
  }

  group('the settings (4.0 defaults)', () {
    test('no stripe and no tags; the rest as before', () {
      const s = HostCardSettings();
      expect(s.accentMode, HostCardAccentMode.none);
      expect(s.showTags, isFalse);
      expect(s.showStatusPill, isTrue);
      expect(s.showOsIcon, isTrue);
      expect(s.showSubtitle, isTrue);
      expect(s.showHoverEdit, isTrue);
      expect(s.density, HostCardDensity.comfortable);
      expect(s.columns, HostCardColumns.auto);
    });

    test("an older app's settings: its default stripe takes the new default, a stripe chosen stays", () {
      // As an app before 4.0 wrote them: every field, its own default stripe
      // among them, after a change of density.
      Map<String, dynamic> old(String accent) => {
            'density': 'spacious',
            'columns': 'auto',
            'accentMode': accent,
            'showStatusPill': true,
            'showOsIcon': true,
            'showSubtitle': true,
            'showHoverEdit': true,
          };
      final fromOld = HostCardSettings.fromJson(old('group'));
      expect(fromOld.accentMode, HostCardAccentMode.none);
      expect(fromOld.density, HostCardDensity.spacious, reason: 'what was chosen stays');
      expect(fromOld.showTags, isFalse);
      expect(HostCardSettings.fromJson(old('uniform')).accentMode, HostCardAccentMode.uniform);
      expect(HostCardSettings.fromJson(old('none')).accentMode, HostCardAccentMode.none);
      // Chosen in this version: kept.
      const chosen = HostCardSettings(accentMode: HostCardAccentMode.group, showTags: true);
      expect(HostCardSettings.fromJson(chosen.toJson()), chosen);
      expect(chosen.toJson()['v'], HostCardSettings.version);
    });
  });
}
