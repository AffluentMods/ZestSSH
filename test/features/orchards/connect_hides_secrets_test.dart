import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/orchard_db_fixture.dart';

/// Connect hides a key's secrets (3.0): the key editor, opened on
/// an Orchard key whose Crate this account reaches at Connect, never reads
/// its password (so nothing on screen can show or copy it), says so, and
/// offers no save; at Use the same screen reads and shows it.

const _orchard = kFixtureOrchardId;
const _connectCrate = '77777777-7777-4777-8777-777777777777';
const _useCrate = kFixtureCrateId;

/// The key store, counting every time a secret is read.
class _CountingCrud extends IdentityCrudNotifier {
  _CountingCrud(AppDatabase db)
      : super(db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);

  final reads = <String>[];

  @override
  Future<String?> getPassword(String id) {
    reads.add('password:$id');
    return super.getPassword(id);
  }

  @override
  Future<String?> getPrivateKey(String id) {
    reads.add('privateKey:$id');
    return super.getPrivateKey(id);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late _CountingCrud crud;
  late OrchardSummary summary;
  late String connectKey;
  late String useKey;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
        await seedOrchardAsOwner(db);
        await db.customStatement(
            "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Prod', 'connect', ?, 1)",
            [_connectCrate, jsonEncode(switchList(levelSwitches(CrateLevel.connect)))]);
        crud = _CountingCrud(db);
        connectKey =
            await crud.create(label: 'prod', username: 'deploy', authMethod: 'password', password: 'hunter2-prod');
        useKey = await crud.create(label: 'dev', username: 'deploy', authMethod: 'password', password: 'hunter2-dev');
        // As the sync engine leaves them: each in its Crate, on the server.
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        await db.customStatement(
            'INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES '
            "('key', ?, ?, 1), ('key', ?, ?, 1)",
            [connectKey, _connectCrate, useKey, _useCrate]);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
        summary = await readOrchardSummary(db, _orchard);
        crud.reads.clear();
      });

  Future<void> open(WidgetTester tester, String identityId) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(_orchard)),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        itemCratesProvider('key').overrideWith((ref) => Stream.value({connectKey: _connectCrate, useKey: _useCrate})),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: IdentityEditScreen(identityId: identityId, embedded: true, onClose: (_) {})),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  testWidgets('at Connect the password is never read, the screen says so, and nothing saves', (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    await open(tester, connectKey);

    expect(crud.reads, isEmpty, reason: 'the secret never reaches the screen');
    expect(find.byKey(const ValueKey('secret-hidden')), findsOneWidget);
    expect(find.text(l10n.orchardSecretHidden), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is EditableText && w.obscureText), findsNothing,
        reason: 'no password field at all');
    expect(find.text(l10n.identityPassword), findsNothing, reason: 'nor a choice of how it signs in');
    expect(find.byTooltip(l10n.save), findsNothing, reason: 'saving would write over what is hidden');
    expect(find.textContaining('hunter2'), findsNothing);
  });

  testWidgets('at Use the same screen reads and shows it', (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    await open(tester, useKey);

    expect(crud.reads, contains('password:$useKey'));
    expect(find.byKey(const ValueKey('secret-hidden')), findsNothing);
    final field = tester.widget<EditableText>(find.byWidgetPredicate((w) => w is EditableText && w.obscureText));
    expect(field.controller.text, 'hunter2-dev', reason: 'loaded, behind the usual eye toggle');
    expect(find.byTooltip(l10n.save), findsOneWidget);
  });
}
