import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';

import '../helpers/desktop_mouse.dart';
import '../ui/sharing_ui_fakes.dart' show FakeSessions;
import 'shots_util.dart';

/// Pictures of the computer's Snippets page, for comparing with its
/// design mockup, with made-up snippets and hosts only. Off
/// unless asked for:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/snippets_shots_test.dart
const _shots = shotsEnabled;
final _computer = TargetPlatformVariant.only(TargetPlatform.windows);

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final host = ConnectionWithDetails(
    connection: Connection(
      id: 'c1',
      label: 'web-01',
      host: '192.168.10.21',
      port: 22,
      colorIndex: 0,
      protocol: 'ssh',
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: DateTime(2026, 10, 2),
      updatedAt: DateTime(2026, 10, 2),
    ),
  );

  Future<(AppDatabase, List<Snippet>)> seed(WidgetTester tester) async {
    late AppDatabase db;
    final rows = await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      final now = DateTime(2026, 10, 2);
      var n = 0;
      Future<void> add(String folder, String label, String command, {bool confirm = false, String? meta}) =>
          db.snippetsDao.insertSnippet(SnippetsCompanion(
            id: Value('s${n++}'),
            label: Value(label),
            command: Value(command),
            category: Value(folder),
            confirmBeforeRun: Value(confirm),
            metadata: Value(meta),
            sortOrder: Value(n),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      await add('Docker', 'Running Containers', 'docker ps');
      await add('Docker', 'All Containers', 'docker ps -a');
      await add('Docker', 'Container Logs', r'docker logs $[DOCKER] --tail 50',
          meta: '{"variables":{"[DOCKER]":"Container name"}}');
      await add('Docker', 'Follow Container Logs', r'docker logs $[DOCKER] -f');
      await add('Docker', 'Restart Container', r'docker restart $[DOCKER]');
      await add('Docker', 'Container Shell', r'docker exec -it $[DOCKER] /bin/sh');
      await add('Docker', 'Docker Disk Usage', 'docker system df');
      await add('Docker', 'Prune Unused', 'docker system prune -f', confirm: true);
      await add('Releases', 'Pull Release', 'set -e\ncd /srv/shop\ngit pull\nnpm ci');
      await add('Releases', 'Build Site', 'cd /srv/shop/site && npm ci && npm run build');
      await add('Files', 'Disk Usage', r'du -sh ${PATH:-.}/*');
      await add('Files', 'Largest Files', 'find . -type f -size +100M');
      await add('Postgres', 'Postgres Backup', 'pg_dump -Fc shop > /backups/shop.dump');
      await add('macOS', 'Brew Upgrade', 'brew update && brew upgrade');
      await add('Network', 'Open Ports', 'ss -tulpn');
      await add('Backups', 'Snapshot Now', r'restic backup ${TARGET}');
      await add('Logs', 'Tail Syslog', 'tail -f /var/log/syslog');
      return db.snippetsDao.getAll();
    });
    return (db, rows!);
  }

  Future<GlobalKey> pumpPage(WidgetTester tester, String themeId, AppDatabase db, List<Snippet> snippets,
      {Size size = const Size(2000, 1000)}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({
      'app_theme_id': themeId,
      'snippet_usage_v1': jsonEncode({
        's12': {'runCount': 3, 'lastRunAt': DateTime.now().subtract(const Duration(days: 43)).millisecondsSinceEpoch},
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(prefs),
          redactionFleetRegistrar.overrideWith((ref) {}),
          snippetsProvider.overrideWith((ref) => Stream.value(snippets)),
          snippetCategoryMetaProvider.overrideWith((ref) => Stream.value(const <SnippetCategory>[])),
          connectionsWithDetailsProvider.overrideWith((ref) => Stream.value([host])),
          connectionGroupsProvider.overrideWith((ref) => Stream.value(const <ConnectionGroup>[])),
          activeSessionsProvider.overrideWith((ref) => FakeSessions(ref)
            ..show({
              'live': SessionState(
                status: SessionStatus.connected,
                connectionId: 'c1',
                connectionLabel: 'web-01',
                host: '192.168.10.21',
                port: 22,
                session: TerminalSession(
                  id: 'live',
                  connectionId: 'c1',
                  terminal: Terminal(),
                  shell: _Shell(),
                  startedAt: DateTime(2026, 10, 2),
                ),
              ),
            })),
          v3ActiveSessionTabProvider.overrideWith((ref) => 'live'),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: SnippetsLibraryView()),
        ),
      ),
    ));
    await settle(tester);
    return key;
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(db.close);
  }

  for (final themeId in const ['default_dark', 'default_light', 'graphite']) {
    testWidgets('the Snippets page as the design draws it, $themeId', (tester) async {
      final (db, snippets) = await seed(tester);
      final key = await pumpPage(tester, themeId, db, snippets);
      await saveShot(tester, key, 'snippets-list-$themeId');
      final mouse = TestMouse(tester);
      await mouse.click(find.text('Container Logs'));
      await settle(tester);
      await mouse.moveOver(find.text('Restart Container'));
      await settle(tester);
      await saveShot(tester, key, 'snippets-detail-$themeId');
      await mouse.putAway();
      await finish(tester, db);
    }, skip: !_shots, variant: _computer);
  }

  testWidgets('the Snippets page in a smaller window', (tester) async {
    final (db, snippets) = await seed(tester);
    final key = await pumpPage(tester, 'default_dark', db, snippets, size: const Size(1366, 820));
    await saveShot(tester, key, 'snippets-small-default_dark');
    await TestMouse(tester).click(find.text('Prune Unused'));
    await settle(tester);
    await saveShot(tester, key, 'snippets-small-detail-default_dark');
    await TestMouse(tester).putAway();
    await finish(tester, db);
  }, skip: !_shots, variant: _computer);
}
