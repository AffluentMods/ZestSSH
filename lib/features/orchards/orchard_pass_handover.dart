part of 'orchard_service.dart';

// An offline pass handed over (3.0; rules/offline_pass.dart says what one is,
// certs/cert_handover.dart what the two texts look like). A member's device
// makes the request; an owner's device checks it against the record, shows
// its owner who asks for what, and signs a pass with the owner's account
// keys; the member's device keeps what comes back only when an owner its own
// record names signed it for its own key. Nothing of it is sent to ZestSSH
// Cloud. An owner's device asks the server for the record when it answers,
// so that it signs by the newest it can have; the member's device, which is
// offline when it needs a pass, goes by its own copy.

/// Why this device makes no request for an offline pass.
enum PassAskProblem {
  /// The Orchard is not on this device.
  otherOrchard,

  /// This device has nowhere to keep a key of its own, so a pass could not
  /// name it.
  noDeviceKey,
}

/// No request for an offline pass could be made.
class OfflinePassUnavailable implements Exception, HasTypeName {
  const OfflinePassUnavailable(this.problem);

  final PassAskProblem problem;

  @override
  String toString() => 'Orchards: no request for an offline pass (${problem.name})';

  @override
  String get typeName => 'OfflinePassUnavailable';
}

/// Why a request for an offline pass handed to this device is not one it
/// signs.
enum HandedPassRequestProblem {
  /// The text holds no request for a pass that reads.
  notARequest,

  /// The text is a pass, the answer to a request.
  isAPass,

  /// The request is for an Orchard that is not on this device.
  otherOrchard,

  /// This account is no owner of the Orchard.
  notAnOwner,

  /// This device is not let into the Orchard now: held back by a rule,
  /// turned away by the server, or closed by its offline limit.
  notLetIn,

  /// This device is past the limit the pass would lift (or, for a pass for
  /// all of the Orchard, past one of its limits): a device that is past a
  /// limit itself lifts it for nobody, whatever pass holds it open.
  closedHere,

  /// The request is this device's own: nobody signs their own pass.
  ownDevice,

  /// The record does not allow the request:
  /// [HandedPassRequestRefused.refusal] says why.
  refused,
}

/// A request for an offline pass handed to this device that it does not
/// sign.
class HandedPassRequestRefused implements Exception, HasTypeName {
  const HandedPassRequestRefused(this.problem, {this.refusal});

  final HandedPassRequestProblem problem;

  /// For [HandedPassRequestProblem.refused]: what the record has against it.
  final PassRequestRefusal? refusal;

  @override
  String toString() =>
      'A request for an offline pass was not signed: ${problem.name}${refusal == null ? '' : ' (${refusal!.words})'}';

  @override
  String get typeName => 'HandedPassRequestRefused';
}

/// A request for an offline pass handed to an owner's device, checked
/// against the record: what its owner reads before signing.
class HandedPassReview {
  const HandedPassReview({
    required this.handed,
    required this.email,
    required this.role,
    required this.deviceCode,
    required this.fromServer,
  });

  final HandedPassRequest handed;

  String get orchardId => handed.orchardId;

  /// The Crate asked for, or [kAllOfOrchard].
  String get crateId => handed.crateId;

  /// The member who asks.
  String get uid => handed.request.uid;

  /// Their address as this device knows it, or null.
  final String? email;

  /// Their role: 'owner', 'admin' or the id of a role the owners made.
  final String role;

  /// What people call the device the pass is for (deviceCode in
  /// devices/device_identity.dart): the member's screen shows the same
  /// eight characters.
  final String deviceCode;

  /// Whether it was checked against the record as the server has it now.
  /// False when the server could not be asked: it was then checked against
  /// the record this device last had, and what changed since is not in it.
  final bool fromServer;
}

/// Why an offline pass handed to this device is not one it keeps.
enum HandedPassProblem {
  /// The text holds no pass that reads.
  notAPass,

  /// The text is a request, not the answer to one.
  isARequest,

  /// The pass is for an Orchard that is not on this device.
  otherOrchard,

  /// The pass does not check out: [HandedPassRefused.refusal] says why.
  refused,
}

/// An offline pass handed to this device that it does not keep.
class HandedPassRefused implements Exception, HasTypeName {
  const HandedPassRefused(this.problem, {this.refusal});

  final HandedPassProblem problem;

  /// For [HandedPassProblem.refused]: what it has against the pass.
  final OfflinePassProblem? refusal;

  @override
  String toString() =>
      'An offline pass was not kept: ${problem.name}${refusal == null ? '' : ' (${refusal!.words})'}';

  @override
  String get typeName => 'HandedPassRefused';
}

/// What this device holds after it took a pass in.
class TakenPass {
  const TakenPass({
    required this.orchardId,
    required this.crateId,
    required this.until,
    required this.orchardClosed,
    this.crateName,
  });

  final String orchardId;

  /// What it is for: a Crate, or [kAllOfOrchard].
  final String crateId;

  /// The Crate's name as this device has it, read while the pass was
  /// checked: an Orchard that is closed here lists no Crates, so whatever
  /// says what was taken could not name it otherwise. Null for a pass for
  /// all of the Orchard, and for a Crate this device has no name for.
  final String? crateName;

  /// The last second the pass this device now holds for it is good
  /// (unix seconds): the one taken, or a longer one it held already.
  final int until;

  /// The Orchard itself is closed on this device by its own offline limit,
  /// which a pass for one Crate does not lift: the pass is kept for when
  /// the Orchard opens again.
  final bool orchardClosed;
}

extension OrchardPassHandover on OrchardService {
  /// The request this device hands to an owner's device for an offline pass
  /// for [crateId] of [orchardId] ([kAllOfOrchard] for all of it), signed
  /// with this account's keys and naming this device's own key. Sent
  /// nowhere. Made whenever the Orchard is on this device, also while the
  /// Orchard is closed here by its offline limit: nothing of the Orchard's
  /// database is needed for it. Throws [OfflinePassUnavailable].
  Future<HandedPassRequest> handPassRequest(String orchardId, {String crateId = kAllOfOrchard}) async {
    if (!(await databases.onDevice()).contains(orchardId)) {
      throw const OfflinePassUnavailable(PassAskProblem.otherOrchard);
    }
    final me = await _me();
    final device = await deviceKeys?.forAccount(me.uid);
    if (device == null) throw const OfflinePassUnavailable(PassAskProblem.noDeviceKey);
    final askedAt = OrchardService._nowSeconds();
    final message = passRequestMessage(
      orchardId: orchardId,
      crateId: crateId,
      uid: me.uid,
      keyVersion: me.keys.version,
      deviceKey: device.publicKey,
      askedAt: askedAt,
    );
    return HandedPassRequest(
      orchardId: orchardId,
      crateId: crateId,
      request: PassRequest(
        uid: me.uid,
        keyVersion: me.keys.version,
        deviceKey: device.publicKey,
        askedAt: askedAt,
        signature: await me.keys.sign(message),
      ),
    );
  }

  /// What people call this device, for the account that is signed in: the
  /// eight characters an owner's screen shows for a request made here. Null
  /// where this device has no key of its own.
  Future<String?> ownDeviceCode() async {
    final device = await deviceKeys?.forAccount((await _me()).uid);
    return device == null ? null : deviceCode(device.key);
  }

  /// What this device makes of [text], a request for an offline pass
  /// handed to it: checked against the record, with what its owner reads
  /// before signing. Nothing is signed yet. Throws
  /// [HandedPassRequestRefused].
  Future<HandedPassReview> reviewPassRequest(String text) async {
    final handed = HandedPassRequest.fromText(text);
    if (handed == null) {
      throw HandedPassRequestRefused(handedKindOf(text) == HandedKind.pass
          ? HandedPassRequestProblem.isAPass
          : HandedPassRequestProblem.notARequest);
    }
    return (await _checkPassRequest(handed)).review;
  }

  /// Signs a pass of [hours] for the request [review] is of, and returns
  /// what to hand back. The request is checked again as the pass is signed:
  /// what was read a moment ago may no longer hold. No longer than
  /// [kOfflinePassMax], whatever is asked. Throws
  /// [HandedPassRequestRefused].
  Future<HandedPass> signPass(HandedPassReview review, {required int hours}) async {
    final handed = review.handed;
    final checked = await _checkPassRequest(handed);
    final me = checked.me;
    final madeAt = checked.now;
    final lasts = math.min(math.max(hours, 1) * Duration.secondsPerHour, kOfflinePassMax.inSeconds);
    final until = madeAt + lasts;
    final message = offlinePassMessage(
      orchardId: handed.orchardId,
      crateId: handed.crateId,
      uid: handed.request.uid,
      deviceKey: handed.request.deviceKey,
      until: until,
      madeAt: madeAt,
      by: me.uid,
      byKeyVersion: me.keys.version,
    );
    AppLogger.info('Orchards: an offline pass was signed for a request handed to this device');
    return HandedPass(
      orchardId: handed.orchardId,
      crateId: handed.crateId,
      pass: OfflinePass(
        uid: handed.request.uid,
        deviceKey: handed.request.deviceKey,
        until: until,
        madeAt: madeAt,
        by: me.uid,
        byKeyVersion: me.keys.version,
        signature: await me.keys.sign(message),
      ),
    );
  }

  /// [handed] checked as an owner's device checks it, with what it takes
  /// to sign.
  Future<({HandedPassReview review, CrateAuthor me, int now})> _checkPassRequest(HandedPassRequest handed) async {
    final orchardId = handed.orchardId;
    final crateId = handed.crateId;
    if (!(await databases.onDevice()).contains(orchardId)) {
      throw const HandedPassRequestRefused(HandedPassRequestProblem.otherOrchard);
    }
    final me = await _me();
    final AppDatabase db;
    final ({OrchardRecord record, bool turnedAway, bool fromServer}) read;
    try {
      db = await databases.open(orchardId);
      read = await _recordOrLast(orchardId);
    } on OrchardClosedOffline {
      throw const HandedPassRequestRefused(HandedPassRequestProblem.notLetIn);
    }
    final record = read.record;
    if (!record.isOwner(me.uid)) throw const HandedPassRequestRefused(HandedPassRequestProblem.notAnOwner);
    if (read.turnedAway || !await OrchardTeamCertificates._letInHere(db)) {
      throw const HandedPassRequestRefused(HandedPassRequestProblem.notLetIn);
    }
    // A device that is past a limit itself lifts it for nobody, whatever
    // pass holds it open here: it has not heard from the Orchard for too
    // long to speak for it. A pass for all of the Orchard lifts every limit
    // of it, so this device must be past none.
    final reached = await limitsReachedIn(db, orchardHours: record.rules.offlineHours);
    if (crateId == kAllOfOrchard
        ? reached.isNotEmpty
        : reached.contains(crateId) || reached.contains(kAllOfOrchard)) {
      throw const HandedPassRequestRefused(HandedPassRequestProblem.closedHere);
    }
    final request = handed.request;
    final mine = await deviceKeys?.forAccount(me.uid);
    if (mine != null && deviceKeyText(request.deviceKey) == mine.key) {
      throw const HandedPassRequestRefused(HandedPassRequestProblem.ownDevice);
    }
    final now = OrchardService._nowSeconds();
    final refusal = await passRequestRefusal(record, request, orchardId: orchardId, crateId: crateId, nowSeconds: now);
    if (refusal != null) throw HandedPassRequestRefused(HandedPassRequestProblem.refused, refusal: refusal);
    return (
      review: HandedPassReview(
        handed: handed,
        email: await OrchardTeamCertificates._emailOf(db, request.uid),
        role: record.members[request.uid]!.role,
        deviceCode: deviceCode(deviceKeyText(request.deviceKey)),
        fromServer: read.fromServer,
      ),
      me: me,
      now: now,
    );
  }

  /// Takes in an offline pass handed to this device: kept only when an
  /// owner this device's own record names signed it for this account and
  /// this device's key, and it has not run out; and in place of the one
  /// already here only when it lasts longer. An Orchard closed here by its
  /// offline limit is opened for the check, and stays open when the pass is
  /// for all of it; it is closed again when the pass is refused, or is for
  /// one Crate only. Throws [HandedPassRefused].
  Future<TakenPass> takePass(String text) async {
    final handed = HandedPass.fromText(text);
    if (handed == null) {
      throw HandedPassRefused(handedKindOf(text) == HandedKind.passRequest
          ? HandedPassProblem.isARequest
          : HandedPassProblem.notAPass);
    }
    final orchardId = handed.orchardId;
    final crateId = handed.crateId;
    if (!(await databases.onDevice()).contains(orchardId)) {
      throw const HandedPassRefused(HandedPassProblem.otherOrchard);
    }
    final me = await _me();
    final device = await deviceKeys?.forAccount(me.uid);
    if (device == null) {
      throw const HandedPassRefused(HandedPassProblem.refused, refusal: OfflinePassProblem.notForThisDevice);
    }
    final wasClosed = databases.closedOffline.contains(orchardId);
    if (wasClosed) databases.reopenOne(orchardId);
    var keepOpen = false;
    try {
      final db = await databases.open(orchardId);
      final record = (await LocalRecord.load(db, orchardId)).latest;
      final now = OrchardService._nowSeconds();
      final problem = await offlinePassProblem(record, handed.pass,
          orchardId: orchardId, crateId: crateId, uid: me.uid, deviceKey: device.publicKey, nowSeconds: now);
      if (problem != null) throw HandedPassRefused(HandedPassProblem.refused, refusal: problem);
      final store = LocalStateStore(db);
      // What has run out is not kept for ever.
      for (final key in await store.keysWithPrefix(kOfflinePassState)) {
        final old = HeldPass.fromStored(await store.read(key));
        if (old == null || old.until <= now) await store.remove(key);
      }
      final held = await heldPassIn(db, crateId);
      var until = handed.pass.until;
      if (held != null && held.until >= until) {
        until = held.until;
      } else {
        await store.write(
            '$kOfflinePassState$crateId',
            HeldPass(until: handed.pass.until, madeAt: handed.pass.madeAt, by: handed.pass.by).toStored());
      }
      AppLogger.info('Orchards: an offline pass was taken in');
      keepOpen = crateId == kAllOfOrchard;
      // (No Crate goes by the id that stands for all of the Orchard.)
      final named = await db
          .customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?', variables: [Variable(crateId)])
          .getSingleOrNull();
      return TakenPass(
        orchardId: orchardId,
        crateId: crateId,
        until: until,
        orchardClosed: wasClosed && !keepOpen,
        crateName: named?.read<String?>('name'),
      );
    } finally {
      if (wasClosed && !keepOpen) await databases.closeOffline(orchardId);
      // What the limits close is looked at again, and the lists told.
      onPass?.call();
    }
  }
}
