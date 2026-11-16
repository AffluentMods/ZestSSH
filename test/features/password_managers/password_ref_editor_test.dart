import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_ref_editor.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/features/password_managers/password_manager_import.dart';

/// The key editor's password manager part (3.0): the manager and
/// its item, picked from what the manager lists (or typed in), kept only as
/// a reference; a reference that cannot be used says so and is not kept; on
/// a phone there is nothing to pick with, and it says how the password is
/// given there.

class _Runner implements PmProcessRunner {
  final calls = <List<String>>[];

  @override
  Future<PmProcessResult> run(String executable, List<String> args,
      {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async {
    calls.add(args);
    if (args.join(' ') == 'item list --format=json') {
      return const PmProcessResult(0,
          '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaa","title":"db-prod","vault":{"id":"vvvvvvvvvvvvvvvvvvvvvvvvvv","name":"Engineering"},"additional_information":"postgres"},'
          '{"id":"cccccccccccccccccccccccccc","title":"Bank","vault":{"id":"pppppppppppppppppppppppppp","name":"Private"}},'
          '{"id":"dddddddddddddddddddddddddd","title":"web1","vault":{"id":"vvvvvvvvvvvvvvvvvvvvvvvvvv","name":"Engineering"},"additional_information":"deploy","urls":[{"href":"https://intranet"},{"primary":true,"href":"ssh://web1.example.com:2222"}]}]',
          '');
    }
    return const PmProcessResult(1, '', 'no');
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<List<String?>> pump(WidgetTester tester, {String? value, bool phone = false, _Runner? runner}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <String?>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        passwordManagersProvider.overrideWith((ref) => phone
            ? null
            : PasswordManagers(
                runner: runner ?? _Runner(),
                settings: () => ref.read(passwordManagerSettingsProvider),
                environment: const {'PATH': '/usr/bin'},
                exists: (p) => p == '/usr/bin/op',
                isWindows: false,
                isMacOS: false,
              )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: PasswordRefEditor(value: value, onChanged: changes.add))),
      ),
    ));
    await tester.pumpAndSettle();
    return changes;
  }

  testWidgets('a valid reference is kept, one that cannot be used says so and is not', (tester) async {
    final changes = await pump(tester);
    expect(find.text(l10n.pmToolFound('op', '/usr/bin/op')), findsOneWidget);
    expect(find.text(l10n.pmRefNote('1Password')), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('pm-ref-field')), matching: find.byType(TextField)),
        '--out-file=/tmp/x');
    await tester.pump();
    expect(find.text(l10n.pmRefInvalid), findsOneWidget);
    expect(changes.last, isNull);

    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('pm-ref-field')), matching: find.byType(TextField)),
        'op://Engineering/db-prod/password');
    await tester.pump();
    expect(find.text(l10n.pmRefInvalid), findsNothing);
    expect(PasswordRef.decode(changes.last)?.target, 'op://Engineering/db-prod/password');

    // Another manager starts empty; its tool is not there.
    await tester.tap(find.text('Bitwarden'));
    await tester.pumpAndSettle();
    expect(changes.last, isNull);
    // Set up right here (it pointed to Settings); nothing to pick with yet.
    expect(find.text(l10n.pmSetupMissing('bw', 'Bitwarden')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-setup-bw')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-choose')), findsNothing, reason: 'nothing to pick with');
  });

  testWidgets('picked from what the manager lists, searched by name, vault or user', (tester) async {
    final runner = _Runner();
    final changes = await pump(tester, runner: runner);
    await tester.tap(find.byKey(const ValueKey('pm-choose')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmChooseFrom('1Password')), findsWidgets);
    expect(find.text('db-prod'), findsOneWidget);
    expect(find.text('Bank'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pm-pick-search')), 'postgres');
    await tester.pump();
    expect(find.text('Bank'), findsNothing);
    await tester.tap(find.text('db-prod'));
    await tester.pumpAndSettle();
    expect(PasswordRef.decode(changes.last)?.target, 'op://Engineering/db-prod/password');
    expect(find.text('db-prod · Engineering · postgres'), findsOneWidget);
    expect(runner.calls.every((c) => c.first != 'read'), isTrue, reason: 'picking never fetches a password');
  });

  testWidgets('a phone: nothing to pick with, and how the password is given there', (tester) async {
    await pump(tester, phone: true, value: PasswordRef.bitwarden('5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a')!.encode());
    expect(find.byKey(const ValueKey('pm-choose')), findsNothing);
    expect(find.text(l10n.pmRefNotePhone('Bitwarden')), findsOneWidget);
    expect(find.text('5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a'), findsOneWidget);
  });

  testWidgets('adding from a password manager: a key per item, keeping only its reference; a host where the address is SSH',
      (tester) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final keys = IdentityCrudNotifier(
        db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
    final hosts = ConnectionCrudNotifier(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao);
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PasswordManagerImport? done;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        identityCrudProvider.overrideWithValue(keys),
        connectionCrudProvider.overrideWithValue(hosts),
        passwordManagersProvider.overrideWith((ref) => PasswordManagers(
              runner: _Runner(),
              settings: () => ref.read(passwordManagerSettingsProvider),
              environment: const {'PATH': '/usr/bin'},
              exists: (p) => p == '/usr/bin/op',
              isWindows: false,
              isMacOS: false,
            )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showAddFromPasswordManager(context, ref).then((v) => done = v),
              child: const Text('add'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('add'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(find.text(l10n.pmAddNote), findsOneWidget);
    expect(find.textContaining(l10n.pmAddMakesHost('web1.example.com:2222')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pm-add-go'))).onPressed, isNull, reason: 'nothing picked');
    await tester.tap(find.text('web1'));
    await tester.tap(find.text('Bank'));
    await tester.pump();
    expect(find.text(l10n.pmAddCount(2)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pm-add-go')));
    for (var i = 0; i < 20 && done == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect((done?.keys, done?.hosts), (2, 1));
    final stored = await tester.runAsync(() => db.identitiesDao.getAll());
    expect([for (final k in stored!) (k.label, k.username, k.authMethod, PasswordRef.decode(k.passwordRef)?.target)]..sort((a, b) => a.$1.compareTo(b.$1)), [
      ('Bank', Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? 'root', 'passwordManager', 'op://Private/Bank/password'),
      ('web1', 'deploy', 'passwordManager', 'op://Engineering/web1/password'),
    ]);
    for (final k in stored) {
      expect(await tester.runAsync(() => keys.getPassword(k.id)), isNull, reason: 'no password copied');
    }
    final conns = await tester.runAsync(() => db.connectionsDao.getAll());
    expect([for (final c in conns!) (c.label, c.host, c.port, c.identityId)],
        [('web1', 'web1.example.com', 2222, stored.firstWhere((k) => k.label == 'web1').id)]);
  });
}
