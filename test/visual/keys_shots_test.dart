import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_action_dialogs.dart';
import 'package:zestssh/features/keys/key_agent.dart';
import 'package:zestssh/features/keys/replace_key.dart';
import 'package:zestssh/features/keys/replace_key_view.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_ref_editor.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/utils/redactor.dart';

import 'shots_util.dart';

/// Pictures of the Keys page on a computer, for comparing with its
/// design mockup (dark and light), with the demo world's keys
/// and hosts only (the website's); and of a password manager's tool set up in place. Off unless asked
/// for:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/keys_shots_test.dart
const _shots = shotsEnabled;
final _computer = TargetPlatformVariant.only(TargetPlatform.windows);

class _NoTool implements PmProcessRunner {
  @override
  Future<PmProcessResult> run(String executable, List<String> args,
          {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async =>
      const PmProcessResult(1, '', '');
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

  /// The mockup's page with the demo world's keys (the website's): Ops
  /// laptop on eight hosts, a build key, two saved passwords (one in
  /// 1Password), a key in the agent and a security key, no certificate.
  Future<(AppDatabase, IdentityCrudNotifier, String)> seed(WidgetTester tester) async {
    late AppDatabase db;
    late IdentityCrudNotifier crud;
    late String main;
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      final now = DateTime.now();
      final sep1 = DateTime(now.year, 9, 1, 10);
      Future<String> key(String label, String user, String method,
          {String? fp, String? type, String? line, bool agent = false, DateTime? added, String? ref}) async {
        final id = await crud.create(
            label: label,
            username: user,
            authMethod: method,
            keyType: type,
            publicKeyFingerprint: fp,
            publicKeyData: line,
            passwordRef: ref,
            password: method == 'password' ? 'demo-only' : null);
        await db.identitiesDao.updateIdentity(IdentitiesCompanion(
            id: Value(id), createdAt: Value(added ?? sep1), usesAgent: Value(agent)));
        return id;
      }

      main = await key('Ops laptop', 'deploy', 'publicKey',
          type: 'ssh-ed25519',
          fp: 'SHA256:Hq3vR1kZ8sYdW0aJm5uT2nE7bL4xCq9oPfGpR8tWc',
          line: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoOnlyKeyMaterialForThePictures ops@laptop');
      final build = await key('Build key', 'ci', 'publicKey',
          type: 'ssh-ed25519', fp: 'SHA256:nC7xKjMNYpi8Qe4LmV1rT6uWx9AbCdH2LmQaZ');
      final router = await key('Router admin', 'root', 'password', added: DateTime(now.year, 10, 2, 9));
      final hypervisors = await key('Hypervisors', 'root', 'password');
      await key('ops@mac-studio', 'ops', 'hardwareToken', type: 'ssh-ed25519', agent: true);
      await key('Security key', 'ops', 'hardwareToken', type: 'sk-ssh-ed25519@openssh.com', agent: true);

      var n = 0;
      Future<void> host(String label, String address, String? keyId, DateTime? last, String icon) async {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: 'h${n++}',
              label: label,
              host: address,
              identityId: Value(keyId),
              iconId: Value(icon),
              lastConnected: Value(last),
              createdAt: sep1,
              updatedAt: sep1,
            ));
      }

      // The demo fleet (the website's), each host with the key it signs in with.
      final fleet = [
        ('web-01', '192.168.10.21', 'ubuntu'),
        ('web-02', '192.168.10.22', 'ubuntu'),
        ('db-primary', '192.168.10.31', 'debian'),
        ('cache-01', '192.168.10.41', 'alpine'),
        ('monitoring', '192.168.10.60', 'ubuntu'),
        ('log-store', '192.168.10.24', 'rocky'),
        ('vpn-gateway', '192.168.10.23', 'alpine'),
        ('mac-studio', '192.168.10.30', 'macos'),
      ];
      for (final (i, (name, address, icon)) in fleet.indexed) {
        await host(name, address, main, i == 0 ? now.subtract(const Duration(hours: 2)) : null, icon);
      }
      await host('build-runner', '192.168.10.50', build, DateTime(now.year, 10, 12, 15), 'debian');
      await host('edge-router', '192.168.20.1', router, now.subtract(const Duration(days: 2)), 'router');
      await host('hypervisor-a', '192.168.20.11', hypervisors, now.subtract(const Duration(hours: 3)), 'debian');
      await host('hypervisor-b', '192.168.20.12', hypervisors, null, 'debian');
    });
    return (db, crud, main);
  }

  Future<GlobalKey> pumpPage(WidgetTester tester, String themeId, AppDatabase db, IdentityCrudNotifier crud,
      {Size size = const Size(1376, 860), List<Override> overrides = const [], Widget? body, bool keepSecrets = false}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    if (!keepSecrets) FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId});
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
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          identitiesDaoProvider.overrideWithValue(db.identitiesDao),
          identityCrudProvider.overrideWithValue(crud),
          syncIsActiveProvider.overrideWith((ref) async => true),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
          ...overrides,
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: body ?? const KeysView()),
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
    testWidgets('the Keys page as the design draws it, $themeId', (tester) async {
      final (db, crud, _) = await seed(tester);
      final key = await pumpPage(tester, themeId, db, crud);
      await saveShot(tester, key, 'keys-list-$themeId');
      await tester.tap(find.text('Ops laptop'));
      await settle(tester);
      await saveShot(tester, key, 'keys-key-$themeId');
      await tester.tap(find.text('Hypervisors'));
      await settle(tester);
      await saveShot(tester, key, 'keys-password-$themeId');
      await tester.tap(find.text('Security key'));
      await settle(tester);
      await saveShot(tester, key, 'keys-agent-$themeId');
      await tester.tap(find.text('Ops laptop'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      await saveShot(tester, key, 'keys-edit-$themeId');
      await finish(tester, db);
    }, skip: !_shots, variant: _computer);
  }

  testWidgets('the Keys page in a narrow window: the details as a page of their own', (tester) async {
    final (db, crud, _) = await seed(tester);
    final key = await pumpPage(tester, 'default_dark', db, crud, size: const Size(900, 760));
    await saveShot(tester, key, 'keys-narrow-list-default_dark');
    await tester.tap(find.text('Ops laptop'));
    await settle(tester);
    await saveShot(tester, key, 'keys-narrow-key-default_dark');
    await finish(tester, db);
  }, skip: !_shots, variant: _computer);

  for (final themeId in const ['default_dark', 'default_light']) {
    testWidgets("a password manager's tool not found, set up in place, $themeId", (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(620, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = BuiltInThemes.getById(themeId);
      AppColors.applyTheme(theme.colorScheme);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            passwordManagersProvider.overrideWith((ref) => PasswordManagers(
                  runner: _NoTool(),
                  settings: () => ref.read(passwordManagerSettingsProvider),
                  environment: const {'LOCALAPPDATA': r'C:\Users\demo\AppData\Local', 'Path': r'C:\Windows'},
                  exists: (_) => false,
                  isWindows: true,
                  isMacOS: false,
                )),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.toThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: PasswordRefEditor(value: null, onChanged: (_) {}),
              ),
            ),
          ),
        ),
      ));
      await settle(tester);
      await saveShot(tester, key, 'pm-setup-missing-$themeId');
      plainShadows();
      await tester.pumpWidget(const SizedBox());
    }, skip: !_shots, variant: _computer);
  }

  // The four actions of a key's details (3.0):
  // Export and Add to agent on its line, the passphrase in PROTECTION,
  // Replace on all hosts at its foot; the Replace dialog before it starts
  // and while it runs; and the dialogs of the other three.
  for (final themeId in const ['default_dark', 'default_light']) {
    testWidgets('a key\'s details with its actions, and Replace on all hosts, $themeId', (tester) async {
      final (db, crud, main) = await seed(tester);
      await tester.runAsync(() => LocalStateStore(db).write('key_passphrase:$main', 'none'));
      final actions = <Override>[
        localStateStoreProvider.overrideWithValue(LocalStateStore(db)),
        systemAgentProvider.overrideWithValue(const _NoKeysAgent()),
      ];
      final key = await pumpPage(tester, themeId, db, crud, overrides: actions);
      await tester.tap(find.text('Ops laptop'));
      await settle(tester);
      await saveShot(tester, key, 'keys-actions-details-$themeId');
      await tester.tap(find.byKey(const ValueKey('keys-replace-on-hosts')));
      await settle(tester);
      await settle(tester);
      await saveShot(tester, key, 'keys-replace-setup-$themeId');
      await finish(tester, db);

      // While it runs: hosts done, one done whose old key was not in the
      // file, one proving the new key, one failed, one skipped, the rest
      // waiting.
      final (db2, crud2, main2) = await seed(tester);
      final old = (await tester.runAsync(() => db2.identitiesDao.getById(main2)))!;
      final hosts = (await tester.runAsync(() => db2.connectionsDao.getAll()))!.where((c) => c.identityId == main2).toList()
        ..sort((a, b) => a.label.compareTo(b.label));
      final steps = <ReplaceHost Function(Connection)>[
        (h) => ReplaceHost(host: h, step: ReplaceStep.done, removed: 1, user: 'deploy'),
        (h) => ReplaceHost(host: h, step: ReplaceStep.done, removed: 1, user: 'deploy'),
        (h) => ReplaceHost(host: h, step: ReplaceStep.done, why: ReplaceWhy.oldNotFound, user: 'deploy'),
        (h) => ReplaceHost(host: h, step: ReplaceStep.proving, user: 'deploy'),
        (h) => ReplaceHost(host: h, step: ReplaceStep.removing, user: 'deploy'),
        (h) => ReplaceHost(host: h, step: ReplaceStep.failed, why: ReplaceWhy.proofFailed, details: 'Permission denied (publickey)', user: 'deploy'),
        (h) => ReplaceHost(host: h, step: ReplaceStep.skipped, why: ReplaceWhy.oldWithOptions, details: 'authorized_keys line 3', user: 'deploy'),
      ];
      final run = ReplaceRun(
        oldId: old.id,
        oldLabel: old.label,
        newId: 'new',
        newLabel: 'Ops laptop (new)',
        running: true,
        hosts: [
          for (var i = 0; i < hosts.length; i++)
            i < steps.length ? steps[i](hosts[i]) : ReplaceHost(host: hosts[i]),
        ],
      );
      final key2 = await pumpPage(tester, themeId, db2, crud2,
          size: const Size(1100, 980),
          overrides: [
            ...actions,
            replaceKeyRunProvider.overrideWith((ref) => _ShownRun(ref, run)),
          ],
          body: Center(child: ReplaceKeyDialog(oldKey: old)));
      await saveShot(tester, key2, 'keys-replace-progress-$themeId');
      await finish(tester, db2);
    }, skip: !_shots, variant: _computer);
  }

  testWidgets('the passphrase, Add to agent and Export dialogs, default_dark', (tester) async {
    final (db, crud, main) = await seed(tester);
    await tester.runAsync(() async {
      final made = await KeyGenerationService().generateEd25519(comment: 'ops');
      await crud.update(id: main, privateKeyPem: made.privatePem);
    });
    final keyRow = (await tester.runAsync(() => db.identitiesDao.getById(main)))!;
    final actions = <Override>[
      localStateStoreProvider.overrideWithValue(LocalStateStore(db)),
      systemAgentProvider.overrideWithValue(const _NoKeysAgent()),
    ];
    for (final (name, dialog) in [
      ('keys-passphrase-add-dialog', KeyPassphraseDialog(keyToChange: keyRow, mode: KeyPassphraseMode.add) as Widget),
      ('keys-agent-dialog', AddToAgentDialog(keyToAdd: keyRow, windows: true)),
      ('keys-export-dialog', KeyExportDialog(keyToExport: keyRow)),
    ]) {
      final key = await pumpPage(tester, 'default_dark', db, crud,
          size: const Size(760, 640), overrides: actions, body: Center(child: dialog), keepSecrets: true);
      await saveShot(tester, key, '$name-default_dark');
    }
    await finish(tester, db);
  }, skip: !_shots, variant: _computer);
}

/// A system agent that holds no key.
class _NoKeysAgent implements SystemAgent {
  @override
  Future<void> remove(Set<String> fingerprints) async {}

  const _NoKeysAgent();

  @override
  Future<void> add(Uint8List request) async {}

  @override
  Future<Set<String>> fingerprints() async => const {};
}

/// A replacement shown as it stands at one moment.
class _ShownRun extends ReplaceKeyNotifier {
  _ShownRun(Ref ref, ReplaceRun run)
      : super(
          ref,
          ReplaceKeyDeps(
            openOld: (_) => throw UnimplementedError(),
            prove: (_, _, _) => throw UnimplementedError(),
            skipBefore: (_, _) async => null,
            point: (_, {required oldId, required newId}) async {},
          ),
        ) {
    state = run;
  }
}
