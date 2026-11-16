import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// An in-memory [CrateServer] with the rules of ZestSSH Cloud's
/// routes/orchards.js, the Orchard's record included: every change to
/// who is in an Orchard or what they may do is an entry checked by the same
/// rules as the app's (lib/features/orchards/record/orchard_record.dart),
/// by whoever sends it; a change that gives someone a key must bring every
/// generation of it sealed to them and signed by the entry's author, and
/// one that takes a key away drops the server's copies and marks it for
/// replacement. Access counts end dates, and accounts in [deletedAccounts]
/// hold nothing; a new key generation is a key.rotate entry with a copy
/// for exactly everyone who holds the key. A Crate given until a set time
/// counts while it runs, by this server's [clock]; when it has ended
/// the copies go and the key is marked at the next change to the record or
/// when [runEndedAccessJob] is called, and members ask for access with
/// requests kept here until they are answered. One revision sequence for every
/// Crate, create-only items (a
/// create of an id that exists is a conflict), a write based on anything but
/// the current revision is a conflict carrying the current version, a
/// replaced version is kept in the history, and a write under an old key
/// generation refuses the whole batch. The Orchard's rules: an account
/// in [held] is answered 'rules-unmet' on the Orchard's routes and listed as
/// such, with the rules its devices keep to meanwhile, except that an owner
/// still reads the record and sets the rules, and anyone may leave.
/// Trusted devices: a sign-in ([accountSession]) says which device it
/// is; where an Orchard's rules let in approved devices only, a sign-in
/// whose device the record does not list for the member is answered
/// 'rules-unmet' with 'trusted_device', an owner's too; a device asks to be
/// approved with a request this server passes between the two devices; and
/// a certificate is taken only for a device the record lists.
///
/// It answers as [accountUid] (the device under test). Tests act as other
/// members with [appendAs], [acceptAs] and [publish].
class FakeCrateServer implements CrateServer {
  FakeCrateServer({this.accountUid = 'owner-1'});

  /// The account this server answers for.
  String accountUid;

  /// The version of each account's published keys: item writes name it,
  /// and a key replacement moves it on.
  final keyVersions = <String, int>{};

  int get accountKeyVersion => keyVersions[accountUid] ?? 1;
  set accountKeyVersion(int v) => keyVersions[accountUid] = v;

  /// The sign-in this server answers: null for one with no session.
  String? accountSession;

  /// The server cannot be reached: whatever a device asks of it through its
  /// own view ([as]) fails as a refused connection does, and nothing is
  /// changed here. (What a test does to this server directly still works:
  /// that is the test, not a device.)
  bool down = false;

  /// How often a device asked while it could not be reached.
  int askedWhileDown = 0;

  /// The server answers whatever a device asks of it with a fault of its
  /// own, this HTTP status (502, 503): nothing is done, nothing is changed.
  int? fault;

  /// Whatever a device asks waits for this first: a server that takes its
  /// time, or one that never answers.
  Future<void>? stall;

  /// How often a device asked anything at all.
  int asked = 0;

  /// The server stops answering once a device has asked this many more
  /// things of it ([down] from then on): a device that loses the server in
  /// the middle of something.
  int? downAfter;

  /// This server as [uid]'s devices see it: the same Orchards, records and
  /// items, answered as that account, from the sign-in of its device
  /// [device] when given, or from the sign-in [signIn] names at each
  /// call (a device that signs in again has another). (One call at a time,
  /// as the tests make them.)
  CrateServer as(String uid, {String? device, String? Function()? signIn}) => _AccountView(this, uid, () {
        final name = signIn == null ? device : signIn();
        return name == null ? null : sessionOf(uid, name);
      });

  /// The id of the sign-in of [uid]'s device [device].
  static String sessionOf(String uid, String device) => '$uid/$device';

  /// The device key each sign-in named, by session id.
  final namedDevices = <String, String>{};

  /// Published account keys and addresses, by account.
  final published = <String, PublishedAccountKeys>{};
  final emails = <String, String>{};

  /// The name and picture each account shows, as the member list gives them.
  final names = <String, String>{};
  final pictures = <String, String>{};

  /// Registers [uid]'s published keys (and address), as POST /v1/keys would.
  Future<void> publish(String uid, AccountKeys keys, {String? email}) async {
    published[uid] = await keys.publish(uid);
    if (email != null) emails[uid] = email;
  }

  final _orchards = <String, _Orchard>{};
  final crateGenerations = <String, int>{};

  /// Teams purged after their deletion: the record's entries,
  /// for its fingerprints, and when they went.
  final _deletedTeams = <String, ({List<RecordEntry> entries, DateTime at})>{};

  /// How often a team was asked to be deleted, or undeleted, refused or not.
  var deletes = 0;
  var restores = 0;

  /// Deleting a team wants a sign-in from the last ten minutes, and this one
  /// is older.
  bool deleteSignInTooOld = false;

  /// Accounts deleted since an Orchard's record added them: they hold no
  /// key and the member list names them.
  final deletedAccounts = <String>{};

  /// crateId -> itemId -> the item now.
  final items = <String, Map<String, RemoteItem>>{};

  /// itemId -> replaced and kept versions, oldest first.
  final history = <String, List<SealedItem>>{};

  /// Every replaced and kept version with its Crate, revision and when it
  /// was replaced, oldest first.
  final historyRows = <FakeHistoryRow>[];
  var _historyId = 0;

  /// The server's clock: for when versions are replaced and history is
  /// turned on, and for what counts now (end dates, and access given
  /// until a set time). A test moves it.
  DateTime Function() clock = DateTime.now;

  /// Activity events taken, by Orchard.
  final activityRows = <String, List<ActivityEntry>>{};

  /// Every request to send activity, refused ones too.
  var activityCalls = 0;

  /// Team session logs by Crate, oldest first.
  final sessionLogRows = <String, List<FakeSessionLog>>{};

  /// Every chunk request, refused ones too.
  var sessionLogChunkCalls = 0;

  /// Answers a request for one item's history with every item's, as a
  /// server not playing by the rules would.
  bool historyIgnoresItem = false;

  /// More people than seats: a write that adds anything (a deleted
  /// item brought back too) is refused.
  bool seatsShort = false;

  /// What the Orchard's vaults hold is what its seats keep: nothing new goes in
  /// (the server's 'seats-needed' with the reason 'storage'), and, with
  /// [vaultsPastChanges], no change either.
  bool vaultsFull = false;
  bool vaultsPastChanges = false;
  var _activityId = 0;

  final writeCalls = <List<ItemWrite>>[];
  var _revision = 0;
  final rotations = <String>[];

  /// Places (`orchard:<id>`, `crate:<id>`) whose next rotation fails once,
  /// as a dropped connection would.
  final failRotationOnce = <String>{};

  /// Runs once as this account's next rotation arrives, before it is
  /// checked: lets another device get in first.
  Future<void> Function()? beforeRotate;

  /// Whom each rotation request sealed the new key to, as sent (before any
  /// check), in order.
  final rotationRequests = <List<String>>[];

  /// Runs inside a write, before the answer: lets a test change things on
  /// the device while a push is on its way.
  Future<void> Function()? duringWrite;

  final memberReads = <String>[];

  /// Whether new kinds of record entry are on, as the list says (on here,
  /// for the tests of what they do; one test turns it off).
  bool newRecordKinds = true;

  /// Puts an entry of a kind this app does not know after [orchardId]'s
  /// record, as a newer app's would be: served, not applied here.
  void serveNewerEntry(String orchardId, {String type = 'team.future'}) {
    final o = _orchard(orchardId);
    o.entries.add(RecordEntry(
        seq: o.record.seq + 1,
        prev: o.record.head,
        type: type,
        bodyJson: '{}',
        by: accountUid,
        byKeyVersion: 1,
        signature: Uint8List(64)));
  }

  /// Statements stored by [verifyMember].
  final verifications =
      <({String orchardId, String by, String subjectUid, int subjectKeyVersion, int keyVersion, Uint8List signature})>[];

  _Orchard _orchard(String id) =>
      _acting = _orchards[id] ?? (throw const OrchardServerException(404, 'not-found'));

  /// The Orchard the call in progress is about (the one it looked up last):
  /// whether a device is approved is each Orchard's own to say.
  _Orchard? _acting;

  /// The record of [orchardId], as the server holds it.
  OrchardRecord recordOf(String orchardId) => _orchard(orchardId).record;

  /// A server that says [uid]'s device [key] was removed from [orchardId] with no
  /// signed device.revoke in its record: a lie a device must not act on.
  void sayDeviceRemoved(String orchardId, String uid, String key) => _orchard(orchardId).removedDevices.add('$uid|$key');

  /// Its entries, oldest first.
  List<RecordEntry> entriesOf(String orchardId) => List.unmodifiable(_orchard(orchardId).entries);

  // ── What an account sees ──

  int get _now => clock().millisecondsSinceEpoch ~/ 1000;

  /// Whether [uid]'s membership counts now: in the record, not suspended,
  /// and before any end date.
  bool _counts(OrchardRecord r, String uid) {
    final m = r.members[uid];
    return m != null && m.status == MemberStatus.active && (m.endsAt == null || m.endsAt! > _now);
  }

  /// The Orchards this server lists for [accountUid], by id.
  Map<String, RemoteOrchard> get orchardsById => {
        for (final o in _orchards.values)
          if (!hidden.contains(o.id)) o.id: ?_listing(o, accountUid),
      };

  /// Orchards the server stops listing (as for an account taken out).
  final hidden = <String>{};

  /// Serves [keys] as this account's copies of the Orchard's key (null
  /// [crateId]) or a Crate's, instead of the ones it holds; [generation]
  /// moves the key's current generation.
  void serveKeys(String orchardId, List<SealedSpaceKey> keys, {String? crateId, int? generation}) {
    final o = _orchard(orchardId);
    o.copies.putIfAbsent(accountUid, () => {})[crateId ?? 'orchard'] = {for (final k in keys) k.generation: k};
    if (generation != null) {
      if (crateId == null) {
        o.generation = generation;
      } else {
        o.crates[crateId]!.generation = generation;
        crateGenerations[crateId] = generation;
      }
    }
  }

  /// Accounts the server holds back by the Orchard's rules, with the
  /// rules they fall short of ('two_step', 'email_domain', 'reauth').
  final held = <String, List<String>>{};

  /// Whom a rules.set leaves short of the new rules, as the server checks
  /// the account sending it: 'rules-unmet-by-you' when not empty.
  List<String> Function(RecordRules rules)? unmetBySender;

  /// Whether the record of [o] lists, for the account this server answers,
  /// the device its sign-in named.
  bool _deviceApproved(_Orchard o) {
    final key = namedDevices[accountSession];
    return key != null && o.record.devicesOf(accountUid).contains(key);
  }

  /// Whether only approved devices get into [o] and this sign-in's is not
  /// one. No exception is made for it, not for an owner either.
  bool _deviceHeld(_Orchard o) => o.record.rules.trustedDevices && !_deviceApproved(o);

  /// The rules [uid] falls short of in [o] (the Orchard the call is about,
  /// when not given): the ones a test put in [held], and the device.
  List<String> _unmet(String uid, [_Orchard? o]) {
    final orchard = o ?? _acting;
    return [
      ...?held[uid],
      if (orchard != null && uid == accountUid && _deviceHeld(orchard)) 'trusted_device',
    ];
  }

  OrchardServerException _heldError(String uid) =>
      OrchardServerException(403, 'rules-unmet', unmet: _unmet(uid));

  bool _isHeld(String uid) => _unmet(uid).isNotEmpty;

  RemoteOrchard? _listing(_Orchard o, String uid) {
    final m = o.record.members[uid];
    if (m == null || m.status == MemberStatus.removed) return null;
    if (!_counts(o.record, uid)) {
      return RemoteOrchard.inactive(o.id, m.status == MemberStatus.suspended ? 'suspended' : 'ended');
    }
    // Being deleted: every member learns who asked and the day,
    // and their role; nothing else.
    if (o.record.deleting != null) {
      final rules = o.record.rules;
      return RemoteOrchard.inactive(o.id, 'deleting',
          role: m.role,
          heldDeviceRules: RecordRules(
            requireAppLock: rules.requireAppLock,
            maxLockMinutes: rules.maxLockMinutes,
            noExport: rules.noExport,
            offlineHours: rules.offlineHours,
            screensSshOnly: rules.screensSshOnly,
            screensLockRedirections: rules.screensLockRedirections,
          ),
          deleting: _deletionOf(o));
    }
    final unmet = _unmet(uid, o);
    if (unmet.isNotEmpty) {
      final rules = o.record.rules;
      return RemoteOrchard.inactive(o.id, 'rules',
          role: m.role,
          rulesUnmet: unmet,
          ruleDomains: unmet.contains('email_domain') ? (rules.emailDomains.toList()..sort()) : const [],
          // The rules its devices keep to meanwhile, and only those.
          heldDeviceRules: RecordRules(
            requireAppLock: rules.requireAppLock,
            maxLockMinutes: rules.maxLockMinutes,
            noExport: rules.noExport,
            offlineHours: rules.offlineHours,
            screensSshOnly: rules.screensSshOnly,
            screensLockRedirections: rules.screensLockRedirections,
          ),
          // Approved once, and no longer: it drops what it holds.
          deviceRemoved: unmet.contains('trusted_device') &&
              o.removedDevices.contains('$uid|${namedDevices[accountSession]}'));
    }
    final can = {
      for (final c in RoleCan.all)
        if (o.record.can(uid, c)) c,
    };
    return RemoteOrchard(
      id: o.id,
      nameEnc: o.nameEnc,
      keyGeneration: o.generation,
      role: m.role,
      status: 'active',
      recordSeq: o.record.seq,
      rotationDue: o.rotationDue,
      can: can,
      // A deleted account's membership goes with it, which moves the tag.
      membersTag: '${o.membersTag}:${[for (final m in o.record.members.keys) emails[m]].join(',')}:${deletedAccounts.where(o.record.members.containsKey).length}',
      invitesWaiting: can.contains(RoleCan.invite)
          ? o.invites.values.where((i) => i.acceptedBy != null && !i.expired).length
          : null,
      keys: [...?o.copies[uid]?['orchard']?.values],
      crates: [
        for (final c in o.crates.values)
          if (o.record.switchesAt(uid, c.id, _now).isNotEmpty)
            RemoteCrate(
              id: c.id,
              nameEnc: c.nameEnc,
              keyGeneration: c.generation,
              level: (levelOf(o.record.switchesAt(uid, c.id, _now)) ?? CrateLevel.connect).name,
              switches: o.record.switchesAt(uid, c.id, _now),
              ownersOnly: o.record.crates[c.id]!.ownersOnly,
              allow: o.record.crates[c.id]!.allow,
              rotationDue: c.rotationDue,
              keys: [...?o.copies[uid]?[c.id]?.values],
            ),
      ],
    );
  }

  /// The list of Orchards cannot be read while set, as with no way to
  /// ZestSSH Cloud.
  bool failOrchards = false;

  /// Awaited before the list is read, where set: a test holds a device's
  /// read of the list back until another has got so far.
  Future<void> Function()? beforeOrchards;

  /// Called as the record is asked for (with the reads so far).
  void Function(int reads)? onRecordRead;

  @override
  Future<List<RemoteOrchard>> orchards() async {
    final gate = beforeOrchards;
    if (gate != null) await gate();
    if (failOrchards) throw const OrchardServerException(503, null);
    newRecordKindsOn.value = newRecordKinds;
    return orchardsById.values.toList();
  }

  /// How often the record was asked for, refused or not.
  var recordReads = 0;

  /// A server that lets someone the record took out read it (ZestSSH Cloud
  /// does not): their device then sees the signed member.remove.
  bool formerMembersRead = false;

  @override
  Future<RecordPage> record(String orchardId, {required int after}) async {
    recordReads++;
    onRecordRead?.call(recordReads);
    if (failRecord) throw const OrchardServerException(503, null);
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid) && !(formerMembersRead && o.record.members.containsKey(accountUid))) {
      throw const OrchardServerException(404, 'not-found');
    }
    // Owners read it even while held back: they can always change the
    // rules. Not from a device nobody approved. A device whose approval
    // was taken back reads it, to see the signed removal.
    final removedHere = _deviceHeld(o) && o.removedDevices.contains('$accountUid|${namedDevices[accountSession]}');
    if (!removedHere && _isHeld(accountUid) && (!o.record.isOwner(accountUid) || _deviceHeld(o))) {
      throw _heldError(accountUid);
    }
    final rest = o.entries.where((e) => e.seq > after).toList();
    final page = rest.take(recordPage).toList();
    final more = rest.length > page.length;
    return RecordPage(
        entries: page,
        seq: o.record.seq,
        more: more,
        receipt: more || o.record.seq == 0 || olderServer ? null : receiptFor(orchardId, o.record.seq, o.record.head));
  }

  // ── A restore from a backup (the restore work) ──

  /// This server's receipt for [orchardId]'s record at [seq] with [head]:
  /// made up, but only this server makes it.
  static String receiptFor(String orchardId, int seq, List<int> head) => 'receipt:$orchardId:$seq:${base64Encode(head)}';

  /// The record of [orchardId] taken back to its first [seq] entries, as a
  /// restore from an older backup takes it (the tables that follow it are
  /// not: tests take back what they need).
  Future<void> rollBackRecord(String orchardId, int seq) async {
    final o = _orchard(orchardId);
    o.entries.removeRange(seq, o.entries.length);
    o.record = await OrchardRecord.replay(orchardId, o.entries, trusted: true);
  }

  /// Every mend asked for, refused or not, and the names the last one
  /// brought.
  var mends = 0;
  var lastMendNames = <MendName>[];

  /// Whether a Crate's changes answer an [ItemCheck] (an older server does
  /// not, and leaves the device to the Crate's head).
  bool answersChecks = true;

  /// A server a deploy behind the app (as deployed before the restore work,
  /// ZestSSH Cloud's 2a58e74): no receipt with the record, no Crate head or
  /// check, never copies missing, and the restore work's routes are not
  /// there (a "Not found" with no code, as its Express 404 answers).
  bool olderServer = false;

  static const _noRoute = OrchardServerException(404, null);

  @override
  Future<int> mendRecord(String orchardId,
      {required int after, required List<RecordEntry> entries, required String receipt, List<MendName> names = const []}) async {
    mends++;
    lastMendNames = names;
    if (olderServer) throw _noRoute;
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (entries.isEmpty || entries.first.seq != after + 1) throw const OrchardServerException(400, 'invalid-request');
    if (o.record.seq != after) throw const OrchardServerException(409, 'record-moved');
    final head = o.record.head;
    if (!_same(entries.first.prev, head)) throw const OrchardServerException(409, 'record-fork');
    final next = o.record.copy();
    for (final e in entries) {
      try {
        await next.append(e);
      } on RecordRejected catch (r) {
        throw OrchardServerException(403, 'record-refused', reason: r.reason);
      }
    }
    if (receipt != receiptFor(orchardId, next.seq, next.head)) throw const OrchardServerException(403, 'record-unproven');
    o.entries.addAll(entries);
    o.record = next;
    return next.seq;
  }

  @override
  Future<RecordHolds> recordHolds(String orchardId, int seq, Uint8List hash) async {
    holdsAsked++;
    if (olderServer) throw _noRoute;
    final fail = holdsFail;
    if (fail != null) throw fail;
    final o = _orchards[orchardId];
    // A team that was deleted keeps its fingerprints, and says
    // so to a device that shows it held them.
    final gone = o == null ? _deletedTeams[orchardId] : null;
    final entries = o?.entries ?? gone?.entries;
    if (entries == null || seq < 1 || seq > entries.length) return const RecordHolds(false);
    final r = await OrchardRecord.replay(orchardId, entries.sublist(0, seq), trusted: true);
    if (!_same(r.head, hash)) return const RecordHolds(false);
    return RecordHolds(true, deletedAt: gone?.at);
  }

  /// How often a device asked whether the record holds an entry.
  var holdsAsked = 0;

  /// What that question fails with, where it does (null: it is answered).
  OrchardServerException? holdsFail;

  @override
  Future<List<MissingCopy>> missingCopies(String orchardId) async => olderServer ? throw _noRoute : const [];

  @override
  Future<int> fillCopies(String orchardId, List<GrantCopy> copies) async => olderServer ? throw _noRoute : 0;

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Entries per page of the record (the server's is 200).
  int recordPage = 200;

  /// The record cannot be read, as when the connection drops.
  bool failRecord = false;

  // ── Changing the record ──

  static const _appendTypes = {
    RecordTypes.crateSet,
    RecordTypes.roleSet,
    RecordTypes.roleDrop,
    RecordTypes.memberSet,
    RecordTypes.memberSuspend,
    RecordTypes.memberResume,
    RecordTypes.memberRemove,
    RecordTypes.rulesSet,
    RecordTypes.recoverySet,
    RecordTypes.caSet,
    RecordTypes.trackingSet,
    RecordTypes.accessGrant,
    RecordTypes.deviceTrust,
    RecordTypes.deviceRevoke,
    RecordTypes.exportSet,
    // (A report of a session without a watcher: taken like any other
    // entry, and with no recent sign-in asked, since a device sends it by
    // itself when it is back.)
    RecordTypes.sessionUnwatched,
    // The Admin role changed or put back (3.3.0).
    RecordTypes.adminSet,
    // A member limited in a vault.
    RecordTypes.memberLimit,
  };

  /// The types of each append, one list per request.
  final appends = <List<String>>[];

  /// What the next append is answered with, once, in place of taking it:
  /// a refusal that only the server makes.
  Object? failNextAppend;

  /// How many appends are taken first, before [failNextAppend] answers one.
  int failAppendAfter = 0;

  /// [failNextAppend] is the server going away: nothing answers from then on.
  bool failAppendsStay = false;

  /// Changing who is in the Orchard or what they may do asks for a recent
  /// sign-in, as the server does when the account's last sign-in is older
  /// than ten minutes. Leaving does not.
  bool requireRecentSignIn = false;

  static const _stepUp = {
    RecordTypes.crateSet,
    RecordTypes.roleSet,
    RecordTypes.roleDrop,
    RecordTypes.memberSet,
    RecordTypes.memberSuspend,
    RecordTypes.memberResume,
    RecordTypes.memberRemove,
    RecordTypes.rulesSet,
    RecordTypes.recoverySet,
    RecordTypes.caSet,
    RecordTypes.trackingSet,
    RecordTypes.accessGrant,
    RecordTypes.deviceTrust,
    RecordTypes.deviceRevoke,
    RecordTypes.exportSet,
    RecordTypes.adminSet,
    RecordTypes.memberLimit,
  };

  /// Leaving needs no recent sign-in, nor does ending access given until a
  /// set time.
  bool _needsStepUp(RecordEntry e) =>
      _stepUp.contains(e.type) &&
      !(e.type == RecordTypes.memberRemove && e.body['uid'] == accountUid) &&
      !(e.type == RecordTypes.accessGrant && e.body['until'] == 0) &&
      // A device takes back its own approval without signing in again.
      !(e.type == RecordTypes.deviceRevoke && e.body['via'] is String && e.body['via'] == e.body['device']);

  /// Access until a set time ends within thirty days of when it is given,
  /// by this server's clock (five minutes of leeway).
  static const _maxAccessSeconds = 30 * 24 * 60 * 60;
  static const _accessLeewaySeconds = 5 * 60;

  @override
  Future<int> appendRecord(String orchardId, List<RecordEntry> entries, {List<GrantCopy> copies = const []}) async {
    appends.add([for (final e in entries) e.type]);
    if (failNextAppend != null && failAppendAfter > 0) {
      failAppendAfter--;
    } else {
      final refusal = failNextAppend;
      if (!failAppendsStay) failNextAppend = null;
      if (refusal != null) {
        if (failAppendsStay) failOrchards = true;
        throw refusal;
      }
    }
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (entries.isEmpty || entries.any((e) => !_appendTypes.contains(e.type) || e.by != accountUid)) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    // While the team is being deleted, only what lets it be seen, undone
    // and left.
    if (o.record.deleting != null && !entries.every(OrchardRecord.takenWhileDeleting)) {
      throw OrchardServerException(403, 'team-being-deleted', deleting: _deletionOf(o));
    }
    if (requireRecentSignIn && entries.any(_needsStepUp)) {
      throw const OrchardServerException(403, 'recent-sign-in-required');
    }
    // New kinds of record entry, as the server takes them:
    // refused until they are on, and the first in a team is an owner's.
    final firstNew = entries.where((e) => RecordTypes.newKinds.contains(e.type)).firstOrNull;
    if (firstNew != null) {
      if (!newRecordKinds) throw const OrchardServerException(409, 'feature-not-yet');
      if (!o.record.newKindsUsed && !o.record.isOwner(firstNew.by)) {
        throw const OrchardServerException(409, 'first-change-needs-owner');
      }
    }
    for (final e in entries) {
      final until = e.type == RecordTypes.accessGrant ? e.body['until'] : null;
      if (until is! int || until == 0) continue;
      if (until <= _now) throw const OrchardServerException(409, 'access-until-passed');
      if (until > _now + _maxAccessSeconds + _accessLeewaySeconds) {
        throw const OrchardServerException(409, 'access-too-long');
      }
    }
    // An owner sets the rules whatever they fall short of, but not from a
    // device nobody approved; and anyone may leave.
    final always = entries.every((e) =>
        (e.type == RecordTypes.rulesSet && !_deviceHeld(o)) ||
        (e.type == RecordTypes.memberRemove && e.body['uid'] == accountUid));
    if (_isHeld(accountUid) && !always) throw _heldError(accountUid);
    if (entries.any((e) => e.type == RecordTypes.rulesSet)) {
      final after = o.record.copy();
      var applied = true;
      for (final e in entries) {
        try {
          await after.append(e);
        } on RecordRejected {
          applied = false;
          break;
        }
      }
      // Nor rules the sender does not meet: the device counts as the record
      // stands after these entries.
      final key = namedDevices[accountSession];
      final unmet = [
        ...?unmetBySender?.call(after.rules),
        if (applied && after.rules.trustedDevices && !(key != null && after.devicesOf(accountUid).contains(key)))
          'trusted_device',
      ];
      if (unmet.isNotEmpty) throw OrchardServerException(409, 'rules-unmet-by-you', unmet: unmet);
    }
    await _apply(o, entries, copies, by: accountUid);
    return o.record.seq;
  }

  /// [by] appends [entries] with [copies], as that member's device would; the
  /// rules and the copies are checked as for anyone. With [checkCopies] off,
  /// the copies are not asked for (a test that is not about them).
  Future<void> appendAs(String by, String orchardId, List<RecordEntry> entries,
          {List<GrantCopy> copies = const [], bool checkCopies = true}) =>
      _apply(_orchard(orchardId), entries, copies, by: by, checkCopies: checkCopies);

  /// Checks [entries] against the record and the copies against what they
  /// give, then applies them. Throws what the server answers.
  Future<void> _apply(_Orchard o, List<RecordEntry> entries, List<GrantCopy> copies,
      {required String by, bool checkCopies = true}) async {
    _endTimedAccess(o);
    final after = o.record.copy();
    for (final e in entries) {
      try {
        await after.append(e);
      } on RecordRejected catch (x) {
        if (x.reason == 'out of order' || x.reason == 'does not follow the entry before') {
          throw const OrchardServerException(409, 'record-moved');
        }
        throw OrchardServerException(403, 'record-refused', reason: x.reason);
      }
    }
    final granted = entitlementsGained(o.record, after, nowSeconds: _now)
      ..removeWhere((uid, _) => deletedAccounts.contains(uid));
    if (checkCopies) {
      final want = <String>{
        for (final g in granted.entries)
          for (final scope in g.value)
            for (var i = 1; i <= after.generationOf(scope); i++) '${g.key}|$scope|$i',
      };
      await _checkCopies(o, after, want, [for (final c in copies) if (!deletedAccounts.contains(c.uid)) c], by: by);
    }
    // Taken away: the server's copies go, and the key waits for a new one.
    final had = o.record.entitlementsAt(_now);
    final has = after.entitlementsAt(_now);
    for (final e in had.entries) {
      for (final scope in e.value.difference(has[e.key] ?? const {})) {
        o.copies[e.key]?.remove(scope);
        if (scope == 'orchard') {
          o.rotationDue = true;
        } else {
          o.crates[scope]?.rotationDue = true;
        }
      }
    }
    for (final c in copies) {
      if (!(granted[c.uid]?.contains(c.crateId ?? 'orchard') ?? false)) continue;
      o.copies.putIfAbsent(c.uid, () => {}).putIfAbsent(c.crateId ?? 'orchard', () => {})[c.generation] =
          SealedSpaceKey(c.generation, c.sealed,
              recipientKeyVersion: after.members[c.uid]!.currentKeys.version,
              sealedBy: by,
              sealerKeyVersion: after.members[by]!.currentKeys.version,
              signature: c.signature);
    }
    // Approved devices: one whose approval was taken back is remembered
    // while its member stays, one approved (again) is not, and a request of a
    // device approved now, or of someone removed, is done with.
    for (final m in o.record.members.values) {
      for (final key in m.devices) {
        o.removedDevices.add('${m.uid}|$key');
      }
    }
    o.removedDevices.removeWhere((entry) {
      final at = entry.indexOf('|');
      final m = after.members[entry.substring(0, at)];
      return m == null || m.status == MemberStatus.removed || m.devices.contains(entry.substring(at + 1));
    });
    o.deviceRequests.removeWhere((_, r) {
      final m = after.members[r.uid];
      return m == null || m.status == MemberStatus.removed || m.devices.contains(namedDevices[r.session]);
    });
    o.entries.addAll(entries);
    o.record = after;
    o.membersTag = 'tag-${o.record.seq}-${verifications.length}';
    // A request an entry answers is done with: the one of the member it
    // gives to. And a request is only ever from an active member below admin.
    for (final e in entries) {
      final req = e.type == RecordTypes.accessGrant ? e.body['req'] : null;
      if (req is String && o.requests[req]?.uid == e.body['uid']) o.requests.remove(req);
    }
    o.requests.removeWhere((_, r) {
      final m = after.members[r.uid];
      return m == null || m.status != MemberStatus.active || m.role == FixedRoles.owner || m.role == FixedRoles.admin;
    });
    // What the team records: version history counts from when it was
    // last turned on; activity is kept only while it is on.
    if (after.tracking.history) {
      o.historySince ??= clock();
    } else {
      o.historySince = null;
    }
    if (!after.tracking.activity) activityRows.remove(o.id);
    // Session logs turned off: the Crate's logs go at once.
    for (final c in after.crates.values) {
      if (!c.sessionLogs) sessionLogRows.remove(c.id);
    }
  }

  /// Exactly the copies in [want] ("uid|scope|generation"), each
  /// sealed to its recipient's keys in [after] and signed by [by] with the
  /// keys the record holds for it. A rotation's refusal names [recipients].
  Future<void> _checkCopies(_Orchard o, OrchardRecord after, Set<String> want, List<GrantCopy> copies,
      {required String by, List<String>? recipients}) async {
    final seen = <String>{};
    final sealer = after.members[by]?.currentKeys;
    for (final c in copies) {
      final k = '${c.uid}|${c.crateId ?? 'orchard'}|${c.generation}';
      if (!want.contains(k) || !seen.add(k)) {
        throw OrchardServerException(409, 'copies-changed', recipients: recipients);
      }
      final recipient = after.members[c.uid]!.currentKeys;
      final ok = sealer != null &&
          await verifyKeyCopy(
            sealer.signingKey,
            KeyCopyPlace(
              orchardId: o.id,
              crateId: c.crateId,
              generation: c.generation,
              recipient: c.uid,
              recipientKeyVersion: recipient.version,
              sealer: by,
              sealerKeyVersion: sealer.version,
            ),
            c.sealed,
            c.signature,
          );
      if (!ok) throw const OrchardServerException(400, 'bad-signature');
    }
    if (seen.length != want.length) throw OrchardServerException(409, 'copies-changed', recipients: recipients);
  }

  // ── Team recovery ──

  /// Owners' approvals waiting: Orchard id -> member -> approving owner.
  final recoveryApprovals =
      <String, Map<String, Map<String, ({int keyVersion, int approverKeyVersion, Uint8List signature})>>>{};

  /// [uid] starts over with [keys] after losing the old ones, as POST
  /// /v1/keys/reset does: published without anything to vouch for them,
  /// every copy sealed to the old keys gone, and every approval that named
  /// the account (as the member or as the approving owner) with them.
  Future<void> resetKeys(String uid, AccountKeys keys) async {
    published[uid] = await keys.publish(uid);
    keyVersions[uid] = keys.version;
    for (final o in _orchards.values) {
      o.copies.remove(uid);
    }
    for (final byMember in recoveryApprovals.values) {
      byMember.remove(uid);
      for (final approvals in byMember.values) {
        approvals.remove(uid);
      }
    }
  }

  static bool _sameKeys(PublishedAccountKeys? a, RecordKeys b) =>
      a != null &&
      a.version == b.version &&
      base64Encode(a.signingKey) == base64Encode(b.signingKey) &&
      base64Encode(a.encryptionKey) == base64Encode(b.encryptionKey);

  /// What the server says about team recovery instead of the truth: a
  /// server that lies, for the checks devices make on their own.
  TeamRecoveryStatus? recoveryListing;

  @override
  Future<TeamRecoveryStatus> teamRecovery(String orchardId) async {
    final o = _orchard(orchardId);
    final r = o.record;
    if (!_counts(r, accountUid)) throw const OrchardServerException(404, 'not-found');
    final lie = recoveryListing;
    if (lie != null) return lie;
    final owner = r.isOwner(accountUid) && !_isHeld(accountUid);
    final waiting = <RecoveryWait>[];
    final uids = [for (final m in r.members.values) if (m.status != MemberStatus.removed) m.uid]..sort();
    for (final uid in uids) {
      if (!owner && uid != accountUid) continue;
      final keys = published[uid];
      final recorded = r.members[uid]!.currentKeys.version;
      if (keys == null || keys.version <= recorded) continue;
      final given = recoveryApprovals[orchardId]?[uid] ?? const {};
      final approvers = given.keys.toList()..sort();
      waiting.add(RecoveryWait(
        uid: uid,
        email: owner ? emails[uid] : null,
        keys: keys,
        recordKeyVersion: recorded,
        approvals: [
          for (final by in approvers)
            if (given[by]!.keyVersion == keys.version &&
                r.isOwner(by) &&
                r.members[by]!.currentKeys.version == given[by]!.approverKeyVersion)
              RecoveryApproval(
                  uid: by, keyVersion: given[by]!.approverKeyVersion, signature: owner ? given[by]!.signature : null),
        ],
      ));
    }
    return TeamRecoveryStatus(on: r.teamRecovery, owners: r.owners.length, waiting: waiting);
  }

  @override
  Future<void> approveRecovery(
    String orchardId, {
    required String subjectUid,
    required int keyVersion,
    required int approverKeyVersion,
    required Uint8List approval,
  }) async {
    final o = _orchard(orchardId);
    final r = o.record;
    if (!_counts(r, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (requireRecentSignIn) throw const OrchardServerException(403, 'recent-sign-in-required');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!r.teamRecovery) throw const OrchardServerException(409, 'team-recovery-off');
    if (!r.isOwner(accountUid)) throw const OrchardServerException(403, 'owners-only');
    if (subjectUid == accountUid) throw const OrchardServerException(409, 'not-for-yourself');
    final subject = r.members[subjectUid];
    if (subject == null || subject.status == MemberStatus.removed) {
      throw const OrchardServerException(404, 'not-found');
    }
    final keys = published[subjectUid];
    if (keys == null || keys.version != keyVersion || keyVersion <= subject.currentKeys.version) {
      throw const OrchardServerException(409, 'not-waiting');
    }
    final mine = r.members[accountUid]!.currentKeys;
    if (mine.version != approverKeyVersion) throw const OrchardServerException(409, 'stale-account-keys');
    final ok = await verifyTeamRecovery(
      mine.signingKey,
      approval,
      orchardId: orchardId,
      subjectUid: subjectUid,
      subjectKeyVersion: keyVersion,
      fingerprint: keys.fingerprint,
      approverUid: accountUid,
      approverKeyVersion: approverKeyVersion,
    );
    if (!ok) throw const OrchardServerException(400, 'bad-signature');
    recoveryApprovals.putIfAbsent(orchardId, () => {}).putIfAbsent(subjectUid, () => {})[accountUid] =
        (keyVersion: keyVersion, approverKeyVersion: approverKeyVersion, signature: approval);
  }

  @override
  Future<void> withdrawRecoveryApproval(String orchardId, String subjectUid) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    recoveryApprovals[orchardId]?[subjectUid]?.remove(accountUid);
  }

  /// Completed recoveries, as sent.
  final recoveries = <({String orchardId, RecordEntry entry, List<GrantCopy> copies})>[];

  /// Runs once as the next recovery arrives, before it is checked: lets
  /// another device get an entry in first.
  Future<void> Function()? beforeRecover;

  @override
  Future<void> completeRecovery(String orchardId, RecordEntry entry, {required List<GrantCopy> copies}) async {
    final first = beforeRecover;
    beforeRecover = null;
    if (first != null) await first();
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (entry.type != RecordTypes.memberRecover || entry.by != accountUid) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    if (requireRecentSignIn) throw const OrchardServerException(403, 'recent-sign-in-required');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    recoveries.add((orchardId: orchardId, entry: entry, copies: copies));
    final after = o.record.copy();
    try {
      await after.append(entry);
    } on RecordRejected catch (x) {
      if (x.reason == 'out of order' || x.reason == 'does not follow the entry before') {
        throw const OrchardServerException(409, 'record-moved');
      }
      throw OrchardServerException(403, 'record-refused', reason: x.reason);
    }
    final uid = entry.body['uid'] as String;
    if (!_sameKeys(published[uid], after.members[uid]!.currentKeys)) {
      throw const OrchardServerException(409, 'not-waiting');
    }
    final held = deletedAccounts.contains(uid) ? const <String>{} : after.entitlementsAt(_now)[uid] ?? const <String>{};
    await _checkCopies(o, after, {
      for (final scope in held)
        for (var g = 1; g <= after.generationOf(scope); g++) '$uid|$scope|$g',
    }, copies, by: accountUid);
    final sealer = after.members[accountUid]!.currentKeys.version;
    final recipient = after.members[uid]!.currentKeys.version;
    o.copies[uid] = {};
    for (final c in copies) {
      o.copies[uid]!.putIfAbsent(c.crateId ?? 'orchard', () => {})[c.generation] = SealedSpaceKey(c.generation, c.sealed,
          recipientKeyVersion: recipient, sealedBy: accountUid, sealerKeyVersion: sealer, signature: c.signature);
    }
    recoveryApprovals[orchardId]?.remove(uid);
    o.entries.add(entry);
    o.record = after;
    o.membersTag = 'tag-${o.record.seq}-${verifications.length}';
  }

  // ── Certificates ──

  /// Certificate requests by id: whose, in which Crate, and once signed the
  /// certificate and when it expires.
  final certRequests =
      <String, ({String crateId, String uid, CertRequest request, Uint8List? certificate, int? validBefore})>{};

  /// Requests the server lists to owners on top of the true ones, by Crate:
  /// a server that makes them up.
  final madeUpRequests = <String, List<CertRequest>>{};

  /// What the server hands back as this account's certificates instead of
  /// the truth.
  List<IssuedCertificate>? certificateListing;

  /// Every certificate handed back and taken.
  final certificatesSigned = <({String crateId, String requestId, Uint8List certificate, String by})>[];

  /// The request of every certificate handed back, taken or not.
  final signAttempts = <String>[];

  // ── Access on request ──

  /// Acts on what was given until a set time in [o] and has ended: where
  /// nothing else gives the member the Crate, their copies go and the
  /// Crate's key waits for a new one. Each end once.
  void _endTimedAccess(_Orchard o) {
    final now = _now;
    for (final m in o.record.members.values) {
      for (final t in m.timed.entries) {
        if (t.value.until > now || !o.endedAccess.add('${m.uid}|${t.key}|${t.value.until}')) continue;
        if (o.record.switchesOf(m.uid, t.key).isNotEmpty) continue;
        o.copies[m.uid]?.remove(t.key);
        o.crates[t.key]?.rotationDue = true;
      }
    }
  }

  /// The server's job for access that ended by itself, run now, in every
  /// Orchard.
  void runEndedAccessJob() => _orchards.values.forEach(_endTimedAccess);

  /// The requests for access waiting in [orchardId], as the server keeps
  /// them: who asks, for which Crate (null: one they cannot name).
  List<({String id, String uid, String? crateId})> requestsOf(String orchardId) => [
        for (final r in _orchard(orchardId).requests.values) (id: r.id, uid: r.uid, crateId: r.crateId),
      ];

  /// Changes one byte of the note of the request [requestId], as a server
  /// that tampered with it would: nobody opens it any more.
  void spoilRequestNote(String orchardId, String requestId) {
    final note = _orchard(orchardId).requests[requestId]!.noteEnc!;
    note[note.length - 1] ^= 1;
  }

  /// Every request for access made, refused ones too.
  var requestCalls = 0;
  var _requestId = 0;

  /// The Crates [uid] manages for good in [o] that someone could be given
  /// ([crateId] alone, when given).
  bool _answers(_Orchard o, String uid, String? crateId) =>
      _counts(o.record, uid) &&
      o.record.crates.values.any((c) =>
          (crateId == null || c.id == crateId) &&
          !c.ownersOnly &&
          o.record.switchesOf(uid, c.id).contains(CrateSwitches.manage));

  @override
  Future<AccessRequest> requestAccess(String orchardId,
      {String? crateId, required CrateLevel level, required int seconds, Uint8List? noteEnc, int? noteGeneration}) async {
    requestCalls++;
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (level == CrateLevel.manage ||
        seconds < 300 ||
        seconds > _maxAccessSeconds ||
        (noteEnc == null) != (noteGeneration == null) ||
        (noteEnc != null && (noteEnc.isEmpty || noteEnc.length > 1024)) ||
        (crateId == null && noteEnc == null)) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    final role = o.record.members[accountUid]!.role;
    if (role == FixedRoles.owner || role == FixedRoles.admin) {
      throw const OrchardServerException(409, 'access-not-needed');
    }
    if (crateId != null && (o.record.crates[crateId]?.ownersOnly ?? true)) {
      throw const OrchardServerException(404, 'not-found');
    }
    final open = [
      for (final r in o.requests.values)
        if (r.uid == accountUid && r.expiresAt > _now) r,
    ];
    final same = open.where((r) => r.crateId == crateId).firstOrNull;
    if (same == null && open.length >= 5) throw const OrchardServerException(409, 'request-limit');
    o.requests.removeWhere((_, r) => r.uid == accountUid && (r.id == same?.id || r.expiresAt <= _now));
    final made = _AccessRequest(
      id: same?.id ?? '00000000-0000-4000-8000-${(++_requestId).toString().padLeft(12, '0')}',
      uid: accountUid,
      crateId: crateId,
      level: level,
      seconds: seconds,
      noteEnc: noteEnc,
      noteGeneration: noteGeneration,
      expiresAt: _now + 7 * 24 * 60 * 60,
    );
    o.requests[made.id] = made;
    return made.listed();
  }

  /// Every time the requests were listed, and a listing that fails as a
  /// dropped connection would.
  var accessListCalls = 0;
  bool failAccessRequests = false;

  @override
  Future<AccessRequests> accessRequests(String orchardId) async {
    accessListCalls++;
    if (failAccessRequests) throw const OrchardServerException(503, null);
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    final lie = accessRequestListing;
    if (lie != null) return lie;
    final live = [
      for (final r in o.requests.values)
        if (r.expiresAt > _now) r,
    ];
    return (
      mine: [
        for (final r in live)
          if (r.uid == accountUid) r.listed(),
      ],
      waiting: [
        for (final r in live)
          if (r.uid != accountUid && _counts(o.record, r.uid) && _answers(o, accountUid, r.crateId)) r.listed(asked: true),
      ],
    );
  }

  /// Answers [accessRequests] with this instead: a server that lists
  /// requests this account has no say over.
  AccessRequests? accessRequestListing;

  @override
  Future<void> deleteAccessRequest(String orchardId, String requestId) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    final r = o.requests[requestId];
    if (r == null || (r.uid != accountUid && !_answers(o, accountUid, r.crateId))) {
      throw const OrchardServerException(404, 'not-found');
    }
    o.requests.remove(requestId);
  }

  _Orchard _orchardOfCrate(String crateId) => _acting = _orchards.values.firstWhere(
        (o) => o.record.crates.containsKey(crateId),
        orElse: () => throw const OrchardServerException(404, 'not-found'),
      );

  // ── Trusted devices ──

  /// How often a device asked which sign-in it is.
  var sessionAsks = 0;

  @override
  Future<String?> currentSession() async {
    sessionAsks++;
    return accountSession;
  }

  /// The calls about devices named here do not get through, as when ZestSSH
  /// Cloud cannot be reached: 'name', 'list', 'answer', 'drop'.
  final failDeviceCalls = <String>{};

  void _deviceCall(String what) {
    if (failDeviceCalls.contains(what)) throw const OrchardServerException(503, null);
  }

  /// How often a sign-in said which device it is, refused ones too.
  var nameDeviceCalls = 0;

  @override
  Future<bool> nameDevice({required Uint8List deviceKey, required Uint8List signature}) async {
    nameDeviceCalls++;
    _deviceCall('name');
    final session = accountSession;
    if (session == null) return false;
    if (deviceKey.length != 32 || signature.length != 64) throw const OrchardServerException(400, 'invalid-device');
    if (!await verifyDeviceSignature(deviceKey, sessionDeviceMessage(session), signature)) {
      throw const OrchardServerException(400, 'bad-signature');
    }
    // Only for an account that is in an Orchard: nothing is kept otherwise.
    if (!_orchards.values.any((o) => o.record.members.containsKey(accountUid))) return false;
    final key = deviceKeyText(deviceKey);
    final named = namedDevices[session];
    if (named != null && named != key) throw const OrchardServerException(409, 'device-key-set');
    namedDevices[session] = key;
    return true;
  }

  /// The Orchard [orchardId] for the routes a device that is not approved
  /// must reach: refused as everywhere unless only its device holds it back.
  _Orchard _forDevices(String orchardId) {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (_unmet(accountUid, o).any((u) => u != 'trusted_device')) throw _heldError(accountUid);
    return o;
  }

  /// Whether the account this server answers may approve a device of [uid]:
  /// their own, an owner anyone's, an admin those below admin.
  bool _mayApprove(OrchardRecord r, String uid) {
    final role = r.members[accountUid]?.role;
    final theirs = r.members[uid]?.role;
    return uid == accountUid ||
        role == FixedRoles.owner ||
        (role == FixedRoles.admin && theirs != FixedRoles.owner && theirs != FixedRoles.admin);
  }

  /// The device requests waiting in [orchardId], as the server keeps them:
  /// whose device asks, from which sign-in, where it stands, what the
  /// device committed to, what it was answered with and what it showed.
  List<
      ({
        String id,
        String uid,
        String session,
        String stage,
        Uint8List commitment,
        Uint8List? responderNonce,
        Uint8List? deviceKey,
        Uint8List? nonce,
      })> deviceRequestsOf(String orchardId) => [
        for (final r in _orchard(orchardId).deviceRequests.values)
          (
            id: r.id,
            uid: r.uid,
            session: r.session,
            stage: r.stage,
            commitment: r.commitment,
            responderNonce: r.responderNonce,
            deviceKey: r.deviceKey,
            nonce: r.nonce,
          ),
      ];

  /// Lets every device request in [orchardId] lapse, as ten minutes do.
  void lapseDeviceRequests(String orchardId) {
    for (final r in _orchard(orchardId).deviceRequests.values) {
      r.expiresAt = _now - 1;
    }
  }

  /// Changes what the server passes along for the device request
  /// [requestId], as someone in between the two devices would: whose device
  /// asks, what the asking device committed to, the answer, or what it
  /// showed.
  void spoilDeviceRequest(String orchardId, String requestId,
      {String? uid, Uint8List? commitment, Uint8List? responderNonce, Uint8List? deviceKey, Uint8List? nonce}) {
    final r = _orchard(orchardId).deviceRequests[requestId]!;
    if (uid != null) r.uid = uid;
    if (commitment != null) r.commitment = commitment;
    if (responderNonce != null) r.responderNonce = responderNonce;
    if (deviceKey != null) r.deviceKey = deviceKey;
    if (nonce != null) r.nonce = nonce;
  }

  /// A server that lists every waiting device request to every device,
  /// approved or not, whoever may approve it and whoever answered it.
  var listsDeviceRequestsToAll = false;

  /// How often the lists of device requests were read, and how often a
  /// request was taken back or declined.
  var deviceLists = 0;
  var deviceDrops = 0;

  var _deviceRequestId = 0;

  @override
  Future<DeviceTrustRequests> deviceRequests(String orchardId) async {
    deviceLists++;
    _deviceCall('list');
    final o = _forDevices(orchardId);
    final open = [
      for (final r in o.deviceRequests.values)
        if (r.expiresAt > _now) r,
    ];
    return (
      mine: [
        for (final r in open)
          if (r.uid == accountUid && r.session == accountSession) r.listed(mine: true),
      ],
      // Only a device that is approved itself approves another; and a
      // request someone answered is theirs to finish, on that device.
      waiting: [
        if (_deviceApproved(o) || listsDeviceRequestsToAll)
          for (final r in open)
            if ((_mayApprove(o.record, r.uid) || listsDeviceRequestsToAll) &&
                (r.stage == 'created' ||
                    listsDeviceRequestsToAll ||
                    (r.responder == accountUid && r.responderSession == accountSession)))
              r.listed(mine: false),
      ],
    );
  }

  @override
  Future<String> askDeviceTrust(String orchardId, Uint8List commitment) async {
    final o = _forDevices(orchardId);
    if (commitment.length != 32) throw const OrchardServerException(400, 'invalid-request');
    final session = accountSession;
    if (session == null || !namedDevices.containsKey(session)) throw const OrchardServerException(409, 'device-not-named');
    if (_deviceApproved(o)) throw const OrchardServerException(409, 'device-approved');
    o.deviceRequests.removeWhere((_, r) => r.session == session || r.expiresAt <= _now);
    final made = _DeviceRequest(
      id: '00000000-0000-4000-9000-${(++_deviceRequestId).toString().padLeft(12, '0')}',
      uid: accountUid,
      session: session,
      commitment: commitment,
      expiresAt: _now + 600,
    );
    o.deviceRequests[made.id] = made;
    return made.id;
  }

  @override
  Future<void> answerDeviceTrust(String orchardId, String requestId, Uint8List nonce) async {
    _deviceCall('answer');
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (nonce.length != 32) throw const OrchardServerException(400, 'invalid-request');
    if (!_deviceApproved(o)) throw const OrchardServerException(409, 'device-not-approved');
    final r = o.deviceRequests[requestId];
    if (r == null || r.expiresAt <= _now || !_mayApprove(o.record, r.uid)) {
      throw const OrchardServerException(404, 'not-found');
    }
    if (r.stage != 'created') throw const OrchardServerException(409, 'answered');
    r
      ..stage = 'responded'
      ..responder = accountUid
      ..responderSession = accountSession
      ..responderNonce = nonce;
  }

  @override
  Future<void> showDeviceTrust(String orchardId, String requestId,
      {required Uint8List deviceKey, required Uint8List nonce}) async {
    final o = _forDevices(orchardId);
    if (deviceKey.length != 32 || nonce.length != 32) throw const OrchardServerException(400, 'invalid-request');
    final r = o.deviceRequests[requestId];
    if (r == null || r.uid != accountUid || r.session != accountSession || r.expiresAt <= _now) {
      throw const OrchardServerException(404, 'not-found');
    }
    if (r.stage != 'responded') throw const OrchardServerException(409, 'not-answered');
    // What it shows is what it committed to, and the key this sign-in named.
    final key = deviceKeyText(deviceKey);
    if (base64Encode(deviceTrustCommitment(deviceKey, nonce)) != base64Encode(r.commitment) ||
        key != namedDevices[accountSession]) {
      o.deviceRequests.remove(requestId);
      throw const OrchardServerException(409, 'reveal-mismatch');
    }
    r
      ..stage = 'revealed'
      ..deviceKey = deviceKey
      ..nonce = nonce;
  }

  @override
  Future<void> dropDeviceTrust(String orchardId, String requestId) async {
    deviceDrops++;
    _deviceCall('drop');
    final o = _forDevices(orchardId);
    final r = o.deviceRequests[requestId];
    // Their own, from any of their devices; someone else's only from an
    // approved device of someone who may approve it.
    final may = r != null && (r.uid == accountUid || (_deviceApproved(o) && _mayApprove(o.record, r.uid)));
    if (!may) throw const OrchardServerException(404, 'not-found');
    o.deviceRequests.remove(requestId);
  }

  /// [uid] can open [crateId] now.
  bool _canOpen(OrchardRecord r, String uid, String crateId) =>
      _counts(r, uid) && (r.entitlementsAt(_now)[uid]?.contains(crateId) ?? false);

  @override
  Future<void> askCertificate(String crateId, CertRequest request) async {
    final o = _orchardOfCrate(crateId);
    final r = o.record;
    if (!_canOpen(r, accountUid, crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    final ca = r.crates[crateId]!.ca;
    if (ca == null || !ca.on) throw const OrchardServerException(409, 'no-authority');
    if ((request.requestedAt - _now).abs() > kCertRequestWindowSeconds) throw const OrchardServerException(409, 'clock');
    final me = r.members[accountUid]!;
    if (me.currentKeys.version != request.keyVersion) throw const OrchardServerException(409, 'stale-account-keys');
    if ((ca.principals[me.role] ?? const []).isEmpty) throw const OrchardServerException(409, 'no-principals');
    final device = request.deviceKey;
    final deviceSignature = request.deviceSignature;
    if ((device == null) != (deviceSignature == null)) throw const OrchardServerException(400, 'invalid-request');
    final asked = CertRequest(
      id: request.id,
      uid: accountUid,
      keyVersion: request.keyVersion,
      sshPublicKey: request.sshPublicKey,
      requestedAt: request.requestedAt,
      signature: request.signature,
      deviceKey: device,
      deviceSignature: deviceSignature,
    );
    if (!await verifyCertRequest(me.currentKeys.signingKey, asked, orchardId: o.id, crateId: crateId)) {
      throw const OrchardServerException(400, 'bad-signature');
    }
    // Signed by the device it names; and where only approved devices get in,
    // that device is one the record lists for this member.
    if (device != null &&
        !await verifyDeviceSignature(
            device, certDeviceMessage(asked.message(orchardId: o.id, crateId: crateId)), deviceSignature!)) {
      throw const OrchardServerException(400, 'bad-signature');
    }
    if (r.rules.trustedDevices && !(device != null && r.devicesOf(accountUid).contains(deviceKeyText(device)))) {
      throw const OrchardServerException(409, 'device-not-approved');
    }
    final known = certRequests[request.id];
    if (known != null) {
      if (known.crateId != crateId || known.uid != accountUid) throw const OrchardServerException(409, 'id-taken');
      return;
    }
    final open = certRequests.values.where((q) => q.crateId == crateId && q.uid == accountUid && q.certificate == null);
    if (open.length >= 5) throw const OrchardServerException(429, 'rate-limited');
    certRequests[request.id] = (crateId: crateId, uid: accountUid, request: asked, certificate: null, validBefore: null);
  }

  @override
  Future<List<CertRequest>> waitingCertificates(String crateId) async {
    final r = _orchardOfCrate(crateId).record;
    if (!_canOpen(r, accountUid, crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!r.isOwner(accountUid)) throw const OrchardServerException(403, 'owners-only');
    return [
      for (final q in certRequests.values)
        if (q.crateId == crateId && q.certificate == null && q.request.requestedAt >= _now - 86400) q.request,
      ...?madeUpRequests[crateId],
    ];
  }

  @override
  Future<void> signCertificate(String crateId, String requestId, Uint8List certificate) async {
    signAttempts.add(requestId);
    final r = _orchardOfCrate(crateId).record;
    if (!_canOpen(r, accountUid, crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!r.isOwner(accountUid)) throw const OrchardServerException(403, 'owners-only');
    final ca = r.crates[crateId]!.ca;
    if (ca == null || !ca.on) throw const OrchardServerException(409, 'no-authority');
    final q = certRequests[requestId];
    if (q == null || q.crateId != crateId) throw const OrchardServerException(404, 'not-found');
    if (q.certificate != null) throw const OrchardServerException(409, 'already-signed');
    final cert = await readTeamCertificate(certificate, caPublicKey: ca.publicKey, subject: q.request.sshPublicKey);
    const slack = 600;
    final now = _now;
    if (cert == null ||
        cert.validAfter < now - slack ||
        cert.validAfter > now + slack ||
        cert.validBefore <= now ||
        cert.validBefore - cert.validAfter > ca.ttlMinutes * 60 + slack) {
      throw const OrchardServerException(400, 'bad-certificate');
    }
    final member = r.members[q.uid];
    final allowed = member != null && _canOpen(r, q.uid, crateId) ? ca.principals[member.role] ?? const [] : const [];
    if (cert.principals.isEmpty || !cert.principals.every(allowed.contains)) {
      throw const OrchardServerException(400, 'bad-certificate');
    }
    // No longer than the access it rests on lasts by itself.
    final accessEnds = r.accessEndsAt(q.uid, crateId, now, of: CrateSwitches.inCertificate);
    if (accessEnds != null && cert.validBefore > accessEnds) {
      throw const OrchardServerException(400, 'bad-certificate');
    }
    // Where only approved devices get in: for a device the record lists
    // for the requester now, not one removed since it asked.
    final askedFrom = q.request.deviceKey;
    if (r.rules.trustedDevices && !(askedFrom != null && r.devicesOf(q.uid).contains(deviceKeyText(askedFrom)))) {
      throw const OrchardServerException(400, 'bad-certificate');
    }
    certificatesSigned.add((crateId: crateId, requestId: requestId, certificate: certificate, by: accountUid));
    certRequests[requestId] =
        (crateId: crateId, uid: q.uid, request: q.request, certificate: certificate, validBefore: cert.validBefore);
  }

  @override
  Future<List<IssuedCertificate>> myCertificates(String crateId) async {
    final r = _orchardOfCrate(crateId).record;
    if (!_canOpen(r, accountUid, crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    final lie = certificateListing;
    if (lie != null) return lie;
    final out = [
      for (final q in certRequests.values)
        if (q.crateId == crateId && q.uid == accountUid && q.certificate != null && q.validBefore! > _now)
          IssuedCertificate(
            requestId: q.request.id,
            sshPublicKey: q.request.sshPublicKey,
            certificate: q.certificate!,
            validBefore: q.validBefore!,
          ),
    ]..sort((a, b) => b.validBefore.compareTo(a.validBefore));
    return out;
  }

  @override
  Future<void> createOrchard(NewOrchard orchard) async {
    final known = _orchards[orchard.id];
    if (known != null) {
      if (known.record.isOwner(accountUid)) return; // a retry
      throw const OrchardServerException(409, 'id-taken');
    }
    if (orchard.record.type != RecordTypes.create || orchard.record.by != accountUid) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    final o = _Orchard(orchard.id)..nameEnc = orchard.nameEnc;
    try {
      await o.record.append(orchard.record);
    } on RecordRejected catch (x) {
      throw OrchardServerException(403, 'record-refused', reason: x.reason);
    }
    final mine = published[accountUid];
    final owner = o.record.members[accountUid]!.currentKeys;
    if (mine != null &&
        (owner.version != mine.version ||
            base64Encode(owner.signingKey) != base64Encode(mine.signingKey) ||
            base64Encode(owner.encryptionKey) != base64Encode(mine.encryptionKey))) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    if (!o.record.crates.containsKey(orchard.firstCrate.id)) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    o.entries.add(orchard.record);
    o.crates[orchard.firstCrate.id] = _Crate(orchard.firstCrate.id)..nameEnc = orchard.firstCrate.nameEnc;
    SealedSpaceKey own(Uint8List sealed, Uint8List signature) => SealedSpaceKey(1, sealed,
        recipientKeyVersion: owner.version, sealedBy: accountUid, sealerKeyVersion: owner.version, signature: signature);
    o.copies[accountUid] = {
      'orchard': {1: own(orchard.keySealed, orchard.keySignature)},
      orchard.firstCrate.id: {1: own(orchard.firstCrate.keySealed, orchard.firstCrate.keySignature)},
    };
    o.membersTag = 'tag-1-0';
    _orchards[o.id] = o;
    crateGenerations[orchard.firstCrate.id] = 1;
    items[orchard.firstCrate.id] = {};
  }

  @override
  Future<void> createCrate(String orchardId, NewCrate crate) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (crate.entry.type != RecordTypes.crateAdd || crate.entry.by != accountUid) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    if (o.crates.containsKey(crate.id)) {
      if (o.record.switchesOf(accountUid, crate.id).isNotEmpty) return; // a retry
      throw const OrchardServerException(409, 'id-taken');
    }
    final probe = o.record.copy();
    try {
      await probe.append(crate.entry);
    } catch (_) {/* answered below, as the route answers it */}
    if (!probe.crates.containsKey(crate.id) && probe.seq > o.record.seq) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    await _apply(o, [crate.entry], crate.copies, by: accountUid);
    o.crates[crate.id] = _Crate(crate.id)..nameEnc = crate.nameEnc;
    crateGenerations[crate.id] = 1;
    items[crate.id] = {};
  }

  /// Places renamed (`crate:<id>`, `orchard:<id>`), in order.
  final renames = <String>[];

  @override
  Future<void> renameCrate(String crateId, Uint8List nameEnc, {required int generation}) async {
    for (final o in _orchards.values) {
      final c = o.crates[crateId];
      if (c == null) continue;
      if (!_counts(o.record, accountUid) || o.record.switchesOf(accountUid, crateId).isEmpty) {
        throw const OrchardServerException(404, 'not-found');
      }
      if (!o.record.switchesOf(accountUid, crateId).contains(CrateSwitches.manage)) {
        throw const OrchardServerException(403, 'forbidden');
      }
      if (generation != c.generation) throw const OrchardServerException(409, 'generation-moved');
      c.nameEnc = nameEnc;
      renames.add('crate:$crateId');
      return;
    }
    throw const OrchardServerException(404, 'not-found');
  }

  @override
  Future<void> renameOrchard(String orchardId, Uint8List nameEnc, {required int generation}) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    final role = o.record.members[accountUid]!.role;
    if (role != FixedRoles.owner && role != FixedRoles.admin) throw const OrchardServerException(403, 'forbidden');
    if (generation != o.generation) throw const OrchardServerException(409, 'generation-moved');
    o.nameEnc = nameEnc;
    renames.add('orchard:$orchardId');
  }

  /// A Crate outside any Orchard this server holds, for tests of the sync
  /// engine alone: this account may do anything in it.
  void addCrate(String crateId, {int generation = 1}) {
    crateGenerations[crateId] = generation;
    items[crateId] = {};
  }

  /// This account loses a Crate outside the record's say (a Crate the server
  /// stops listing): its items go too.
  void dropCrate(String orchardId, String crateId) {
    final o = _orchard(orchardId);
    o.copies[accountUid]?.remove(crateId);
    o.crates.remove(crateId);
    items.remove(crateId);
  }

  // ── Rotations ──

  @override
  Future<int> rotateKey(String orchardId, RecordEntry entry,
      {required Uint8List nameEnc, required List<GrantCopy> copies}) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (entry.type != RecordTypes.keyRotate || entry.by != accountUid) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    rotationRequests.add([for (final c in copies) c.uid]..sort());
    final first = beforeRotate;
    if (first != null) {
      beforeRotate = null;
      final uid = accountUid;
      await first();
      accountUid = uid;
    }
    return _rotate(o, entry, nameEnc, copies, by: accountUid);
  }

  /// [by] makes a new key generation with [entry], as that member's device
  /// would; the rules and the copies are checked as for anyone.
  Future<int> rotateAs(String by, String orchardId, RecordEntry entry,
          {required Uint8List nameEnc, required List<GrantCopy> copies}) =>
      _rotate(_orchard(orchardId), entry, nameEnc, copies, by: by);

  /// The rotation route: the key.rotate entry checked by the record's rules,
  /// then a copy of the new key for exactly everyone who holds it now (end
  /// dates counted, deleted accounts aside), signed by [by]; then the new
  /// generation, the name under it, and the copies, all together.
  Future<int> _rotate(_Orchard o, RecordEntry entry, Uint8List nameEnc, List<GrantCopy> copies,
      {required String by}) async {
    final crateId = entry.body['crate'] is String ? entry.body['crate'] as String : null;
    final place = crateId == null ? 'orchard:${o.id}' : 'crate:$crateId';
    _failOnce(place);
    _endTimedAccess(o);
    final after = o.record.copy();
    try {
      await after.append(entry);
    } on RecordRejected catch (x) {
      if (x.reason == 'out of order' || x.reason == 'does not follow the entry before') {
        throw const OrchardServerException(409, 'record-moved');
      }
      throw OrchardServerException(403, 'record-refused', reason: x.reason);
    }
    final scope = crateId ?? kOrchardScope;
    final generation = after.generationOf(scope);
    final to = after.holdersAt(scope, _now, skip: deletedAccounts);
    await _checkCopies(o, after, {for (final uid in to) '$uid|$scope|$generation'},
        [for (final c in copies) if (!deletedAccounts.contains(c.uid)) c],
        by: by, recipients: to);
    o.entries.add(entry);
    o.record = after;
    if (crateId == null) {
      o
        ..generation = generation
        ..nameEnc = nameEnc
        ..rotationDue = false;
    } else {
      o.crates[crateId]!
        ..generation = generation
        ..nameEnc = nameEnc
        ..rotationDue = false;
      crateGenerations[crateId] = generation;
    }
    for (final c in copies) {
      if (!to.contains(c.uid)) continue;
      o.copies.putIfAbsent(c.uid, () => {}).putIfAbsent(scope, () => {})[generation] = SealedSpaceKey(
          generation, c.sealed,
          recipientKeyVersion: after.members[c.uid]!.currentKeys.version,
          sealedBy: by,
          sealerKeyVersion: after.members[by]!.currentKeys.version,
          signature: c.signature);
    }
    o.membersTag = 'tag-${o.record.seq}-${verifications.length}';
    rotations.add(place);
    return generation;
  }

  void _failOnce(String place) {
    if (failRotationOnce.remove(place)) throw const OrchardServerException(503, null);
  }

  /// A key replacement (routes/keys.js PUT): every copy the account holds
  /// replaced by one re-sealed to [version], and a member.keys entry for
  /// each Orchard the account is in, all or none.
  Future<void> replaceOwnCopies(int version, List<ResealedKeyCopy> copies,
      {Map<String, Map<String, dynamic>> records = const {}}) async {
    String place(String orchardId, String? crateId, int generation) => '${crateId ?? orchardId}:$generation';
    final held = <String>{
      for (final o in _orchards.values)
        for (final scope in (o.copies[accountUid] ?? const <String, Map<int, SealedSpaceKey>>{}).entries)
          for (final g in scope.value.keys) place(o.id, scope.key == 'orchard' ? null : scope.key, g),
    };
    final sent = {for (final c in copies) place(c.orchardId, c.crateId, c.generation)};
    if (sent.length != copies.length || sent.length != held.length || !held.containsAll(sent)) {
      throw const AccountKeysReplaceConflict('copies-changed');
    }
    final inOrchards = [
      for (final o in _orchards.values)
        if (o.record.members[accountUid] != null && o.record.members[accountUid]!.status != MemberStatus.removed) o,
    ];
    if (records.length != inOrchards.length || !inOrchards.every((o) => records.containsKey(o.id))) {
      throw AccountKeysRecordsNeeded({
        for (final o in inOrchards)
          if (!records.containsKey(o.id)) o.id: (seq: o.record.seq, hash: o.record.head),
      });
    }
    final next = <_Orchard, OrchardRecord>{};
    for (final o in inOrchards) {
      final probe = o.record.copy();
      try {
        await probe.append(RecordEntry.fromJson(records[o.id]!));
      } on RecordRejected catch (x) {
        if (x.reason == 'out of order' || x.reason == 'does not follow the entry before') {
          throw const AccountKeysReplaceConflict('record-moved');
        }
        throw StateError('record refused: ${x.reason}');
      }
      next[o] = probe;
    }
    for (final e in next.entries) {
      e.key.entries.add(RecordEntry.fromJson(records[e.key.id]!));
      e.key.record = e.value;
      e.key.membersTag = 'tag-${e.value.seq}-${verifications.length}';
    }
    for (final o in _orchards.values) {
      final mine = o.copies[accountUid];
      if (mine == null) continue;
      for (final scope in mine.entries) {
        for (final g in scope.value.keys.toList()) {
          final c = copies.firstWhere((c) =>
              c.orchardId == o.id && c.crateId == (scope.key == 'orchard' ? null : scope.key) && c.generation == g);
          scope.value[g] = SealedSpaceKey(g, c.sealed,
              recipientKeyVersion: version, sealedBy: accountUid, sealerKeyVersion: version, signature: c.signature);
        }
      }
    }
    accountKeyVersion = version;
  }

  // ── Members ──

  @override
  Future<MemberList> members(String orchardId) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    memberReads.add(orchardId);
    return MemberList([
      for (final m in o.record.members.values)
        if (m.status != MemberStatus.removed && !deletedAccounts.contains(m.uid))
          MemberListing(
            uid: m.uid,
            role: m.role,
            status: m.status.name,
            endsAt: m.endsAt,
            email: emails[m.uid],
            name: names[m.uid],
            picture: pictures[m.uid],
            keys: published[m.uid],
            checks: [
              for (final v in verifications)
                if (v.orchardId == orchardId && v.subjectUid == m.uid)
                  MemberCheck(by: v.by, byKeyVersion: v.keyVersion, keyVersion: v.subjectKeyVersion, signature: v.signature),
            ],
          ),
    ], deleted: {
      for (final m in o.record.members.values)
        if (m.status != MemberStatus.removed && deletedAccounts.contains(m.uid)) m.uid,
    });
  }

  @override
  Future<void> verifyMember(
    String orchardId, {
    required String subjectUid,
    required int subjectKeyVersion,
    required int keyVersion,
    required Uint8List signature,
  }) async {
    final o = _orchard(orchardId);
    verifications.add((
      orchardId: orchardId,
      by: accountUid,
      subjectUid: subjectUid,
      subjectKeyVersion: subjectKeyVersion,
      keyVersion: keyVersion,
      signature: signature,
    ));
    o.membersTag = 'tag-${o.record.seq}-${verifications.length}';
  }

  /// A check signed on another device (or by another member), as the
  /// server would list it.
  void addVerification(String orchardId,
      {required String by, required String subjectUid, required int subjectKeyVersion, required int keyVersion,
      required Uint8List signature}) {
    final o = _orchard(orchardId);
    verifications.add((
      orchardId: orchardId,
      by: by,
      subjectUid: subjectUid,
      subjectKeyVersion: subjectKeyVersion,
      keyVersion: keyVersion,
      signature: signature,
    ));
    o.membersTag = 'tag-${o.record.seq}-${verifications.length}';
  }

  // ── Invitations ──

  final sentInvites = <({String orchardId, String email, String role, Map<String, Set<String>> grants, int? endsAt})>[];
  final withdrawn = <String>[];
  final confirmations =
      <({String orchardId, String inviteId, RecordEntry entry, List<GrantCopy> copies, RecordEntry? device})>[];

  /// The next confirmation is refused once with this code, as when a key
  /// moved on between the device's refresh and its request.
  String? failConfirmOnce;

  /// Reading the invitations fails while set, as offline.
  bool failInvites = false;
  final accepted = <String>[];
  final declined = <String>[];

  @override
  Future<InviteSent> invite(
    String orchardId, {
    required String email,
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
    bool sendEmail = true,
    bool resend = false,
  }) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (!o.record.can(accountUid, RoleCan.invite)) throw const OrchardServerException(403, 'forbidden');
    sentInvites.add((orchardId: orchardId, email: email, role: role, grants: grants, endsAt: endsAt));
    if (resend) resent.add(email);
    final existing = o.invites.values.where((i) => i.email == email && i.code == null).firstOrNull;
    final id = existing?.id ?? 'invite-${sentInvites.length}';
    o.invites[id] = _Invite(id, email, role, {for (final g in grants.entries) g.key: {...g.value}}, endsAt,
        invitedBy: emails[accountUid], acceptedBy: existing?.acceptedBy);
    return InviteSent(id, emailed: sendEmail && (existing == null || resend));
  }

  /// The addresses an invitation was sent to again ("Resend").
  final resent = <String>[];

  // ── Invite codes ──

  /// What was saved of each invite code, as the server keeps it.
  final savedCodes = <({String orchardId, String inviteId, String lookupId, int expiresIn, String? replaces})>[];

  /// The next invite code is refused with this error once.
  OrchardServerException? failCodeOnce;

  @override
  Future<InviteCodeSaved> saveInviteCode(
    String orchardId, {
    required String inviteId,
    required String lookupId,
    required Uint8List ownerTag,
    required int makerKeyVersion,
    required Uint8List codeSealed,
    required Uint8List offerSealed,
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
    required int expiresIn,
    String? replacesInvite,
    int usesMax = 1,
  }) async {
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (!o.record.can(accountUid, RoleCan.invite)) throw const OrchardServerException(403, 'forbidden');
    final fail = failCodeOnce;
    if (fail != null) {
      failCodeOnce = null;
      throw fail;
    }
    if (published[accountUid]?.version != makerKeyVersion) {
      throw const OrchardServerException(409, 'stale-account-keys');
    }
    savedCodes.add((
      orchardId: orchardId,
      inviteId: inviteId,
      lookupId: lookupId,
      expiresIn: expiresIn,
      replaces: replacesInvite,
    ));
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    o.invites[inviteId] = _Invite(inviteId, '', role, {for (final g in grants.entries) g.key: {...g.value}}, endsAt,
        invitedBy: emails[accountUid])
      ..code = _Code(lookupId, ownerTag, accountUid, makerKeyVersion, codeSealed, offerSealed)
      ..expiresAt = expiresAt
      ..replaces = replacesInvite;
    return InviteCodeSaved(inviteId: inviteId, expiresAt: expiresAt);
  }

  @override
  Future<DateTime> changeInviteCodeExpiry(String orchardId, String inviteId, int expiresIn) async {
    final i = _orchard(orchardId).invites[inviteId];
    if (i == null || i.code == null || i.acceptedBy != null) throw const OrchardServerException(404, 'not-found');
    i.expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    return i.expiresAt!;
  }

  ({String orchardId, _Invite invite})? _liveCode(String lookupId) {
    for (final o in _orchards.entries) {
      for (final i in o.value.invites.values) {
        final c = i.code;
        if (c != null &&
            c.lookupId == lookupId &&
            i.acceptedBy == null &&
            !i.expired &&
            published[c.makerUid]?.version == c.makerKeyVersion) {
          return (orchardId: o.key, invite: i);
        }
      }
    }
    return null;
  }

  /// How many times a code was looked up.
  var codeLookups = 0;

  @override
  Future<InviteCodeOffer> inviteCodeOffer(String lookupId) async {
    codeLookups++;
    final found = _liveCode(lookupId);
    if (found == null) throw const OrchardServerException(404, 'join-code-invalid');
    final i = found.invite;
    return InviteCodeOffer(
      invite: MyInvite(
        id: i.id,
        orchardId: found.orchardId,
        role: i.role,
        crates: i.grants.length,
        expiresAt: i.expiresAt ?? DateTime.now().add(const Duration(days: 7)),
        accepted: false,
        invitedBy: i.invitedBy,
        endsAt: i.endsAt,
      ),
      grants: i.grants,
      makerKeys: published[i.code!.makerUid]!,
      ownerTag: i.code!.ownerTag,
      offerSealed: i.code!.offerSealed,
    );
  }

  @override
  Future<String> acceptInviteCode(String lookupId,
      {required int keyVersion, required Uint8List joinerTag, JoinDevice? device}) async {
    final mineKeys = published[accountUid];
    if (mineKeys == null) throw const OrchardServerException(409, 'no-keys');
    if (mineKeys.version != keyVersion) throw const OrchardServerException(409, 'stale-account-keys');
    final found = _liveCode(lookupId);
    if (found == null) throw const OrchardServerException(404, 'join-code-invalid');
    final i = found.invite
      ..acceptedBy = accountUid
      ..device = _offeredDevice(device);
    i.code!
      ..joinerTag = joinerTag
      ..usedAt = DateTime.now();
    final replaced = i.replaces;
    if (replaced != null) _orchard(found.orchardId).invites.remove(replaced);
    mine.add(MyInvite(
      id: i.id,
      orchardId: found.orchardId,
      role: i.role,
      crates: i.grants.length,
      expiresAt: i.expiresAt ?? DateTime.now(),
      accepted: true,
      invitedBy: i.invitedBy,
      endsAt: i.endsAt,
      byCode: true,
    ));
    return i.id;
  }

  /// Sets when [inviteId]'s code was used (pictures that say "4 min ago").
  void codeUsedAt(String orchardId, String inviteId, DateTime at) =>
      _orchards[orchardId]!.invites[inviteId]!.code!.usedAt = at;

  /// An Orchard's invitations cannot be read while set.
  bool failOrchardInvites = false;

  /// How often an Orchard's invitations were asked for, refused or not.
  var inviteLists = 0;

  @override
  Future<List<OrchardInvite>> invites(String orchardId) async {
    inviteLists++;
    if (failOrchardInvites) throw const OrchardServerException(503, null);
    final o = _orchard(orchardId);
    if (!o.record.can(accountUid, RoleCan.invite)) throw const OrchardServerException(403, 'forbidden');
    return [
      for (final i in o.invites.values)
        OrchardInvite(
          id: i.id,
          email: i.code == null ? i.email : (i.acceptedBy == null ? '' : emails[i.acceptedBy] ?? ''),
          role: i.role,
          grants: i.grants,
          endsAt: i.endsAt,
          expiresAt: i.expiresAt ?? DateTime.now().add(const Duration(days: 14)),
          expired: i.expired,
          invitedBy: i.invitedBy,
          acceptedUid: i.acceptedBy,
          acceptedKeys: i.acceptedBy == null ? null : published[i.acceptedBy],
          acceptedDevice: i.acceptedBy == null ? null : i.device,
          acceptedProvider: i.code != null && i.acceptedBy != null ? 'google.com' : null,
          code: i.code == null
              ? null
              : InviteCodeInfo(
                  makerUid: i.code!.makerUid,
                  makerKeyVersion: i.code!.makerKeyVersion,
                  sealed: i.code!.makerUid == accountUid ? i.code!.codeSealed : null,
                  joinerTag: i.code!.joinerTag,
                  usedPlatform: i.acceptedBy == null ? null : 'android',
                  usedAt: i.code!.usedAt,
                ),
        ),
    ];
  }

  @override
  Future<void> withdrawInvite(String orchardId, String inviteId) async {
    withdrawn.add(inviteId);
    _orchard(orchardId).invites.remove(inviteId);
  }

  /// [uid] accepts [inviteId] (their keys must be published), offering
  /// [device] as the server keeps it: a test's own, made up or not.
  void acceptAs(String orchardId, String inviteId, String uid, {JoinDevice? device}) {
    if (!published.containsKey(uid)) throw const OrchardServerException(409, 'no-keys');
    _orchard(orchardId).invites[inviteId]!
      ..acceptedBy = uid
      ..device = _offeredDevice(device);
  }

  /// The platform the server lists beside a device offered with an
  /// invitation (what the accepting session reports).
  String? acceptedPlatform = 'windows';

  /// [device] as the server keeps it: only a key of 32 bytes with a
  /// signature of 64, which it does not check; none otherwise.
  JoinDevice? _offeredDevice(JoinDevice? device) => device == null ||
          device.key.length != 32 ||
          device.signature.length != 64
      ? null
      : JoinDevice(key: device.key, signature: device.signature, platform: acceptedPlatform);

  /// Lapses [inviteId].
  void lapse(String orchardId, String inviteId) => _orchard(orchardId).invites[inviteId]!.expired = true;

  @override
  Future<void> confirmInvite(String orchardId, String inviteId,
      {required RecordEntry entry, required List<GrantCopy> copies, RecordEntry? device}) async {
    final code = failConfirmOnce;
    if (code != null) {
      failConfirmOnce = null;
      throw OrchardServerException(409, code);
    }
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (entry.type != RecordTypes.memberAdd || entry.by != accountUid) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    // Beside it, only the approval of the device they accepted on.
    if (device != null && (device.type != RecordTypes.deviceTrust || device.by != accountUid)) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    final invite = o.invites[inviteId];
    if (invite == null) throw const OrchardServerException(404, 'not-found');
    final uid = invite.acceptedBy;
    if (uid == null) throw const OrchardServerException(409, 'not-accepted');
    if (invite.expired) throw const OrchardServerException(409, 'expired');
    final offered = invite.device;
    if (device != null && (offered == null || device.body['uid'] != uid || device.body['device'] != offered.keyText)) {
      throw const OrchardServerException(409, 'invite-changed');
    }
    final probe = o.record.copy();
    try {
      await probe.append(entry);
      if (device != null) await probe.append(device);
    } on RecordRejected catch (x) {
      if (x.reason == 'out of order' || x.reason == 'does not follow the entry before') {
        throw const OrchardServerException(409, 'record-moved');
      }
      throw OrchardServerException(403, 'record-refused', reason: x.reason);
    }
    final added = probe.members[uid];
    if (added == null || added.since != entry.seq) throw const OrchardServerException(409, 'invite-changed');
    String grantsKey(Map<String, Set<String>> g) =>
        jsonEncode({for (final k in (g.keys.toList()..sort())) k: switchList(g[k]!)});
    if (added.role != invite.role || grantsKey(added.grants) != grantsKey(invite.grants) || added.endsAt != invite.endsAt) {
      throw const OrchardServerException(409, 'invite-changed');
    }
    final keys = added.currentKeys;
    final shown = published[uid]!;
    if (keys.version != shown.version ||
        base64Encode(keys.signingKey) != base64Encode(shown.signingKey) ||
        base64Encode(keys.encryptionKey) != base64Encode(shown.encryptionKey)) {
      throw const OrchardServerException(409, 'recipient-keys-changed');
    }
    await _apply(o, [entry, ?device], copies, by: accountUid);
    o.invites.remove(inviteId);
    confirmations.add((orchardId: orchardId, inviteId: inviteId, entry: entry, copies: copies, device: device));
  }

  /// The invitations to this account's address, as tests set them.
  final mine = <MyInvite>[];

  @override
  Future<List<MyInvite>> myInvites() async {
    if (failInvites) throw const OrchardServerException(503, null);
    return List.of(mine);
  }

  @override
  Future<void> acceptInvite(String inviteId, {JoinDevice? device}) async {
    accepted.add(inviteId);
    final i = mine.indexWhere((m) => m.id == inviteId);
    if (i < 0) return;
    final m = mine[i];
    mine[i] = MyInvite(
      id: m.id,
      orchardId: m.orchardId,
      role: m.role,
      crates: m.crates,
      expiresAt: m.expiresAt,
      accepted: true,
      invitedBy: m.invitedBy,
      endsAt: m.endsAt,
      rulesUnmet: m.rulesUnmet,
      tracking: m.tracking,
      exported: m.exported,
    );
    for (final o in _orchards.values) {
      final invite = o.invites[inviteId];
      // What accepted last is what is offered (none from an older app).
      if (invite != null) {
        invite
          ..acceptedBy = accountUid
          ..device = _offeredDevice(device);
      }
    }
  }

  @override
  Future<void> declineInvite(String inviteId) async {
    declined.add(inviteId);
    mine.removeWhere((i) => i.id == inviteId);
  }

  // ── Items ──

  /// How many times a Crate's changes were asked for.
  var changesCalls = 0;

  @override
  Future<ItemsPage> changes(String crateId, {required int since, int? limit, ItemCheck? check}) async {
    changesCalls++;
    final crate = items[crateId];
    if (crate == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    _holdIfDeleting(crateId);
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    final max = limit ?? 500;
    final newer = crate.entries.where((e) => e.value.revision > since).toList()
      ..sort((a, b) => a.value.revision.compareTo(b.value.revision));
    final page = newer.take(max).toList();
    var head = 0;
    for (final i in crate.values) {
      if (i.revision > head) head = i.revision;
    }
    return ItemsPage(
      items: [for (final e in page) (e.key, e.value)],
      latest: page.isEmpty ? since : page.last.value.revision,
      more: newer.length > max,
      keyGeneration: crateGenerations[crateId]!,
      head: olderServer ? null : head,
      check: check == null || !answersChecks || olderServer
          ? null
          : crate[check.itemId]?.revision == check.revision ||
              historyRows.any((h) => h.crateId == crateId && h.itemId == check.itemId && h.revision == check.revision),
    );
  }

  /// What [accountUid] may do in [crateId], as the record says now.
  Set<String> _switches(String crateId) {
    for (final o in _orchards.values) {
      if (o.crates.containsKey(crateId)) {
        return _counts(o.record, accountUid) ? o.record.switchesAt(accountUid, crateId, _now) : const {};
      }
    }
    // A Crate a test set up without a record.
    return CrateSwitches.all;
  }

  bool _opens(String crateId) => _switches(crateId).isNotEmpty;

  /// A Crate of a team being deleted is held back like the team.
  void _holdIfDeleting(String crateId) {
    for (final o in _orchards.values) {
      if (o.crates.containsKey(crateId) && o.record.deleting != null) {
        throw OrchardServerException(403, 'team-being-deleted', deleting: _deletionOf(o));
      }
    }
  }

  /// [o]'s deletion as the server says it: when it was asked here, or, for a
  /// record a test made otherwise, now.
  TeamDeletion _deletionOf(_Orchard o) {
    final asked = o.deletion;
    if (asked != null) return asked;
    final now = DateTime.fromMillisecondsSinceEpoch(_now * 1000, isUtc: true);
    return TeamDeletion(
        by: o.record.deleting?.by,
        seq: o.record.deleting?.seq,
        askedAt: now,
        purgeAt: now.add(const Duration(days: 7)));
  }

  @override
  Future<TeamDeletion> deleteTeam(String orchardId, RecordEntry entry) async {
    deletes++;
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (entry.type != RecordTypes.teamDelete || entry.by != accountUid) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    if (!newRecordKinds) throw const OrchardServerException(409, 'feature-not-yet');
    if (deleteSignInTooOld) throw const OrchardServerException(403, 'recent-sign-in-required', withinSeconds: 600);
    if (o.record.deleting != null) {
      // Asked already: a retry of this very request is answered as the first was.
      final same = entry.seq <= o.entries.length && _same(o.entries[entry.seq - 1].signature, entry.signature);
      if (same) return _deletionOf(o);
      throw OrchardServerException(409, 'team-being-deleted', deleting: _deletionOf(o));
    }
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!o.record.isOwner(accountUid)) throw const OrchardServerException(403, 'owners-only');
    await _apply(o, [entry], const [], by: accountUid);
    final now = DateTime.fromMillisecondsSinceEpoch(_now * 1000, isUtc: true);
    return o.deletion =
        TeamDeletion(by: entry.by, seq: entry.seq, askedAt: now, purgeAt: now.add(const Duration(days: 7)));
  }

  @override
  Future<int> restoreTeam(String orchardId, RecordEntry entry) async {
    restores++;
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (entry.type != RecordTypes.teamRestore || entry.by != accountUid) {
      throw const OrchardServerException(400, 'invalid-request');
    }
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    // Owners and admins undo it, as the server has it.
    if (!o.record.isOwner(accountUid) && !o.record.isAdmin(accountUid)) {
      throw const OrchardServerException(403, 'owners-only');
    }
    if (o.record.deleting == null) throw const OrchardServerException(409, 'team-not-being-deleted');
    if (!_deletionOf(o).purgeAt.isAfter(DateTime.fromMillisecondsSinceEpoch(_now * 1000, isUtc: true))) {
      throw const OrchardServerException(409, 'undo-too-late');
    }
    await _apply(o, [entry], const [], by: accountUid);
    o.deletion = null;
    return o.record.seq;
  }

  /// The team [orchardId], being deleted, purged as the clean-up job does on
  /// its day: gone, its record's fingerprints kept, so that
  /// "does this server hold this entry?" stays yes and says when it went.
  void purgeTeam(String orchardId, {DateTime? at}) {
    final o = _orchards.remove(orchardId) ?? (throw StateError('no team $orchardId'));
    _deletedTeams[orchardId] = (entries: [...o.entries], at: at ?? clock().toUtc());
  }

  @override
  Future<List<WriteResult>> write(String crateId, List<ItemWrite> writes, {required int keyVersion}) async {
    final crate = items[crateId];
    if (crate == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    _holdIfDeleting(crateId);
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    // Every attempt is recorded, refused ones too.
    writeCalls.add(writes);
    final switches = _switches(crateId);
    var adding = false;
    for (final w in writes) {
      var need = w.item.deleted
          ? CrateSwitches.delete
          : w.baseRevision == null
              ? CrateSwitches.add
              : CrateSwitches.edit;
      // Bringing back a deleted item adds it again.
      final base = crate[w.item.itemId];
      if (need == CrateSwitches.edit && base != null && base.revision == w.baseRevision && base.item?.deleted == true) {
        need = CrateSwitches.add;
      }
      if (!switches.contains(need)) throw OrchardServerException(403, 'read-only', need: need);
      if (need == CrateSwitches.add) adding = true;
    }
    if (seatsShort && adding) throw const OrchardServerException(409, 'seats-needed', seats: 1, seatsUsed: 2);
    if (vaultsFull && (adding || vaultsPastChanges)) {
      throw const OrchardServerException(409, 'seats-needed', reason: 'storage', seats: 5, seatsUsed: 5, seatsNeeded: 1);
    }
    if (keyVersion != accountKeyVersion) throw const OrchardServerException(409, 'stale-account-keys');
    final generation = crateGenerations[crateId]!;
    if (writes.any((w) => w.item.keyGeneration != generation)) throw StaleCrateKey(generation);
    final results = <WriteResult>[];
    for (final w in writes) {
      final id = w.item.itemId;
      final current = crate[id];
      if (w.baseRevision == null) {
        if (current != null) {
          results.add(WriteConflict(id, current));
          continue;
        }
      } else if (current == null || current.revision != w.baseRevision) {
        results.add(WriteConflict(id, current));
        continue;
      } else {
        history.putIfAbsent(id, () => []).add(current.item!);
        historyRows.add(FakeHistoryRow(++_historyId, crateId, id, current.revision, current.item!, clock()));
      }
      crate[id] = RemoteItem(revision: ++_revision, item: w.item);
      results.add(WriteOk(id, _revision));
    }
    final hook = duringWrite;
    if (hook != null) {
      duringWrite = null;
      await hook();
    }
    return results;
  }

  /// Says no key of Orchard [orchardId] waits to be replaced, whoever has
  /// lost access, as a server that is not playing by the rules would.
  void hideRotationDue(String orchardId) {
    final o = _orchards[orchardId]!;
    o.rotationDue = false;
    for (final c in o.crates.values) {
      c.rotationDue = false;
    }
  }

  /// Stores [item] as the item's current version whatever its key, its
  /// signature or who may write it, as a server that is not playing by the
  /// rules would.
  /// The version it replaces goes to the history, as every write's does on
  /// the server (so a device that asks whether the server still holds the
  /// version it knows is told yes: this is not a restore).
  void forceItem(String crateId, SealedItem item) {
    final current = items[crateId]![item.itemId];
    if (current?.item != null) {
      historyRows.add(FakeHistoryRow(++_historyId, crateId, item.itemId, current!.revision, current.item!, clock()));
    }
    items[crateId]![item.itemId] = RemoteItem(revision: ++_revision, item: item);
  }

  @override
  Future<void> keepInHistory(String crateId, SealedItem item, {int? revision}) async {
    history.putIfAbsent(item.itemId, () => []).add(item);
    historyRows.add(FakeHistoryRow(++_historyId, crateId, item.itemId, revision, item, clock()));
  }

  // ── What the team records ──

  @override
  Future<List<TrashedItem>> trash(String crateId) async {
    final crate = items[crateId];
    if (crate == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!_switches(crateId).contains(CrateSwitches.add)) {
      throw const OrchardServerException(403, 'read-only', need: CrateSwitches.add);
    }
    final kept = clock().subtract(const Duration(days: 30));
    final out = <(DateTime, TrashedItem)>[];
    for (final e in crate.entries) {
      if (e.value.item?.deleted != true) continue;
      final last = historyRows
          .where((r) => r.crateId == crateId && r.itemId == e.key && !r.item.deleted && r.replacedAt.isAfter(kept))
          .lastOrNull;
      if (last == null) continue;
      out.add((
        last.replacedAt,
        TrashedItem(
          itemId: e.key,
          deletion: e.value,
          last: RemoteItem(revision: last.revision ?? 0, item: last.item),
          keptUntil: last.replacedAt.add(const Duration(days: 30)),
        ),
      ));
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final t in out) t.$2];
  }

  @override
  Future<HistoryPage> itemHistory(String crateId, {String? itemId, int? before}) async {
    final crate = items[crateId];
    if (crate == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!_switches(crateId).contains(CrateSwitches.manage)) {
      throw const OrchardServerException(403, 'read-only', need: CrateSwitches.manage);
    }
    final o = _orchardOfCrate(crateId);
    final since = o.historySince;
    if (!o.record.tracking.history || since == null) throw const OrchardServerException(409, 'history-off');
    final rows = [
      for (final r in historyRows.reversed)
        if (r.crateId == crateId &&
            !r.replacedAt.isBefore(since) &&
            (itemId == null || historyIgnoresItem || r.itemId == itemId) &&
            (before == null || r.id < before))
          r,
    ];
    final page = rows.take(100).toList();
    return HistoryPage(
      versions: [
        for (final r in page)
          HistoryVersion(id: r.id, itemId: r.itemId, revision: r.revision, item: r.item, replacedAt: r.replacedAt),
      ],
      current: {
        for (final r in page)
          if (crate[r.itemId] != null) r.itemId: crate[r.itemId]!,
      },
      since: since,
      more: rows.length > page.length,
    );
  }

  @override
  Future<void> sendActivity(String orchardId, List<SealedActivity> events) async {
    activityCalls++;
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (events.isEmpty || events.length > 50) throw const OrchardServerException(400, 'invalid-request');
    if (!o.record.tracking.activity) throw const OrchardServerException(409, 'activity-off');
    if (events.any((e) => e.keyGeneration > o.generation)) throw const OrchardServerException(400, 'invalid-request');
    for (final e in events) {
      activityRows.putIfAbsent(orchardId, () => []).add(ActivityEntry(
          id: ++_activityId, uid: accountUid, keyGeneration: e.keyGeneration, sealed: e.sealed, at: clock()));
    }
  }

  // ── Team session logs ──

  bool _sessionLogsOn(String crateId) => _orchardOfCrate(crateId).record.crates[crateId]?.sessionLogs ?? false;

  @override
  Future<void> startSessionLog(String crateId, String logId, {required int keyGeneration, required Uint8List header}) async {
    sessionLogStartCalls++;
    final fault = sessionLogStartFault;
    if (fault != null) throw fault;
    if (items[crateId] == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!_sessionLogsOn(crateId)) throw const OrchardServerException(409, 'session-logs-off');
    if (keyGeneration > crateGenerations[crateId]!) throw const OrchardServerException(400, 'invalid-request');
    for (final logs in sessionLogRows.values) {
      final same = logs.where((l) => l.id == logId).firstOrNull;
      if (same == null) continue;
      if (same.crateId == crateId && same.uid == accountUid) return;
      throw const OrchardServerException(409, 'id-taken');
    }
    sessionLogRows.putIfAbsent(crateId, () => []).add(FakeSessionLog(
        logId, crateId, accountUid, keyGeneration, header, clock()));
  }

  @override
  Future<void> sendSessionLogChunk(String crateId, String logId,
      {required int seq, required int keyGeneration, required Uint8List sealed, bool last = false}) async {
    sessionLogChunkCalls++;
    final fault = sessionLogChunkFault?.call(seq);
    if (fault != null) throw fault;
    if (items[crateId] == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!_sessionLogsOn(crateId)) throw const OrchardServerException(409, 'session-logs-off');
    final log = (sessionLogRows[crateId] ?? const <FakeSessionLog>[])
        .where((l) => l.id == logId && l.uid == accountUid)
        .firstOrNull;
    if (log == null) throw const OrchardServerException(404, 'not-found');
    if (seq <= log.chunks.length) return;
    if (log.closed) throw const OrchardServerException(409, 'log-closed');
    if (seq != log.chunks.length + 1) throw const OrchardServerException(409, 'out-of-order');
    log.chunks.add((seq: seq, keyGeneration: keyGeneration, sealed: sealed));
    log.closed = last;
    log.updatedAt = clock();
  }

  /// What asking to start a log throws, while set.
  Object? sessionLogStartFault;

  /// What sending the chunk [seq] throws instead of going in, while set.
  Object? Function(int seq)? sessionLogChunkFault;

  /// How many logs devices asked to start.
  int sessionLogStartCalls = 0;

  void _mayReadLogs(String crateId) {
    if (items[crateId] == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!_switches(crateId).contains(CrateSwitches.manage)) {
      throw const OrchardServerException(403, 'read-only', need: CrateSwitches.manage);
    }
  }

  @override
  Future<SessionLogPage> sessionLogs(String crateId, {String? before}) async {
    _mayReadLogs(crateId);
    final all = (sessionLogRows[crateId] ?? const <FakeSessionLog>[]).reversed.toList();
    final from = before == null ? 0 : all.indexWhere((l) => l.id == before) + 1;
    final rest = all.skip(from).toList();
    final page = rest.take(100).toList();
    return SessionLogPage(
      logs: [
        for (final l in page)
          RemoteSessionLog(
            id: l.id,
            uid: l.uid,
            keyGeneration: l.keyGeneration,
            header: l.header,
            chunks: l.chunks.length,
            bytes: l.chunks.fold(0, (n, c) => n + c.sealed.length),
            closed: l.closed,
            startedAt: l.startedAt,
            updatedAt: l.updatedAt,
          ),
      ],
      more: rest.length > page.length,
    );
  }

  @override
  Future<SessionLogChunkPage> sessionLogChunks(String crateId, String logId, {int after = 0}) async {
    _mayReadLogs(crateId);
    final log = (sessionLogRows[crateId] ?? const <FakeSessionLog>[]).where((l) => l.id == logId).firstOrNull;
    if (log == null) throw const OrchardServerException(404, 'not-found');
    final page = log.chunks.where((c) => c.seq > after).take(16).toList();
    return SessionLogChunkPage(chunks: page, more: (page.isEmpty ? after : page.last.seq) < log.chunks.length);
  }

  @override
  Future<void> deleteSessionLog(String crateId, String logId) async {
    if (items[crateId] == null || !_opens(crateId)) throw const OrchardServerException(404, 'not-found');
    if (!_orchardOfCrate(crateId).record.isOwner(accountUid)) throw const OrchardServerException(403, 'owners-only');
    final logs = sessionLogRows[crateId];
    if (logs == null || !logs.any((l) => l.id == logId)) throw const OrchardServerException(404, 'not-found');
    logs.removeWhere((l) => l.id == logId);
  }

  @override
  Future<ActivityPage> activity(String orchardId, {int? before, int? after}) async {
    activityReads.add((orchardId: orchardId, before: before, after: after));
    // A client that asks for the same page a thousand times in a row goes
    // round for ever: said here, so that a test fails instead of hanging.
    final asked = (orchardId, before, after);
    _sameActivityRead = asked == _lastActivityRead ? _sameActivityRead + 1 : 0;
    _lastActivityRead = asked;
    if (_sameActivityRead >= 1000) throw StateError('the same page of activity was asked for again and again');
    if (failActivityReads) throw const OrchardServerException(503, null);
    final o = _orchard(orchardId);
    if (!_counts(o.record, accountUid)) throw const OrchardServerException(404, 'not-found');
    if (_isHeld(accountUid)) throw _heldError(accountUid);
    if (!o.record.isOwner(accountUid)) throw const OrchardServerException(403, 'owners-only');
    if (!o.record.tracking.activity) throw const OrchardServerException(409, 'activity-off');
    if (after != null && (after < 0 || before != null)) throw const OrchardServerException(400, 'invalid-request');
    final kept = activityRows[orchardId] ?? const <ActivityEntry>[];
    // Read forward from an event: oldest first.
    final rows = after != null
        ? [
            for (final e in kept)
              if (e.id > after) e,
          ]
        : [
            for (final e in kept.reversed)
              if (before == null || e.id < before) e,
          ];
    final page = rows.take(activityPage).toList();
    return ActivityPage(events: page, more: rows.length > page.length);
  }

  /// How many events a page of activity holds (200 on the real server).
  int activityPage = 200;

  /// Keeps [sealed] as a note of activity from [uid], whatever it is (one
  /// nobody can read, in a test), with the next id as any other.
  ActivityEntry plantActivity(String orchardId, String uid, Uint8List sealed, {DateTime? at}) {
    final entry = ActivityEntry(id: ++_activityId, uid: uid, keyGeneration: 1, sealed: sealed, at: at ?? clock());
    activityRows.putIfAbsent(orchardId, () => []).add(entry);
    return entry;
  }

  /// Every read of an Orchard's activity, as asked.
  final activityReads = <({String orchardId, int? before, int? after})>[];
  (String, int?, int?)? _lastActivityRead;
  int _sameActivityRead = 0;

  /// The activity cannot be read just now.
  bool failActivityReads = false;

  /// Everything stored, as bytes, to check nothing readable reaches the
  /// server.
  Iterable<Uint8List> get storedBytes sync* {
    for (final crate in items.values) {
      for (final item in crate.values) {
        if (item.item != null) yield item.item!.record;
      }
    }
    for (final kept in history.values) {
      for (final item in kept) {
        yield item.record;
      }
    }
  }
}

/// [FakeCrateServer] answering as [uid], from the sign-in [session] names,
/// when it has one.
class _AccountView implements CrateServer {
  _AccountView(this.server, this.uid, this.session);

  final FakeCrateServer server;
  final String uid;
  final String? Function() session;

  Future<T> _as<T>(Future<T> Function() call) async {
    server.asked++;
    final answersLeft = server.downAfter;
    if (answersLeft != null) {
      if (answersLeft <= 0) {
        server.downAfter = null;
        server.down = true;
      } else {
        server.downAfter = answersLeft - 1;
      }
    }
    final stall = server.stall;
    if (stall != null) await stall;
    if (server.down) {
      server.askedWhileDown++;
      throw const SocketException('Connection refused');
    }
    final fault = server.fault;
    if (fault != null) throw OrchardServerException(fault, null);
    final was = server.accountUid;
    final wasSession = server.accountSession;
    server.accountUid = uid;
    server.accountSession = session();
    try {
      return await call();
    } finally {
      server.accountUid = was;
      server.accountSession = wasSession;
    }
  }

  @override
  Future<String?> currentSession() => _as(server.currentSession);

  @override
  Future<bool> nameDevice({required Uint8List deviceKey, required Uint8List signature}) =>
      _as(() => server.nameDevice(deviceKey: deviceKey, signature: signature));

  @override
  Future<DeviceTrustRequests> deviceRequests(String orchardId) => _as(() => server.deviceRequests(orchardId));

  @override
  Future<String> askDeviceTrust(String orchardId, Uint8List commitment) =>
      _as(() => server.askDeviceTrust(orchardId, commitment));

  @override
  Future<void> answerDeviceTrust(String orchardId, String requestId, Uint8List nonce) =>
      _as(() => server.answerDeviceTrust(orchardId, requestId, nonce));

  @override
  Future<void> showDeviceTrust(String orchardId, String requestId,
          {required Uint8List deviceKey, required Uint8List nonce}) =>
      _as(() => server.showDeviceTrust(orchardId, requestId, deviceKey: deviceKey, nonce: nonce));

  @override
  Future<void> dropDeviceTrust(String orchardId, String requestId) =>
      _as(() => server.dropDeviceTrust(orchardId, requestId));

  @override
  Future<List<RemoteOrchard>> orchards() => _as(server.orchards);

  @override
  Future<RecordPage> record(String orchardId, {required int after}) =>
      _as(() => server.record(orchardId, after: after));

  @override
  Future<int> appendRecord(String orchardId, List<RecordEntry> entries, {List<GrantCopy> copies = const []}) =>
      _as(() => server.appendRecord(orchardId, entries, copies: copies));

  @override
  Future<TeamDeletion> deleteTeam(String orchardId, RecordEntry entry) =>
      _as(() => server.deleteTeam(orchardId, entry));

  @override
  Future<int> restoreTeam(String orchardId, RecordEntry entry) => _as(() => server.restoreTeam(orchardId, entry));

  @override
  Future<void> createOrchard(NewOrchard orchard) => _as(() => server.createOrchard(orchard));

  @override
  Future<void> createCrate(String orchardId, NewCrate crate) => _as(() => server.createCrate(orchardId, crate));

  @override
  Future<void> renameCrate(String crateId, Uint8List nameEnc, {required int generation}) =>
      _as(() => server.renameCrate(crateId, nameEnc, generation: generation));

  @override
  Future<void> renameOrchard(String orchardId, Uint8List nameEnc, {required int generation}) =>
      _as(() => server.renameOrchard(orchardId, nameEnc, generation: generation));

  @override
  Future<ItemsPage> changes(String crateId, {required int since, int? limit, ItemCheck? check}) =>
      _as(() => server.changes(crateId, since: since, limit: limit, check: check));

  @override
  Future<int> mendRecord(String orchardId,
          {required int after, required List<RecordEntry> entries, required String receipt, List<MendName> names = const []}) =>
      _as(() => server.mendRecord(orchardId, after: after, entries: entries, receipt: receipt, names: names));

  @override
  Future<RecordHolds> recordHolds(String orchardId, int seq, Uint8List hash) =>
      _as(() => server.recordHolds(orchardId, seq, hash));

  @override
  Future<List<MissingCopy>> missingCopies(String orchardId) => _as(() => server.missingCopies(orchardId));

  @override
  Future<int> fillCopies(String orchardId, List<GrantCopy> copies) => _as(() => server.fillCopies(orchardId, copies));

  @override
  Future<List<WriteResult>> write(String crateId, List<ItemWrite> writes, {required int keyVersion}) =>
      _as(() => server.write(crateId, writes, keyVersion: keyVersion));

  @override
  Future<void> keepInHistory(String crateId, SealedItem item, {int? revision}) =>
      _as(() => server.keepInHistory(crateId, item, revision: revision));

  @override
  Future<int> rotateKey(String orchardId, RecordEntry entry,
          {required Uint8List nameEnc, required List<GrantCopy> copies}) =>
      _as(() => server.rotateKey(orchardId, entry, nameEnc: nameEnc, copies: copies));

  @override
  Future<MemberList> members(String orchardId) => _as(() => server.members(orchardId));

  @override
  Future<void> verifyMember(String orchardId,
          {required String subjectUid,
          required int subjectKeyVersion,
          required int keyVersion,
          required Uint8List signature}) =>
      _as(() => server.verifyMember(orchardId,
          subjectUid: subjectUid, subjectKeyVersion: subjectKeyVersion, keyVersion: keyVersion, signature: signature));

  @override
  Future<InviteSent> invite(String orchardId,
          {required String email,
          required String role,
          Map<String, Set<String>> grants = const {},
          int? endsAt,
          bool sendEmail = true,
          bool resend = false}) =>
      _as(() => server.invite(orchardId,
          email: email, role: role, grants: grants, endsAt: endsAt, sendEmail: sendEmail, resend: resend));

  @override
  Future<InviteCodeSaved> saveInviteCode(String orchardId,
          {required String inviteId,
          required String lookupId,
          required Uint8List ownerTag,
          required int makerKeyVersion,
          required Uint8List codeSealed,
          required Uint8List offerSealed,
          required String role,
          Map<String, Set<String>> grants = const {},
          int? endsAt,
          required int expiresIn,
          String? replacesInvite, int usesMax = 1}) =>
      _as(() => server.saveInviteCode(orchardId,
          inviteId: inviteId,
          lookupId: lookupId,
          ownerTag: ownerTag,
          makerKeyVersion: makerKeyVersion,
          codeSealed: codeSealed,
          offerSealed: offerSealed,
          role: role,
          grants: grants,
          endsAt: endsAt,
          expiresIn: expiresIn,
          replacesInvite: replacesInvite));

  @override
  Future<DateTime> changeInviteCodeExpiry(String orchardId, String inviteId, int expiresIn) =>
      _as(() => server.changeInviteCodeExpiry(orchardId, inviteId, expiresIn));

  @override
  Future<InviteCodeOffer> inviteCodeOffer(String lookupId) => _as(() => server.inviteCodeOffer(lookupId));

  @override
  Future<String> acceptInviteCode(String lookupId,
          {required int keyVersion, required Uint8List joinerTag, JoinDevice? device}) =>
      _as(() => server.acceptInviteCode(lookupId, keyVersion: keyVersion, joinerTag: joinerTag, device: device));

  @override
  Future<List<OrchardInvite>> invites(String orchardId) => _as(() => server.invites(orchardId));

  @override
  Future<void> withdrawInvite(String orchardId, String inviteId) =>
      _as(() => server.withdrawInvite(orchardId, inviteId));

  @override
  Future<AccessRequest> requestAccess(String orchardId,
          {String? crateId, required CrateLevel level, required int seconds, Uint8List? noteEnc, int? noteGeneration}) =>
      _as(() => server.requestAccess(orchardId,
          crateId: crateId, level: level, seconds: seconds, noteEnc: noteEnc, noteGeneration: noteGeneration));

  @override
  Future<AccessRequests> accessRequests(String orchardId) => _as(() => server.accessRequests(orchardId));

  @override
  Future<void> deleteAccessRequest(String orchardId, String requestId) =>
      _as(() => server.deleteAccessRequest(orchardId, requestId));

  @override
  Future<void> confirmInvite(String orchardId, String inviteId,
          {required RecordEntry entry, required List<GrantCopy> copies, RecordEntry? device}) =>
      _as(() => server.confirmInvite(orchardId, inviteId, entry: entry, copies: copies, device: device));

  @override
  Future<List<MyInvite>> myInvites() => _as(server.myInvites);

  @override
  Future<void> acceptInvite(String inviteId, {JoinDevice? device}) =>
      _as(() => server.acceptInvite(inviteId, device: device));

  @override
  Future<void> declineInvite(String inviteId) => _as(() => server.declineInvite(inviteId));

  @override
  Future<TeamRecoveryStatus> teamRecovery(String orchardId) => _as(() => server.teamRecovery(orchardId));

  @override
  Future<void> approveRecovery(String orchardId,
          {required String subjectUid,
          required int keyVersion,
          required int approverKeyVersion,
          required Uint8List approval}) =>
      _as(() => server.approveRecovery(orchardId,
          subjectUid: subjectUid, keyVersion: keyVersion, approverKeyVersion: approverKeyVersion, approval: approval));

  @override
  Future<void> withdrawRecoveryApproval(String orchardId, String subjectUid) =>
      _as(() => server.withdrawRecoveryApproval(orchardId, subjectUid));

  @override
  Future<void> completeRecovery(String orchardId, RecordEntry entry, {required List<GrantCopy> copies}) =>
      _as(() => server.completeRecovery(orchardId, entry, copies: copies));

  @override
  Future<void> askCertificate(String crateId, CertRequest request) =>
      _as(() => server.askCertificate(crateId, request));

  @override
  Future<List<CertRequest>> waitingCertificates(String crateId) => _as(() => server.waitingCertificates(crateId));

  @override
  Future<void> signCertificate(String crateId, String requestId, Uint8List certificate) =>
      _as(() => server.signCertificate(crateId, requestId, certificate));

  @override
  Future<List<IssuedCertificate>> myCertificates(String crateId) => _as(() => server.myCertificates(crateId));

  @override
  Future<List<TrashedItem>> trash(String crateId) => _as(() => server.trash(crateId));

  @override
  Future<HistoryPage> itemHistory(String crateId, {String? itemId, int? before}) =>
      _as(() => server.itemHistory(crateId, itemId: itemId, before: before));

  @override
  Future<void> sendActivity(String orchardId, List<SealedActivity> events) =>
      _as(() => server.sendActivity(orchardId, events));

  @override
  Future<ActivityPage> activity(String orchardId, {int? before, int? after}) =>
      _as(() => server.activity(orchardId, before: before, after: after));

  @override
  Future<void> startSessionLog(String crateId, String logId, {required int keyGeneration, required Uint8List header}) =>
      _as(() => server.startSessionLog(crateId, logId, keyGeneration: keyGeneration, header: header));

  @override
  Future<void> sendSessionLogChunk(String crateId, String logId,
          {required int seq, required int keyGeneration, required Uint8List sealed, bool last = false}) =>
      _as(() => server.sendSessionLogChunk(crateId, logId,
          seq: seq, keyGeneration: keyGeneration, sealed: sealed, last: last));

  @override
  Future<SessionLogPage> sessionLogs(String crateId, {String? before}) =>
      _as(() => server.sessionLogs(crateId, before: before));

  @override
  Future<SessionLogChunkPage> sessionLogChunks(String crateId, String logId, {int after = 0}) =>
      _as(() => server.sessionLogChunks(crateId, logId, after: after));

  @override
  Future<void> deleteSessionLog(String crateId, String logId) => _as(() => server.deleteSessionLog(crateId, logId));
}

class _Orchard {
  _Orchard(this.id) : record = OrchardRecord(id);

  final String id;

  /// While it is being deleted: who asked and the day it goes.
  TeamDeletion? deletion;
  Uint8List nameEnc = Uint8List(0);
  int generation = 1;
  bool rotationDue = false;
  final entries = <RecordEntry>[];
  OrchardRecord record;
  final crates = <String, _Crate>{};

  /// uid -> 'orchard' or a Crate id -> generation -> that account's copy.
  final copies = <String, Map<String, Map<int, SealedSpaceKey>>>{};
  final invites = <String, _Invite>{};
  String membersTag = 'tag-0-0';

  /// When version history was last turned on; null while it is off.
  DateTime? historySince;

  /// The requests for access that wait, by id.
  final requests = <String, _AccessRequest>{};

  /// The requests of devices to be approved, by id.
  final deviceRequests = <String, _DeviceRequest>{};

  /// Devices whose approval was taken back while their member stays:
  /// "uid|key".
  final removedDevices = <String>{};

  /// What was given until a set time and has been acted on as ended:
  /// "uid|crate|until".
  final endedAccess = <String>{};
}

/// A device's request to be approved as the server keeps it.
class _DeviceRequest {
  _DeviceRequest({
    required this.id,
    required this.uid,
    required this.session,
    required this.commitment,
    required this.expiresAt,
  });

  final String id;
  String uid;
  final String session;
  Uint8List commitment;
  int expiresAt;
  String stage = 'created';
  String? responder;
  String? responderSession;
  Uint8List? responderNonce;
  Uint8List? deviceKey;
  Uint8List? nonce;

  /// As the server lists it: for the device that made it ([mine]), or for
  /// someone who could answer it.
  DeviceTrustRequest listed({required bool mine}) => DeviceTrustRequest(
        id: id,
        stage: stage,
        expiresAt: expiresAt,
        uid: mine ? null : uid,
        commitment: mine ? null : commitment,
        responderNonce: responderNonce,
        sameAccount: mine && responder == uid,
        deviceKey: mine ? null : deviceKey,
        nonce: mine ? null : nonce,
      );
}

/// A request for access as the server keeps it.
class _AccessRequest {
  _AccessRequest({
    required this.id,
    required this.uid,
    required this.crateId,
    required this.level,
    required this.seconds,
    required this.noteEnc,
    required this.noteGeneration,
    required this.expiresAt,
  });

  final String id;
  final String uid;
  final String? crateId;
  final CrateLevel level;
  final int seconds;
  final Uint8List? noteEnc;
  final int? noteGeneration;
  final int expiresAt;

  /// As the server lists it: with who asks ([asked]) for someone who could
  /// answer it.
  AccessRequest listed({bool asked = false}) => AccessRequest(
        id: id,
        crateId: crateId,
        level: level,
        seconds: seconds,
        noteEnc: noteEnc,
        noteGeneration: noteGeneration,
        expiresAt: expiresAt,
        uid: asked ? uid : null,
      );
}

/// A team session log as the server keeps it.
class FakeSessionLog {
  FakeSessionLog(this.id, this.crateId, this.uid, this.keyGeneration, this.header, this.startedAt)
      : updatedAt = startedAt;

  final String id;
  final String crateId;
  final String uid;
  final int keyGeneration;
  final Uint8List header;
  final DateTime startedAt;
  DateTime updatedAt;
  final chunks = <({int seq, int keyGeneration, Uint8List sealed})>[];
  bool closed = false;
}

/// One replaced or kept version, as the server keeps it.
class FakeHistoryRow {
  FakeHistoryRow(this.id, this.crateId, this.itemId, this.revision, this.item, this.replacedAt);

  final int id;
  final String crateId;
  final String itemId;
  final int? revision;
  final SealedItem item;
  DateTime replacedAt;
}

class _Crate {
  _Crate(this.id);

  final String id;
  Uint8List nameEnc = Uint8List(0);
  int generation = 1;
  bool rotationDue = false;
}

class _Invite {
  _Invite(this.id, this.email, this.role, this.grants, this.endsAt, {this.invitedBy, this.acceptedBy});

  final String id;
  final String email;
  final String role;
  final Map<String, Set<String>> grants;
  final int? endsAt;
  final String? invitedBy;
  String? acceptedBy;
  bool expired = false;

  /// An invite code's, as the server keeps it.
  _Code? code;
  DateTime? expiresAt;
  String? replaces;

  /// The device it was accepted on, as offered.
  JoinDevice? device;
}

class _Code {
  _Code(this.lookupId, this.ownerTag, this.makerUid, this.makerKeyVersion, this.codeSealed, this.offerSealed);

  final String lookupId;
  final Uint8List ownerTag;
  final String makerUid;
  final int makerKeyVersion;
  final Uint8List codeSealed;
  final Uint8List offerSealed;
  Uint8List? joinerTag;
  DateTime? usedAt;
}
