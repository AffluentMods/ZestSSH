import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/import/ssh_config_import_screen.dart';

/// A phone's import of an SSH config makes the hosts a computer's makes
/// (3.0; found while comparing the five
/// versions). It read the file with a reader of its own and wrote the hosts
/// itself: a ProxyJump was dropped, nothing was kept of an IdentityFile,
/// `Host a b` made one host named "a b", and a host's name kept characters
/// that turn text around (a name that reads as something else).
void main() {
  final de = lookupAppLocalizations(const Locale('de'));

  testWidgets('Compatibility mode for every host of a config, where it is ticked (item 53)', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: '/import', builder: (_, _) => const SshConfigImportScreen()),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    router.push('/import');
    await tester.pumpAndSettle();
    final en = lookupAppLocalizations(const Locale('en'));
    await tester.enterText(find.byType(TextField).first, 'Host old-01\n  HostName 203.0.113.10\n\nHost old-02\n  HostName 203.0.113.11\n');
    await tester.tap(find.text(en.sshImportParseConfig));
    await tester.pumpAndSettle();
    expect(find.text(en.csvImpCompatibility), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ssh-import-compatibility')));
    await tester.pump();
    await tester.tap(find.text(en.sshImportButtonCount(2)));
    await tester.pumpAndSettle();
    expect({for (final c in await db.connectionsDao.getAll()) c.label: c.compatibilityMode}, {'old-01': true, 'old-02': true});
    // The notice that they were imported goes by itself.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a backup pasted, or a key: said, and nothing of it stays in the field', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final en = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: SshConfigImportScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n');
    await tester.tap(find.text(en.sshImportParseConfig));
    await tester.pumpAndSettle();
    expect(find.text(en.importWrongTitle(en.cloudImpSshConfig)), findsOneWidget);
    expect(find.text(en.importPastedOther), findsOneWidget);
    await tester.tap(find.text(en.close).last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, isEmpty);
  });

  const config = 'Host bastion\n'
      '  HostName 192.0.2.10\n'
      '  User alex\n'
      '\n'
      'Host web-01 web-02\n'
      '  HostName 10.50.0.11\n'
      '  User robin\n'
      '  IdentityFile ~/.ssh/id_ed25519\n'
      '  ProxyJump bastion\n'
      '\n'
      'Host build\u202Eexe.sh\n'
      '  HostName 10.50.0.13\n'
      '\n'
      'Host *\n'
      '  ServerAliveInterval 30\n';

  testWidgets('a pasted config: one host per alias, none for a wildcard, ProxyJump to the host it names, '
      "IdentityFile in the host's note, names cleaned, keys named in the person's language", (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(onPressed: () => context.push('/import'), child: const Text('open')),
        ),
      ),
      GoRoute(path: '/import', builder: (_, _) => const SshConfigImportScreen()),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), config);
    await tester.tap(find.text(de.sshImportParseConfig));
    await tester.pumpAndSettle();
    expect(find.text(de.sshImportHostsFound(4)), findsOneWidget, reason: 'bastion, web-01, web-02 and build; no wildcard');
    await tester.runAsync(() async {
      await tester.tap(find.text(de.sshImportButtonCount(4)));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    final hosts = await tester.runAsync(() => db.select(db.connections).get()) ?? const [];
    final byLabel = {for (final h in hosts) h.label: h};
    expect(byLabel.keys.toSet(), {'bastion', 'web-01', 'web-02', 'buildexe.sh'}, reason: 'the name cleaned of U+202E');
    expect(byLabel['web-01']!.connectViaId, byLabel['bastion']!.id, reason: 'ProxyJump bastion');
    expect(byLabel['web-02']!.connectViaId, byLabel['bastion']!.id);
    expect(byLabel['bastion']!.connectViaId, isNull);
    expect(byLabel['web-01']!.note, contains('IdentityFile: ~/.ssh/id_ed25519'));
    expect(byLabel['web-01']!.host, '10.50.0.11');
    final keys = await tester.runAsync(() => db.select(db.identities).get()) ?? const [];
    expect(keys.map((k) => k.label).toSet(), {
      de.sshConfigImportImportedIdentityLabel('bastion'),
      de.sshConfigImportImportedIdentityLabel('web-01'),
      de.sshConfigImportImportedIdentityLabel('web-02'),
    }, reason: 'build has no User; each name in the language of the app');
    expect(find.byType(SshConfigImportScreen), findsNothing, reason: 'it closed after the import');
  });
}
