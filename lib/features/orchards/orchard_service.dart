import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:uuid/uuid.dart';
import 'package:zest_ssh_core/dartssh2.dart' show OpenSSHEd25519KeyPair, SSHKeyPair;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/orchards/crypto/join_device.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/members/invite_maker_checks.dart';
import 'package:zestssh/features/orchards/members/member_actions.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/sessionlogs/session_log_redactor.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/terminal/terminal_text_filter.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';
import 'package:zestssh/services/ssh_cert/ssh_wire.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';
import 'package:zestssh/utils/type_name.dart';

export 'package:zestssh/features/teams/account_key_service.dart' show AccountKeysNotReady;

part 'orchard_management.dart';
part 'orchard_certificates.dart';
part 'orchard_cert_handover.dart';
part 'orchard_pass_handover.dart';
part 'orchard_recovery.dart';
part 'orchard_trash_history.dart';
part 'orchard_activity.dart';
part 'orchard_session_logs.dart';
part 'orchard_access.dart';
part 'orchard_devices.dart';
part 'orchard_setup.dart';
part 'orchard_unwatched.dart';
part 'orchard_deletion.dart';

/// One change to an Orchard's record: an entry's type and body.
typedef RecordChange = ({String type, Map<String, Object?> body});

/// Where an Orchard's own database (on this device only) keeps the names of
/// the vaults that left it lately, by id: a notice can still name one (design
/// 66: a member told a vault was taken away from them, after it left).
const String kGoneCrateNamesState = 'orchards.gone_crate_names';

/// Where an Orchard's own database (on this device only) keeps what this
/// device offered with each invitation or invite code it made: a key
/// per invitation, 'to:' and the address or 'id:' and the code's invitation
/// id, holding JSON {"id": invitation id, "offer": base64 of joinOfferDigest,
/// "at": seconds since the epoch}.
const String kInviteOfferState = 'orchards.invite_offer.';

/// The names of the vaults that left [db] lately, by id, oldest first.
Future<Map<String, String>> goneCrateNames(AppDatabase db) async {
  final raw = await LocalStateStore(db).read(kGoneCrateNamesState);
  if (raw == null) return const {};
  try {
    final m = jsonDecode(raw);
    if (m is Map) {
      return {
        for (final e in m.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    }
  } catch (_) {/* a value written otherwise: none */}
  return const {};
}

/// What a new Crate allows: SFTP and port forwarding, not agent forwarding.
const Set<String> kDefaultCrateAllow = {CrateSwitches.forward, CrateSwitches.sftp};

/// The rank of the role an Orchard starts with: room above and below
/// for roles the owners make.
const int kDefaultMemberRank = 1000;

/// The roles an Orchard's owners may make (the server holds to it too).
const int kMaxOrchardRoles = 30;

/// Makes and keeps this device's Orchards (3.0): creates an
/// Orchard with its first Crate, adds Crates, invites and confirms members,
/// and brings each Orchard's database up to date with the server: its
/// record (checked entry by entry), the members, roles and Crates that
/// follow from it, and the keys this account holds, opened with its account
/// key. What this account can no longer open leaves the device.
///
/// Every change to who is in an Orchard or what they may do is an entry in
/// the Orchard's record, signed here and checked against the same rules
/// here and on the server. A change that lets someone open the Orchard or a
/// Crate brings every generation of those keys sealed to them.
class OrchardService {
  OrchardService({
    required this.server,
    required this.databases,
    required this.author,
    this.onContact,
    this.onPass,
    this.flushEvents,
    this.onTeamDeleted,
    this.deviceKeys,
    this.makerChecks,
    this.cloudAway,
    this.loginRecordWait = const Duration(seconds: 6),
    this.onServerList,
  });

  /// ZestSSH Cloud's list of the teams of the account it was asked as ([uid]) came,
  /// before anything opens one of them: a team on the device with no owner yet goes
  /// into the profile only on this word.
  final Future<void> Function(Set<String> ids, String uid)? onServerList;

  final CrateServer server;
  final OrchardDatabasesNotifier databases;

  /// Whether the app knows that ZestSSH Cloud is not answering just now
  /// (lib/services/cloud/cloud_reach.dart). A login then goes by what the
  /// device holds at once, and asks nothing of a server that would only
  /// keep it waiting. Null where nothing knows: the server is then asked.
  final bool Function()? cloudAway;

  /// How long a login waits for the server's copy of the record before it
  /// goes by the device's own. The API's own patience, half a minute, is
  /// for work nobody sits and watches.
  final Duration loginRecordWait;

  /// Where this device keeps its own signing key (trusted devices);
  /// null where there is nowhere to keep one. The device then says nothing
  /// about itself, and is one nobody can approve.
  final DeviceIdentityStore? deviceKeys;

  /// Where this device keeps the keys an invite code was checked over, for the
  /// first record it reads of that team; null where there is nowhere to keep
  /// them (nothing is then held to them).
  final InviteMakerChecks? makerChecks;

  /// What is in progress between devices while the app runs
  /// (orchard_devices.dart).
  final _deviceRun = _DeviceRun();

  /// What this device keeps of session logs while the app runs
  /// (orchard_session_logs.dart).
  final _sessionLogRun = _SessionLogRun();

  /// Called each time the list of Orchards came back from ZestSSH Cloud:
  /// this device reached it, for the Orchards' offline limits.
  final void Function()? onContact;

  /// Called when an offline pass was handed to this device and taken in,
  /// or refused (orchard_pass_handover.dart): what the offline limits close
  /// here is looked at again at once, and whatever lists the Orchards is
  /// told.
  final void Function()? onPass;

  /// Has the device that sends an Orchard's events on (event export)
  /// send what it has not sent yet, now. Called before a change made here
  /// ends that sending or hands it to another device (what members did
  /// until then is still its to send), and before an Orchard this account
  /// leaves goes from the device. Null where nothing sends.
  final Future<void> Function(String orchardId)? flushEvents;

  /// Called when a deleted team left this device, with its name
  /// and who deleted it, for the notice that says so: its own database, where
  /// a notice would live, is gone with it.
  final void Function(TeamGone gone)? onTeamDeleted;

  Future<void> _flushEvents(String orchardId) async {
    try {
      await flushEvents?.call(orchardId);
    } catch (e) {
      // Whatever comes of it, the change goes on.
      AppLogger.info('Orchards: the events left to send did not go (${errorKind(e)})');
    }
  }

  /// The signed-in account and its keys; null when they are not ready.
  final Future<CrateAuthor?> Function() author;

  Future<CrateAuthor> _me() async => await author() ?? (throw const AccountKeysNotReady());

  /// The signed-in account and its keys, or null when they are not ready.
  Future<CrateAuthor?> currentAuthor() => author();

  /// One change at a time per Orchard: its record grows one entry after
  /// another.
  final _queues = <String, Future<void>>{};

  Future<T> _serial<T>(String orchardId, Future<T> Function() body) {
    final run = (_queues[orchardId] ?? Future<void>.value()).then((_) => body());
    _queues[orchardId] = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Creates an Orchard owned by this account, with its first Crate and a
  /// first role named [memberRoleName] (use of that Crate, the role people
  /// are invited into until the owners make others), and returns its id.
  /// Its keys exist only here and, sealed to this account's key, on the
  /// server.
  Future<String> createOrchard(String name,
      {required String firstCrateName, required String memberRoleName}) async {
    final me = await _me();
    const uuid = Uuid();
    final orchardId = uuid.v4();
    final crateId = uuid.v4();
    final roleId = uuid.v4();
    final orchardKey = newSpaceKey();
    final crateKey = newSpaceKey();
    final myKey = me.keys.encryption.publicKey;
    final entry = await signRecordEntry(
      me.keys,
      orchardId: orchardId,
      seq: 1,
      prev: const [],
      type: RecordTypes.create,
      by: me.uid,
      body: {
        // Owners and admins only after comparing codes, in the record itself.
        'format': kRecordFormat,
        'owner': {...recordKeysBody(await me.keys.publish(me.uid)), 'uid': me.uid},
        'key_commit':
            base64Encode(await keyCommitment(orchardKey, orchardId: orchardId, generation: 1)),
        'crate': {
          'id': crateId,
          'owners_only': false,
          'allow': switchList(kDefaultCrateAllow),
          'key_commit':
              base64Encode(await keyCommitment(crateKey, orchardId: orchardId, crateId: crateId, generation: 1)),
        },
        'roles': [
          {
            'id': roleId,
            'rank': kDefaultMemberRank,
            'name_enc': base64Encode(await encryptRoleName(memberRoleName, orchardKey,
                orchardId: orchardId, roleId: roleId, generation: 1)),
            'name_gen': 1,
            'can': const <String>[],
            'crates': {crateId: switchList(levelSwitches(CrateLevel.use))},
          },
        ],
      },
    );
    final orchardSealed = await sealOrchardKey(myKey, orchardKey, orchardId: orchardId, generation: 1);
    final crateSealed =
        await sealCrateKey(myKey, crateKey, orchardId: orchardId, crateId: crateId, generation: 1);
    await server.createOrchard(NewOrchard(
      id: orchardId,
      nameEnc: await encryptOrchardName(name, orchardKey, orchardId: orchardId, generation: 1),
      keySealed: orchardSealed,
      keyVersion: me.keys.version,
      keySignature: await signKeyCopy(me.keys, _ownCopy(me, orchardId: orchardId, generation: 1), orchardSealed),
      firstCrate: FirstCrate(
        id: crateId,
        nameEnc: await encryptCrateName(firstCrateName, crateKey,
            orchardId: orchardId, crateId: crateId, generation: 1),
        keySealed: crateSealed,
        keySignature: await signKeyCopy(
            me.keys, _ownCopy(me, orchardId: orchardId, crateId: crateId, generation: 1), crateSealed),
      ),
      record: entry,
    ));
    final db = await databases.open(orchardId);
    final record = await LocalRecord.empty(orchardId).extend(db, [entry]);
    await _store(
      db,
      _snapshot(
        record.latest,
        me,
        name: name.trim(),
        keyGeneration: 1,
        orchardKeys: {1: orchardKey},
        crates: {crateId: (name: firstCrateName.trim(), generation: 1, keys: {1: crateKey}, rotationDue: false)},
      ),
      defaultCrate: crateId,
    );
    return orchardId;
  }

  /// Adds a Crate to an Orchard and returns its id: a crate.add entry, and
  /// the Crate's key sealed to everyone it opens to (the owners, the admins
  /// unless it is [ownersOnly], and this account). Throws
  /// [OrchardRecordRefused] when this account's role may not add it (only
  /// owners add an owners-only Crate).
  Future<String> createCrate(String orchardId, String name, {bool ownersOnly = false}) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    return _serial(orchardId, () async {
      for (var attempt = 0;; attempt++) {
        final record = await pullRecord(db, orchardId, server);
        final crateId = const Uuid().v4();
        final crateKey = newSpaceKey();
        final entry = await _sign(me, record, RecordTypes.crateAdd, {
          'id': crateId,
          'owners_only': ownersOnly,
          'allow': switchList(kDefaultCrateAllow),
          'key_commit':
              base64Encode(await keyCommitment(crateKey, orchardId: orchardId, crateId: crateId, generation: 1)),
        });
        final after = await _probe(record, entry);
        final copies = await _copiesFor(db, orchardId, me, record.latest, after, fresh: {crateId: {1: crateKey}});
        try {
          await server.createCrate(
            orchardId,
            NewCrate(
              id: crateId,
              nameEnc: await encryptCrateName(name, crateKey, orchardId: orchardId, crateId: crateId, generation: 1),
              entry: entry,
              copies: copies,
            ),
          );
        } on OrchardServerException catch (e) {
          if ((e.recordMoved || e.code == 'copies-changed') && attempt < 2) {
            await _refreshOrchard(orchardId, me);
            continue;
          }
          rethrow;
        }
        final now = await record.extend(db, [entry]);
        await db.transaction(() async {
          await _putCrate(db, now.latest, me.uid, crateId, name: name.trim(), generation: 1, rotationDue: false);
          await _putKey(db, 'crate', crateId, 1, crateKey);
        });
        return crateId;
      }
    });
  }

  /// Appends one change to the Orchard's record (a role, a member's role,
  /// Crates, end date or standing, a Crate's settings), with every key it
  /// hands out sealed to whoever gains it. Throws [OrchardRecordRefused] when
  /// the rules refuse it, before anything is sent, and
  /// [MemberKeysNotTrusted] when someone who would gain a key has keys this
  /// device does not trust yet.
  Future<void> change(String orchardId, String type, Map<String, Object?> body) =>
      changeAll(orchardId, [(type: type, body: body)]);

  /// Appends [changes] to the Orchard's record in one step, all or nothing
  /// (making someone an owner and stepping down is two entries), with every
  /// key they hand out. See [change].
  Future<void> changeAll(String orchardId, List<RecordChange> changes) =>
      _changeWith(orchardId, (_) async => changes);

  /// Appends the changes [build] makes from the record as it stands on the
  /// server, checked entry by entry, then brings the Orchard up to date
  /// ([refresh] false when the change takes this account out of it).
  Future<void> _changeWith(
    String orchardId,
    Future<List<RecordChange>> Function(OrchardRecord latest) build, {
    bool refresh = true,
  }) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    await _serial(orchardId, () async {
      // True once the changes are in the record; false when there were none
      // to make.
      Future<bool> append() async {
        for (var attempt = 0;; attempt++) {
          final record = await pullRecord(db, orchardId, server);
          final changes = await build(record.latest);
          if (changes.isEmpty) return false;
          final entries = <RecordEntry>[];
          var after = record.latest;
          for (final c in changes) {
            final entry = await signRecordEntry(me.keys,
                orchardId: orchardId,
                seq: after.seq + 1,
                prev: after.head,
                type: c.type,
                body: c.body,
                by: me.uid);
            after = await _probeOn(after, entry);
            entries.add(entry);
          }
          final copies = await _copiesFor(db, orchardId, me, record.latest, after);
          // The team's events are sent on, and after this change they
          // are not, or another device sends them: the one that sends now
          // says what it has left first.
          final sent = record.latest.eventExport;
          if (sent != null && after.eventExport?.keyText != sent.keyText) await _flushEvents(orchardId);
          try {
            await server.appendRecord(orchardId, entries, copies: copies);
          } on OrchardServerException catch (e) {
            if ((e.recordMoved || e.code == 'copies-changed') && attempt < 2) {
              await _refreshOrchard(orchardId, me);
              continue;
            }
            rethrow;
          }
          await record.extend(db, entries);
          return true;
        }
      }

      final changed = await _namingDevice(append);
      if (changed && refresh) await _refreshOrchard(orchardId, me);
    });
  }

  /// How many people wait for this account to confirm them, by Orchard, as
  /// of the last [refresh] (those who may invite). Not kept across
  /// starts.
  Map<String, int> get invitesWaiting => Map.unmodifiable(_invitesWaiting);
  final _invitesWaiting = <String, int>{};

  /// Each Orchard the server lists for this account, by standing ('active',
  /// 'suspended' or 'ended'), as of the last [refresh].
  Map<String, String> get standing => Map.unmodifiable(_standing);
  final _standing = <String, String>{};

  /// The Orchards the server listed for the account [uid] at the last
  /// [refresh] that reached it; null when this run has not asked for that
  /// account yet. An Orchard it leaves out, the account is no longer in.
  Set<String>? listedFor(String uid) => _listedFor == uid ? Set.unmodifiable(_listed) : null;
  String? _listedFor;
  var _listed = <String>{};

  /// Brings every Orchard of this account onto this device and up to date,
  /// and takes the ones it is no longer in off it. Returns the Orchards whose
  /// membership counts now (not suspended, not ended): the ones to sync.
  /// Changes nothing when the server cannot be asked.
  ///
  /// One at a time: a call while one runs waits for it and then runs once
  /// more (calls meanwhile share that one, which starts after each of them).
  /// When two ran at once, the second cleared what the first knew of the
  /// list, so the first took Orchards the server does list for ones it no
  /// longer listed and took them off the device under the second ("Can't
  /// re-open a database after closing it"): the Members page, which
  /// refreshes as it opens, said the members could not be loaded while the
  /// sync of every Orchard ran.
  Future<List<String>> refresh() {
    final queued = _refreshQueued;
    if (queued != null) return queued;
    final running = _refreshRunning;
    if (running == null) return _startRefresh();
    final next = running.then<void>((_) {}, onError: (_) {}).then((_) {
      _refreshQueued = null;
      return _startRefresh();
    });
    _refreshQueued = next;
    return next;
  }

  Future<List<String>>? _refreshRunning;
  Future<List<String>>? _refreshQueued;

  Future<List<String>> _startRefresh() {
    final run = _refreshOnce();
    _refreshRunning = run;
    run.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_refreshRunning, run)) _refreshRunning = null;
    });
    return run;
  }

  Future<List<String>> _refreshOnce() async {
    final me = await _me();
    var remote = await server.orchards();
    // Reached ZestSSH Cloud: the Orchards' offline limits start afresh.
    onContact?.call();
    await onServerList?.call({for (final o in remote) o.id}, me.uid);
    if (remote.isNotEmpty) {
      // In an Orchard: this sign-in says which device it is. A list
      // made before it said so may hold the device back as not approved.
      final heldAsDevice = remote.any((o) => o.rulesUnmet.contains(kTrustedDeviceRule));
      try {
        if (await _nameThisDevice(me, again: heldAsDevice) && heldAsDevice) remote = await server.orchards();
      } catch (e) {
        AppLogger.warning('Orchards: this sign-in could not say which device it is ($e)');
      }
    }
    _listedFor = me.uid;
    _listed = {for (final o in remote) o.id};
    final active = <String>[];
    _invitesWaiting.clear();
    _standing.clear();
    for (final orchard in remote) {
      _standing[orchard.id] = orchard.status;
      if (await _serial(orchard.id, () => _refreshOne(orchard, me))) active.add(orchard.id);
    }
    // What this run read from the server decides what leaves the device.
    final listedNow = {for (final o in remote) o.id};
    for (final id in await databases.onDevice()) {
      if (!listedNow.contains(id)) {
        final why = await _whyUnlisted(id, me);
        if (why == null) continue; // asked again at the next refresh
        if (why.deletedAt != null) {
          // The team was deleted: removed, or its person asked.
          await _teamDeleted(id, why.deletedAt!);
          continue;
        }
        if (why.behind) {
          // The server lost the entry that put this account in (a restore
          // from a backup): what is here stays, and nothing syncs until a
          // member's device has sent the lost entries back.
          AppLogger.info('Orchards: the server is behind an Orchard this device holds; it stays and waits');
          final db = await databases.open(id);
          await db.customStatement('UPDATE orchard_info SET status = ? WHERE id = 1', [kServerBehindStatus]);
          _standing[id] = kServerBehindStatus;
          continue;
        }
        if (why.held) {
          // ZestSSH Cloud alone says this account is out: no record this
          // device checked says so. What is here stays, held back, changes
          // not yet sent included, and its person is asked.
          AppLogger.warning('Orchards: ZestSSH Cloud no longer lists a team whose signed record still has '
              'this account in it: what is here stays, and its person is asked');
          final db = await databases.open(id);
          await db.customStatement('UPDATE orchard_info SET status = ? WHERE id = 1', [kUnlistedStatus]);
          _standing[id] = kUnlistedStatus;
          continue;
        }
        AppLogger.info('Orchards: an Orchard this account is no longer in left this device');
        await databases.forget(id);
      }
    }
    return active;
  }

  /// Why the server does not list the Orchard [orchardId] for this account:
  /// [behind] when it is behind the record this device holds of it (the
  /// restore work: the record here has this account in it, and the server's
  /// does not hold this device's last entry), [deletedAt] when it holds that
  /// entry and says the team was deleted then. Otherwise it says
  /// it took the account out (it holds every entry this device has), or it
  /// has no such question ([OrchardServerException.routeMissing], a server a
  /// deploy behind this app, or one that answers as if it were): the Orchard
  /// leaves the device only where a record this device checks has this
  /// account out of it, the one here or the server's read now and checked
  /// whole; otherwise it is [held], and its person is asked (found in a
  /// security review: the server's word alone wiped a team's data, an
  /// only owner's too, changes not yet sent included). Neither when the
  /// record here already has the account out: the Orchard leaves, as before.
  /// Null when the server could not be asked: nothing leaves the device on a
  /// question not answered.
  Future<({bool behind, DateTime? deletedAt, bool held})?> _whyUnlisted(String orchardId, CrateAuthor me) async {
    const left = (behind: false, deletedAt: null, held: false);
    const held = (behind: false, deletedAt: null, held: true);
    try {
      final db = await databases.open(orchardId);
      final local = await LocalRecord.load(db, orchardId);
      if (local.seq == 0) return left;
      final mine = local.latest.members[me.uid];
      if (mine == null || mine.status != MemberStatus.active) return left;
      final RecordHolds answer;
      try {
        answer = await server.recordHolds(orchardId, local.seq, local.head);
      } on OrchardServerException catch (e) {
        if (!e.routeMissing) rethrow;
        return await _outBySignedRecord(db, orchardId, me.uid) ? left : held;
      }
      if (!answer.holds) return (behind: true, deletedAt: null, held: false);
      if (answer.deleted) return (behind: false, deletedAt: answer.deletedAt, held: false);
      return await _outBySignedRecord(db, orchardId, me.uid) ? left : held;
    } on OrchardServerException catch (e) {
      AppLogger.warning('Orchards: could not ask whether the server is behind an Orchard ($e)');
      return null;
    } catch (e) {
      AppLogger.warning('Orchards: could not ask whether the server is behind an Orchard ($e)');
      return null;
    }
  }

  /// Whether the team's record, read from the server now and checked whole
  /// on top of the one here, has [uid] out of it (removed, or not active).
  /// False where it cannot be read (ZestSSH Cloud lets no former member read
  /// it) or does not check out: then nothing leaves on the server's word.
  Future<bool> _outBySignedRecord(AppDatabase db, String orchardId, String uid) async {
    try {
      final record = await pullRecord(db, orchardId, server);
      final mine = record.latest.members[uid];
      return mine == null || mine.status != MemberStatus.active;
    } catch (e) {
      AppLogger.info("Orchards: the team's record could not say whether this account is out of it (${errorKind(e)})");
      return false;
    }
  }

  /// Takes [orchardId], which ZestSSH Cloud no longer lists for this account
  /// while the record here still has it in ([kUnlistedStatus]), off this
  /// device once its person says so: its database, its key, its owner entry
  /// and the cloud import accounts that brought hosts into it, changes not
  /// yet sent included. Only a team held back so: any other is left as it is.
  Future<void> removeUnlistedTeam(String orchardId) async {
    final db = await databases.open(orchardId);
    final status = (await db.customSelect('SELECT status FROM orchard_info WHERE id = 1').getSingleOrNull())
        ?.read<String?>('status');
    if (status != kUnlistedStatus) throw StateError('That team is not one ZestSSH Cloud stopped listing');
    _standing.remove(orchardId);
    _listed.remove(orchardId);
    _invitesWaiting.remove(orchardId);
    await databases.forget(orchardId);
    AppLogger.info('Orchards: a team ZestSSH Cloud no longer lists left this device, as its person asked');
  }

  /// One Orchard, with the queue for it held.
  Future<void> _refreshOrchard(String orchardId, CrateAuthor me) async {
    final remote = (await server.orchards()).where((o) => o.id == orchardId).firstOrNull;
    if (remote == null) throw const OrchardServerException(404, 'not-found');
    await _refreshOne(remote, me);
  }

  /// Brings one Orchard up to date. True when it is one to sync.
  Future<bool> _refreshOne(RemoteOrchard orchard, CrateAuthor me) async {
    var db = await databases.open(orchard.id);
    if (orchard.status == kDeletingStatus) return _refreshDeleting(db, orchard);
    if (orchard.status == 'rules') {
      String? nameWas;
      var removedHere = orchard.deviceRemoved && await _droppedAsRemoved(db);
      if (orchard.deviceRemoved && !removedHere) {
        if (await _removalSigned(db, orchard.id, me.uid)) {
          // This device was approved, and someone took that back, as the
          // team's signed record says: what it holds of the Orchard goes. Once:
          // the note below says it went. Only the Orchard's name stays, so
          // that its person is told which one it was.
          AppLogger.info('Orchards: this device was removed from an Orchard, which left it');
          nameWas = (await db.customSelect('SELECT name FROM orchard_info WHERE id = 1').getSingleOrNull())
              ?.read<String?>('name');
          _deviceRun.removed[orchard.id] = nameWas;
          await databases.forget(orchard.id);
          db = await databases.open(orchard.id);
          removedHere = true;
        } else {
          // ZestSSH Cloud says so, and the team's signed record does not (or
          // could not be read now): what is here stays, held, and is looked at
          // again next time (found in a security review:
          // the server alone wiped a team's data here, changes not yet
          // sent included).
          AppLogger.warning('Orchards: ZestSSH Cloud says this device was removed from a team, '
              "and the team's signed record does not say so: what is here stays");
        }
      }
      // Held back by the rules: what is here stays, nothing syncs, and
      // the device shows which rules and how to meet them. It keeps to the
      // device rules the server says are in force meanwhile, on top of the
      // record's (readOrchardSummary).
      final device = orchard.heldDeviceRules;
      await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, role, key_generation, status, held) '
        'VALUES (1, ?, ?, 0, ?, ?) ON CONFLICT(id) DO UPDATE SET status = excluded.status, held = excluded.held',
        [
          orchard.id,
          orchard.role,
          'rules',
          jsonEncode({
            'unmet': orchard.rulesUnmet,
            'email_domains': orchard.ruleDomains,
            if (device != null) 'device_rules': device.toBody(),
            if (removedHere) 'device_removed': true,
          }),
        ],
      );
      if (nameWas != null) await db.customStatement('UPDATE orchard_info SET name = ? WHERE id = 1', [nameWas]);
      // (Not from a device nobody approved: the record is closed to it, an
      // owner's too.)
      if (orchard.role == FixedRoles.owner && !orchard.rulesUnmet.contains(kTrustedDeviceRule)) {
        // Owners can always change the rules, so they keep up with the
        // record, and with the rules in it.
        try {
          final record = await pullRecord(db, orchard.id, server);
          await db.customStatement(
              'UPDATE orchard_info SET rules = ? WHERE id = 1', [jsonEncode(record.latest.rules.toBody())]);
        } catch (e) {
          AppLogger.warning('Orchards: could not read the record of an Orchard held back by its rules ($e)');
        }
      }
      return false;
    }
    if (!orchard.active) {
      // Suspended, or the access ended: what is here stays, and nothing
      // syncs until it counts again.
      await db.customStatement('UPDATE orchard_info SET status = ? WHERE id = 1', [orchard.status]);
      return false;
    }
    final LocalRecord record;
    final wentBackBefore = await LocalStateStore(db).read(kServerWentBackState);
    try {
      record = await pullRecord(db, orchard.id, server);
    } on RecordProblem catch (e) {
      AppLogger.warning('Orchards: stopped following an Orchard ($e)');
      await db.customStatement('UPDATE orchard_info SET record_problem = ? WHERE id = 1', [e.reason]);
      return false;
    }
    if (wentBackBefore == null && await LocalStateStore(db).read(kServerWentBackState) != null) {
      // This device just sent back entries the server had lost (a restore):
      // the Crates and members they bring are the server's again, so the
      // list is read again for them.
      final again = (await server.orchards()).where((o) => o.id == orchard.id).firstOrNull;
      if (again != null && again.active) orchard = again;
    }
    final mine = record.latest.members[me.uid];
    if (mine == null || mine.status != MemberStatus.active) {
      // The server lists the Orchard, and its record does not have this
      // account in it: the record decides.
      await db.customStatement('UPDATE orchard_info SET record_problem = ? WHERE id = 1',
          ['the record does not have this account as a member']);
      return false;
    }
    // Joined by an invite code: the first record shown here must hold the keys
    // the code was checked over. Until it does, nothing syncs, and the person
    // is told as for any record this device does not follow.
    final bool? makerHeld;
    try {
      makerHeld = await makerChecks?.holds(orchard.id, record.latest, joiner: me.uid);
    } on InviteMakerCheckUnread {
      // Not taken unchecked: looked at again at the next refresh.
      AppLogger.warning('Orchards: the keys an invite code was checked over could not be read now');
      return false;
    }
    if (makerHeld == false) {
      AppLogger.warning('Orchards: the record of a team joined by an invite code does not hold the keys of its maker');
      await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, role, key_generation, status, record_problem) '
        "VALUES (1, ?, ?, 0, 'active', ?) ON CONFLICT(id) DO UPDATE SET record_problem = excluded.record_problem",
        [orchard.id, orchard.role, 'the record does not hold the keys the invite code was checked over'],
      );
      return false;
    }
    if (makerHeld == true) await makerChecks!.forget(orchard.id);
    if (mine.currentKeys.version < me.keys.version) {
      // This account started over with new keys after losing the old ones
      // and nothing here is sealed to the new keys yet. It waits for two
      // owners to recover it (team recovery) or to be invited again; nothing
      // syncs meanwhile.
      await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, role, key_generation, status) VALUES (1, ?, ?, 0, ?) '
        'ON CONFLICT(id) DO UPDATE SET status = excluded.status',
        [orchard.id, orchard.role, kRecoveryWaitStatus],
      );
      return false;
    }
    if (orchard.invitesWaiting != null) _invitesWaiting[orchard.id] = orchard.invitesWaiting!;
    final tagRead = await _refreshMembers(db, orchard, me, record);
    final snapshot = await _openKeys(orchard, me, record.latest, await MemberDirectory(db).pins(),
        firstSeen: (seq) => seq >= 1 && seq <= record.firstSeen.length ? record.firstSeen[seq - 1] : null);
    // A Crate leaves this device only once the record no longer opens it to
    // this account, by this device's clock: one the list alone leaves out
    // stays, held, with its items, its keys and the changes not yet sent
    // (found in a security review; before it, only while the list
    // was made from a record shorter than this device's, a server restored
    // from an older backup). One the record no longer opens goes, whatever
    // the list says (_openKeys).
    final now = _nowSeconds();
    final latest = record.latest;
    await _store(db, snapshot, keep: {
      for (final c in latest.crates.keys)
        if (latest.switchesAt(me.uid, c, now) case final switches when switches.isNotEmpty)
          c: (
            switches: switches,
            heldUntil: latest.switchesOf(me.uid, c).isEmpty ? latest.members[me.uid]?.timed[c]?.until : null,
          ),
    });
    if (tagRead) {
      await db.customStatement('UPDATE orchard_info SET members_tag = ? WHERE id = 1', [orchard.membersTag]);
    }
    if (orchard.copiesMissing) {
      // Never why a refresh fails: another member's device may do it.
      try {
        await _sealAgain(db, orchard, me, record.latest, snapshot);
      } catch (e) {
        AppLogger.warning('Orchards: could not seal again the keys the server lost ($e)');
      }
    }
    return true;
  }

  /// After a restore of the server (the restore work): seals again, for
  /// those who should hold them, the key copies the server lost and this
  /// device holds the keys of, and names again the Crates whose names it
  /// lost (a placeholder no device opens) where this account may rename them.
  Future<void> _sealAgain(AppDatabase db, RemoteOrchard orchard, CrateAuthor me, OrchardRecord record, _Snapshot s) async {
    final missing = await server.missingCopies(orchard.id);
    final copies = <GrantCopy>[];
    for (final m in missing) {
      final scope = m.crateId == null ? 'orchard' : 'crate';
      final key = await db.customSelect(
        'SELECT secret FROM space_keys WHERE scope = ? AND scope_id = ? AND generation = ?',
        variables: [Variable(scope), Variable(m.crateId ?? orchard.id), Variable(m.generation)],
      ).getSingleOrNull();
      if (key == null) continue;
      try {
        final sealed = await _sealTo(db, record, me, [m.uid], key.read<Uint8List>('secret'),
            orchardId: orchard.id, crateId: m.crateId, generation: m.generation);
        // Sealed to the keys this device trusts for them: only where those
        // are the ones the server asks for.
        if ((await _trustedKeys(db, record, me, m.uid)).version == m.recipientKeyVersion) copies.addAll(sealed);
      } catch (e) {
        AppLogger.info('Orchards: a lost key copy waits for another member\'s device ($e)');
      }
    }
    if (copies.isNotEmpty) {
      final left = await server.fillCopies(orchard.id, copies);
      AppLogger.info('Orchards: sealed ${copies.length} lost key copies again; $left still missing');
    }
    for (final c in s.crates) {
      if (c.name != null || !c.switches.contains(CrateSwitches.manage)) continue;
      final local = await db.customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?',
          variables: [Variable(c.id)]).getSingleOrNull();
      final name = local?.read<String?>('name');
      final key = (await db.customSelect(
        "SELECT secret FROM space_keys WHERE scope = 'crate' AND scope_id = ? AND generation = ?",
        variables: [Variable(c.id), Variable(c.keyGeneration)],
      ).getSingleOrNull())
          ?.read<Uint8List>('secret');
      if (name == null || key == null) continue;
      await server.renameCrate(
          c.id, await encryptCrateName(name, key, orchardId: orchard.id, crateId: c.id, generation: c.keyGeneration),
          generation: c.keyGeneration);
    }
  }

  /// Whether the Orchard in [db] was already dropped from this device as
  /// one it was removed from.
  /// Whether the team's signed record takes this device's approval back
  /// when, read now and checked whole, it holds a device.revoke of this
  /// account's key for this device, and the device was not approved again
  /// since. ZestSSH Cloud saying so alone wipes nothing. False where it cannot
  /// be told now (no key here, the record not read): nothing goes.
  Future<bool> _removalSigned(AppDatabase db, String orchardId, String uid) async {
    final keys = deviceKeys;
    if (keys == null) return false;
    try {
      final mine = await keys.read(uid);
      if (mine == null) return false;
      final key = mine.key;
      final record = await pullRecord(db, orchardId, server);
      if (record.latest.devicesOf(uid).contains(key)) return false;
      return record.entries.any((e) {
        if (e.type != RecordTypes.deviceRevoke) return false;
        final body = e.body;
        return body['uid'] == uid && body['device'] == key;
      });
    } catch (e) {
      AppLogger.warning("Orchards: the removal of this device could not be checked in the team's record (${errorKind(e)})");
      return false;
    }
  }

  static Future<bool> _droppedAsRemoved(AppDatabase db) async {
    final held = (await db.customSelect('SELECT held FROM orchard_info WHERE id = 1').getSingleOrNull())
        ?.read<String?>('held');
    if (held == null) return false;
    try {
      final decoded = jsonDecode(held);
      return decoded is Map && decoded['device_removed'] == true;
    } on FormatException {
      return false;
    }
  }

  /// Applies the record to the member directory: every member's
  /// keys pinned, followed or stopped on. Their addresses and the checks of
  /// their keys are read again only when the server's tag for them moved.
  /// Returns whether it read them, so the tag is kept once the Orchard is
  /// stored. A member list that cannot be read now is read at the next
  /// refresh; it never stops the sync.
  Future<bool> _refreshMembers(AppDatabase db, RemoteOrchard orchard, CrateAuthor me, LocalRecord record) async {
    final known = (await db
            .customSelect('SELECT members_tag FROM orchard_info WHERE id = 1')
            .getSingleOrNull())
        ?.read<String?>('members_tag');
    MemberList? listings;
    if (orchard.membersTag == null || orchard.membersTag != known) {
      try {
        listings = await server.members(orchard.id);
      } catch (e) {
        AppLogger.warning('Orchards: the member list could not be read ($e)');
      }
    }
    final changes =
        await MemberDirectory(db).apply(orchardId: orchard.id, record: record, listings: listings, me: me);
    final stopped = changes.values.where((c) => c == MemberKeyChange.hardStop).length;
    if (stopped > 0) AppLogger.warning('Orchards: $stopped member key change(s) wait for a check');
    return listings != null;
  }

  /// Every Orchard and Crate key this account holds, sealed to [next], its
  /// next account keys, and signed with them: what a key replacement sends
  /// (3.0). The Orchards are refreshed first, so these are
  /// exactly the keys the server lists for the account; one this device
  /// could not open makes the server refuse the replacement instead of the
  /// account losing it. A suspended member holds no copies.
  Future<List<ResealedKeyCopy>> resealAll(String uid, AccountKeys next) async {
    final copies = <ResealedKeyCopy>[];
    for (final orchardId in await refresh()) {
      final db = await databases.open(orchardId);
      final keys = await db.customSelect('SELECT scope, scope_id, generation, secret FROM space_keys').get();
      for (final k in keys) {
        final crateId = k.read<String>('scope') == 'crate' ? k.read<String>('scope_id') : null;
        final generation = k.read<int>('generation');
        final secret = k.read<Uint8List>('secret');
        final sealed = crateId == null
            ? await sealOrchardKey(next.encryption.publicKey, secret, orchardId: orchardId, generation: generation)
            : await sealCrateKey(next.encryption.publicKey, secret,
                orchardId: orchardId, crateId: crateId, generation: generation);
        final place = KeyCopyPlace(
          orchardId: orchardId,
          crateId: crateId,
          generation: generation,
          recipient: uid,
          recipientKeyVersion: next.version,
          sealer: uid,
          sealerKeyVersion: next.version,
        );
        copies.add(ResealedKeyCopy(
          orchardId: orchardId,
          crateId: crateId,
          generation: generation,
          sealed: sealed,
          signature: await signKeyCopy(next, place, sealed),
        ));
      }
    }
    return copies;
  }

  /// The member.keys entry for each Orchard the account is in, recording
  /// [published] (its next keys, which sign the entry) vouched for by
  /// [endorsement] from the current ones: what a key replacement brings for
  /// every Orchard's record. Each entry follows the record's last one:
  /// this device's own copy of it, or [heads] as the server names them (a
  /// suspended member cannot read the record). Orchards known to neither
  /// are left out; the server then names them with their heads.
  Future<Map<String, RecordEntry>> memberKeysEntries(
    String uid,
    AccountKeys next,
    PublishedAccountKeys published,
    Uint8List endorsement, {
    Map<String, RecordHead> heads = const {},
  }) async {
    final out = <String, RecordEntry>{};
    final ids = {..._standing.keys, ...heads.keys};
    for (final orchardId in ids) {
      int seq;
      Uint8List prev;
      final head = heads[orchardId];
      if (head != null) {
        seq = head.seq;
        prev = head.hash;
      } else {
        if (_standing[orchardId] != 'active') continue;
        final db = await databases.open(orchardId);
        final record = await LocalRecord.load(db, orchardId);
        if (record.seq == 0) continue;
        seq = record.seq;
        prev = record.head;
      }
      out[orchardId] = await signRecordEntry(
        next,
        orchardId: orchardId,
        seq: seq + 1,
        prev: prev,
        type: RecordTypes.memberKeys,
        by: uid,
        body: {...recordKeysBody(published), 'endorsement': base64Encode(endorsement)},
      );
    }
    return out;
  }

  /// Moves every Orchard key this account may replace (an owner or admin)
  /// and every Crate key it manages to a new generation, sealed to every
  /// member whose access counts: after a key replacement, so the old keys,
  /// and the keys a lost device already opened, open nothing written from
  /// then on. Items keep the generation they were written with.
  ///
  /// [skip] names places already moved (`orchard:<id>`, `crate:<id>`) and
  /// [onMoved] hears each place as it moves, so an interrupted run carries on
  /// where it stopped. A place the server says moved on meanwhile counts as
  /// moved. Returns the places that could not move this time (a member's
  /// keys this device does not trust yet among them).
  Future<List<String>> rotateAll({
    Set<String> skip = const {},
    Future<void> Function(String place)? onMoved,
  }) async {
    final me = await _me();
    final left = <String>[];
    for (final orchardId in await refresh()) {
      await _rotatePlaces(orchardId, me, left, skip: skip, onMoved: onMoved);
    }
    return left;
  }

  /// Moves every key of [orchardId] this account may replace to a new
  /// generation (with [dueOnly], only those waiting for it): the Orchard's
  /// own for an owner or admin, and each Crate's it manages. A place that
  /// could not move goes into [left]; see [rotateAll]. A key someone else
  /// moved on meanwhile counts as moved.
  Future<void> _rotatePlaces(
    String orchardId,
    CrateAuthor me,
    List<String> left, {
    bool dueOnly = false,
    Set<String> skip = const {},
    Future<void> Function(String place)? onMoved,
  }) async {
    Future<void> move(String place, Future<void> Function() rotate) async {
      if (skip.contains(place)) return;
      try {
        await rotate();
      } catch (e) {
        AppLogger.warning('Orchards: could not replace a key ($e)');
        left.add(place);
        return;
      }
      await onMoved?.call(place);
    }

    final db = await databases.open(orchardId);
    final record = (await LocalRecord.load(db, orchardId)).latest;
    final info = await db
        .customSelect('SELECT name, role, rotation_due FROM orchard_info WHERE id = 1')
        .getSingleOrNull();
    if (info == null) return;
    final role = info.read<String>('role');
    if ((role == FixedRoles.owner || role == FixedRoles.admin) && (!dueOnly || info.read<int>('rotation_due') == 1)) {
      await move(
          'orchard:$orchardId',
          () => _serial(orchardId, () => _rotate(db, orchardId, me,
              name: info.read<String?>('name'), from: record.generationOf(kOrchardScope))));
    }
    final crates = await db.customSelect('SELECT crate_id, name, switches, rotation_due FROM orchard_crates').get();
    for (final c in crates) {
      if (!_switches(c.read<String>('switches')).contains(CrateSwitches.manage)) continue;
      if (dueOnly && c.read<int>('rotation_due') != 1) continue;
      final crateId = c.read<String>('crate_id');
      await move(
          'crate:$crateId',
          () => _serial(orchardId, () => _rotate(db, orchardId, me,
              crateId: crateId, name: c.read<String?>('name'), from: record.generationOf(crateId))));
    }
  }

  /// This device's clock. A test moves it to see access end.
  @visibleForTesting
  static DateTime Function() debugNow = DateTime.now;

  static int _nowSeconds() => debugNow().millisecondsSinceEpoch ~/ 1000;

  /// Makes the next generation of the Orchard's key (null [crateId]) or a
  /// Crate's (3.0), through the record: a key.rotate entry that
  /// commits to a fresh key, the [name] encrypted under it, and a copy of it
  /// for exactly everyone who holds the key now (end dates counted, accounts
  /// the server says were deleted aside), each sealed to the keys this device
  /// trusts for them. [from] is the generation this device meant to replace:
  /// when someone else moved the key on meanwhile, that counts as done.
  Future<void> _rotate(
    AppDatabase db,
    String orchardId,
    CrateAuthor me, {
    String? crateId,
    required String? name,
    required int from,
  }) async {
    // The name is re-encrypted under the new key; one this device never read
    // would come out blank for everyone.
    if (name == null) {
      throw StateError(crateId == null ? 'The Orchard name is not on this device' : 'The Crate name is not on this device');
    }
    final scope = crateId ?? kOrchardScope;
    final deleted = await MemberDirectory(db).deletedAccounts();
    for (var attempt = 0;; attempt++) {
      final record = await pullRecord(db, orchardId, server);
      if (record.latest.generationOf(scope) > from) return;
      final generation = from + 1;
      final key = newSpaceKey();
      final entry = await _sign(me, record, RecordTypes.keyRotate, {
        'crate': ?crateId,
        'generation': generation,
        'key_commit':
            base64Encode(await keyCommitment(key, orchardId: orchardId, crateId: crateId, generation: generation)),
      });
      final after = await _probe(record, entry);
      final nameEnc = crateId == null
          ? await encryptOrchardName(name, key, orchardId: orchardId, generation: generation)
          : await encryptCrateName(name, key, orchardId: orchardId, crateId: crateId, generation: generation);
      var to = after.holdersAt(scope, _nowSeconds(), skip: deleted);
      try {
        for (var narrowed = false;; narrowed = true) {
          try {
            await server.rotateKey(orchardId, entry,
                nameEnc: nameEnc,
                copies: await _sealTo(db, after, me, to, key, orchardId: orchardId, crateId: crateId, generation: generation));
            break;
          } on OrchardServerException catch (e) {
            // The server counts fewer holders (an account deleted, or an end
            // date passed by its clock): seal to the ones it names, never to
            // anyone this device does not count.
            final theirs = e.recipients;
            if (e.code != 'copies-changed' || theirs == null || narrowed || !to.toSet().containsAll(theirs)) rethrow;
            to = [...theirs]..sort();
          }
        }
      } on OrchardServerException catch (e) {
        if (e.recordMoved && attempt < 2) continue;
        rethrow;
      }
      await record.extend(db, [entry]);
      await db.transaction(() async {
        await _putKey(db, crateId == null ? 'orchard' : 'crate', crateId ?? orchardId, generation, key);
        if (crateId == null) {
          await db.customStatement(
              'UPDATE orchard_info SET key_generation = ?, rotation_due = 0 WHERE id = 1', [generation]);
        } else {
          await db.customStatement(
              'UPDATE orchard_crates SET key_generation = ?, rotation_due = 0 WHERE crate_id = ?', [generation, crateId]);
        }
      });
      return;
    }
  }

  /// Generation [generation] of the Orchard's key (null [crateId]) or a
  /// Crate's, [key], sealed to each of [to] with the keys this device trusts
  /// for them in [record] and signed by this account.
  Future<List<GrantCopy>> _sealTo(AppDatabase db, OrchardRecord record, CrateAuthor me, List<String> to, Uint8List key,
      {required String orchardId, String? crateId, required int generation}) async {
    final out = <GrantCopy>[];
    for (final uid in to) {
      final keys = await _trustedKeys(db, record, me, uid);
      final sealed = crateId == null
          ? await sealOrchardKey(keys.encryptionKey, key, orchardId: orchardId, generation: generation)
          : await sealCrateKey(keys.encryptionKey, key, orchardId: orchardId, crateId: crateId, generation: generation);
      out.add(GrantCopy(
        uid: uid,
        crateId: crateId,
        generation: generation,
        sealed: sealed,
        signature: await signKeyCopy(
          me.keys,
          KeyCopyPlace(
            orchardId: orchardId,
            crateId: crateId,
            generation: generation,
            recipient: uid,
            recipientKeyVersion: keys.version,
            sealer: me.uid,
            sealerKeyVersion: me.keys.version,
          ),
          sealed,
        ),
      ));
    }
    return out;
  }

  /// This device's person compared [uid]'s fingerprint: the signed
  /// statement goes to the server, and this device trusts the keys, the new
  /// ones waiting after a hard stop included.
  Future<void> verifyMember(String orchardId, String uid) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final directory = MemberDirectory(db);
    final pin = await directory.pin(uid);
    if (pin == null) throw StateError('No keys for that member on this device');
    final keys = pin.pending ?? pin.asPublished;
    await server.verifyMember(
      orchardId,
      subjectUid: uid,
      subjectKeyVersion: keys.version,
      keyVersion: me.keys.version,
      signature: await signMemberVerification(me.keys, verifierUid: me.uid, orchardId: orchardId, subject: keys),
    );
    await directory.markVerified(uid);
  }

  /// The roles the owners made in [orchardId], their names opened with the
  /// Orchard's key, highest rank first. A name whose key is not on this
  /// device is null.
  Future<List<OrchardRoleView>> roles(String orchardId) async {
    final db = await databases.open(orchardId);
    final record = await LocalRecord.load(db, orchardId);
    final out = <OrchardRoleView>[];
    for (final r in record.latest.roles.values) {
      String? name;
      final key = await _secret(db, orchardId, null, r.nameGeneration);
      if (key != null) {
        try {
          name = await decryptRoleName(base64Decode(r.nameEnc), key,
              orchardId: orchardId, roleId: r.id, generation: r.nameGeneration);
        } catch (_) {/* shown as unnamed */}
      }
      out.add(OrchardRoleView(
        id: r.id,
        name: name,
        rank: r.rank,
        can: {...r.can},
        crates: {for (final e in r.crates.entries) e.key: {...e.value}},
      ));
    }
    out.sort((a, b) => b.rank.compareTo(a.rank));
    return out;
  }

  // ── Invitations ──

  /// Invites [email] into [orchardId] as [role], with the extra Crates
  /// [grants] and an end date [endsAt] (seconds since the epoch). Returns
  /// whether an email went out (the invitation stands either way: the person
  /// sees it in the app once signed in with that address).
  Future<bool> invite(
    String orchardId, {
    required String email,
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
  }) async {
    final address = email.trim().toLowerCase();
    final sent = await server.invite(orchardId, email: address, role: role, grants: grants, endsAt: endsAt);
    await _keepOffer(orchardId, sent.inviteId, address: address, role: role, grants: grants, endsAt: endsAt);
    return sent.emailed;
  }

  Future<List<OrchardInvite>> invites(String orchardId) => server.invites(orchardId);

  Future<void> withdrawInvite(String orchardId, String inviteId) async {
    await server.withdrawInvite(orchardId, inviteId);
    await _forgetOffer(orchardId, inviteId);
  }

  // What this device offered (found in security
  // reviews). ZestSSH Cloud keeps an invitation's role, extra vaults and
  // end date, and lists them to whoever lets the person in, who signs them
  // into the member.add: nothing tied them to what the inviter offered, so a
  // server could list "admin, no end date" for "member until Friday". It has
  // nowhere to keep a signed digest of an invitation to an address, so the
  // device that makes an invitation, or an invite code, keeps the digest of
  // its offer here, in the team's own database, by the invitation's id and,
  // for an address, by the address (an invitation to it is one row, so a
  // server cannot list the offer under another id): one listed with another
  // offer lets nobody in from this device. Elsewhere (another device, another
  // admin) the person who lets them in sees the offer as listed, role, vaults
  // and end date, before they confirm.

  /// Kept for this long: an invitation lasts 14 days and a code 30 at most.
  static const _offersKept = Duration(days: 45);

  Future<void> _keepOffer(String orchardId, String inviteId,
      {String? address,
      required String role,
      required Map<String, Set<String>> grants,
      required int? endsAt}) async {
    try {
      final db = await databases.open(orchardId);
      final store = LocalStateStore(db);
      final now = _nowSeconds();
      final digest = await joinOfferDigest(role: role, grants: grants, endsAt: endsAt);
      // Older ones go: their invitations ended long ago.
      for (final key in await store.keysWithPrefix(kInviteOfferState)) {
        final at = _keptOffer(await store.read(key))?.at;
        if (at == null || now - at > _offersKept.inSeconds) await store.remove(key);
      }
      await store.write('$kInviteOfferState${address == null ? 'id:$inviteId' : 'to:$address'}',
          jsonEncode({'id': inviteId, 'offer': base64Encode(digest), 'at': now}));
    } catch (e) {
      // The invitation stands; whoever lets them in sees its offer.
      AppLogger.warning('Orchards: what an invitation offers was not kept here (${errorKind(e)})');
    }
  }

  static ({String id, List<int> offer, int at})? _keptOffer(String? raw) {
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map || m['id'] is! String || m['offer'] is! String || m['at'] is! int) return null;
      return (id: m['id'] as String, offer: base64Decode(m['offer'] as String), at: m['at'] as int);
    } catch (_) {
      return null;
    }
  }

  /// Whether this device offered [invite] (made it, or the code it is a use
  /// of) with another role, other vaults or another end date than are listed
  /// for it now: changed on the way, and nobody is let in on it from here.
  /// False where this device made none of it.
  Future<bool> inviteOfferChanged(String orchardId, OrchardInvite invite) async {
    final db = await databases.open(orchardId);
    final store = LocalStateStore(db);
    final ids = {invite.id, ?invite.code?.fromCode};
    final address = invite.byCode ? null : '${kInviteOfferState}to:${invite.email.trim().toLowerCase()}';
    final listed = await joinOfferDigest(role: invite.role, grants: invite.grants, endsAt: invite.endsAt);
    for (final key in await store.keysWithPrefix(kInviteOfferState)) {
      final kept = _keptOffer(await store.read(key));
      if (kept == null || (key != address && !ids.contains(kept.id))) continue;
      var diff = kept.offer.length ^ listed.length;
      for (var i = 0; i < kept.offer.length && i < listed.length; i++) {
        diff |= kept.offer[i] ^ listed[i];
      }
      if (diff != 0) return true;
    }
    return false;
  }

  Future<void> _forgetOffer(String orchardId, String inviteId) async {
    try {
      final store = LocalStateStore(await databases.open(orchardId));
      for (final key in await store.keysWithPrefix(kInviteOfferState)) {
        if (_keptOffer(await store.read(key))?.id == inviteId) await store.remove(key);
      }
    } catch (e) {
      AppLogger.info('Orchards: what an invitation offered was not dropped here (${errorKind(e)})');
    }
  }

  /// Adds the person who accepted [invite], once this device's person has
  /// compared the fingerprint of [OrchardInvite.acceptedKeys] with them: a
  /// member.add entry naming those keys and exactly what was offered, and
  /// every generation of every key they gain, sealed to those keys and
  /// signed with this account's. The keys are pinned here as verified, and
  /// the check is signed for the rest of the Orchard. When the server says
  /// their keys changed meanwhile ('recipient-keys-changed'), nothing was
  /// added: compare again.
  ///
  /// [approveDevice]: the device they accepted on, as [joinDeviceOffer] gave
  /// it and its person left it ticked, approved in the same step: a
  /// device.trust made on this device right after the member.add, sent with
  /// it. Its statement is checked again here; a device whose statement no
  /// longer holds, or whose approval the record would refuse, is left out,
  /// and they are let in without it (their device then asks, as before).
  /// Returns whether a device asked for was left out so, for its person to be
  /// told (found in a security review: only the log
  /// said so, while the box had shown it ticked).
  Future<bool> confirmInvite(String orchardId, OrchardInvite invite, {String? approveDevice}) async {
    final me = await _me();
    final keys = invite.acceptedKeys;
    if (!invite.accepted || keys == null) throw const OrchardInviteError(OrchardInviteProblem.notAccepted);
    if (keys.uid != invite.acceptedUid || !await keys.verify()) {
      throw const OrchardInviteError(OrchardInviteProblem.badKeys);
    }
    // What a code's maker signed it to offer is what is signed here; another
    // role, other vaults or another end date was changed on the way (found in
    // a security review). Where the code
    // cannot be read (another device, another admin) the person who lets
    // them in sees the offer, as for an invitation to an address.
    if (invite.byCode && (await checkInviteCode(orchardId, invite)).offerChanged) {
      throw const OrchardInviteError(OrchardInviteProblem.offerChanged);
    }
    // An invitation to an address this device made, listed with another offer.
    //
    if (!invite.byCode && await inviteOfferChanged(orchardId, invite)) {
      throw const OrchardInviteError(OrchardInviteProblem.inviteOfferChanged);
    }
    Uint8List? device;
    var deviceLeftOut = false;
    if (approveDevice != null) {
      // Only the device whose statement holds with the keys compared: never
      // a key handed in from anywhere else.
      final checked = await _joinDeviceChecked(orchardId, invite);
      if (checked != null && deviceKeyText(checked) == approveDevice) {
        device = checked;
      } else {
        AppLogger.warning('Orchards: the device offered with an invitation does not check out; let in without it');
        deviceLeftOut = true;
      }
    }
    final db = await databases.open(orchardId);
    await _serial(orchardId, () async {
      for (var attempt = 0;; attempt++) {
        await _refreshOrchard(orchardId, me);
        final record = await LocalRecord.load(db, orchardId);
        final entry = await _sign(me, record, RecordTypes.memberAdd, {
          ...recordKeysBody(keys),
          'uid': keys.uid,
          'role': invite.role,
          // Just compared: an owner or admin joins with the statement.
          if (invite.role == FixedRoles.owner || invite.role == FixedRoles.admin)
            'verified': base64Encode(
                await signMemberVerification(me.keys, verifierUid: me.uid, orchardId: orchardId, subject: keys)),
          if (invite.grants.isNotEmpty)
            'grants': {for (final g in invite.grants.entries) g.key: switchList(g.value)},
          'ends_at': ?invite.endsAt,
        });
        final after = await _probe(record, entry);
        RecordEntry? trust;
        deviceLeftOut = approveDevice != null && device == null;
        if (device != null) {
          try {
            trust = await _joinDeviceEntry(me, orchardId, after, uid: keys.uid, device: device);
          } catch (e) {
            // Not this account's to approve after all, or this device cannot
            // sign for it: they are let in, and their device asks as before.
            AppLogger.warning('Orchards: the device of someone joining was not approved with them (${errorKind(e)})');
            deviceLeftOut = true;
          }
        }
        // (A device.trust gives no keys: the copies are the member.add's.)
        final copies = await _copiesFor(db, orchardId, me, record.latest, after, compared: {keys.uid: keys});
        try {
          await server.confirmInvite(orchardId, invite.id, entry: entry, copies: copies, device: trust);
        } on OrchardServerException catch (e) {
          // Another entry, or a new key, came first: once more on top of it.
          if ((e.recordMoved || e.code == 'copies-changed') && attempt < 2) continue;
          rethrow;
        }
        await record.extend(db, [entry, ?trust]);
        break;
      }
      await MemberDirectory(db).pinConfirmed(keys, email: invite.email, role: invite.role);
      if (!invite.byCode) await _forgetOffer(orchardId, invite.id);
    });
    try {
      await server.verifyMember(
        orchardId,
        subjectUid: keys.uid,
        subjectKeyVersion: keys.version,
        keyVersion: me.keys.version,
        signature: await signMemberVerification(me.keys, verifierUid: me.uid, orchardId: orchardId, subject: keys),
      );
    } catch (e) {
      // They are in; only the "verified by" note for the others is missing.
      AppLogger.warning('Orchards: the check of a new member was not saved ($e)');
    }
    await refresh();
    return deviceLeftOut;
  }

  /// The invitations to this account's address.
  Future<List<MyInvite>> myInvites() => server.myInvites();

  /// Accepts an invitation. The account's keys must be published first:
  /// everything will be sealed to them. With [orchardId] (the invitation's
  /// team), this device is offered for approval as well, where it can
  /// be: in a team that lets in approved devices only, whoever lets them in
  /// approves it in the same step.
  Future<void> acceptInvite(String inviteId, {String? orchardId}) async {
    final me = await _me();
    await server.acceptInvite(inviteId, device: orchardId == null ? null : await _joinDevice(me, orchardId, inviteId));
  }

  Future<void> declineInvite(String inviteId) => server.declineInvite(inviteId);

  /// Sends a live invitation's email again ("Resend").
  Future<bool> resendInvite(String orchardId, OrchardInvite invite) async {
    // Sent again as listed: never another offer than this device made.
    if (await inviteOfferChanged(orchardId, invite)) {
      throw const OrchardInviteError(OrchardInviteProblem.inviteOfferChanged);
    }
    final sent = await server.invite(orchardId,
        email: invite.email, role: invite.role, grants: invite.grants, endsAt: invite.endsAt, resend: true);
    return sent.emailed;
  }

  // ── Invite codes (crypto/join_code_crypto.dart) ──

  /// Makes an invite code on this device for [orchardId], offering [role],
  /// [grants] and [endsAt], waiting [expiresIn] seconds (an hour, a day, a
  /// week or 30 days). The server is given what is derived from the code and
  /// what is sealed, never the code: [shown] (the team's name, the role's
  /// and the vaults, in words) sealed under the code, and the code itself
  /// sealed to this account's own key, so its other devices can check whoever
  /// uses it. [replacesInvite]: an invitation to an address the code is
  /// sent instead of (it goes once the code is used).
  Future<MadeInviteCode> makeInviteCode(
    String orchardId, {
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
    required int expiresIn,
    required JoinOffer shown,
    String? replacesInvite,
    int usesMax = 1,
  }) async {
    final me = await _me();
    final code = newJoinCode();
    final keys = await joinCodeKeys(code);
    final inviteId = const Uuid().v4();
    final maker = _party(me.uid, me.keys);
    final ownerTag = await joinCodeTag(
        keys.macKey,
        ownerTranscript(
            orchardId: orchardId,
            inviteId: inviteId,
            lookupId: keys.lookupId,
            maker: maker,
            role: role,
            grants: grants,
            endsAt: endsAt));
    final saved = await server.saveInviteCode(
      orchardId,
      inviteId: inviteId,
      lookupId: keys.lookupHex,
      ownerTag: ownerTag,
      makerKeyVersion: me.keys.version,
      codeSealed: await sealMadeJoinCode(code,
          makerEncryptionKey: me.keys.encryption.publicKey,
          sign: me.keys.sign,
          orchardId: orchardId,
          inviteId: inviteId,
          usesMax: usesMax,
          role: role,
          grants: grants,
          endsAt: endsAt),
      offerSealed: await sealJoinOffer(shown, keys.offerKey, orchardId: orchardId, inviteId: inviteId),
      role: role,
      grants: grants,
      endsAt: endsAt,
      expiresIn: expiresIn,
      replacesInvite: replacesInvite,
      usesMax: usesMax,
    );
    await _keepOffer(orchardId, saved.inviteId, role: role, grants: grants, endsAt: endsAt);
    return MadeInviteCode(code: code, inviteId: saved.inviteId, expiresAt: saved.expiresAt);
  }

  /// How long an unused code waits, from now.
  Future<DateTime> changeInviteCodeExpiry(String orchardId, String inviteId, int expiresIn) =>
      server.changeInviteCodeExpiry(orchardId, inviteId, expiresIn);

  /// What a code offers, checked against the code: the maker's published
  /// keys must sign for their account, and the maker's tag must hold over
  /// them, the team, the invitation and the offer exactly as the server gave
  /// them. Throws [InviteCodeError] for text that is no code, or a code
  /// that does not check out; [OrchardServerException] 'join-code-invalid'
  /// for one that is not live.
  Future<InviteCodePreview> previewInviteCode(String raw) async {
    final code = joinCodeFromText(raw);
    if (code == null) throw const InviteCodeError(InviteCodeProblem.notACode);
    final keys = await joinCodeKeys(code);
    final offer = await server.inviteCodeOffer(keys.lookupHex);
    final maker = offer.makerKeys;
    if (!await maker.verify()) throw const InviteCodeError(InviteCodeProblem.checkFailed);
    final checked = await joinCodeTagMatches(
        keys.macKey,
        ownerTranscript(
            orchardId: offer.invite.orchardId,
            inviteId: offer.invite.id,
            lookupId: keys.lookupId,
            maker: _published(maker),
            role: offer.invite.role,
            grants: offer.grants,
            endsAt: offer.invite.endsAt),
        offer.ownerTag);
    if (!checked) throw const InviteCodeError(InviteCodeProblem.checkFailed);
    JoinOffer shown;
    try {
      shown = await openJoinOffer(offer.offerSealed, keys.offerKey,
          orchardId: offer.invite.orchardId, inviteId: offer.invite.id);
    } catch (_) {
      // Sealed under the code by its maker: what does not open was not.
      throw const InviteCodeError(InviteCodeProblem.checkFailed);
    }
    return InviteCodePreview(code: code, offer: offer, shown: shown);
  }

  /// Accepts a checked code with this account's keys as published, and its
  /// tag over them and the maker's. The account's keys must be on this
  /// device first (readyToJoin, team/join_readiness.dart). Returns the
  /// invitation's id; from here it is an accepted invitation.
  Future<String> acceptInviteCode(InviteCodePreview preview) async {
    final me = await _me();
    final keys = await joinCodeKeys(preview.code);
    final joinerTag = await joinCodeTag(
        keys.macKey,
        joinerTranscript(
            orchardId: preview.offer.invite.orchardId,
            inviteId: preview.offer.invite.id,
            lookupId: keys.lookupId,
            maker: _published(preview.offer.makerKeys),
            joiner: _party(me.uid, me.keys)));
    // The maker's keys are kept before the code is used (found in a
    // security review): kept after, a failure or the app ending between
    // the two left a used code with nothing kept, and the team's first record
    // was taken unchecked. Where keeping them fails, the code is not used.
    final orchardId = preview.offer.invite.orchardId;
    final checks = makerChecks;
    final before = await checks?.keptNow(orchardId);
    await checks?.remember(orchardId, joiner: me.uid, maker: preview.offer.makerKeys);
    final String inviteId;
    try {
      inviteId = await server.acceptInviteCode(keys.lookupHex,
          keyVersion: me.keys.version,
          joinerTag: joinerTag,
          // This device, offered for approval with it.
          device: await _joinDevice(me, orchardId, preview.offer.invite.id));
    } on OrchardServerException catch (e) {
      // A refusal (4xx) says the code was not used: what was kept before is as
      // it was. "You used this code already" (409 code-used-already) says this
      // account used it, and a server error (5xx: a proxy's 502 after the
      // server had used it) says nothing either way: what was kept stays, as
      // with no answer, where it holds for the real maker's keys whichever way
      // the person joins that team (found in a review: every
      // error put it back, and the team's first record was taken unchecked).
      final refused = e.status >= 400 && e.status < 500 && e.code != 'code-used-already';
      if (refused) await checks?.putBack(orchardId, before);
      rethrow;
    }
    return inviteId;
  }

  /// Whether the keys of whoever used [invite] (an invite code) are checked by
  /// the code: on a device of the code's maker, with the code as its maker
  /// made and signed it, a code for one person, offering what the server
  /// lists, whose tag holds over the keys the server lists for them and the
  /// maker's own. Unchecked anywhere else, for a team code (everyone it went
  /// to holds it), or where anything differs: then the fingerprints are
  /// compared, as for an invitation to an address. [InviteCodeCheck.offerChanged]
  /// where the server lists another offer than the maker signed: nobody is let
  /// in on it ([confirmInvite]).
  Future<InviteCodeCheck> checkInviteCode(String orchardId, OrchardInvite invite) async {
    final info = invite.code;
    final joiner = invite.acceptedKeys;
    if (info == null) return const InviteCodeCheck(checked: false);
    // Made on this device: the offer it kept must be the one listed, whatever
    // the server says of the copy or of whose code it is.
    if (await inviteOfferChanged(orchardId, invite)) return const InviteCodeCheck(checked: false, offerChanged: true);
    final me = await author();
    if (me == null || me.uid != info.makerUid) return const InviteCodeCheck(checked: false);
    // This account's own code: only the copy it signed says what the code
    // offers. Withheld, garbled, an older version's unsigned copy, or sealed to
    // keys this account no longer has, it cannot say, and the offer as listed
    // is not taken: nobody is let in on it, and a new code is made (found in a
    // security review: a server that withheld
    // the copy had the maker sign whatever role it listed).
    final sealed = info.sealed;
    if (sealed == null || me.keys.version != info.makerKeyVersion) {
      return const InviteCodeCheck(checked: false, offerChanged: true);
    }
    // A use of a team code was made with the code's own invitation id.
    final codeInvite = info.fromCode ?? invite.id;
    // Only a copy the maker signed counts: anyone can seal to its key (found in
    // a security review).
    final made = await openMadeJoinCode(me.keys.encryption, me.keys.signingPublicKey, sealed,
        orchardId: orchardId, inviteId: codeInvite);
    if (made == null) return const InviteCodeCheck(checked: false, offerChanged: true);
    final code = made.code;
    if (!await made.offers(role: invite.role, grants: invite.grants, endsAt: invite.endsAt)) {
      return InviteCodeCheck(checked: false, code: code, offerChanged: true);
    }
    // A team code went to several people: any of them, or wherever it was
    // passed on, could tag keys with it.
    if (made.usesMax > 1) return InviteCodeCheck(checked: false, code: code, teamCode: true);
    // A code made for one person is used on its own row, never on one made
    // from it as a team code's uses are.
    if (info.fromCode != null && info.fromCode != invite.id) return InviteCodeCheck(checked: false, code: code);
    if (joiner == null || joiner.uid != invite.acceptedUid || !await joiner.verify()) {
      return InviteCodeCheck(checked: false, code: code);
    }
    final keys = await joinCodeKeys(code);
    final checked = await joinCodeTagMatches(
        keys.macKey,
        joinerTranscript(
            orchardId: orchardId,
            inviteId: codeInvite,
            lookupId: keys.lookupId,
            maker: _party(me.uid, me.keys),
            joiner: _published(joiner)),
        info.joinerTag);
    return InviteCodeCheck(checked: checked, code: code);
  }

  static JoinCodeParty _party(String uid, AccountKeys keys) => JoinCodeParty(
      uid: uid, keyVersion: keys.version, signingKey: keys.signingPublicKey, encryptionKey: keys.encryption.publicKey);

  static JoinCodeParty _published(PublishedAccountKeys keys) => JoinCodeParty(
      uid: keys.uid, keyVersion: keys.version, signingKey: keys.signingKey, encryptionKey: keys.encryptionKey);

  // ── Helpers ──

  /// [me]'s entry of [type] with [body], next after [record]'s last.
  static Future<RecordEntry> _sign(CrateAuthor me, LocalRecord record, String type, Map<String, Object?> body) =>
      signRecordEntry(me.keys,
          orchardId: record.orchardId, seq: record.seq + 1, prev: record.head, type: type, body: body, by: me.uid);

  /// The record after [entry], checked here first. Throws
  /// [OrchardRecordRefused] when the rules refuse it.
  static Future<OrchardRecord> _probe(LocalRecord record, RecordEntry entry) => _probeOn(record.latest, entry);

  static Future<OrchardRecord> _probeOn(OrchardRecord state, RecordEntry entry) async {
    final after = state.copy();
    try {
      await after.append(entry);
    } on RecordRejected catch (e) {
      throw OrchardRecordRefused(e.reason);
    }
    return after;
  }

  /// The keys this device seals to for [uid]: its own, the ones its person
  /// just [compared], or the ones pinned for them, when those are the keys
  /// the record holds for them now and not stopped on. Throws
  /// [MemberKeysNotTrusted] otherwise.
  Future<({int version, List<int> encryptionKey})> _trustedKeys(
      AppDatabase db, OrchardRecord record, CrateAuthor me, String uid,
      {Map<String, PublishedAccountKeys> compared = const {}}) async {
    final current = record.members[uid]?.currentKeys;
    if (uid == me.uid) {
      return (version: me.keys.version, encryptionKey: me.keys.encryption.publicKey);
    }
    final seen = compared[uid];
    if (seen != null && current != null && seen.version == current.version && _eq(seen.encryptionKey, current.encryptionKey)) {
      return (version: seen.version, encryptionKey: seen.encryptionKey);
    }
    final pin = await MemberDirectory(db).pin(uid);
    if (pin == null || pin.hardStop || current == null || pin.keyVersion != current.version ||
        !_eq(pin.encryptionKey, current.encryptionKey)) {
      throw MemberKeysNotTrusted(uid);
    }
    return (version: pin.keyVersion, encryptionKey: pin.encryptionKey);
  }

  /// Every generation of each key someone gains between [before] and
  /// [after], sealed to them and signed by this account: what the server
  /// asks to come with a change. End dates count (someone whose access
  /// ended gains nothing; one given a later end date gains it all again),
  /// and accounts the server says were deleted get nothing. The generations
  /// are the record's. [fresh] holds keys the change itself makes (a new
  /// Crate's), by Crate and generation; the rest come from this device.
  /// Throws [OrchardInviteError] when a key is not on this device.
  Future<List<GrantCopy>> _copiesFor(AppDatabase db, String orchardId, CrateAuthor me, OrchardRecord before,
      OrchardRecord after,
      {Map<String, Map<int, Uint8List>> fresh = const {},
      Map<String, PublishedAccountKeys> compared = const {}}) async {
    final out = <GrantCopy>[];
    final deleted = await MemberDirectory(db).deletedAccounts();
    for (final gained in entitlementsGained(before, after, nowSeconds: _nowSeconds()).entries) {
      final uid = gained.key;
      if (deleted.contains(uid)) continue;
      final keys = await _trustedKeys(db, after, me, uid, compared: compared);
      out.addAll(await _sealEvery(db, orchardId, me, after, uid, keys, gained.value, fresh: fresh));
    }
    return out;
  }

  /// Every generation of each key in [scopes] (as [after] numbers them),
  /// sealed to [uid]'s [keys] and signed by this account. [fresh] holds keys
  /// a change itself makes; the rest come from this device. Throws
  /// [OrchardInviteError] when a key is not on this device.
  Future<List<GrantCopy>> _sealEvery(AppDatabase db, String orchardId, CrateAuthor me, OrchardRecord after,
      String uid, ({int version, List<int> encryptionKey}) keys, Iterable<String> scopes,
      {Map<String, Map<int, Uint8List>> fresh = const {}}) async {
    final out = <GrantCopy>[];
    for (final scope in scopes) {
      final crateId = scope == kOrchardScope ? null : scope;
      for (var g = 1; g <= after.generationOf(scope); g++) {
        final secret = fresh[scope]?[g] ?? await _secret(db, orchardId, crateId, g);
        if (secret == null) throw const OrchardInviteError(OrchardInviteProblem.missingKeys);
        final sealed = crateId == null
            ? await sealOrchardKey(keys.encryptionKey, secret, orchardId: orchardId, generation: g)
            : await sealCrateKey(keys.encryptionKey, secret, orchardId: orchardId, crateId: crateId, generation: g);
        out.add(GrantCopy(
          uid: uid,
          crateId: crateId,
          generation: g,
          sealed: sealed,
          signature: await signKeyCopy(
            me.keys,
            KeyCopyPlace(
              orchardId: orchardId,
              crateId: crateId,
              generation: g,
              recipient: uid,
              recipientKeyVersion: keys.version,
              sealer: me.uid,
              sealerKeyVersion: me.keys.version,
            ),
            sealed,
          ),
        ));
      }
    }
    return out;
  }

  static Future<Uint8List?> _secret(AppDatabase db, String orchardId, String? crateId, int generation) async =>
      (await db.customSelect(
        'SELECT secret FROM space_keys WHERE scope = ? AND scope_id = ? AND generation = ?',
        variables: [
          Variable(crateId == null ? 'orchard' : 'crate'),
          Variable(crateId ?? orchardId),
          Variable(generation),
        ],
      ).getSingleOrNull())
          ?.read<Uint8List>('secret');

  /// A copy this account seals to itself, with its current keys.
  static KeyCopyPlace _ownCopy(
    CrateAuthor me, {
    required String orchardId,
    String? crateId,
    required int generation,
  }) =>
      KeyCopyPlace(
        orchardId: orchardId,
        crateId: crateId,
        generation: generation,
        recipient: me.uid,
        recipientKeyVersion: me.keys.version,
        sealer: me.uid,
        sealerKeyVersion: me.keys.version,
      );

  /// Whether a copy is one this device may open: sealed to this account's
  /// current keys and signed either by this account or by a member whose
  /// keys this device pinned (from the record), at exactly the
  /// pinned version and not stopped on a key change. The server knows every
  /// public key and could seal a key of its own to anyone, so a copy it made
  /// up, one signed by keys this device does not trust, or one stored before
  /// copies were signed, is refused.
  static Future<bool> _trusted(
    SealedSpaceKey k,
    CrateAuthor me,
    Map<String, PinnedMember> pins, {
    required String orchardId,
    String? crateId,
  }) async {
    final signature = k.signature;
    final sealer = k.sealedBy;
    final sealerVersion = k.sealerKeyVersion;
    if (signature == null || sealer == null || sealerVersion == null || k.recipientKeyVersion != me.keys.version) {
      return false;
    }
    final List<int> signingKey;
    if (sealer == me.uid) {
      if (sealerVersion != me.keys.version) return false;
      signingKey = me.keys.signingPublicKey;
    } else {
      final pin = pins[sealer];
      if (pin == null || pin.hardStop || pin.keyVersion != sealerVersion) return false;
      signingKey = pin.signingKey;
    }
    return verifyKeyCopy(
      signingKey,
      KeyCopyPlace(
        orchardId: orchardId,
        crateId: crateId,
        generation: k.generation,
        recipient: me.uid,
        recipientKeyVersion: me.keys.version,
        sealer: sealer,
        sealerKeyVersion: sealerVersion,
      ),
      k.sealed,
      signature,
    );
  }

  /// What this device keeps of an Orchard: its keys opened, and the Crates
  /// this account can open as the record says, with what it may do in each.
  /// A key is kept only when it is the one the record committed to for its
  /// generation: whoever sealed a copy, the key inside must be the one
  /// its maker made. Each key's current generation is the record's, not the
  /// server's word for it, so a server cannot keep this device writing with
  /// a key someone who left still holds.
  Future<_Snapshot> _openKeys(RemoteOrchard o, CrateAuthor me, OrchardRecord record, Map<String, PinnedMember> pins,
      {int? Function(int seq)? firstSeen}) async {
    final orchardKeys = <int, Uint8List>{};
    for (final k in o.keys) {
      if (!await _trusted(k, me, pins, orchardId: o.id)) {
        AppLogger.warning('Orchards: refused an Orchard key copy no trusted account signed');
        continue;
      }
      final Uint8List key;
      try {
        key = await openOrchardKey(me.keys.encryption, k.sealed, orchardId: o.id, generation: k.generation);
      } catch (_) {
        AppLogger.warning('Orchards: an Orchard key did not open with this account key');
        continue;
      }
      if (!await keyMatchesCommitment(key, record.keyCommitOf(kOrchardScope, k.generation),
          orchardId: o.id, generation: k.generation)) {
        AppLogger.warning('Orchards: refused an Orchard key that is not the one the record committed to');
        continue;
      }
      orchardKeys[k.generation] = key;
    }
    final orchardGeneration = record.generationOf(kOrchardScope);
    String? name;
    final nameKey = orchardKeys[orchardGeneration];
    if (nameKey != null) {
      try {
        name = await decryptOrchardName(o.nameEnc, nameKey, orchardId: o.id, generation: orchardGeneration);
      } catch (_) {/* shown as unnamed */}
    }
    final crates = <String, ({String? name, int generation, Map<int, Uint8List> keys, bool rotationDue})>{};
    final now = _nowSeconds();
    // The keys waiting to be replaced as the record and this device's clock
    // say, beside the server's word.
    final due = record.keysDueAt(now, firstSeen: firstSeen);
    for (final c in o.crates) {
      // Only Crates the record opens to this account: for good, or until a
      // time that has not come. One whose time has come is not kept,
      // whatever the server lists.
      if (record.switchesAt(me.uid, c.id, now).isEmpty) continue;
      final keys = <int, Uint8List>{};
      for (final k in c.keys) {
        if (!await _trusted(k, me, pins, orchardId: o.id, crateId: c.id)) {
          AppLogger.warning('Orchards: refused a Crate key copy no trusted account signed');
          continue;
        }
        final Uint8List key;
        try {
          key = await openCrateKey(me.keys.encryption, k.sealed, orchardId: o.id, crateId: c.id, generation: k.generation);
        } catch (_) {
          AppLogger.warning('Orchards: a Crate key did not open with this account key');
          continue;
        }
        if (!await keyMatchesCommitment(key, record.keyCommitOf(c.id, k.generation),
            orchardId: o.id, crateId: c.id, generation: k.generation)) {
          AppLogger.warning('Orchards: refused a Crate key that is not the one the record committed to');
          continue;
        }
        keys[k.generation] = key;
      }
      final generation = record.generationOf(c.id);
      String? crateName;
      final crateKey = keys[generation];
      if (crateKey != null) {
        try {
          crateName = await decryptCrateName(c.nameEnc, crateKey, orchardId: o.id, crateId: c.id, generation: generation);
        } catch (_) {/* shown as unnamed */}
      }
      // Waiting to be replaced as the record says, or as the server does
      // (a server can add to it, not hide it).
      crates[c.id] = (
        name: crateName,
        generation: generation,
        keys: keys,
        rotationDue: c.rotationDue || due.contains(c.id),
      );
    }
    return _snapshot(record, me,
        name: name,
        keyGeneration: orchardGeneration,
        orchardKeys: orchardKeys,
        crates: crates,
        rotationDue: o.rotationDue || due.contains(kOrchardScope));
  }

  static _Snapshot _snapshot(
    OrchardRecord record,
    CrateAuthor me, {
    required String? name,
    required int keyGeneration,
    required Map<int, Uint8List> orchardKeys,
    required Map<String, ({String? name, int generation, Map<int, Uint8List> keys, bool rotationDue})> crates,
    bool rotationDue = false,
  }) =>
      _Snapshot(
        orchardId: record.orchardId,
        name: name,
        role: record.members[me.uid]!.role,
        can: {
          for (final c in RoleCan.all)
            if (record.can(me.uid, c)) c,
        },
        keyGeneration: keyGeneration,
        rotationDue: rotationDue,
        rules: record.rules,
        orchardKeys: orchardKeys,
        crates: [
          for (final e in crates.entries)
            _CrateSnapshot(
              id: e.key,
              name: e.value.name,
              switches: record.switchesAt(me.uid, e.key, _nowSeconds()),
              ownersOnly: record.crates[e.key]?.ownersOnly ?? false,
              allow: record.crates[e.key]?.allow ?? kDefaultCrateAllow,
              confirmReveal: record.crates[e.key]?.confirmReveal ?? false,
              rotationDue: e.value.rotationDue,
              keyGeneration: e.value.generation,
              keys: e.value.keys,
              // Held only until a set time: when that comes.
              heldUntil:
                  record.switchesOf(me.uid, e.key).isEmpty ? record.members[me.uid]?.timed[e.key]?.until : null,
            ),
        ],
      );

  /// [keep]: Crates that stay on this device although the server does not
  /// list them (the record still opens them to this account), each with what
  /// the record lets this account do in it now and, for access held only
  /// until a set time, when that comes.
  Future<void> _store(AppDatabase db, _Snapshot s,
      {String? defaultCrate, Map<String, ({Set<String> switches, int? heldUntil})> keep = const {}}) async {
    await db.transaction(() async {
      final info =
          await db.customSelect('SELECT default_crate_id FROM orchard_info WHERE id = 1').getSingleOrNull();
      // New items go into a Crate this account may add to.
      final addable = [
        for (final c in s.crates)
          if (c.switches.contains(CrateSwitches.add)) c.id,
      ]..sort();
      var home = defaultCrate ?? info?.read<String?>('default_crate_id');
      if (home == null || !addable.contains(home)) {
        home = addable.isEmpty ? null : addable.first;
      }
      await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can, '
        "status, rotation_due, record_problem, rules, held) VALUES (1, ?, ?, ?, ?, ?, ?, 'active', ?, NULL, ?, NULL) "
        'ON CONFLICT(id) DO UPDATE SET '
        'orchard_id = excluded.orchard_id, name = COALESCE(excluded.name, orchard_info.name), '
        'role = excluded.role, key_generation = excluded.key_generation, '
        'default_crate_id = excluded.default_crate_id, can = excluded.can, status = excluded.status, '
        'rotation_due = excluded.rotation_due, record_problem = NULL, rules = excluded.rules, held = NULL',
        [
          s.orchardId,
          s.name,
          s.role,
          s.keyGeneration,
          home,
          jsonEncode(switchList(s.can)),
          s.rotationDue ? 1 : 0,
          jsonEncode(s.rules.toBody()),
        ],
      );
      for (final e in s.orchardKeys.entries) {
        await _putKey(db, 'orchard', s.orchardId, e.key, e.value);
      }
      for (final c in s.crates) {
        await db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, owners_only, allow, rotation_due, '
          'key_generation, confirm_reveal) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(crate_id) DO UPDATE SET '
          'name = COALESCE(excluded.name, orchard_crates.name), level = excluded.level, '
          'switches = excluded.switches, owners_only = excluded.owners_only, allow = excluded.allow, '
          'rotation_due = excluded.rotation_due, key_generation = excluded.key_generation, '
          'confirm_reveal = excluded.confirm_reveal',
          [
            c.id,
            c.name,
            (levelOf(c.switches) ?? CrateLevel.connect).name,
            jsonEncode(switchList(c.switches)),
            c.ownersOnly ? 1 : 0,
            jsonEncode(switchList(c.allow)),
            c.rotationDue ? 1 : 0,
            c.keyGeneration,
            c.confirmReveal ? 1 : 0,
          ],
        );
        for (final e in c.keys.entries) {
          await _putKey(db, 'crate', c.id, e.key, e.value);
        }
      }
      final listed = {for (final c in s.crates) c.id};
      final held = <String, int>{};
      for (final row in await db.customSelect('SELECT crate_id FROM orchard_crates').get()) {
        final crateId = row.read<String>('crate_id');
        if (listed.contains(crateId)) continue;
        final kept = keep[crateId];
        if (kept == null) {
          await _dropCrate(db, crateId);
          continue;
        }
        // Held: what the record lets this account do in it now. One it
        // opens only until a set time is closed here at once, as at
        // that time (rules/crate_offline.dart): the list is made by the
        // server's clock, which says that time came, and a device whose
        // clock is behind keeps nothing usable past it; what is in it stays
        // until this device's clock passes the record's time too.
        await db.customStatement('UPDATE orchard_crates SET level = ?, switches = ? WHERE crate_id = ?', [
          (levelOf(kept.switches) ?? CrateLevel.connect).name,
          jsonEncode(switchList(kept.switches)),
          crateId,
        ]);
        if (kept.heldUntil != null) held[crateId] = math.min(kept.heldUntil!, _nowSeconds());
      }
      // Until when each Crate held only until a set time is held: from
      // that second the device closes it by itself (rules/crate_offline.dart).
      await _keepAccessUntil(db, {
        for (final c in s.crates)
          if (c.heldUntil != null) c.id: c.heldUntil!,
        ...held,
      });
    });
    // A dropped Crate's items are gone: screens showing them read again.
    db.notifyOrchardItemsChanged();
  }

  /// Keeps until when each Crate this account holds only until a set time
  /// is held ([kAccessUntilState]); nothing where there is none.
  static Future<void> _keepAccessUntil(AppDatabase db, Map<String, int> until) {
    final store = LocalStateStore(db);
    return until.isEmpty ? store.remove(kAccessUntilState) : store.write(kAccessUntilState, jsonEncode(until));
  }

  /// A Crate this account just added, as the record says.
  static Future<void> _putCrate(AppDatabase db, OrchardRecord record, String uid, String crateId,
      {required String name, required int generation, required bool rotationDue}) {
    final switches = record.switchesOf(uid, crateId);
    return db.customStatement(
      'INSERT OR REPLACE INTO orchard_crates (crate_id, name, level, switches, owners_only, allow, rotation_due, '
      'key_generation, last_revision, confirm_reveal) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)',
      [
        crateId,
        name,
        (levelOf(switches) ?? CrateLevel.connect).name,
        jsonEncode(switchList(switches)),
        (record.crates[crateId]?.ownersOnly ?? false) ? 1 : 0,
        jsonEncode(switchList(record.crates[crateId]?.allow ?? kDefaultCrateAllow)),
        rotationDue ? 1 : 0,
        generation,
        (record.crates[crateId]?.confirmReveal ?? false) ? 1 : 0,
      ],
    );
  }

  /// A Crate this account can no longer open leaves this device, with its
  /// items and its keys. Its name stays a while ([goneCrateNames]).
  Future<void> _dropCrate(AppDatabase db, String crateId) async {
    final store = OrchardItemStore(db);
    await _keepGoneCrateName(db, crateId);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    try {
      final items = await db.customSelect(
        'SELECT kind, item_key FROM crate_items_meta WHERE crate_id = ?',
        variables: [Variable(crateId)],
      ).get();
      for (final r in items) {
        final kind = r.read<String>('kind');
        final key = r.read<String>('item_key');
        if (OrchardItemStore.isKind(kind)) {
          await store.write(kind, key, data: null, editedAt: 0);
        }
        await db.customStatement('DELETE FROM crate_outbox WHERE kind = ? AND item_key = ?', [kind, key]);
      }
      await db.customStatement('DELETE FROM crate_items_meta WHERE crate_id = ?', [crateId]);
      await db.customStatement('DELETE FROM crate_leftovers WHERE crate_id = ?', [crateId]);
      await db.customStatement("DELETE FROM space_keys WHERE scope = 'crate' AND scope_id = ?", [crateId]);
      await db.customStatement('DELETE FROM orchard_crates WHERE crate_id = ?', [crateId]);
    } finally {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    }
  }

  /// Keeps the name of [crateId], leaving this device, among the last
  /// [_goneCrateNamesKept] gone ([goneCrateNames]).
  static Future<void> _keepGoneCrateName(AppDatabase db, String crateId) async {
    final row = await db
        .customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?', variables: [Variable(crateId)])
        .getSingleOrNull();
    final name = row?.read<String?>('name');
    if (name == null || name.isEmpty) return;
    final names = {...await goneCrateNames(db)}
      ..remove(crateId)
      ..[crateId] = name;
    while (names.length > _goneCrateNamesKept) {
      names.remove(names.keys.first);
    }
    await LocalStateStore(db).write(kGoneCrateNamesState, jsonEncode(names));
  }

  static const _goneCrateNamesKept = 20;

  /// Keeps a key this device opened. A generation's key never changes, so
  /// one already here is never replaced, whatever a later copy says.
  static Future<void> _putKey(AppDatabase db, String scope, String scopeId, int generation, Uint8List secret) =>
      db.customStatement(
        'INSERT OR IGNORE INTO space_keys (scope, scope_id, generation, secret) VALUES (?, ?, ?, ?)',
        [scope, scopeId, generation, secret],
      );

  static Set<String> _switches(String json) {
    try {
      return {
        for (final s in jsonDecode(json) as List)
          if (s is String) s,
      };
    } catch (_) {
      return const {};
    }
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// A role the owners made, as this device shows it.
class OrchardRoleView {
  const OrchardRoleView({
    required this.id,
    required this.name,
    required this.rank,
    required this.can,
    required this.crates,
  });

  final String id;

  /// Null while the Orchard key it is encrypted with is not on this device.
  final String? name;
  final int rank;
  final Set<String> can;

  /// Crate id -> the switches the role gives there.
  final Map<String, Set<String>> crates;
}

/// The last entry of an Orchard's record as the server names it: its number
/// and hash.
class RecordHead {
  const RecordHead(this.seq, this.hash);

  final int seq;
  final Uint8List hash;
}

/// The server holds this account back by the Orchard's rules ([e]) since the
/// list of Orchards was read: noted in the Orchard's own database, until the
/// next refresh says more.
Future<void> _noteHeldByRules(AppDatabase db, OrchardServerException e) => db.customStatement(
      'UPDATE orchard_info SET status = ?, held = ? WHERE id = 1',
      ['rules', jsonEncode({'unmet': e.unmet ?? const <String>[], 'email_domains': const <String>[]})],
    );

/// Keeps every Orchard on this device in sync: refreshes the list and the
/// keys, then syncs each Orchard. One engine per open Orchard database, so
/// each Orchard runs one sync at a time.
class OrchardSyncCoordinator {
  OrchardSyncCoordinator({
    required this.service,
    required this.server,
    required this.databases,
    this.onStaleAccountKeys,
    Future<List<UnmetRule>> Function(RecordRules rules)? deviceRules,
  }) : deviceRules = deviceRules ?? _noDeviceRules;

  static Future<List<UnmetRule>> _noDeviceRules(RecordRules _) async => const [];

  final OrchardService service;
  final CrateServer server;
  final OrchardDatabasesNotifier databases;

  /// The rules this device falls short of (its app lock): an Orchard
  /// that asks for one does not sync while it does.
  final Future<List<UnmetRule>> Function(RecordRules rules) deviceRules;

  /// Called when the server refused a write made with keys the account has
  /// replaced: this device must learn the new keys.
  final void Function()? onStaleAccountKeys;
  final _engines = <String, (AppDatabase, CrateSyncEngine)>{};

  /// Every Orchard of this account whose membership counts, refreshed and
  /// synced. Returns each Orchard's report.
  Future<Map<String, CrateSyncReport>> syncAll() async {
    final me = await service._me();
    final reports = <String, CrateSyncReport>{};
    for (final id in await service.refresh()) {
      reports[id] = await syncOne(id, me: me);
    }
    return reports;
  }

  /// One Orchard: its Crates pulled, then this device's changes pushed. When
  /// a key or the record is missing or out of date, they are refreshed and
  /// it runs once more.
  Future<CrateSyncReport> syncOne(String orchardId, {CrateAuthor? me}) async {
    final db = await databases.open(orchardId);
    if (!await _maySync(db)) return CrateSyncReport()..held = true;
    final author = me ?? await service._me();
    try {
      var report = await engineFor(orchardId, author: author).then((e) => e.sync());
      if ((report.needsKeys || report.needsRecord) && !report.staleAccountKeys) {
        await service.refresh();
        report = await engineFor(orchardId, author: author).then((e) => e.sync());
      }
      if (report.staleAccountKeys) {
        onStaleAccountKeys?.call();
      } else {
        // Certificates: signed for others as an owner, taken in, and
        // asked for again when due. Never why a sync fails.
        await service.certificateRound(orchardId);
        // What this device did, while the owners record activity.
        try {
          await service.activityRound(orchardId);
        } catch (e) {
          AppLogger.info('Orchards: activity waits for the next sync ($e)');
        }
        // What this device reports of sessions that went on with nobody
        // watching while the server could not be reached (the outage work).
        try {
          await service.unwatchedRound(orchardId);
        } catch (e) {
          AppLogger.info('Orchards: a report of a session with nobody watching waits for the next sync ($e)');
        }
        // What this device keeps of session logs the server has not taken
        // (the outage work): sent from now on, since the server answers.
        // Never why a sync fails, nor what one waits for: much may be kept.
        unawaited(service.sessionLogCatchUp(orchardId));
      }
      return report;
    } on OrchardServerException catch (e) {
      if (e.teamBeingDeleted) {
        // Deleted since the list was read : held back, as the
        // next refresh says in full.
        await _noteBeingDeleted(db, e);
        return CrateSyncReport()..held = true;
      }
      if (!e.rulesUnmet) rethrow;
      await _noteHeldByRules(db, e);
      return CrateSyncReport()..held = true;
    }
  }

  /// Whether [db]'s Orchard may sync now: not while the server holds
  /// this account back by its rules, nor while this device falls short of
  /// one of them.
  Future<bool> _maySync(AppDatabase db) async {
    final info = await db.customSelect('SELECT status, rules FROM orchard_info WHERE id = 1').getSingleOrNull();
    if (info == null) return true;
    final status = info.read<String>('status');
    // Nor while the team is being deleted, or was, nor while
    // ZestSSH Cloud no longer lists it.
    if (status == 'rules' || status == kDeletingStatus || status == kDeletedStatus || status == kUnlistedStatus) {
      return false;
    }
    final raw = info.read<String?>('rules');
    if (raw == null) return true;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } catch (_) {
      return true;
    }
    return (await deviceRules(RecordRules.fromStored(json))).isEmpty;
  }

  /// What this device holds back of an Orchard's items ([CrateSyncEngine.heldBack]).
  Future<List<HeldBackItem>> heldBack(String orchardId) async =>
      (await engineFor(orchardId, author: await service._me())).heldBack();

  /// [CrateSyncEngine.keepHeldBack], and the sync that sends it. A sync that fails
  /// throws, and the choice waits for the next one.
  Future<bool> keepHeldBack(String orchardId, String kind, String key, String crateId) async {
    final engine = await engineFor(orchardId, author: await service._me());
    if (!await engine.keepHeldBack(kind, key, crateId)) return false;
    await syncOne(orchardId);
    return true;
  }

  /// [CrateSyncEngine.removeHeldBack], and the sync that sends it, as [keepHeldBack].
  Future<bool> removeHeldBack(String orchardId, String kind, String key, String crateId) async {
    final engine = await engineFor(orchardId, author: await service._me());
    if (!await engine.removeHeldBack(kind, key, crateId)) return false;
    await syncOne(orchardId);
    return true;
  }

  /// The engine of an Orchard, for moving and placing items.
  Future<CrateSyncEngine> engineFor(String orchardId, {required CrateAuthor author}) async {
    final db = await databases.open(orchardId);
    final known = _engines[orchardId];
    // A new engine for new keys: an engine signs, and checks signatures,
    // with the keys it was made with.
    if (known != null &&
        identical(known.$1, db) &&
        known.$2.author.uid == author.uid &&
        known.$2.author.keys.version == author.keys.version) {
      return known.$2;
    }
    final members = MemberDirectory(db);
    final engine = CrateSyncEngine(
      db: db,
      orchardId: orchardId,
      server: server,
      author: author,
      // This account's own current keys, and each member's keys as this
      // device trusts them: after a hard stop, not their new ones.
      signers: (uid, version) async => uid == author.uid
          ? (version == author.keys.version ? author.keys.signingPublicKey : null)
          : members.signingKey(uid, version),
    );
    _engines[orchardId] = (db, engine);
    return engine;
  }
}

/// An invite code made on this device: shown to its maker once, here.
class MadeInviteCode {
  const MadeInviteCode({required this.code, required this.inviteId, required this.expiresAt});

  /// In its normal form (join_code_crypto.dart).
  final String code;
  final String inviteId;
  final DateTime expiresAt;
}

/// A code's offer, checked against the code ([OrchardService.previewInviteCode]).
class InviteCodePreview {
  const InviteCodePreview({required this.code, required this.offer, required this.shown});

  final String code;
  final InviteCodeOffer offer;

  /// The team's name, the role's and the vaults, as its maker wrote them.
  final JoinOffer shown;
}

/// Whether whoever used an invite code is checked by it, and the code
/// (where this device could open it).
class InviteCodeCheck {
  const InviteCodeCheck({required this.checked, this.code, this.teamCode = false, this.offerChanged = false});

  final bool checked;
  final String? code;

  /// A use of a team code: its keys are compared, never checked by the code.
  final bool teamCode;

  /// The server lists another role, other vaults or another end date than
  /// the maker signed: nobody is let in on it.
  final bool offerChanged;
}

enum InviteCodeProblem {
  /// What was typed, pasted or scanned is no invite code.
  notACode,

  /// The code does not check out: the team, its maker's keys or the offer
  /// are not what its maker made it for.
  checkFailed,
}

class InviteCodeError implements Exception, HasTypeName {
  const InviteCodeError(this.problem);

  final InviteCodeProblem problem;

  @override
  String toString() => 'Orchards: invite code refused (${problem.name})';

  @override
  String get typeName => 'InviteCodeError';
}

/// Why an invitation could not be confirmed on this device.
enum OrchardInviteProblem {
  /// They have not accepted (or their keys were not listed).
  notAccepted,

  /// The keys listed for them do not sign for their account.
  badKeys,

  /// An invite code's use offers another role, other vaults or another end
  /// date than its maker signed: changed on the way. On a device of
  /// the code's maker, also where the copy the maker signed is not there to
  /// say.
  offerChanged,

  /// An invitation to an address this device made is listed with another
  /// role, other vaults or another end date than it offered.
  inviteOfferChanged,

  /// A key the invitation needs is not on this device: a Crate offered that
  /// this account cannot open.
  missingKeys,
}

class OrchardInviteError implements Exception, HasTypeName {
  const OrchardInviteError(this.problem);

  final OrchardInviteProblem problem;

  @override
  String toString() => 'Orchards: invitation not confirmed (${problem.name})';

  @override
  String get typeName => 'OrchardInviteError';
}

/// The Orchard's rules refuse a change this account asked for (checked here
/// before anything is sent; the server applies the same rules).
class OrchardRecordRefused implements Exception, HasTypeName {
  const OrchardRecordRefused(this.reason);

  final String reason;

  @override
  String toString() => 'Orchards: the record refused the change ($reason)';

  @override
  String get typeName => 'OrchardRecordRefused';
}

/// An Orchard already has as many roles as it may ([kMaxOrchardRoles]).
class OrchardRoleLimit implements Exception, HasTypeName {
  const OrchardRoleLimit();

  @override
  String toString() => 'Orchards: no room for another role';

  @override
  String get typeName => 'OrchardRoleLimit';
}

/// A key would be sealed to [uid], and this device does not trust their
/// keys yet (a hard stop, or keys it has not seen): someone compares their
/// fingerprint first.
class MemberKeysNotTrusted implements Exception, HasTypeName {
  const MemberKeysNotTrusted(this.uid);

  final String uid;

  @override
  String toString() => 'Orchards: the keys of $uid are not trusted on this device';

  @override
  String get typeName => 'MemberKeysNotTrusted';
}

class _Snapshot {
  const _Snapshot({
    required this.orchardId,
    required this.name,
    required this.role,
    required this.can,
    required this.keyGeneration,
    required this.rotationDue,
    required this.rules,
    required this.orchardKeys,
    required this.crates,
  });

  final String orchardId;
  final String? name;
  final String role;
  final Set<String> can;
  final int keyGeneration;
  final bool rotationDue;
  final RecordRules rules;
  final Map<int, Uint8List> orchardKeys;
  final List<_CrateSnapshot> crates;
}

class _CrateSnapshot {
  const _CrateSnapshot({
    required this.id,
    required this.name,
    required this.switches,
    required this.ownersOnly,
    required this.allow,
    required this.rotationDue,
    required this.keyGeneration,
    required this.keys,
    this.confirmReveal = false,
    this.heldUntil,
  });

  final String id;
  final String? name;
  final Set<String> switches;

  /// The second, since the epoch, until which this account holds the Crate,
  /// where it holds it only until a set time; null where it opens it
  /// for good.
  final int? heldUntil;
  final bool ownersOnly;
  final Set<String> allow;
  final bool confirmReveal;
  final bool rotationDue;
  final int keyGeneration;
  final Map<int, Uint8List> keys;
}
