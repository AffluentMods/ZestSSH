import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/connect_as.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_theme.dart';

import '../../helpers/desktop_mouse.dart';

/// "Connect as" in a host's menu on a computer (3.0, accounts per host): the
/// Hosts page, and the hosts shown where no session is open (cards and rows),
/// offer each of a host's other accounts, by its username, and by its
/// identity's name as well where the username is not enough to tell it from
/// another; a pick connects with that account. A host without other accounts
/// has none, and a screen that does not give the callback offers none.
Future<void> _loadFonts() async {
  for (final (family, files) in [
    ('GeistSans', ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf', 'GeistSans-Bold.ttf']),
    ('JetBrainsMono', ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf']),
  ]) {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File('assets/fonts/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load().timeout(const Duration(seconds: 30));
  }
}

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
}

class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// What "Connect as" was asked for: (host, account).
  late List<(String, String)> asked;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void connectAs(ConnectionWithDetails item, String account) => asked.add((item.connection.id, account));

  /// [body] on a computer's screen, over three hosts: web-01 (default root,
  /// and deploy), db-primary (root alone), and ops-01 (two accounts of the
  /// user ops: a key, its default, and a password).
  Future<void> pump(WidgetTester tester, Widget body) async {
    asked = [];
    await tester.runAsync(_loadFonts);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 15);
    await tester.runAsync(() async {
      for (final (id, user, label) in [
        ('i-root', 'root', 'root key'),
        ('i-deploy', 'deploy', 'deploy key'),
        ('i-ops-key', 'ops', 'ops key'),
        ('i-ops-pw', 'ops', 'ops password'),
      ]) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: id,
              label: label,
              username: user,
              authMethod: 'publicKey',
              createdAt: now,
            ));
      }
      for (final (id, label, identity) in [
        ('h-web', 'web-01', 'i-root'),
        ('h-db', 'db-primary', 'i-root'),
        ('h-ops', 'ops-01', 'i-ops-key'),
      ]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: '$label.example.com',
              identityId: Value(identity),
              createdAt: now,
              updatedAt: now,
            ));
      }
      await db.hostAccountsDao.setOtherAccounts('h-web', ['i-deploy']);
      await db.hostAccountsDao.setOtherAccounts('h-ops', ['i-ops-pw']);
    });
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      serverStatsProvider.overrideWith(_NoStats.new),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: body),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Future<void> menuOf(WidgetTester tester, String label) async {
    await TestMouse(tester).rightClick(find.text(label).first);
    await settle(tester);
  }

  Future<void> closeMenu(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
  }

  final anyConnectAs = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('connect-as-'));

  /// The three menus offer what the hosts have, and a pick connects with it.
  Future<void> offersAndConnects(WidgetTester tester) async {
    await menuOf(tester, 'web-01');
    expect(find.text(l10n.hostConnectAs('deploy')), findsOneWidget);
    expect(anyConnectAs, findsOneWidget);
    await tester.tap(find.text(l10n.hostConnectAs('deploy')));
    await settle(tester);
    expect(asked, [('h-web', 'i-deploy')]);

    await menuOf(tester, 'db-primary');
    expect(find.text(l10n.edit), findsOneWidget, reason: 'its menu is open');
    expect(anyConnectAs, findsNothing);
    await closeMenu(tester);

    await menuOf(tester, 'ops-01');
    expect(find.text(l10n.hostConnectAs('ops (ops password)')), findsOneWidget,
        reason: 'the default signs in as ops too: the name of the identity tells them apart');
    await closeMenu(tester);
    expect(asked, hasLength(1));
  }

  desktopTest('the Hosts page', (tester) async {
    await pump(tester, HostsHomePage(onConnectTo: (_) {}, onConnectAs: connectAs));
    await offersAndConnects(tester);
    await finish(tester);
  });

  test('the accounts a host offers come in their order, and a change shows', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 15);
    for (final (id, user) in [('i-root', 'root'), ('i-deploy', 'deploy'), ('i-backup', 'backup')]) {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: '$user key',
            username: user,
            authMethod: 'publicKey',
            createdAt: now,
          ));
    }
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: 'web-01.example.com',
          identityId: const Value('i-root'),
          createdAt: now,
          updatedAt: now,
        ));
    // Written as a team's record may write them: not in their order.
    await db.into(db.hostAccounts).insert(
        HostAccountsCompanion.insert(connectionId: 'h-web', identityId: 'i-backup', position: 1));
    await db.into(db.hostAccounts).insert(
        HostAccountsCompanion.insert(connectionId: 'h-web', identityId: 'i-deploy', position: 0));
    final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(c.dispose);
    final seen = <List<String>>[];
    final sub = c.listen(hostAccountChoicesProvider('h-web'), (_, next) {
      final now = next.valueOrNull;
      if (now != null) seen.add([for (final a in now) '${a.id}:${a.username}']);
    }, fireImmediately: true);
    addTearDown(sub.close);
    Future<void> until(List<String> want) async {
      for (var i = 0; i < 200 && (seen.isEmpty || seen.last.join(',') != want.join(',')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(seen.last, want);
    }

    await until(['i-deploy:deploy', 'i-backup:backup']);
    await db.hostAccountsDao.setOtherAccounts('h-web', ['i-backup']);
    await until(['i-backup:backup']);
  });

  desktopTest('a screen that does not give Connect as offers none', (tester) async {
    await pump(tester, HostsHomePage(onConnectTo: (_) {}));
    await menuOf(tester, 'web-01');
    expect(find.text(l10n.edit), findsOneWidget);
    expect(anyConnectAs, findsNothing);
    await closeMenu(tester);
    await finish(tester);
  });
}
