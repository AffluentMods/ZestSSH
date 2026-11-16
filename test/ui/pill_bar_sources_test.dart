import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/tab_sources.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';

SessionState _state(String label) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$label',
      connectionLabel: label,
      host: '10.50.0.5',
      port: 22,
      username: 'deploy',
    );

/// Where a tab's host comes from, under its name:
/// "Acme · Production" for a team's vault, "Personal" for your own,
/// only while the open tabs come from more than one place; otherwise the
/// name alone, as before.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(WidgetTester tester, Map<String, TabSource?> sources,
      {TabSourceMode mode = TabSourceMode.auto, bool vault = true, bool group = true, int acmeVaults = 0}) async {
    tester.view.physicalSize = const Size(1600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
        orchardSummariesProvider.overrideWith((ref) async => [
              OrchardSummary(
                id: 'o1',
                name: 'Acme',
                role: 'owner',
                crates: [
                  for (var i = 0; i < acmeVaults; i++) CrateSummary(id: 'v$i', name: 'Vault $i', level: 'manage'),
                ],
                defaultCrateId: null,
              ),
            ]),
        tabSourceProvider.overrideWith((ref, connectionId) async => sources[connectionId]),
        tabSourceModeProvider.overrideWith((ref) => mode),
        tabSourceVaultProvider.overrideWith((ref) => vault),
        tabSourceGroupProvider.overrideWith((ref) => group),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PillBar(
              activeNav: NavSection.hosts,
              activeSessionId: 't1',
              sessions: [
                MapEntry('t1', _state('web-01')),
                MapEntry('t2', _state('db-01')),
              ],
              onNavChanged: (_) {},
              onSessionSelected: (_) {},
              onSessionClosed: (_) {},
              onNewSession: () {},
              onCommandPalette: () {},
              onHelp: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('tabs from a team vault and from Personal: each says where it comes from, under its name',
      (tester) async {
    await pump(tester, {
      'c-web-01': (orchardId: 'o1', vaultName: 'Prod', groupName: null),
      'c-db-01': (orchardId: null, vaultName: null, groupName: null),
    });
    expect(find.byKey(const ValueKey('tab-source-t1')), findsOneWidget);
    expect(find.text('Acme · Prod'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('tab-source-t2')), matching: find.text(l10n.treeSelectorPersonal)),
        findsOneWidget, reason: 'the space switcher says Personal too: this is the tab');
    // The name sits above where it comes from.
    expect(tester.getTopLeft(find.text('web-01')).dy, lessThan(tester.getTopLeft(find.text('Acme · Prod')).dy));
  }, skip: !kOrchardsEnabled);

  testWidgets('a personal host says its group; a long name is cut in the middle, both ends kept', (tester) async {
    await pump(tester, {
      'c-web-01': (orchardId: 'o1', vaultName: 'A vault with a really long name for its team', groupName: 'Databases'),
      'c-db-01': (orchardId: null, vaultName: null, groupName: 'Web'),
    });
    final team = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey('tab-source-t1')), matching: find.byType(Text))).data!;
    expect(team, startsWith('Acme'));
    expect(team, contains('\u2026'));
    expect(team, endsWith('ases'), reason: 'team, vault and group: the middle goes, both ends stay');
    final personal = tester.widget<Text>(
        find.descendant(of: find.byKey(const ValueKey('tab-source-t2')), matching: find.byType(Text))).data!;
    expect(personal, '${l10n.treeSelectorPersonal} · Web');
  }, skip: !kOrchardsEnabled);

  // Settings: when the line shows, and whether
  // the vault and the group are in it.
  final mixed = <String, TabSource?>{
    'c-web-01': (orchardId: 'o1', vaultName: 'Prod', groupName: 'DB'),
    'c-db-01': (orchardId: null, vaultName: null, groupName: 'Web'),
  };
  String? line(WidgetTester tester, String tab) {
    final f = find.descendant(of: find.byKey(ValueKey('tab-source-$tab')), matching: find.byType(Text));
    return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
  }

  testWidgets('Off: no line, however many places', (tester) async {
    await pump(tester, mixed, mode: TabSourceMode.off);
    expect(line(tester, 't1'), isNull);
    expect(line(tester, 't2'), isNull);
  }, skip: !kOrchardsEnabled);

  testWidgets('Always: the line on tabs all from one place too', (tester) async {
    await pump(tester, {
      'c-web-01': (orchardId: null, vaultName: null, groupName: null),
      'c-db-01': (orchardId: null, vaultName: null, groupName: null),
    }, mode: TabSourceMode.always);
    expect(line(tester, 't1'), l10n.treeSelectorPersonal);
  }, skip: !kOrchardsEnabled);

  testWidgets('the Vault and Group switches leave those parts out', (tester) async {
    await pump(tester, mixed, vault: false);
    expect(line(tester, 't1'), 'Acme \u00b7 DB');
    await tester.pumpWidget(const SizedBox());
    await pump(tester, mixed, group: false);
    expect(line(tester, 't1'), 'Acme \u00b7 Prod');
    expect(line(tester, 't2'), l10n.treeSelectorPersonal);
  }, skip: !kOrchardsEnabled);

  testWidgets('Automatic leaves out the vault of a team where you open only one; Always keeps it', (tester) async {
    await pump(tester, mixed, acmeVaults: 1);
    expect(line(tester, 't1'), 'Acme \u00b7 DB');
    await tester.pumpWidget(const SizedBox());
    await pump(tester, mixed, acmeVaults: 2);
    expect(line(tester, 't1'), 'Acme \u00b7 Prod \u00b7 DB');
    await tester.pumpWidget(const SizedBox());
    await pump(tester, mixed, acmeVaults: 1, mode: TabSourceMode.always);
    expect(line(tester, 't1'), 'Acme \u00b7 Prod \u00b7 DB');
  }, skip: !kOrchardsEnabled);

  testWidgets('tabs all from the same place: the name alone, in the middle', (tester) async {
    await pump(tester, {
      // Personal both, from two groups: still one place.
      'c-web-01': (orchardId: null, vaultName: null, groupName: 'Web'),
      'c-db-01': (orchardId: null, vaultName: null, groupName: 'Databases'),
    });
    expect(find.byKey(const ValueKey('tab-source-t1')), findsNothing);
    expect(find.byKey(const ValueKey('tab-source-t2')), findsNothing);
    final tab = tester.getRect(find.byKey(const ValueKey('t1')));
    final name = tester.getRect(find.text('web-01'));
    expect((name.center.dy - tab.center.dy).abs(), lessThan(2), reason: 'centred as before');
  });
}
