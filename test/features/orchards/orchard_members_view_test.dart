import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/teams/crypto/fingerprint_words.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/record_statements.dart';

import 'fake_crate_server.dart';

/// The Members screen (3.0): this account's fingerprint to read
/// out, each member's state, and a check that is signed and stored.
class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('shows my fingerprint and each member, and a check is signed and stored',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = _MemoryStorage();
    addTearDown(() async {
      for (final db in storage.dbs.values) {
        await db.close();
      }
    });
    late AccountKeys myKeys;
    late PublishedAccountKeys alice;
    late String orchardId;
    final server = FakeCrateServer(accountUid: 'owner-1');
    final service = OrchardService(
      server: server,
      databases:
          OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: 'owner-1', keys: myKeys),
    );
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      final aliceKeys = await AccountKeys.generate();
      final bob1 = await AccountKeys.generate();
      final bob2 = await AccountKeys.generate();
      alice = await aliceKeys.publish('alice');
      await server.publish('owner-1', myKeys, email: 'me@example.com');
      await server.publish('alice', aliceKeys, email: 'alice@example.com');
      await server.publish('bob', bob1, email: 'bob@example.com');
      orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final role = server.recordOf(orchardId).roles.values.single.id;
      Future<void> append(String type, Map<String, Object?> body) async {
        final r = server.recordOf(orchardId);
        await server.appendAs('owner-1', orchardId, [
          await signRecordEntry(myKeys,
              orchardId: orchardId, seq: r.seq + 1, prev: r.head, type: type, body: body, by: 'owner-1'),
        ], checkCopies: false);
      }

      await append(RecordTypes.memberAdd, {...recordKeysBody(alice), 'uid': 'alice', 'role': role});
      await append(RecordTypes.memberAdd,
          {
            ...recordKeysBody(await bob1.publish('bob')),
            'uid': 'bob',
            'role': FixedRoles.admin,
            'verified': await comparedStatement(myKeys, 'owner-1', orchardId, await bob1.publish('bob')),
          });
      await service.refresh();
      // Bob taken out and added again with other keys, which the old ones
      // never vouched for: a hard stop.
      await server.publish('bob', bob2, email: 'bob@example.com');
      await append(RecordTypes.memberRemove, {'uid': 'bob'});
      await append(RecordTypes.memberAdd,
          {
            ...recordKeysBody(await bob2.publish('bob')),
            'uid': 'bob',
            'role': FixedRoles.admin,
            'verified': await comparedStatement(myKeys, 'owner-1', orchardId, await bob2.publish('bob')),
          });
    });

    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        // The rows mask names in recording mode, as every layout does.
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showOrchardMembers(context, ref, orchardId),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);

    // My own words to read out, and the same fingerprint as digits.
    final mine = (await myKeys.publish('owner-1')).fingerprint;
    expect(find.descendant(of: find.byKey(const ValueKey('my-fingerprint')), matching: fingerprintOf(mine)),
        findsOneWidget);
    expect(find.text(fingerprintWords(mine).first), findsWidgets);
    expect(find.text(l10n.orchardYourFingerprint), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('my-fingerprint')), matching: find.byKey(const ValueKey('fingerprint-format'))));
    await tester.pump();
    expect(find.text(formatFingerprint(mine)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('member-alice')), matching: find.text(l10n.orchardMemberNotVerified)),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('member-bob')), matching: find.text(l10n.orchardMemberKeyChanged)),
        findsOneWidget);

    // Check Alice: her words and mine side by side (one call checks both of
    // us), digits on request, then "They match".
    await tester.tap(find.byKey(const ValueKey('member-alice')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('compare-theirs')), matching: fingerprintOf(alice.fingerprint)),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('compare-mine')), matching: fingerprintOf(mine)),
        findsOneWidget);
    expect(find.text(l10n.fpTheirWords('alice@example.com')), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('member-fingerprint')), matching: find.byKey(const ValueKey('fingerprint-format'))));
    await tester.pump();
    expect(find.text(formatFingerprint(alice.fingerprint)), findsOneWidget);
    await tester.tap(find.text(l10n.orchardVerifyMatch));
    await settle(tester);
    expect(server.verifications.single.subjectUid, 'alice');
    expect(find.descendant(of: find.byKey(const ValueKey('member-alice')), matching: find.text(l10n.orchardMemberVerifiedByYou)),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the toast times out
  });
}

/// The fingerprint widget showing [fp].
Finder fingerprintOf(List<int> fp) =>
    find.byWidgetPredicate((w) => w is FingerprintWords && listEquals(w.fingerprint, fp));

/// Lets the database and crypto work finish (checking the record's
/// signatures takes a moment of real time), then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
