part of 'orchard_service.dart';

// Trusted devices (3.0): an Orchard can let its members in only
// from devices the team approved. Every device has a signing key of its own
// (devices/device_identity.dart). The devices the team approved are listed
// in the Orchard's signed record (device.trust and device.revoke), where
// each device checks them for itself, and ZestSSH Cloud holds the rule for
// every request by the device a sign-in says it is.
//
// A device that is not approved asks: it commits to its key and a random
// value; an approved device of someone who may approve it answers with a
// random value of its own; the asking device then shows its key; and both
// screens show three words made from all of it. The person at the approved
// device compares them with the other screen and only then approves, with
// an entry that device signs. ZestSSH Cloud passes the request along and
// cannot have another key approved without the words differing.
//
// What is in progress (a request this device made, the requests it
// answered) is kept only while the app runs: a request lasts ten minutes,
// and one that was cut off is simply asked again.
//
// Joining: the device that accepts an
// invitation offers itself for approval, with a statement the joining
// account signs (crypto/join_device.dart). Whoever lets them in checks it
// with the keys they compared (or the code checked) and, where they may
// approve that person's devices from this one, approves it in the same step,
// ticked unless they untick it. No words to compare a second time: the
// account's signature already says the device is theirs.

/// A device the record lists for a member.
class MemberDevice {
  const MemberDevice({required this.uid, required this.key, required this.isThis, required this.canRemove});

  final String uid;

  /// The device's key as the record writes it.
  final String key;

  /// It is the device asking.
  final bool isThis;

  /// This account may take its approval back now, from this device.
  final bool canRemove;

  /// What people call it ([deviceCode]).
  String get code => deviceCode(key);
}

/// Where an Orchard stands with approved devices, as this device's copy of
/// the record has it.
class DeviceStanding {
  const DeviceStanding({
    required this.ruleOn,
    required this.thisKey,
    required this.approved,
    required this.mine,
    required this.ownerDevices,
    required this.isOwner,
    required this.without,
  });

  /// The Orchard lets in approved devices only.
  final bool ruleOn;

  /// This device's key for the signed-in account, or null where there is
  /// nowhere to keep one.
  final String? thisKey;

  /// The record lists this device for this account.
  final bool approved;

  /// How many devices of this account the record lists.
  final int mine;

  /// How many devices of owners the record lists.
  final int ownerDevices;

  final bool isOwner;

  /// The active members none of whose devices is approved: turning the rule
  /// on shuts them out until one is.
  final List<String> without;

  /// What this device is called ([deviceCode]).
  String? get thisCode => thisKey == null ? null : deviceCode(thisKey!);

  /// An owner's own first device approves itself, while the rule is off.
  /// Every other device is approved from one that already is.
  bool get canApproveItself => thisKey != null && isOwner && !ruleOn && mine == 0;

  /// What turning the rule on takes: this device approved, and two approved
  /// devices among the owners, so that losing one does not lock the owners
  /// out of their own Orchard.
  bool get canTurnOn => approved && ownerDevices >= 2;
}

/// This device's own request to be approved, as it stands.
class DeviceAsk {
  const DeviceAsk({required this.id, required this.expiresAt, this.words, this.sameAccount = false});

  final String id;

  /// When it lapses, in seconds since the epoch.
  final int expiresAt;

  /// The words to compare with the other screen, once someone answered;
  /// null while nobody has.
  final List<String>? words;

  /// The answer came from another device of this account.
  final bool sameAccount;
}

/// Where a request this device could answer stands.
enum DeviceRequestStage {
  /// Nobody answered yet: this device may.
  asks,

  /// This device answered, and the device that asks has not shown its key
  /// yet.
  answered,

  /// Both sides showed: the words are there to compare.
  compare,

  /// This account answered it on this device, in a run of the app that is
  /// gone: what was answered with is gone too, so it can only be declined.
  /// The other device asks again.
  cutOff,

  /// What the asking device showed is not what it committed to before this
  /// device answered: someone in between changed it. The request is ended.
  changed,
}

/// A device's request that this account could answer from this device.
class DeviceRequestView {
  const DeviceRequestView({
    required this.id,
    required this.uid,
    required this.stage,
    required this.expiresAt,
    this.words,
    this.deviceKey,
  });

  final String id;

  /// Whose device asks.
  final String uid;

  final DeviceRequestStage stage;

  /// When it lapses, in seconds since the epoch.
  final int expiresAt;

  /// The words to compare with the other screen ([DeviceRequestStage.compare]).
  final List<String>? words;

  /// The device's key, once it showed it.
  final String? deviceKey;

  /// What the device is called, once it showed its key ([deviceCode]).
  String? get code => deviceKey == null ? null : deviceCode(deviceKey!);
}

/// Something about devices this device tells its person once.
enum DeviceNoticeKind {
  /// A device asks to be approved, and this account could approve it from
  /// here.
  asked,

  /// This device's approval was taken back, and what it held of the Orchard
  /// is gone from it.
  removed,
}

class DeviceNotice {
  const DeviceNotice(this.kind, {this.uid, this.own = false, this.count = 1, this.orchardName});

  final DeviceNoticeKind kind;

  /// For [DeviceNoticeKind.asked]: whose device asks, when it is one.
  final String? uid;

  /// For [DeviceNoticeKind.asked]: it is another device of this account.
  final bool own;

  /// For [DeviceNoticeKind.asked]: how many new requests.
  final int count;

  /// For [DeviceNoticeKind.removed]: the Orchard's name as this device had
  /// it, when it had one.
  final String? orchardName;
}

/// Where an Orchard's own database (on this device only) keeps the device
/// requests it has already told its person about, each until it lapses.
const _deviceSeenKey = 'device.seen';

/// This device cannot say which device it is: its sign-in has no session of
/// its own, or already names another key (the key kept here was lost and
/// made again), or there is nowhere to keep a key. Signing out and in again
/// on this device makes a sign-in that can.
class DeviceCannotBeNamed implements Exception, HasTypeName {
  const DeviceCannotBeNamed();

  @override
  String toString() => 'Orchards: this sign-in cannot say which device it is';

  @override
  String get typeName => 'DeviceCannotBeNamed';
}

/// The request is not there any more: it lapsed, was taken back, or was
/// answered somewhere else.
class DeviceRequestGone implements Exception, HasTypeName {
  const DeviceRequestGone();

  @override
  String toString() => 'Orchards: the device request is gone';

  @override
  String get typeName => 'DeviceRequestGone';
}

/// A request this device made to be approved.
class _OwnAsk {
  _OwnAsk({required this.id, required this.nonce, required this.commitment});

  final String id;
  final Uint8List nonce;
  final Uint8List commitment;

  /// The answer this device first saw, which the words are made from: one
  /// that changes afterwards changes nothing here.
  Uint8List? answer;
}

/// A request this device answered.
class _Answer {
  _Answer({required this.uid, required this.commitment, required this.nonce});

  /// Whose device asked, as the request said when this device answered.
  final String uid;

  /// What the asking device had committed to when this device answered.
  final Uint8List commitment;

  /// This device's random value.
  final Uint8List nonce;

  /// The key the asking device showed, once it matched [commitment]: the
  /// one the words were made from, and the only one this device approves.
  Uint8List? deviceKey;
}

/// What the service remembers about devices while the app runs.
class _DeviceRun {
  /// The sign-in each account's device said is its own, and the key it
  /// said so with.
  final named = <String, ({String session, String key})>{};

  /// This device's requests to be approved, by Orchard.
  final asks = <String, _OwnAsk>{};

  /// The requests this device answered, by request.
  final answers = <String, _Answer>{};

  /// The Orchards this device was removed from and has not told its person
  /// about yet, each with the name it had here.
  final removed = <String, String?>{};
}

extension OrchardDevices on OrchardService {
  /// This device's key for the signed-in account.
  Future<DeviceIdentity> _thisDevice(CrateAuthor me) async =>
      await deviceKeys?.forAccount(me.uid) ?? (throw const DeviceCannotBeNamed());

  /// Says to ZestSSH Cloud which device this sign-in is: its key, with its
  /// signature over the sign-in's id. Once for each sign-in while the app
  /// runs, unless [again], which asks which sign-in this is once more (a
  /// device that is held back as not approved may have signed in anew).
  /// Returns whether it was said now. Nothing is said, or kept there, for an
  /// account that is in no Orchard.
  Future<bool> _nameThisDevice(CrateAuthor me, {bool again = false}) async {
    final store = deviceKeys;
    if (store == null) return false;
    final known = _deviceRun.named[me.uid];
    if (known != null && !again) return false;
    final session = await server.currentSession();
    if (session == null) {
      _deviceRun.named.remove(me.uid);
      return false;
    }
    final identity = await store.forAccount(me.uid);
    if (known != null && known.session == session && known.key == identity.key) return false;
    _deviceRun.named.remove(me.uid);
    final said = await server.nameDevice(
      deviceKey: identity.publicKey,
      signature: await identity.sign(sessionDeviceMessage(session)),
    );
    if (!said) return false;
    _deviceRun.named[me.uid] = (session: session, key: identity.key);
    return true;
  }

  /// Runs [body], which reads or changes an Orchard's record. Held back as a
  /// device nobody approved, on a sign-in that has not said which device it
  /// is (signing in again on a computer brings a new one), the sign-in says
  /// so and [body] runs once more.
  Future<T> _namingDevice<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on OrchardServerException catch (e) {
      if (!e.deviceNotApproved) rethrow;
      if (!await _nameThisDevice(await _me(), again: true)) rethrow;
    }
    return body();
  }

  /// [_nameThisDevice] for a device about to ask or to approve itself, which
  /// cannot go on without it. Throws [DeviceCannotBeNamed].
  Future<void> _nameForAsking(CrateAuthor me) async {
    try {
      await _nameThisDevice(me, again: true);
    } on OrchardServerException catch (e) {
      if (e.code == 'device-key-set') throw const DeviceCannotBeNamed();
      rethrow;
    }
    if (_deviceRun.named[me.uid] == null) throw const DeviceCannotBeNamed();
  }

  /// This device signed in again, which on a computer brings a new sign-in:
  /// it says which device it is before anything else is asked of ZestSSH
  /// Cloud with it, or an Orchard that lets in approved devices only would
  /// refuse the very change the person signed in again for. Nothing where
  /// no Orchard is on this device. Never throws.
  Future<void> signedInAgain() async {
    try {
      if ((await databases.onDevice()).isEmpty) return;
      await _nameThisDevice(await _me(), again: true);
    } catch (e) {
      AppLogger.warning('Orchards: the new sign-in could not say which device it is ($e)');
    }
  }

  /// Whether the record lets [me] approve or remove a device of [uid]: their
  /// own, an owner anyone's, an admin those below admin.
  static bool _decidesDevices(OrchardRecord record, String me, String uid) {
    final mine = record.members[me];
    final theirs = record.members[uid];
    if (mine == null || theirs == null) return false;
    if (me == uid || mine.role == FixedRoles.owner) return true;
    return mine.role == FixedRoles.admin && theirs.role != FixedRoles.owner && theirs.role != FixedRoles.admin;
  }

  /// Where [orchardId] stands with approved devices, from this device's copy
  /// of its record.
  Future<DeviceStanding> deviceStanding(String orchardId) async {
    final me = await _me();
    final record = (await LocalRecord.load(await databases.open(orchardId), orchardId)).latest;
    final key = (await deviceKeys?.forAccount(me.uid))?.key;
    final mine = record.devicesOf(me.uid);
    return DeviceStanding(
      ruleOn: record.rules.trustedDevices,
      thisKey: key,
      approved: key != null && mine.contains(key),
      mine: mine.length,
      ownerDevices: record.ownerDevices,
      isOwner: record.isOwner(me.uid),
      without: [
        for (final m in record.members.values)
          if (m.status == MemberStatus.active && m.devices.isEmpty) m.uid,
      ]..sort(),
    );
  }

  /// The devices the record lists for [uid]: this one first, the rest by
  /// what they are called.
  Future<List<MemberDevice>> memberDevices(String orchardId, String uid) async {
    final me = await _me();
    final record = (await LocalRecord.load(await databases.open(orchardId), orchardId)).latest;
    final key = (await deviceKeys?.forAccount(me.uid))?.key;
    // Only from an approved device, and only whose devices the record lets
    // this account decide about.
    final may = key != null && record.devicesOf(me.uid).contains(key) && _decidesDevices(record, me.uid, uid);
    final out = [
      for (final k in record.devicesOf(uid))
        MemberDevice(uid: uid, key: k, isThis: k == key, canRemove: may),
    ];
    out.sort((a, b) => a.isThis != b.isThis ? (a.isThis ? -1 : 1) : a.code.compareTo(b.code));
    return out;
  }

  /// One entry about the device [device] of [uid], made on this device and
  /// signed by it over the place in the record the entry takes.
  Future<void> _deviceChange(String orchardId, String type, {required String uid, required List<int> device}) async {
    final me = await _me();
    final identity = await _thisDevice(me);
    await _changeWith(
      orchardId,
      (latest) async => [
        (
          type: type,
          body: {
            'uid': uid,
            'device': deviceKeyText(device),
            'via': identity.key,
            'sig': base64Encode(await identity.sign(
                deviceEntryMessage(orchardId: orchardId, type: type, uid: uid, device: device, prev: latest.head))),
          },
        ),
      ],
    );
  }

  /// Approves this device as an owner's own first one, which only an owner
  /// can do and only while the rule is off ([DeviceStanding.canApproveItself]).
  /// Throws [OrchardRecordRefused] otherwise, and [DeviceCannotBeNamed].
  Future<void> approveThisDevice(String orchardId) async {
    final me = await _me();
    final identity = await _thisDevice(me);
    await _nameForAsking(me);
    await _deviceChange(orchardId, RecordTypes.deviceTrust, uid: me.uid, device: identity.publicKey);
  }

  /// Takes back the approval of the device [deviceKey] of [uid], from this
  /// device. Throws [OrchardRecordRefused] when the record refuses it: not
  /// from an approved device, not someone this account decides about, or
  /// the last approved device among the owners while the rule is on.
  Future<void> removeDevice(String orchardId, {required String uid, required String deviceKey}) async {
    final device = deviceKeyBytes(deviceKey);
    if (device == null) throw const OrchardRecordRefused('not an approved device');
    await _deviceChange(orchardId, RecordTypes.deviceRevoke, uid: uid, device: device);
  }

  /// Asks for this device to be approved in [orchardId]. Asking again
  /// replaces the request it made before. Throws [DeviceCannotBeNamed], and
  /// an [OrchardServerException] ('device-approved' when there is nothing to
  /// ask for).
  Future<DeviceAsk> askDeviceApproval(String orchardId) async {
    final me = await _me();
    final identity = await _thisDevice(me);
    await _nameForAsking(me);
    final nonce = newSpaceKey();
    final commitment = deviceTrustCommitment(identity.publicKey, nonce);
    final id = await server.askDeviceTrust(orchardId, commitment);
    _deviceRun.asks[orchardId] = _OwnAsk(id: id, nonce: nonce, commitment: commitment);
    return await deviceAsk(orchardId) ?? (throw const DeviceRequestGone());
  }

  /// This device's request in [orchardId] as it stands, or null when it has
  /// none: never asked, or the request is gone (approved, declined, lapsed,
  /// or made before the app was last started). Once someone answered, this
  /// device shows what it committed to, and the words are there to compare.
  Future<DeviceAsk?> deviceAsk(String orchardId) async {
    final me = await _me();
    final ask = _deviceRun.asks[orchardId];
    if (ask == null) return null;
    final DeviceTrustRequest? listed;
    try {
      listed = (await server.deviceRequests(orchardId)).mine.where((r) => r.id == ask.id).firstOrNull;
    } on OrchardServerException catch (e) {
      // No longer in the Orchard at all: nothing to ask for.
      if (e.notFound) _deviceRun.asks.remove(orchardId);
      rethrow;
    }
    if (listed == null) {
      _deviceRun.asks.remove(orchardId);
      return null;
    }
    final answer = ask.answer ??= listed.responderNonce;
    if (answer == null) return DeviceAsk(id: ask.id, expiresAt: listed.expiresAt);
    final identity = await _thisDevice(me);
    if (listed.stage != 'revealed') {
      try {
        await server.showDeviceTrust(orchardId, ask.id, deviceKey: identity.publicKey, nonce: ask.nonce);
      } on OrchardServerException catch (e) {
        // What it showed was not taken: the request ran out meanwhile, or
        // is no longer the one this device made (what it committed to was
        // changed on the way). It is over, and asked again.
        AppLogger.info('Orchards: what this device showed for its request was not taken ($e)');
        _deviceRun.asks.remove(orchardId);
        return null;
      }
    }
    return DeviceAsk(
      id: ask.id,
      expiresAt: listed.expiresAt,
      sameAccount: listed.sameAccount,
      words: deviceTrustWords(
        orchardId: orchardId,
        uid: me.uid,
        commitment: ask.commitment,
        approverNonce: answer,
        deviceKey: identity.publicKey,
        nonce: ask.nonce,
      ),
    );
  }

  /// Takes this device's request in [orchardId] back, when it has one.
  Future<void> withdrawDeviceAsk(String orchardId) async {
    final ask = _deviceRun.asks.remove(orchardId);
    if (ask == null) return;
    try {
      await server.dropDeviceTrust(orchardId, ask.id);
    } on OrchardServerException catch (e) {
      if (!e.notFound) rethrow;
    }
  }

  /// The requests of devices in [orchardId] that this account could answer
  /// from this device, in the server's order (soonest to lapse first). None
  /// from a device that is not approved itself. A request the server lists
  /// that the record does not let this account answer is left out: the
  /// server is not taken at its word for who approves whose device.
  Future<List<DeviceRequestView>> deviceRequests(String orchardId) async {
    final me = await _me();
    final key = (await deviceKeys?.forAccount(me.uid))?.key;
    var record = (await LocalRecord.load(await databases.open(orchardId), orchardId)).latest;
    // Only an approved device answers a request: any other has none to
    // list, and asks nothing of the server (an Orchard that approves no
    // devices never does).
    if (key == null || !record.devicesOf(me.uid).contains(key)) return const [];
    final listed = (await server.deviceRequests(orchardId)).waiting;
    if (listed.isEmpty) return const [];
    if (listed.any((r) => !record.members.containsKey(r.uid))) {
      // Someone this device's copy of the record has not heard of yet (they
      // just joined): it reads the record up to now first, and then decides
      // by it.
      await _serial(orchardId, () => _refreshOrchard(orchardId, me));
      // (Opened again: a device that learns here that it was removed has
      // dropped the database it read before.)
      record = (await LocalRecord.load(await databases.open(orchardId), orchardId)).latest;
      if (!record.devicesOf(me.uid).contains(key)) return const [];
    }
    final out = <DeviceRequestView>[];
    for (final r in listed) {
      final uid = r.uid;
      if (uid == null || !_decidesDevices(record, me.uid, uid)) continue;
      DeviceRequestView view(DeviceRequestStage stage, {List<String>? words, Uint8List? device}) => DeviceRequestView(
            id: r.id,
            uid: uid,
            stage: stage,
            expiresAt: r.expiresAt,
            words: words,
            deviceKey: device == null ? null : deviceKeyText(device),
          );
      if (r.stage == 'created') {
        out.add(view(DeviceRequestStage.asks));
        continue;
      }
      // Nothing kept of an answer, or the request now says someone else's
      // device asks than when this device answered: not one to go on with.
      final answer = _deviceRun.answers[r.id];
      if (answer == null || answer.uid != uid) {
        out.add(view(DeviceRequestStage.cutOff));
        continue;
      }
      final shownKey = r.deviceKey;
      final shownNonce = r.nonce;
      if (shownKey == null || shownNonce == null) {
        out.add(view(DeviceRequestStage.answered));
        continue;
      }
      // What it shows is what it committed to before this device answered
      // (so it cannot become another key later either): otherwise someone
      // in between put another key there, and the request ends here.
      if (!OrchardService._eq(deviceTrustCommitment(shownKey, shownNonce), answer.commitment)) {
        _deviceRun.answers.remove(r.id);
        try {
          await server.dropDeviceTrust(orchardId, r.id);
        } catch (e) {
          AppLogger.warning('Orchards: a device request that was changed on the way could not be ended ($e)');
        }
        out.add(view(DeviceRequestStage.changed));
        continue;
      }
      answer.deviceKey = shownKey;
      out.add(view(
        DeviceRequestStage.compare,
        device: shownKey,
        words: deviceTrustWords(
          orchardId: orchardId,
          uid: uid,
          commitment: answer.commitment,
          approverNonce: answer.nonce,
          deviceKey: shownKey,
          nonce: shownNonce,
        ),
      ));
    }
    return out;
  }

  /// Answers the request [requestId] from this device: its random value,
  /// made now, after the asking device committed to its key. Throws
  /// [DeviceRequestGone] when the request is not there to answer, and an
  /// [OrchardServerException] ('answered' when someone else was first).
  Future<void> answerDeviceRequest(String orchardId, String requestId) async {
    final me = await _me();
    final record = (await LocalRecord.load(await databases.open(orchardId), orchardId)).latest;
    final listed = (await server.deviceRequests(orchardId)).waiting.where((r) => r.id == requestId).firstOrNull;
    final uid = listed?.uid;
    final commitment = listed?.commitment;
    if (listed == null || uid == null || commitment == null || !_decidesDevices(record, me.uid, uid)) {
      throw const DeviceRequestGone();
    }
    if (listed.stage != 'created') throw const OrchardServerException(409, 'answered');
    final nonce = newSpaceKey();
    _deviceRun.answers[requestId] = _Answer(uid: uid, commitment: commitment, nonce: nonce);
    try {
      await server.answerDeviceTrust(orchardId, requestId, nonce);
    } on OrchardServerException catch (e) {
      _deviceRun.answers.remove(requestId);
      // Ended meanwhile, or lost when ZestSSH Cloud was restored from a
      // backup: said as a request that is gone, not as teams switched off.
      if (e.notFound) throw const DeviceRequestGone();
      rethrow;
    } catch (_) {
      _deviceRun.answers.remove(requestId);
      rethrow;
    }
  }

  /// Approves the device behind the request [requestId], after the person
  /// here compared the words with the other screen: a device.trust entry
  /// for the very key those words were made from, signed by this device.
  /// Throws [DeviceRequestGone] when this device has no words for it, and as
  /// [change] does.
  Future<void> approveDevice(String orchardId, String requestId) async {
    final answer = _deviceRun.answers[requestId];
    final device = answer?.deviceKey;
    if (answer == null || device == null) throw const DeviceRequestGone();
    await _deviceChange(orchardId, RecordTypes.deviceTrust, uid: answer.uid, device: device);
    _deviceRun.answers.remove(requestId);
  }

  /// What this device has not told its person yet about devices in
  /// [orchardId], counted as told from now on: that this device was removed
  /// from it, and the requests of devices it could answer that are new
  /// ([requests], as just read with [deviceRequests]).
  Future<List<DeviceNotice>> takeDeviceNotices(String orchardId,
      {List<DeviceRequestView> requests = const []}) async {
    final out = <DeviceNotice>[];
    if (_deviceRun.removed.containsKey(orchardId)) {
      out.add(DeviceNotice(DeviceNoticeKind.removed, orchardName: _deviceRun.removed.remove(orchardId)));
    }
    final store = LocalStateStore(await databases.open(orchardId));
    final now = OrchardService._nowSeconds();
    final seen = <String, int>{};
    final kept = await store.read(_deviceSeenKey);
    if (kept != null) {
      try {
        for (final e in (jsonDecode(kept) as Map<String, dynamic>).entries) {
          if (e.value is int) seen[e.key] = e.value as int;
        }
      } catch (_) {
        // Not what this device wrote: told again, once.
      }
    }
    final before = jsonEncode(seen);
    final fresh = [
      for (final r in requests)
        if (r.stage == DeviceRequestStage.asks && !seen.containsKey(r.id)) r,
    ];
    for (final r in requests) {
      seen[r.id] = r.expiresAt;
    }
    seen.removeWhere((_, expiresAt) => expiresAt <= now);
    if (jsonEncode(seen) != before) await store.write(_deviceSeenKey, jsonEncode(seen));
    if (fresh.length == 1) {
      out.add(DeviceNotice(DeviceNoticeKind.asked, uid: fresh.single.uid, own: fresh.single.uid == (await _me()).uid));
    } else if (fresh.length > 1) {
      out.add(DeviceNotice(DeviceNoticeKind.asked, count: fresh.length));
    }
    return out;
  }

  /// Declines the request [requestId]. Nothing is kept of it.
  Future<void> declineDeviceRequest(String orchardId, String requestId) async {
    _deviceRun.answers.remove(requestId);
    try {
      await server.dropDeviceTrust(orchardId, requestId);
    } on OrchardServerException catch (e) {
      if (!e.notFound) rethrow;
    }
  }

  // ── Joining ──

  /// This device, offered for approval with the invitation [inviteId] to
  /// [orchardId] that [me] accepts: its key, and [me]'s account signature over
  /// the team, the account, that key and the invitation. The sign-in says which device it is first,
  /// where it can (an account in no team yet has nothing to say it to: the
  /// first list of its teams says it). Null where there is no device to
  /// offer, or anything about it fails: the invitation is accepted all the
  /// same, and the device asks to be approved as before.
  Future<JoinDevice?> _joinDevice(CrateAuthor me, String orchardId, String inviteId) async {
    final store = deviceKeys;
    if (store == null) return null;
    try {
      final identity = await store.forAccount(me.uid);
      try {
        await _nameThisDevice(me);
      } catch (e) {
        AppLogger.info('Orchards: the sign-in did not say which device it is before accepting (${errorKind(e)})');
      }
      final message =
          joinDeviceMessage(orchardId: orchardId, uid: me.uid, deviceKey: identity.publicKey, inviteId: inviteId);
      return JoinDevice(key: identity.publicKey, signature: await me.keys.sign(message));
    } catch (e) {
      AppLogger.warning('Orchards: this device was not offered for approval with the invitation (${errorKind(e)})');
      return null;
    }
  }

  /// The device [invite] offers, when its statement holds: signed by
  /// the very keys listed for whoever accepted it ([OrchardInvite.acceptedKeys],
  /// which the fingerprint comparison or the code's check covers and the
  /// member.add names), for this team, that account and this invitation (a
  /// code's own, for a use of a team code). ZestSSH Cloud passes it along and
  /// cannot put another device in its place. Never a device the team's record
  /// approved or took back for that account before, in an earlier membership
  /// too (found in a security review: a statement
  /// replayed from when they joined before re-approved a lost device whose
  /// approval had been taken back); that device asks to be approved as any
  /// other does.
  Future<Uint8List?> _joinDeviceChecked(String orchardId, OrchardInvite invite) async {
    final device = invite.acceptedDevice;
    final keys = invite.acceptedKeys;
    final uid = invite.acceptedUid;
    if (device == null || keys == null || uid == null || keys.uid != uid || !await keys.verify()) return null;
    final holds = await verifyJoinDevice(
      signingKey: keys.signingKey,
      orchardId: orchardId,
      uid: uid,
      deviceKey: device.key,
      inviteId: invite.code?.fromCode ?? invite.id,
      signature: device.signature,
    );
    if (!holds) return null;
    final key = deviceKeyText(device.key);
    final record = await LocalRecord.load(await databases.open(orchardId), orchardId);
    final seenBefore = record.entries.any((e) =>
        (e.type == RecordTypes.deviceTrust || e.type == RecordTypes.deviceRevoke) &&
        e.body['uid'] == uid &&
        e.body['device'] == key);
    if (seenBefore) {
      AppLogger.warning("Orchards: the device offered with an invitation was approved or taken back in the team's "
          'record before; it is not offered');
      return null;
    }
    return device.key;
  }

  /// The device to offer, ticked, as whoever accepted [invite] is let in from
  /// here, as the record writes its key; null for none. Only where the
  /// team lets in approved devices only (elsewhere nothing waits on it), the
  /// device's statement holds ([_joinDeviceChecked]), this device is
  /// approved, and the record will let this account approve their devices
  /// once they are in: an owner anyone's, an admin those below admin (as
  /// [_decidesDevices], for the role they are let in as). Never throws.
  Future<String?> joinDeviceOffer(String orchardId, OrchardInvite invite) async {
    try {
      final me = await author();
      final store = deviceKeys;
      if (me == null || store == null || invite.acceptedDevice == null) return null;
      final record = (await LocalRecord.load(await databases.open(orchardId), orchardId)).latest;
      if (!record.rules.trustedDevices) return null;
      final mine = record.members[me.uid];
      if (mine == null) return null;
      final decides = mine.role == FixedRoles.owner ||
          (mine.role == FixedRoles.admin && invite.role != FixedRoles.owner && invite.role != FixedRoles.admin);
      if (!decides || !record.devicesOf(me.uid).contains((await store.forAccount(me.uid)).key)) return null;
      final device = await _joinDeviceChecked(orchardId, invite);
      return device == null ? null : deviceKeyText(device);
    } catch (e) {
      AppLogger.info('Orchards: whether to offer the device of someone joining could not be told (${errorKind(e)})');
      return null;
    }
  }

  /// The device.trust that approves [device] of [uid], just added in [after]
  /// (the record after their member.add), made on this device and signed by
  /// it over the place it takes: next after the member.add, as
  /// [_deviceChange] makes one. Throws [OrchardRecordRefused] when the
  /// record's rules refuse it, and [DeviceCannotBeNamed].
  Future<RecordEntry> _joinDeviceEntry(CrateAuthor me, String orchardId, OrchardRecord after,
      {required String uid, required Uint8List device}) async {
    final identity = await _thisDevice(me);
    const type = RecordTypes.deviceTrust;
    final entry = await signRecordEntry(
      me.keys,
      orchardId: orchardId,
      seq: after.seq + 1,
      prev: after.head,
      type: type,
      by: me.uid,
      body: {
        'uid': uid,
        'device': deviceKeyText(device),
        'via': identity.key,
        'sig': base64Encode(await identity.sign(
            deviceEntryMessage(orchardId: orchardId, type: type, uid: uid, device: device, prev: after.head))),
      },
    );
    await OrchardService._probeOn(after, entry);
    return entry;
  }
}
