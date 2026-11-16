import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/engine/network_detector.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/pages/networks_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';

import 'shots_util.dart';

/// Pictures of the computer's Port forwarding page as its design
/// mockup draws it, with the real fonts and made-up hosts and rules:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/forwards_networks_shots_test.dart
///
/// Pictures land in build/shots/. Another language with
/// --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

/// The demo world's hosts and rules (the website's): every name and address
/// is invented.
Future<AppDatabase> _forwardsDb() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final at = DateTime(2026, 10, 1);
  await db.into(db.identities).insert(
      IdentitiesCompanion.insert(id: 'key', label: 'Ops laptop', username: 'deploy', authMethod: 'key', createdAt: at));
  for (final (id, label, address, icon) in [
    ('mon', 'monitoring', '192.168.10.60', 'ubuntu'),
    ('db', 'db-primary', '192.168.10.31', 'debian'),
    ('vpn', 'vpn-gateway', '192.168.10.23', 'alpine'),
    ('web', 'web-01', '192.168.10.21', 'ubuntu'),
  ]) {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: address,
          identityId: const Value('key'),
          iconId: Value(icon),
          createdAt: at,
          updatedAt: at,
        ));
  }
  for (final (id, conn, type, bind, host, port, label, auto) in [
    ('pf-graf', 'mon', 'local', 3000, 'localhost', 3000, 'Grafana', true),
    ('pf-db', 'db', 'local', 5433, 'localhost', 5432, 'Orders database', false),
    ('pf-socks', 'vpn', 'dynamic', 1080, '', 0, 'Browsing proxy', false),
  ]) {
    await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: id,
          connectionId: conn,
          type: type,
          bindPort: bind,
          remoteHost: host,
          remotePort: port,
          label: Value(label),
          autoStart: Value(auto),
          createdAt: at,
        ));
  }
  return db;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('the Port forwarding page, a Remote rule being made ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        L10nGlobal.update(l10n);
        final theme = BuiltInThemes.getById(themeId);
        AppColors.applyTheme(theme.colorScheme);
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = await tester.runAsync(_forwardsDb);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              databaseProvider.overrideWithValue(db!),
              activeForwardIdsProvider.overrideWith((ref) => {'pf-graf'}),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.toThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale(_locale),
              home: const Scaffold(body: PortForwardListView()),
            ),
          ),
        ));
        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        await settle();
        // A Remote rule with real values, as the design notes ask.
        await tester.tap(find.byKey(const ValueKey('pf-intent-remote')));
        await settle();
        await tester.enterText(
            find.descendant(of: find.byKey(const ValueKey('pf-name')), matching: find.byType(EditableText)),
            'Preview build');
        await tester.tap(find.text(l10n.zestPfChooseConnection));
        await settle();
        await tester.tap(find.text('web-01').last);
        await settle();
        await tester.enterText(
            find.descendant(of: find.byKey(const ValueKey('pf-port-here')), matching: find.byType(EditableText)),
            '5173');
        await tester.enterText(
            find.descendant(of: find.byKey(const ValueKey('pf-port-server')), matching: find.byType(EditableText)),
            '8080');
        // Typed last, the field would show its caret and focus ring.
        FocusManager.instance.primaryFocus?.unfocus();
        await settle();
        await saveShot(tester, key, 'forwards_page_$tag');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
        await tester.runAsync(db.close);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('the Networks page, a network for this Wi-Fi being made ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        L10nGlobal.update(l10n);
        final theme = BuiltInThemes.getById(themeId);
        AppColors.applyTheme(theme.colorScheme);
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = (await tester.runAsync(_forwardsDb))!;
        await tester.runAsync(() async {
          final repo = NetworkRepository(db.networksDao);
          await repo.ensureDefaultExists();
          await repo.create(const Network(
              id: 'n-example',
              name: 'Office',
              color: GroupColor.blue,
              icon: LucideIcons.building,
              triggers: [SsidTrigger('Office-WiFi')],
              isFallback: false));
          await repo.create(const Network(
              id: 'n-cell',
              name: 'Cellular',
              color: GroupColor.green,
              icon: LucideIcons.signal,
              triggers: [CellularTrigger()],
              isFallback: false));
          await repo.reorder(['n-example', 'n-cell']);
        });
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final fallback = Network.systemDefault();
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              databaseProvider.overrideWithValue(db),
              // Where this computer is: made up.
              currentNetworkStateProvider.overrideWith((ref) async => const NetworkState(
                  localAddresses: ['10.0.1.37'], connectivityKind: ConnectivityKind.wifi, ssid: 'Cafe-Guest')),
              detectedNetworkProvider.overrideWith((ref) => Stream.value(fallback)),
              detectedNetworkMatchProvider
                  .overrideWith((ref) => Stream.value(NetworkMatch(network: fallback, reason: const AlwaysTrigger()))),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.toThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale(_locale),
              home: const Scaffold(body: NetworksPage()),
            ),
          ),
        ));
        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        await settle();
        await tester.tap(find.byKey(const ValueKey('network-make-for-here')));
        await settle();
        final name = find.descendant(of: find.byType(NetworksPage), matching: find.byType(EditableText)).at(1);
        await tester.enterText(name, 'Coffee shop');
        await tester.tap(find.byKey(const ValueKey('network-look-change')));
        await settle();
        await tester.tap(find.byIcon(LucideIcons.coffee).last);
        await settle();
        await tester.tap(find.text('Close').last);
        await settle();
        await tester.tap(find.byKey(const ValueKey('network-reach-jump')));
        await settle();
        await tester.tap(find.byKey(const ValueKey('network-jump-host')));
        await settle();
        await tester.tap(find.text('vpn-gateway').last);
        await settle();
        FocusManager.instance.primaryFocus?.unfocus();
        await settle();
        await saveShot(tester, key, 'networks_page_$tag');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
        await tester.runAsync(db.close);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }
}
