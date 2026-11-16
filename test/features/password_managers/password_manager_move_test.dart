import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/utils/redactor.dart';

/// Moving a saved password into a password manager (3.0), from
/// the desktop Keys screen: the password goes to the tool on its input,
/// never as an argument; the key then keeps only the new item's reference
/// and ZestSSH's copy is deleted.

const _bwId = '5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a';

class _Bitwarden implements PmProcessRunner {
  final calls = <(List<String>, String?)>[];

  @override
  Future<PmProcessResult> run(String executable, List<String> args,
      {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async {
    calls.add((args, stdin));
    if (args.first == 'unlock') return const PmProcessResult(0, 'S', '');
    if (args.join(' ') == 'create item') return const PmProcessResult(0, '{"id":"$_bwId"}', '');
    return const PmProcessResult(1, '', 'no');
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets("a Tree key's saved password moves into Bitwarden; the key then keeps only the reference", (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    late AppDatabase db;
    late IdentityCrudNotifier crud;
    late String key;
    late SharedPreferences prefs;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      key = await crud.create(label: 'web1', username: 'deploy', authMethod: 'password', password: 'hunter2-saved');
      for (final (family, files) in [
        ('GeistSans', ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']),
        ('JetBrainsMono', ['JetBrainsMono-Regular.ttf']),
      ]) {
        final loader = FontLoader(family);
        for (final f in files) {
          loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
        }
        await loader.load();
      }
    });
    addTearDown(() => tester.runAsync(db.close));
    final runner = _Bitwarden();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        sharedPreferencesProvider.overrideWithValue(prefs),
        passwordManagersProvider.overrideWith((r) => PasswordManagers(
              runner: runner,
              settings: () => r.read(passwordManagerSettingsProvider),
              environment: const {'PATH': '/usr/bin'},
              exists: (p) => p == '/usr/bin/bw' || p == '/usr/bin/op',
              isWindows: false,
              isMacOS: false,
            )),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: KeysView()),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('web1').first);
    await settle(tester);
    expect(find.byKey(const ValueKey('pm-move')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pm-move')));
    await settle(tester);
    expect(find.text(l10n.pmMoveBody('1Password')), findsOneWidget);
    await tester.tap(find.text('Bitwarden').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('pm-move-go')));
    await settle(tester);
    // Bitwarden asks for its master password first.
    expect(find.text(l10n.pmUnlockBitwardenTitle), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pm-unlock-field')), 'master');
    await tester.tap(find.text(l10n.pmUnlock));
    await settle(tester);

    final stored = await tester.runAsync(() => db.identitiesDao.getById(key));
    expect((stored!.authMethod, PasswordRef.decode(stored.passwordRef)?.target), ('passwordManager', _bwId));
    expect(await tester.runAsync(() => crud.getPassword(key)), isNull, reason: "ZestSSH's copy is gone");
    final create = runner.calls.firstWhere((c) => c.$1.join(' ') == 'create item');
    expect((jsonDecode(utf8.decode(base64.decode(create.$2!))) as Map)['login']['password'], 'hunter2-saved');
    for (final c in runner.calls) {
      expect(c.$1.join(' '), isNot(contains('hunter2-saved')), reason: 'never an argument');
    }
    // The pane now shows the key as it is: from Bitwarden, nothing kept.
    expect(find.byKey(const ValueKey('pm-move')), findsNothing);
    expect(find.text(_bwId), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    // The "Moved" note times out.
    await tester.pump(const Duration(seconds: 16));
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
}
