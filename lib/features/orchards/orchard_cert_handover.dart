part of 'orchard_service.dart';

// A certificate handed over with nothing of ZestSSH Cloud in between (3.0,
// so that a team reaches its hosts
// while the service is away). For a certificate the service only ever
// carried a member's request to an owner's device and the certificate back.
// Here the two travel as texts (certs/cert_handover.dart), from one screen to
// the other's camera or through whatever still works. A member's device
// makes the request as it makes any; an owner's device checks it as it
// checks any, shows its owner who asks for what, and signs with the routine
// that signs every certificate; the member's device keeps what comes back
// only when the record's authority signed it for its own key. The server is
// asked for the record when it answers, and for nothing it cannot do without.

/// Why a request handed to this device is not one it signs.
enum HandedRequestProblem {
  /// The text holds no request that reads.
  notARequest,

  /// The text is a certificate, the answer to a request.
  isACertificate,

  /// The request is for an Orchard that is not on this device.
  otherOrchard,

  /// This account is no owner of the Orchard.
  notAnOwner,

  /// This device is not let into the Orchard now: held back by a rule,
  /// turned away by the server, or closed by its offline limit.
  notLetIn,

  /// The key the Crate's certificates are signed with is not on this device.
  keyNotHere,

  /// The record does not allow the request: [HandedRequestRefused.refusal]
  /// says why.
  refused,
}

/// A request handed to this device that it does not sign.
class HandedRequestRefused implements Exception, HasTypeName {
  const HandedRequestRefused(this.problem, {this.refusal});

  final HandedRequestProblem problem;

  /// For [HandedRequestProblem.refused]: what the record has against it.
  final CertRequestRefusal? refusal;

  @override
  String toString() =>
      'A request handed over was not signed: ${problem.name}${refusal == null ? '' : ' (${refusal!.words})'}';

  @override
  String get typeName => 'HandedRequestRefused';
}

/// A request handed to an owner's device, checked against the record: what
/// its owner reads before signing.
class HandedRequestReview {
  const HandedRequestReview({
    required this.handed,
    required this.email,
    required this.role,
    required this.userNames,
    required this.validUntil,
    required this.fromServer,
  });

  final HandedRequest handed;

  String get orchardId => handed.orchardId;
  String get crateId => handed.crateId;

  /// The member who asks.
  String get uid => handed.request.uid;

  /// Their address as this device knows it, or null.
  final String? email;

  /// Their role: 'owner', 'admin' or the id of a role the owners made.
  final String role;

  /// The user names the certificate lets them sign in as.
  final List<String> userNames;

  /// When the certificate would run out (unix seconds): as long as the
  /// authority's certificates last, and no longer than their access does.
  final int validUntil;

  /// Whether it was checked against the record as the server has it now.
  /// False when the server could not be asked: it was then checked against
  /// the record this device last had, and what changed since is not in it.
  final bool fromServer;
}

/// Why a certificate handed to this device is not one it keeps.
enum HandedCertificateProblem {
  /// The text holds no certificate that reads.
  notACertificate,

  /// The text is a request, not the answer to one.
  isARequest,

  /// The certificate is for an Orchard that is not on this device.
  otherOrchard,

  /// The Crate has no certificate authority now, or it is off.
  noAuthority,

  /// It was not signed by the Crate's authority, or not for this device's
  /// key: another device's request, or another team's authority.
  notForThisDevice,

  /// It has run out.
  expired,
}

/// A certificate handed to this device that it does not keep.
class HandedCertificateRefused implements Exception, HasTypeName {
  const HandedCertificateRefused(this.problem);

  final HandedCertificateProblem problem;

  @override
  String toString() => 'A certificate handed over was not kept: ${problem.name}';

  @override
  String get typeName => 'HandedCertificateRefused';
}

extension OrchardCertHandover on OrchardService {
  /// The request this device hands to an owner's device for a certificate
  /// in [crateId]: checked as a login checks (the authority on, this account
  /// in the Crate, its role signing in as someone), made as any request is,
  /// and sent nowhere. Throws [TeamCertificateUnavailable] when no owner's
  /// device would sign it.
  ///
  /// A device that is not let into the Orchard now makes none (held back
  /// by a rule the server checks, or turned away by the server when asked):
  /// the server gives such a device no certificate, and what holds it back
  /// (a sign-in that falls short of a rule, say) is the server's to know.
  /// It is not in the record, so the owner's device that would sign cannot
  /// see it; the device that is held back is the one that can, and does not
  /// ask.
  Future<HandedRequest> handRequest(String orchardId, String crateId) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final read = await _recordOrLast(orchardId);
    if (read.turnedAway || !await OrchardTeamCertificates._letInHere(db)) {
      throw const TeamCertificateUnavailable(TeamCertificateProblem.heldBack);
    }
    final record = read.record;
    OrchardTeamCertificates._signsInAs(record, me.uid, crateId);
    final mine = record.members[me.uid];
    if (mine != null && mine.currentKeys.version != me.keys.version) {
      // The record does not have these keys: no owner's device would sign.
      throw const OrchardServerException(409, 'stale-account-keys');
    }
    final request =
        await _certRequest(orchardId, crateId, me, await teamDeviceKey(orchardId), OrchardService._nowSeconds());
    return HandedRequest(orchardId: orchardId, crateId: crateId, request: request);
  }

  /// What this device makes of [text], a request handed to it: checked
  /// against the record as any request is, with what its owner reads before
  /// signing. Nothing is signed yet. Throws [HandedRequestRefused].
  Future<HandedRequestReview> reviewHandedRequest(String text) async {
    final handed = HandedRequest.fromText(text);
    if (handed == null) {
      throw HandedRequestRefused(handedKindOf(text) == HandedKind.certificate
          ? HandedRequestProblem.isACertificate
          : HandedRequestProblem.notARequest);
    }
    return (await _checkHanded(handed)).review;
  }

  /// Signs the request [review] is of, and returns what to hand back. It is
  /// checked again as it is signed: what was read a moment ago may no longer
  /// hold. Throws [HandedRequestRefused].
  Future<HandedCertificate> signHandedRequest(HandedRequestReview review) async {
    final handed = review.handed;
    final checked = await _checkHanded(handed);
    final blob = await _issue(checked.db, checked.record, checked.ca, checked.authority, handed.request,
        crateId: handed.crateId, nowSeconds: checked.now);
    AppLogger.info('Orchards: a certificate was signed for a request handed to this device');
    return HandedCertificate(
        orchardId: handed.orchardId, crateId: handed.crateId, requestId: handed.request.id, certificate: blob);
  }

  /// [handed] checked as an owner's device checks any request, with all it
  /// takes to sign it.
  Future<
      ({
        HandedRequestReview review,
        AppDatabase db,
        OrchardRecord record,
        RecordCa ca,
        SSHKeyPair authority,
        int now,
      })> _checkHanded(HandedRequest handed) async {
    final orchardId = handed.orchardId;
    final crateId = handed.crateId;
    if (!(await databases.onDevice()).contains(orchardId)) {
      throw const HandedRequestRefused(HandedRequestProblem.otherOrchard);
    }
    final me = await _me();
    final AppDatabase db;
    final ({OrchardRecord record, bool turnedAway, bool fromServer}) read;
    try {
      db = await databases.open(orchardId);
      read = await _recordOrLast(orchardId);
    } on OrchardClosedOffline {
      throw const HandedRequestRefused(HandedRequestProblem.notLetIn);
    }
    final record = read.record;
    if (!record.isOwner(me.uid)) throw const HandedRequestRefused(HandedRequestProblem.notAnOwner);
    if (read.turnedAway || !await OrchardTeamCertificates._letInHere(db)) {
      throw const HandedRequestRefused(HandedRequestProblem.notLetIn);
    }
    final now = OrchardService._nowSeconds();
    final request = handed.request;
    final refusal =
        await certRequestRefusal(record, request, orchardId: orchardId, crateId: crateId, nowSeconds: now);
    if (refusal != null) throw HandedRequestRefused(HandedRequestProblem.refused, refusal: refusal);
    final authority = await authorityKey(orchardId, crateId, record: record);
    if (authority == null) throw const HandedRequestRefused(HandedRequestProblem.keyNotHere);
    final ca = record.crates[crateId]!.ca!;
    final member = record.members[request.uid]!;
    final lasts = now + ca.ttlMinutes * 60;
    final ends = record.accessEndsAt(request.uid, crateId, now, of: CrateSwitches.inCertificate);
    return (
      review: HandedRequestReview(
        handed: handed,
        email: await OrchardTeamCertificates._emailOf(db, request.uid),
        role: member.role,
        userNames: List.unmodifiable(ca.principals[member.role]!),
        validUntil: ends != null && ends < lasts ? ends : lasts,
        fromServer: read.fromServer,
      ),
      db: db,
      record: record,
      ca: ca,
      authority: authority,
      now: now,
    );
  }

  /// Takes in a certificate handed to this device: kept only when the
  /// record's authority signed it for this device's own key and it has not
  /// run out, and in place of the one already here only when it lasts
  /// longer. Returns what this device holds for the Crate afterwards.
  /// Throws [HandedCertificateRefused].
  Future<HeldCertificate> takeHandedCertificate(String text) async {
    final handed = HandedCertificate.fromText(text);
    if (handed == null) {
      throw HandedCertificateRefused(handedKindOf(text) == HandedKind.request
          ? HandedCertificateProblem.isARequest
          : HandedCertificateProblem.notACertificate);
    }
    final orchardId = handed.orchardId;
    final crateId = handed.crateId;
    if (!(await databases.onDevice()).contains(orchardId)) {
      throw const HandedCertificateRefused(HandedCertificateProblem.otherOrchard);
    }
    final db = await databases.open(orchardId);
    final record = (await _recordOrLast(orchardId)).record;
    final ca = record.crates[crateId]?.ca;
    if (ca == null || !ca.on) throw const HandedCertificateRefused(HandedCertificateProblem.noAuthority);
    final key = await teamDeviceKey(orchardId);
    final cert = await readTeamCertificate(handed.certificate, caPublicKey: ca.publicKey, subject: key.publicKey);
    if (cert == null) throw const HandedCertificateRefused(HandedCertificateProblem.notForThisDevice);
    if (cert.validBefore <= OrchardService._nowSeconds() + 60) {
      throw const HandedCertificateRefused(HandedCertificateProblem.expired);
    }
    final held = await heldCertificate(orchardId, crateId, record: record);
    if (held != null && held.validBefore >= cert.validBefore) return held;
    await LocalStateStore(db).write('$_heldPrefix$crateId', base64Encode(handed.certificate));
    return HeldCertificate(cert);
  }
}
