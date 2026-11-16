import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/command_history/desktop_history_page.dart';

import '../helpers/desktop_mouse.dart';
import 'shots_util.dart';

/// Pictures of a computer's History page (3.0, as
/// designed), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/history_shots_test.dart
///
/// Pictures land in build/shots/. Every host, folder and command on them is
/// made up. Another language with --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  Future<AppDatabase> seeded() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final made = DateTime(2026, 1, 1);
    for (final (id, user) in [('id-deploy', 'deploy'), ('id-root', 'root'), ('id-ops', 'ops')]) {
      await db.into(db.identities).insert(
          IdentitiesCompanion.insert(id: id, label: user, username: user, authMethod: 'password', createdAt: made));
    }
    // The demo world's hosts (the website's).
    final hosts = {
      'web': ('web-01', 'id-deploy'),
      'edge': ('edge-router', 'id-root'),
      'shop': ('web-02', 'id-deploy'),
      'build': ('build-runner', 'id-ops'),
      'hva': ('hypervisor-a', 'id-root'),
      'logs': ('log-store', 'id-deploy'),
    };
    for (final MapEntry(key: id, value: (label, identity)) in hosts.entries) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: '$label.example.internal',
            identityId: Value(identity),
            createdAt: made,
            updatedAt: made,
          ));
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var n = 0;
    Future<void> ran(String host, String command, DateTime at,
        {String? cwd, int? exit, int? ms}) async {
      await db.into(db.commandHistory).insert(CommandHistoryCompanion.insert(
            id: 'h${n++}',
            command: command,
            connectionId: Value(host),
            hostLabel: Value(hosts[host]!.$1),
            createdAt: at,
            cwd: Value(cwd),
            exitCode: Value(exit),
            durationMs: Value(ms),
          ));
    }

    DateTime at(int daysAgo, int h, int m, [int s = 0]) =>
        today.subtract(Duration(days: daysAgo)).add(Duration(hours: h, minutes: m, seconds: s));
    // Today: three trivial ones on one host, hidden.
    final early = now.hour < 1 ? 0 : 1;
    await ran('web', 'cd ~', today.add(Duration(minutes: 10 * early)), cwd: '/home/deploy', exit: 0, ms: 3);
    await ran('web', 'cd ..', today.add(Duration(minutes: 11 * early)), cwd: '/home', exit: 0, ms: 2);
    await ran('web', 'cd /srv/app', today.add(Duration(minutes: 12 * early)), cwd: '/srv/app', exit: 0, ms: 2);
    // Two days ago.
    await ran('web', 'systemctl restart nginx', at(2, 13, 31, 4), cwd: '/home/deploy', exit: 1, ms: 120);
    await ran('web', 'systemctl status nginx | grep active', at(2, 13, 31, 40), cwd: '/home/deploy', exit: 0, ms: 210);
    // A week ago.
    final rows = <(String, String, int, int, String?, int?, int?)>[
      ('hva', 'htop', 11, 39, '/root', 0, 1080000),
      ('logs', 'uptime', 12, 2, null, null, null),
      ('shop', 'pm2 restart shop', 13, 15, '/home/deploy/shop', 0, 600),
      ('shop', 'ls -la', 13, 15, '/home/deploy/shop', 0, 40),
      ('shop', 'npm run build', 13, 15, '/home/deploy/shop', 0, 41000),
      ('shop', 'node --env-file=.env build.mjs', 13, 16, '/home/deploy/shop', 0, 12300),
      ('edge', 'dig api.example.com +short', 17, 40, '/root', 0, 90),
      ('edge', 'clear', 17, 41, '/root', 0, 5),
      ('edge', 'nft list set inet fw blocklist | wc -l', 18, 0, '/root', 0, 130),
      ('edge', 'service firewall reload; sleep 10; nft list set inet fw blocklist | wc -l', 18, 4, '/root', 0, 10400),
      ('edge', 'service firewall reload; sleep 10; nft list set inet fw blocklist | wc -l', 18, 5, '/root', 0, 10400),
      ('edge', 'openssl s_client -connect 192.168.10.60:8443 < /dev/null | openssl x509 -noout -fingerprint', 18, 51, '/root', 0, 300),
      ('build', 'cd ..', 19, 10, '/home/ops', 0, 2),
      ('build', 'sudo systemctl restart api-gateway', 19, 13, '/home/ops', 0, 1800),
      ('build', 'journalctl -u api-gateway -n 50 --no-pager', 19, 14, '/home/ops', 0, 450),
      ('build', 'ls', 19, 15, '/home/ops', 0, 20),
    ];
    for (final (host, command, h, m, cwd, exit, ms) in rows) {
      await ran(host, command, at(7, h, m), cwd: cwd, exit: exit, ms: ms);
    }
    return db;
  }

  Future<(AppDatabase, GlobalKey)> shown(WidgetTester tester, String themeId) async {
    L10nGlobal.update(l10n);
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = const Size(1380, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'command_history_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final db = (await tester.runAsync(seeded))!;
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          redactionFleetRegistrar.overrideWith((ref) {}),
          isProProvider.overrideWith((ref) => _Pro()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: const Scaffold(body: HistoryView()),
        ),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return (db, key);
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(db.close);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('History page ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (db, key) = await shown(tester, themeId);
        final mouse = TestMouse(tester);
        // One row opened, another under the mouse, as the mockup draws them.
        await tester.tap(find.text('sudo systemctl restart api-gateway'));
        await settle(tester);
        await mouse.moveOver(find.text('dig api.example.com +short'));
        await settle(tester);
        await saveShot(tester, key, 'history_${tag}_$_locale');
        // The Run again menu.
        await mouse.click(find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('history-run-again-')));
        await settle(tester);
        await saveShot(tester, key, 'history_${tag}_run_menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        // The trivial ones of a day shown.
        await mouse.moveTo(const Offset(1370, 850));
        await tester.tap(find.byKey(ValueKey('history-trivial-toggle-${_dayKey(DateTime.now())}')));
        await settle(tester);
        await saveShot(tester, key, 'history_${tag}_trivial_shown');
        // How history works.
        await tester.tap(find.byKey(const ValueKey('history-how')));
        await settle(tester);
        await saveShot(tester, key, 'history_${tag}_how');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        // The host picker.
        await tester.tap(find.byKey(const ValueKey('history-host-filter')));
        await settle(tester);
        await saveShot(tester, key, 'history_${tag}_hosts');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        await finish(tester, db);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }
}

String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
