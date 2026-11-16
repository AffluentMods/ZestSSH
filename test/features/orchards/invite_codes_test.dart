import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/orchards/members/invite_maker_checks.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/invite_people_dialog.dart';
import 'package:zestssh/features/orchards/widgets/join_team.dart';
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

import 'fake_crate_server.dart';

// Invite codes: the maker's device makes the
// code and gives ZestSSH Cloud only what is derived from it; the person's
// device checks the offer against the code before showing it as the team's,
// and accepts with a tag over its keys; the maker's device checks that tag,
// so letting them in needs no fingerprint comparison, but still the maker's
// "Let them in". A server that passes off other keys, another team or
// another offer is caught on either side.

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

/// A server that changes what it hands on, as a dishonest one would.
class _Tampering extends FakeCrateServer {
  _Tampering() : super(accountUid: 'owner-1');

  InviteCodeOffer Function(InviteCodeOffer)? offer;
  OrchardInvite Function(OrchardInvite)? listed;

  @override
  Future<InviteCodeOffer> inviteCodeOffer(String lookupId) async {
    final o = await super.inviteCodeOffer(lookupId);
    return offer == null ? o : offer!(o);
  }

  @override
  Future<List<OrchardInvite>> invites(String orchardId) async =>
      [for (final i in await super.invites(orchardId)) listed == null ? i : listed!(i)];
}

/// The system's keychain, not answering while [down].
class _FlakyStorage extends FlutterSecureStorage {
  _FlakyStorage();

  bool down = false;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (down) throw PlatformException(code: 'unavailable', message: 'played: the keychain does not answer');
    return super.read(key: key);
  }
}

OrchardBilling _seats({required int bought, required int used}) => OrchardBilling.fromJson({
      'seats': {'bought': bought, 'included': 0, 'total': bought, 'used': used, 'free': bought - used, 'over': false},
      'business_services': {'state': 'off'},
    });

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late _MemoryStorage storage;
  late _Tampering server;
  late AccountKeys ownerKeys;
  late AccountKeys joinerKeys;
  late OrchardService owner;
  late OrchardService joiner;
  late String orchardId;
  late String crateId;
  late String role;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = _MemoryStorage();
  });

  tearDown(() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  });

  OrchardService serviceFor(CrateServer s, String uid, AccountKeys keys) => OrchardService(
        server: s,
        databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
        author: () async => CrateAuthor(uid: uid, keys: keys),
        makerChecks: InviteMakerChecks(const FlutterSecureStorage()),
      );

  /// A team of owner-1 (Acme, with Production) and new-1, who is not in it.
  Future<void> team() async {
    server = _Tampering();
    ownerKeys = await AccountKeys.generate();
    joinerKeys = await AccountKeys.generate();
    await server.publish('owner-1', ownerKeys, email: 'owner@example.com');
    await server.publish('new-1', joinerKeys, email: 'new@example.com');
    owner = serviceFor(server, 'owner-1', ownerKeys);
    joiner = serviceFor(server.as('new-1'), 'new-1', joinerKeys);
    orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    crateId = server.orchardsById[orchardId]!.crates.single.id;
    role = server.recordOf(orchardId).roles.values.single.id;
  }

  const shown = JoinOffer(team: 'Acme', role: 'Member', vaults: [JoinOfferVault('Production', 'use')]);

  group('the code checks both sides', () {
    test('made here, looked at and accepted there, checked here, then let in: the server never has the code',
        () async {
      await team();
      final made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      final saved = server.savedCodes.single;
      expect(saved.lookupId, (await joinCodeKeys(made.code)).lookupHex);
      expect(saved.lookupId, isNot(contains(made.code)));
      expect(saved.expiresIn, 3600);
      // Nothing the server holds spells the code.
      final held = server.orchardsById[orchardId]!;
      expect(held, isNotNull);

      // The person types it in lower case, with spaces.
      final typed = writtenJoinCode(made.code).toLowerCase().replaceAll('-', ' ');
      final preview = await joiner.previewInviteCode(typed);
      expect(preview.shown.team, 'Acme');
      expect(preview.shown.vaults.single.name, 'Production');
      expect(preview.offer.invite.role, role);
      expect(preview.offer.invite.invitedBy, 'owner@example.com');
      final inviteId = await joiner.acceptInviteCode(preview);
      expect(inviteId, made.inviteId);

      // Used up: the same code finds nothing now.
      await expectLater(joiner.previewInviteCode(made.code),
          throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'join-code-invalid')));

      // Not in yet.
      expect(server.recordOf(orchardId).members.containsKey('new-1'), isFalse);
      final invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
      expect(invite.byCode, isTrue);
      expect(invite.email, 'new@example.com');
      final check = await owner.checkInviteCode(orchardId, invite);
      expect(check.checked, isTrue);
      expect(check.code, made.code);

      await owner.confirmInvite(orchardId, invite);
      expect(server.recordOf(orchardId).members.containsKey('new-1'), isTrue);
    });

    test('text that is no code is refused before anything is asked', () async {
      await team();
      for (final bad in ['', 'ZEST-ABCD-EFGH-JKLM', 'hello', 'zestssh://share?d=x']) {
        await expectLater(joiner.previewInviteCode(bad),
            throwsA(isA<InviteCodeError>().having((e) => e.problem, 'problem', InviteCodeProblem.notACode)));
      }
      expect(server.codeLookups, 0);
    });

    test('a server that passes off other keys, another offer or another name is caught by the person', () async {
      await team();
      final stranger = await AccountKeys.generate();
      final strangerKeys = await stranger.publish('owner-1');
      final made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      Future<void> refused(InviteCodeOffer Function(InviteCodeOffer) change) async {
        server.offer = change;
        await expectLater(joiner.previewInviteCode(made.code),
            throwsA(isA<InviteCodeError>().having((e) => e.problem, 'problem', InviteCodeProblem.checkFailed)));
        server.offer = null;
      }

      InviteCodeOffer withInvite(InviteCodeOffer o, MyInvite i) => InviteCodeOffer(
          invite: i, grants: o.grants, makerKeys: o.makerKeys, ownerTag: o.ownerTag, offerSealed: o.offerSealed);
      MyInvite inviteWith(MyInvite i, {String? role, int? endsAt, String? orchard}) => MyInvite(
          id: i.id,
          orchardId: orchard ?? i.orchardId,
          role: role ?? i.role,
          crates: i.crates,
          expiresAt: i.expiresAt,
          accepted: false,
          invitedBy: i.invitedBy,
          endsAt: endsAt ?? i.endsAt);

      // Another maker's keys (signed by their own key, so they look whole).
      await refused((o) => InviteCodeOffer(
          invite: o.invite, grants: o.grants, makerKeys: strangerKeys, ownerTag: o.ownerTag, offerSealed: o.offerSealed));
      // Another role, more Crates, an end date, another team.
      await refused((o) => withInvite(o, inviteWith(o.invite, role: FixedRoles.admin)));
      await refused((o) => InviteCodeOffer(
          invite: o.invite,
          grants: {crateId: levelSwitches(CrateLevel.manage)},
          makerKeys: o.makerKeys,
          ownerTag: o.ownerTag,
          offerSealed: o.offerSealed));
      await refused((o) => withInvite(o, inviteWith(o.invite, endsAt: 1900000000)));
      await refused((o) => withInvite(o, inviteWith(o.invite, orchard: 'another-team')));
      // What is shown, changed.
      await refused((o) => InviteCodeOffer(
          invite: o.invite,
          grants: o.grants,
          makerKeys: o.makerKeys,
          ownerTag: o.ownerTag,
          offerSealed: Uint8List.fromList([...o.offerSealed]..[20] ^= 1)));
      // A tag that is not the maker's.
      await refused((o) => InviteCodeOffer(
          invite: o.invite, grants: o.grants, makerKeys: o.makerKeys, ownerTag: Uint8List(32), offerSealed: o.offerSealed));
      // Untouched, it is still fine (and still unused).
      expect((await joiner.previewInviteCode(made.code)).shown.team, 'Acme');
    });

    test('a server that lists other keys for whoever used it is caught by the maker; elsewhere it is unchecked', () async {
      await team();
      final made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      await joiner.acceptInviteCode(await joiner.previewInviteCode(made.code));
      final other = await (await AccountKeys.generate()).publish('new-1');
      server.listed = (i) => OrchardInvite(
            id: i.id,
            email: i.email,
            role: i.role,
            grants: i.grants,
            endsAt: i.endsAt,
            expiresAt: i.expiresAt,
            expired: i.expired,
            invitedBy: i.invitedBy,
            acceptedUid: i.acceptedUid,
            acceptedKeys: other,
            code: i.code,
          );
      var invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
      expect((await owner.checkInviteCode(orchardId, invite)).checked, isFalse);

      // Another device without the code (another admin's): not checked, so
      // the fingerprints are compared.
      server.listed = (i) => OrchardInvite(
            id: i.id,
            email: i.email,
            role: i.role,
            expiresAt: i.expiresAt,
            expired: i.expired,
            acceptedUid: i.acceptedUid,
            acceptedKeys: i.acceptedKeys,
            code: InviteCodeInfo(makerUid: i.code!.makerUid, makerKeyVersion: 1, joinerTag: i.code!.joinerTag),
          );
      invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
      expect((await owner.checkInviteCode(orchardId, invite)).checked, isFalse);
      server.listed = null;
      invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
      expect((await owner.checkInviteCode(orchardId, invite)).checked, isTrue);
    });

    // From a security review, and what was
    // found looking at it: anyone can seal to the maker's public key, so a
    // server could make up a code of its own, seal it to the maker, and tag
    // keys of its own with it.
    test('a server that makes up a code of its own and seals it to the maker cannot pass off other keys as checked',
        () async {
      await team();
      final made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      await joiner.acceptInviteCode(await joiner.previewInviteCode(made.code));
      final otherKeys = await AccountKeys.generate();
      final other = await otherKeys.publish('new-1');
      final madeUp = newJoinCode();
      final madeUpKeys = await joinCodeKeys(madeUp);
      final tag = await joinCodeTag(
          madeUpKeys.macKey,
          joinerTranscript(
            orchardId: orchardId,
            inviteId: made.inviteId,
            lookupId: madeUpKeys.lookupId,
            maker: JoinCodeParty(
                uid: 'owner-1',
                keyVersion: ownerKeys.version,
                signingKey: ownerKeys.signingPublicKey,
                encryptionKey: ownerKeys.encryption.publicKey),
            joiner: JoinCodeParty(
                uid: other.uid, keyVersion: other.version, signingKey: other.signingKey, encryptionKey: other.encryptionKey),
          ));
      // In the form a copy now has, signed by the server's own key; and in the
      // form an older version kept, the code alone.
      final forged = [
        await sealMadeJoinCode(madeUp,
            makerEncryptionKey: ownerKeys.encryption.publicKey,
            sign: otherKeys.sign,
            orchardId: orchardId,
            inviteId: made.inviteId,
            usesMax: 1,
            role: role,
            grants: const {},
            endsAt: null),
        await sealTo(ownerKeys.encryption.publicKey, utf8.encode(madeUp),
            context: 'zestssh.join-code.code.v1|$orchardId|${made.inviteId}'),
      ];
      for (final sealed in forged) {
        server.listed = (i) => OrchardInvite(
              id: i.id,
              email: i.email,
              role: i.role,
              grants: i.grants,
              endsAt: i.endsAt,
              expiresAt: i.expiresAt,
              expired: i.expired,
              invitedBy: i.invitedBy,
              acceptedUid: i.acceptedUid,
              acceptedKeys: other,
              code: InviteCodeInfo(
                  makerUid: 'owner-1', makerKeyVersion: ownerKeys.version, sealed: sealed, joinerTag: tag),
            );
        final invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
        expect((await owner.checkInviteCode(orchardId, invite)).checked, isFalse);
      }
    });

    test('a team code is never taken as checking keys, even shown as a use by one person', () async {
      await team();
      // The test server keeps every code as one person's, as a server that
      // passes a team code's use off as one would.
      final made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown, usesMax: 5);
      await joiner.acceptInviteCode(await joiner.previewInviteCode(made.code));
      final invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
      final check = await owner.checkInviteCode(orchardId, invite);
      expect(check.checked, isFalse);
      expect(check.teamCode, isTrue);
      expect(check.offerChanged, isFalse);
      // Let in once the fingerprints were compared, as for an address.
      await owner.confirmInvite(orchardId, invite);
      expect(server.recordOf(orchardId).members.containsKey('new-1'), isTrue);
    });

    test('a use listed with another offer than its maker signed: nobody is let in on it', () async {
      await team();
      final made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      await joiner.acceptInviteCode(await joiner.previewInviteCode(made.code));
      OrchardInvite offering(OrchardInvite i, {String? role, Map<String, Set<String>>? grants, int? endsAt}) =>
          OrchardInvite(
            id: i.id,
            email: i.email,
            role: role ?? i.role,
            grants: grants ?? i.grants,
            endsAt: endsAt ?? i.endsAt,
            expiresAt: i.expiresAt,
            expired: i.expired,
            invitedBy: i.invitedBy,
            acceptedUid: i.acceptedUid,
            acceptedKeys: i.acceptedKeys,
            code: i.code,
          );
      for (final change in <OrchardInvite Function(OrchardInvite)>[
        (i) => offering(i, role: FixedRoles.admin),
        (i) => offering(i, grants: {crateId: levelSwitches(CrateLevel.manage)}),
        (i) => offering(i, endsAt: 1900000000),
      ]) {
        server.listed = change;
        final invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
        final check = await owner.checkInviteCode(orchardId, invite);
        expect(check.checked, isFalse);
        expect(check.offerChanged, isTrue);
        await expectLater(owner.confirmInvite(orchardId, invite),
            throwsA(isA<OrchardInviteError>().having((e) => e.problem, 'problem', OrchardInviteProblem.offerChanged)));
        expect(server.recordOf(orchardId).members.containsKey('new-1'), isFalse);
      }
      server.listed = null;
      final invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
      expect((await owner.checkInviteCode(orchardId, invite)).checked, isTrue);
    });

    group('the first record a device reads of a team it joined by a code', () {
      /// new-1 used a code and was let in; the team has not reached its device,
      /// a device of its own here.
      Future<OrchardInvite> letIn() async {
        await team();
        final own = _MemoryStorage();
        addTearDown(() async {
          for (final db in own.dbs.values) {
            await db.close();
          }
        });
        joiner = OrchardService(
          server: server.as('new-1'),
          databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: own),
          author: () async => CrateAuthor(uid: 'new-1', keys: joinerKeys),
          makerChecks: InviteMakerChecks(const FlutterSecureStorage()),
        );
        final made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
        await joiner.acceptInviteCode(await joiner.previewInviteCode(made.code));
        final invite = (await owner.invites(orchardId)).singleWhere((i) => i.id == made.inviteId);
        await owner.confirmInvite(orchardId, invite);
        return invite;
      }

      const slot = 'orchard_join_maker_v1';

      test('holding the keys the code was checked over: the team comes in, and the note goes', () async {
        await letIn();
        expect(await const FlutterSecureStorage().read(key: '$slot.$orchardId'), isNotNull);
        expect(await joiner.refresh(), [orchardId]);
        expect(await const FlutterSecureStorage().read(key: '$slot.$orchardId'), isNull);
        final db = await joiner.databases.open(orchardId);
        final info = await db.customSelect('SELECT record_problem FROM orchard_info WHERE id = 1').getSingle();
        expect(info.read<String?>('record_problem'), isNull);
      });

      test('not holding them: nothing syncs, the record is said to be wrong, and it stays so', () async {
        await letIn();
        // As if the keys the code held over were another's than the record's:
        // what a server that shows another record comes to.
        final other = await AccountKeys.generate();
        await InviteMakerChecks(const FlutterSecureStorage())
            .remember(orchardId, joiner: 'new-1', maker: await other.publish('owner-1'));
        for (var i = 0; i < 2; i++) {
          expect(await joiner.refresh(), isEmpty);
          final db = await joiner.databases.open(orchardId);
          final info = await db.customSelect('SELECT record_problem FROM orchard_info WHERE id = 1').getSingle();
          expect(info.read<String?>('record_problem'), contains('invite code'));
          final keys = await db.customSelect('SELECT COUNT(*) AS n FROM space_keys').getSingle();
          expect(keys.read<int>('n'), 0, reason: 'nothing it holds comes from that record');
        }
        final summary = await readOrchardSummary(await joiner.databases.open(orchardId), orchardId);
        expect(summary.recordProblem, contains('invite code'));
        expect(summary.active, isFalse);
      });

      test('a maker whose keys moved on since: the record still holds the version the code was checked over', () async {
        await letIn();
        final kept = await InviteMakerChecks(const FlutterSecureStorage())
            .holds(orchardId, server.recordOf(orchardId), joiner: 'new-1');
        expect(kept, isTrue);
        final next = await AccountKeys.generate(version: ownerKeys.version + 1);
        final published = await next.publish('owner-1');
        final r = server.recordOf(orchardId);
        await server.appendAs('owner-1', orchardId, [
          await signRecordEntry(next,
              orchardId: orchardId,
              seq: r.seq + 1,
              prev: r.head,
              type: RecordTypes.memberKeys,
              by: 'owner-1',
              body: {
                ...recordKeysBody(published),
                'endorsement': base64Encode(await ownerKeys.endorse(published)),
              }),
        ], checkCopies: false);
        expect(
            await InviteMakerChecks(const FlutterSecureStorage())
                .holds(orchardId, server.recordOf(orchardId), joiner: 'new-1'),
            isTrue);
      });

      test('the storage not answering: the record is not taken unchecked, and the team comes in once it does',
          () async {
        await letIn();
        final flaky = _FlakyStorage()..down = true;
        final checking = OrchardService(
          server: server.as('new-1'),
          databases: joiner.databases,
          author: () async => CrateAuthor(uid: 'new-1', keys: joinerKeys),
          makerChecks: InviteMakerChecks(flaky),
        );
        expect(await checking.refresh(), isEmpty, reason: 'not synced with the check unread');
        flaky.down = false;
        expect(await checking.refresh(), [orchardId]);
      });

      test("another account's note is none of this account's", () async {
        await letIn();
        expect(
            await InviteMakerChecks(const FlutterSecureStorage())
                .holds(orchardId, server.recordOf(orchardId), joiner: 'someone-else'),
            isNull);
      });
    });

    test('a code sent instead of an invitation to an address names it, and it goes once the code is used', () async {
      await team();
      await owner.invite(orchardId, email: 'priya@example.com', role: role);
      final email = (await owner.invites(orchardId)).single;
      final made = await owner.makeInviteCode(orchardId,
          role: role, expiresIn: 86400, shown: shown, replacesInvite: email.id);
      expect(server.savedCodes.single.replaces, email.id);
      expect((await owner.invites(orchardId)).map((i) => i.id), containsAll([email.id, made.inviteId]));
      await joiner.acceptInviteCode(await joiner.previewInviteCode(made.code));
      expect((await owner.invites(orchardId)).map((i) => i.id), [made.inviteId]);
    });
  });

  group('screens', () {
    Future<void> open(WidgetTester tester, OrchardService service, void Function(BuildContext, WidgetRef) action,
        {List<OrchardSummary> summaries = const [], bool recording = false}) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          // Signed in: Join a team asks a guest to sign in first.
          currentUserProvider.overrideWith((_) => const UserProfile(uid: 'uid-joiner', email: 'joiner@example.com')),
          orchardServiceProvider.overrideWithValue(service),
          orchardSummariesProvider.overrideWith((ref) async => summaries),
          orchardProvenDomainsProvider.overrideWith((ref, id) async => const <String>[]),
          orchardBillingProvider.overrideWith((ref, id) async => _seats(bought: 5, used: 3)),
          recordingModeProvider.overrideWith((ref) => recording),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(onPressed: () => action(context, ref), child: const Text('open')),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await pumpWork(tester);
    }

    OrchardSummary summary({RecordAdminRole? adminRole}) => OrchardSummary(
          id: orchardId,
          name: 'Acme',
          role: FixedRoles.owner,
          can: RoleCan.all,
          crates: [CrateSummary(id: crateId, name: 'Production', level: 'manage', switches: CrateSwitches.all)],
          defaultCrateId: crateId,
          adminRole: adminRole,
        );

    testWidgets('Admin offered: as every team starts it opens every vault; once an owner changed it, it says so and '
        'names what it opens', (tester) async {
      await tester.runAsync(team);
      for (final changed in [false, true]) {
        final s = summary(
            adminRole: changed ? RecordAdminRole(can: {}, crates: {crateId: levelSwitches(CrateLevel.connect)}) : null);
        await open(tester, owner, (context, ref) => showInvitePeople(context, ref, s, way: InviteWay.code),
            summaries: [s]);
        await tester.tap(find.byKey(const ValueKey('invite-summary-change')));
        await pumpWork(tester);
        await tester.tap(find.byKey(const ValueKey('invite-role-admin')));
        await pumpWork(tester);
        final help = tester.widget<Text>(find.byKey(const ValueKey('invite-admin-help'))).data;
        expect(help, changed ? l10n.orchardInviteRoleAdminChangedHelp : l10n.orchardInviteRoleAdminHelp);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      }
    });

    testWidgets('Code or QR: nothing made until Make code; then shown once with its QR code, copied, its expiry '
        'changed, cancelled', (tester) async {
      await tester.runAsync(team);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      await open(tester, owner, (context, ref) => showInvitePeople(context, ref, summary(), way: InviteWay.code),
          summaries: [summary()]);
      expect(server.savedCodes, isEmpty, reason: 'opening the dialog makes nothing');
      expect(find.byKey(const ValueKey('invite-code-not-yet')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('invite-code-make')));
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('invite-code-qr')), findsOneWidget);
      expect(server.savedCodes, hasLength(1));
      final code = tester.widget<SelectableText>(find.byKey(const ValueKey('invite-code-text'))).data!;
      expect(code, matches(RegExp(r'^ZEST(-[A-HJ-NP-Z2-9]{4}){5}$')));
      // What the server has is the lookup id of exactly this code.
      final keys = (await tester.runAsync(() => joinCodeKeys(normalJoinCode(code)!)))!;
      expect(server.savedCodes.single.lookupId, keys.lookupHex);
      expect(find.text(l10n.inviteCodeHoldsSeat(3, 5)), findsOneWidget);
      expect(find.byKey(const ValueKey('invite-code-waiting')), findsOneWidget);
      expect(find.text(l10n.inviteCodeFootnote), findsOneWidget);
      expect(find.byKey(const ValueKey('invite-summary')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('invite-code-copy')));
      await pumpWork(tester);
      expect(copied, code);
      await tester.tap(find.byKey(const ValueKey('invite-code-copy-link')));
      await pumpWork(tester);
      expect(copied, 'https://zestssh.com/join#$code');

      await tester.tap(find.byKey(const ValueKey('invite-code-expiry')));
      await pumpWork(tester);
      await tester.tap(find.text(l10n.inviteCodeExpiryMonth).last);
      await pumpWork(tester);
      expect(find.text(l10n.inviteCodeExpiryMonth), findsOneWidget);

      // Another role: the tags name the offer, so a new code replaces the
      // old one, which stops working.
      await tester.tap(find.byKey(const ValueKey('invite-summary-change')));
      await pumpWork(tester);
      await tester.tap(find.byKey(const ValueKey('invite-role-admin')));
      await pumpWork(tester);
      await tester.tap(find.byKey(const ValueKey('invite-offer-save')));
      await pumpWork(tester);
      expect(server.savedCodes, hasLength(2));
      expect(server.withdrawn, [server.savedCodes.first.inviteId]);
      expect(find.byKey(const ValueKey('invite-code-remade')), findsOneWidget);
      final second = tester.widget<SelectableText>(find.byKey(const ValueKey('invite-code-text'))).data!;
      expect(second, isNot(code));

      await tester.tap(find.byKey(const ValueKey('invite-code-cancel')));
      await pumpWork(tester);
      expect(server.withdrawn, [server.savedCodes.first.inviteId, server.savedCodes.last.inviteId]);
      expect(find.byKey(const ValueKey('invite-code-qr')), findsNothing, reason: 'the dialog closed');
      await tester.pump(const Duration(seconds: 5));
      // The code was copied as a secret is, but stays 3 minutes
      // on the clipboard: past the 45 seconds of other secrets
      // it is still there, and past the 3 minutes it is not.
      await tester.pump(kSecretClipboardLife);
      expect(SecretClipboard.holding, isTrue);
      await tester.pump(kInviteClipboardLife);
      expect(SecretClipboard.holding, isFalse);
    });

    testWidgets('a code closed before it is kept is withdrawn at once; one left on screen 3 seconds stays',
        (tester) async {
      await tester.runAsync(team);
      await open(tester, owner, (context, ref) => showInvitePeople(context, ref, summary(), way: InviteWay.code),
          summaries: [summary()]);
      await tester.tap(find.byKey(const ValueKey('invite-code-make')));
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('invite-code-keep-note')), findsOneWidget);
      await tester.tap(find.text(l10n.done));
      await pumpWork(tester);
      expect(server.withdrawn, [server.savedCodes.single.inviteId], reason: 'closed before it was kept');

      await open(tester, owner, (context, ref) => showInvitePeople(context, ref, summary(), way: InviteWay.code),
          summaries: [summary()]);
      await tester.tap(find.byKey(const ValueKey('invite-code-make')));
      await pumpWork(tester);
      await tester.pump(const Duration(seconds: 3));
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('invite-code-keep-note')), findsNothing, reason: 'kept after 3 seconds');
      await tester.tap(find.text(l10n.done));
      await pumpWork(tester);
      expect(server.withdrawn, hasLength(1), reason: 'the kept code stays');
      await tester.pump(const Duration(seconds: 20));
    });

    testWidgets('a team code: how many people can use it is chosen before it is made, and said', (tester) async {
      await tester.runAsync(team);
      await open(tester, owner, (context, ref) => showInvitePeople(context, ref, summary(), way: InviteWay.code),
          summaries: [summary()]);
      expect(find.text(l10n.inviteCodePeople(1)), findsOneWidget);
      expect(find.byKey(const ValueKey('invite-code-team-note')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('invite-code-uses')));
      await pumpWork(tester);
      await tester.tap(find.text(l10n.inviteCodePeople(10)).last);
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('invite-code-team-note')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('invite-code-make')));
      await pumpWork(tester);
      expect(server.savedCodes, hasLength(1));
      await tester.pump(const Duration(seconds: 3));
      await pumpWork(tester);
      await tester.tap(find.text(l10n.done));
      await pumpWork(tester);
    });

    testWidgets('recording mode hides the code and its QR code', (tester) async {
      await tester.runAsync(team);
      await open(tester, owner, (context, ref) => showInvitePeople(context, ref, summary(), way: InviteWay.code),
          summaries: [summary()], recording: true);
      await tester.tap(find.byKey(const ValueKey('invite-code-make')));
      await pumpWork(tester);
      expect(server.savedCodes, hasLength(1));
      expect(find.byKey(const ValueKey('invite-code-qr')), findsNothing);
      expect(find.byKey(const ValueKey('invite-code-qr-hidden')), findsOneWidget);
      final shownCode = tester.widget<SelectableText>(find.byKey(const ValueKey('invite-code-text'))).data!;
      expect(normalJoinCode(shownCode), isNull, reason: 'no code on the screen');
      await tester.tap(find.text(l10n.done));
      await pumpWork(tester);
    });

    testWidgets('Join a team: typed in any case, checked, then joined; the maker lets them in without comparing',
        (tester) async {
      late MadeInviteCode made;
      await tester.runAsync(() async {
        await team();
        made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      });
      await open(tester, joiner, (context, ref) => showJoinTeam(context));
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('join-code-field')), matching: find.byType(EditableText)),
          ' ${writtenJoinCode(made.code).toLowerCase()} ');
      await tester.tap(find.byKey(const ValueKey('join-continue')));
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('join-team-name')), findsOneWidget);
      expect(find.text(l10n.joinChecked('Acme')), findsOneWidget);
      expect(find.text(l10n.joinInvitedBy('owner@example.com')), findsOneWidget);
      expect(find.text('Member'), findsOneWidget);
      expect(find.text(l10n.inviteSummaryVault('Production', l10n.crateLevelUse)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('join-accept')));
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('join-joined')), findsOneWidget);
      await tester.tap(find.text(l10n.done));
      await pumpWork(tester);

      // The maker: under Waiting for you, keys checked; Let in with no
      // fingerprint to compare.
      await open(tester, owner, (context, ref) => showOrchardMembers(context, ref, orchardId),
          summaries: [summary()]);
      expect(find.text(l10n.keysCheckedPill), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('invite-confirm-${made.inviteId}')));
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('review-keys-checked')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('review-let-in')));
      await pumpWork(tester);
      expect(find.byKey(const ValueKey('invitee-fingerprint')), findsNothing, reason: 'the code checked their keys');
      expect(server.confirmations.single.inviteId, made.inviteId);
      expect(server.recordOf(orchardId).members.containsKey('new-1'), isTrue);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a code offering access further off than a date can say: what it offers is shown all the same', (tester) async {
      late MadeInviteCode made;
      await tester.runAsync(() async {
        await team();
        made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown, endsAt: 9007199254740991);
      });
      await open(tester, joiner, (context, ref) => showJoinTeam(context));
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('join-code-field')), matching: find.byType(EditableText)),
          writtenJoinCode(made.code));
      await tester.tap(find.byKey(const ValueKey('join-continue')));
      await pumpWork(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('join-team-name')), findsOneWidget);
      expect(find.textContaining('275760'), findsOneWidget);
    });

    testWidgets('a code that does not check out is refused in plain words, with no way to join anyway', (tester) async {
      late MadeInviteCode made;
      await tester.runAsync(() async {
        await team();
        made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      });
      server.offer = (o) => InviteCodeOffer(
          invite: o.invite, grants: o.grants, makerKeys: o.makerKeys, ownerTag: Uint8List(32), offerSealed: o.offerSealed);
      await open(tester, joiner, (context, ref) => showJoinTeam(context, code: made.code));
      await tester.tap(find.byKey(const ValueKey('join-continue')));
      await pumpWork(tester);
      expect(find.text(l10n.joinCodeCheckFailed), findsOneWidget);
      expect(find.byKey(const ValueKey('join-accept')), findsNothing);
    });

    // ZestSSH Cloud takes no more tries after too many codes that found
    // none (routes/invites.js, TOO_MANY_TRIES): the person joining is told
    // that, with its code, where they were told the inviter's "That's a lot
    // of invitations".
    testWidgets("too many tries with codes: the joiner's own words, with the error's code", (tester) async {
      late MadeInviteCode made;
      await tester.runAsync(() async {
        await team();
        made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      });
      server.offer = (o) => throw const OrchardServerException(429, 'rate-limited');
      await open(tester, joiner, (context, ref) => showJoinTeam(context, code: made.code));
      await tester.tap(find.byKey(const ValueKey('join-continue')));
      await pumpWork(tester);
      expect(find.text(ErrorCodes.withCode(l10n.joinCodeTooManyTries, ErrorCodes.joinCodeTooManyTries)), findsOneWidget);
      expect(find.textContaining('ZS-1402'), findsOneWidget);
      expect(find.textContaining(l10n.orchardInviteErrorRateLimited), findsNothing);
      expect(find.byKey(const ValueKey('join-accept')), findsNothing);
    });

    testWidgets('a link opens Join a team with the code typed in, and nothing is asked until they continue',
        (tester) async {
      late MadeInviteCode made;
      await tester.runAsync(() async {
        await team();
        made = await owner.makeInviteCode(orchardId, role: role, expiresIn: 3600, shown: shown);
      });
      await open(tester, joiner, (context, ref) {
        expect(answerJoinLink(Uri.parse('zestssh://join#${writtenJoinCode(made.code)}'), context), isTrue);
      });
      expect(find.byKey(const ValueKey('join-from-link')), findsOneWidget);
      expect(tester.widget<EditableText>(find.descendant(
              of: find.byKey(const ValueKey('join-code-field')), matching: find.byType(EditableText)))
          .controller
          .text, writtenJoinCode(made.code));
      expect(server.codeLookups, 0, reason: 'nothing asked yet');
      await tester.tap(find.byKey(const ValueKey('join-continue')));
      await pumpWork(tester);
      expect(server.codeLookups, 1);
      expect(find.text(l10n.joinChecked('Acme')), findsOneWidget);
      // Other links are not this one's.
      expect(answerJoinLink(Uri.parse('zestssh://share?d=x'), null), isFalse);
      // Without Orchards a join link is taken and opens nothing
      // (answerJoinLink, lib/features/orchards/widgets/join_team.dart).
    }, skip: !kOrchardsEnabled);
  });

  test('the code and its link go only into the link, never a query the website would receive', () {
    const code = 'ZESTABCDEFGHJKLMNPQRSTUV';
    final link = Uri.parse(joinCodeLink(code));
    expect(link.query, isEmpty);
    expect(link.fragment, writtenJoinCode(code));
    expect(utf8.encode(link.path), utf8.encode('/join'));
  });
}

/// Lets the crypto and the fake server's work finish, then the frames,
/// without waiting for a spinner that turns until someone uses the code.
Future<void> pumpWork(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
