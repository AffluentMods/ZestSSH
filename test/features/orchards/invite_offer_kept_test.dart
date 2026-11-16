
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/orchards/members/invite_maker_checks.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';

// What an inviter offered is what is signed when someone is let in (found in
// two security reviews). ZestSSH
// Cloud keeps an invitation's role, extra vaults and end date and lists them to
// whoever lets the person in, whose device signs them into the member.add. The
// device that made an invitation or a code keeps the digest of its offer; a
// listing with another lets nobody in from there. On a device of a code's
// maker, a code whose signed copy is not there to say what it offers lets
// nobody in either. A code for one person is used on its own row. Accepting a
// code keeps the maker's keys first.

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

/// A dishonest server: it lists invitations as [listed] makes them, keeps
/// what a confirmation would sign, and fails accepting a code as [failAccept]
/// says.
class _Dishonest extends FakeCrateServer {
  _Dishonest() : super(accountUid: 'owner-1');

  OrchardInvite Function(OrchardInvite)? listed;
  final confirmed = <RecordEntry>[];
  Object? failAccept;
  var accepts = 0;

  @override
  Future<List<OrchardInvite>> invites(String orchardId) async =>
      [for (final i in await super.invites(orchardId)) listed == null ? i : listed!(i)];

  @override
  Future<void> confirmInvite(String orchardId, String inviteId,
      {required RecordEntry entry, required List<GrantCopy> copies, RecordEntry? device}) async {
    confirmed.add(entry);
    await super.confirmInvite(orchardId, inviteId, entry: entry, copies: copies, device: device);
  }

  @override
  Future<String> acceptInviteCode(String lookupId,
      {required int keyVersion, required Uint8List joinerTag, JoinDevice? device}) async {
    accepts++;
    final fail = failAccept;
    if (fail != null) throw fail;
    final id = await super.acceptInviteCode(lookupId, keyVersion: keyVersion, joinerTag: joinerTag, device: device);
    final after = useThenFail;
    if (after != null) throw after;
    return id;
  }

  /// Uses the code, then answers with this.
  Object? useThenFail;
}

/// The keychain, refusing to write while [down].
class _NoWrite extends FlutterSecureStorage {
  bool down = false;

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (down) throw StateError('played: the keychain does not write');
    return super.write(key: key, value: value);
  }
}

OrchardInvite _relisted(OrchardInvite i, {String? id, String? role, int? endsAt, bool keepEnd = true, InviteCodeInfo? code}) =>
    OrchardInvite(
      id: id ?? i.id,
      email: i.email,
      role: role ?? i.role,
      grants: i.grants,
      endsAt: keepEnd ? (endsAt ?? i.endsAt) : null,
      expiresAt: i.expiresAt,
      expired: i.expired,
      invitedBy: i.invitedBy,
      acceptedUid: i.acceptedUid,
      acceptedKeys: i.acceptedKeys,
      code: code ?? i.code,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _Dishonest server;
  late AccountKeys ownerKeys;
  late AccountKeys newKeys;
  final storages = <_MemoryStorage>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = _Dishonest();
    ownerKeys = await AccountKeys.generate();
    newKeys = await AccountKeys.generate();
    await server.publish('owner-1', ownerKeys, email: 'owner@example.com');
    await server.publish('new-1', newKeys, email: 'new@example.com');
  });

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  /// A device of [uid] with a database of its own.
  OrchardService device(String uid, AccountKeys keys, {FlutterSecureStorage? checks}) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return OrchardService(
      server: uid == 'owner-1' ? server : server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      makerChecks: InviteMakerChecks(checks ?? const FlutterSecureStorage()),
    );
  }

  group('an invitation to an address', () {
    late OrchardService owner;
    late String orchardId;
    late String member;
    late int endsAt;

    Future<OrchardInvite> invited() async {
      owner = device('owner-1', ownerKeys);
      orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      await owner.createCrate(orchardId, 'Staging');
      member = server.recordOf(orchardId).roles.values.single.id;
      endsAt = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000;
      await owner.invite(orchardId, email: 'New@Example.com ', role: member, endsAt: endsAt);
      final made = (await owner.invites(orchardId)).single;
      server.acceptAs(orchardId, made.id, 'new-1');
      return (await owner.invites(orchardId)).single;
    }

    test('listed with another role and no end date, the device that made it lets nobody in and signs nothing', () async {
      final listed = await invited();
      server.listed = (i) => _relisted(i, role: FixedRoles.admin, keepEnd: false);
      final changed = (await owner.invites(orchardId)).single;
      expect(await owner.inviteOfferChanged(orchardId, changed), isTrue);
      await expectLater(owner.confirmInvite(orchardId, changed),
          throwsA(isA<OrchardInviteError>().having((e) => e.problem, 'problem', OrchardInviteProblem.inviteOfferChanged)));
      expect(server.confirmed, isEmpty, reason: 'nothing was signed');
      // Listed under another id, for the same address: the same.
      server.listed = (i) => _relisted(i, id: 'another-row', endsAt: endsAt + 3600);
      expect(await owner.inviteOfferChanged(orchardId, (await owner.invites(orchardId)).single), isTrue);
      // Sent again as listed: refused too.
      await expectLater(owner.resendInvite(orchardId, changed), throwsA(isA<OrchardInviteError>()));
      expect(listed.role, member);
    });

    test('listed as made, they are let in as offered, and what was kept goes', () async {
      final listed = await invited();
      expect(await owner.inviteOfferChanged(orchardId, listed), isFalse);
      await owner.confirmInvite(orchardId, listed);
      expect(server.confirmed.single.body['role'], member);
      expect(server.confirmed.single.body['ends_at'], endsAt);
      final db = await owner.databases.open(orchardId);
      expect(await LocalStateStore(db).keysWithPrefix(kInviteOfferState), isEmpty);
    });

    test('withdrawn, what was kept goes', () async {
      final listed = await invited();
      await owner.withdrawInvite(orchardId, listed.id);
      final db = await owner.databases.open(orchardId);
      expect(await LocalStateStore(db).keysWithPrefix(kInviteOfferState), isEmpty);
    });

    test('on a device that made none of it, the offer as listed is what its person compares and confirms', () async {
      await invited();
      final other = device('owner-1', ownerKeys);
      await other.refresh();
      final listed = (await other.invites(orchardId)).single;
      expect(await other.inviteOfferChanged(orchardId, listed), isFalse);
      await other.confirmInvite(orchardId, listed);
      expect(server.recordOf(orchardId).members['new-1']!.role, member);
    });
  });

  group('an invite code', () {
    late OrchardService owner;
    late OrchardService joiner;
    late String orchardId;
    late String member;
    const shown = JoinOffer(team: 'Acme', role: 'Member', vaults: [JoinOfferVault('Production', 'use')]);

    Future<MadeInviteCode> used({int usesMax = 1}) async {
      owner = device('owner-1', ownerKeys);
      joiner = device('new-1', newKeys);
      orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      member = server.recordOf(orchardId).roles.values.single.id;
      final made = await owner.makeInviteCode(orchardId, role: member, expiresIn: 3600, shown: shown, usesMax: usesMax);
      await joiner.acceptInviteCode(await joiner.previewInviteCode(made.code));
      return made;
    }

    test('made here: its signed copy withheld and Admin listed, it lets nobody in', () async {
      await used();
      server.listed = (i) => _relisted(i,
          role: FixedRoles.admin,
          code: InviteCodeInfo(
              makerUid: i.code!.makerUid, makerKeyVersion: i.code!.makerKeyVersion, joinerTag: i.code!.joinerTag));
      final listed = (await owner.invites(orchardId)).single;
      final check = await owner.checkInviteCode(orchardId, listed);
      expect(check.checked, isFalse);
      expect(check.offerChanged, isTrue);
      await expectLater(owner.confirmInvite(orchardId, listed), throwsA(isA<OrchardInviteError>()));
      expect(server.confirmed, isEmpty);
    });

    test('on another device of its maker, with nothing kept there, a withheld copy lets nobody in either',
        () async {
      await used();
      final other = device('owner-1', ownerKeys);
      await other.refresh();
      server.listed = (i) => _relisted(i,
          code: InviteCodeInfo(
              makerUid: i.code!.makerUid, makerKeyVersion: i.code!.makerKeyVersion, joinerTag: i.code!.joinerTag));
      final listed = (await other.invites(orchardId)).single;
      expect(await other.inviteOfferChanged(orchardId, listed), isFalse, reason: 'nothing was kept on this device');
      expect((await other.checkInviteCode(orchardId, listed)).offerChanged, isTrue);
      server.listed = null;
      final honest = (await other.checkInviteCode(orchardId, (await other.invites(orchardId)).single));
      expect(honest.checked, isTrue, reason: 'with the copy there, it checks out as before');
    });

    test('a code for one person, its use listed on a row made from it, is not checked', () async {
      await used();
      final real = (await owner.invites(orchardId)).single;
      expect((await owner.checkInviteCode(orchardId, real)).checked, isTrue);
      final c = real.code!;
      final elsewhere = _relisted(real,
          id: 'another-row',
          code: InviteCodeInfo(
              makerUid: c.makerUid,
              makerKeyVersion: c.makerKeyVersion,
              sealed: c.sealed,
              joinerTag: c.joinerTag,
              uses: c.uses,
              usesMax: c.usesMax,
              fromCode: real.id));
      expect((await owner.checkInviteCode(orchardId, elsewhere)).checked, isFalse);
    });
  });

  group('accepting a code', () {
    late OrchardService owner;
    late String orchardId;
    const shown = JoinOffer(team: 'Acme', role: 'Member', vaults: [JoinOfferVault('Production', 'use')]);
    const slot = 'orchard_join_maker_v1.';

    Future<InviteCodePreview> preview(OrchardService joiner) async {
      owner = device('owner-1', ownerKeys);
      orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single.id;
      final made = await owner.makeInviteCode(orchardId, role: member, expiresIn: 3600, shown: shown);
      return joiner.previewInviteCode(made.code);
    }

    test("the maker's keys are kept before the code is used: where they cannot be, the code is not used", () async {
      final keychain = _NoWrite();
      final joiner = device('new-1', newKeys, checks: keychain);
      final p = await preview(joiner);
      keychain.down = true;
      await expectLater(joiner.acceptInviteCode(p), throwsA(isA<StateError>()));
      expect(server.accepts, 0, reason: 'the code was not used');
    });

    test('the server says the code was not used: what was kept before is as it was', () async {
      final joiner = device('new-1', newKeys);
      final p = await preview(joiner);
      server.failAccept = const OrchardServerException(404, 'join-code-invalid');
      await expectLater(joiner.acceptInviteCode(p), throwsA(isA<OrchardServerException>()));
      expect(await const FlutterSecureStorage().read(key: '$slot$orchardId'), isNull);
    });

    // Found in a review: every server error put back what was
    // kept, though a 502 from a proxy may come after the server used the
    // code, and "You used this code already" says it was used by this
    // account: nothing was kept, and the team's first record was taken
    // unchecked.
    for (final (status, code) in [(502, null), (503, null), (500, null), (409, 'code-used-already')]) {
      test('the server used the code and answered $status${code == null ? '' : ' $code'}: the maker\'s keys stay kept', () async {
        final joiner = device('new-1', newKeys);
        final p = await preview(joiner);
        server.useThenFail = OrchardServerException(status, code);
        await expectLater(joiner.acceptInviteCode(p), throwsA(isA<OrchardServerException>()));
        expect((await owner.invites(orchardId)).single.accepted, isTrue, reason: 'the code was used');
        expect(await const FlutterSecureStorage().read(key: '$slot$orchardId'), contains('"uid":"owner-1"'),
            reason: 'the first record of this team must hold the maker\'s keys');
      });
    }

    test('the other refusals say the code was not used: what was kept before is put back', () async {
      for (final (status, code) in [(400, 'invalid-request'), (409, 'already-member'), (409, 'rules-unmet'), (429, null)]) {
        final joiner = device('new-1', newKeys);
        final p = await preview(joiner);
        server.failAccept = OrchardServerException(status, code);
        await expectLater(joiner.acceptInviteCode(p), throwsA(isA<OrchardServerException>()));
        expect(await const FlutterSecureStorage().read(key: '$slot$orchardId'), isNull, reason: '$status $code');
      }
    });

    test('no answer (the code may have been used): the keys stay kept, and the first record must hold them', () async {
      final joiner = device('new-1', newKeys);
      final p = await preview(joiner);
      server.failAccept = StateError('played: the app ended');
      await expectLater(joiner.acceptInviteCode(p), throwsA(isA<StateError>()));
      expect(await const FlutterSecureStorage().read(key: '$slot$orchardId'), contains('"uid":"owner-1"'));
    });
  });
}
