part of 'orchard_service.dart';

// Certificates from a Crate's authority (3.0). Each device keeps
// an SSH key of its own for each Orchard (in the Orchard's database, never
// synced, never sent: only its public half is), asks for a certificate for
// it with a request signed by the account's keys, and connects to the
// Crate's hosts with the key and the certificate. Owners' devices sign what
// waits, each request checked against the record first: the member's
// current keys signed it, the member can open the Crate now, their role
// signs in as someone. Certificates are renewed once half their time has
// passed, whenever the app syncs.

/// Where an Orchard's database keeps this device's SSH key for certificates.
const String _deviceKeyState = 'certs.device_key';

/// This device's certificate for a Crate, under this prefix and the Crate's id.
const String _heldPrefix = 'certs.crate.';

/// This device's request waiting in a Crate, under this prefix and the Crate's id.
const String _askedPrefix = 'certs.asked.';

/// The requests an owner's device signed, kept two days: it never signs the
/// same one twice, whatever the server lists.
const String _signedState = 'certs.signed';

/// How long a request is waited on before this device asks again.
const int _askAgainSeconds = 600;

/// A login needed a certificate from the team, and nobody was asked: the
/// app knows that ZestSSH Cloud is not answering just now, and a request
/// would only have kept the person waiting to be told the same.
class TeamCertificateNotAsked implements Exception, HasTypeName {
  const TeamCertificateNotAsked();

  @override
  String toString() => 'ZestSSH Cloud is not answering: no certificate was asked for';

  @override
  String get typeName => 'TeamCertificateNotAsked';
}

/// Why this device has no certificate for a Crate's hosts now.
enum TeamCertificateProblem {
  /// The Crate's certificate authority is off, or it has none.
  noAuthority,

  /// This account cannot open the Crate now.
  noAccess,

  /// This account's role signs in as nobody on the Crate's hosts.
  noUserNames,

  /// Its role does not sign in as the user name the key names.
  notThisUserName,

  /// Asked, and no owner's device has signed it yet.
  waitingForOwner,

  /// This device is not let into the Orchard now (held back by a rule,
  /// turned away by the server): it gets no certificate from the server,
  /// and hands no request to an owner.
  heldBack,
}

class TeamCertificateUnavailable implements Exception, HasTypeName {
  const TeamCertificateUnavailable(this.problem, {this.userNames = const []});

  final TeamCertificateProblem problem;

  /// For [TeamCertificateProblem.notThisUserName]: the ones the role has.
  final List<String> userNames;

  @override
  String toString() => 'Orchards: no certificate (${problem.name})';

  @override
  String get typeName => 'TeamCertificateUnavailable';
}

/// [principals] as a ca.set entry carries them: each role's user names
/// sorted, without repeats; roles with none left out.
Map<String, List<String>> certPrincipalsBody(Map<String, List<String>> principals) => {
      for (final e in principals.entries)
        if (e.value.isNotEmpty) e.key: (e.value.toSet().toList()..sort()),
    };

/// A certificate this device holds for a Crate, checked against the record.
class HeldCertificate {
  const HeldCertificate(this.certificate);

  final SshCertificate certificate;

  int get validAfter => certificate.validAfter;
  int get validBefore => certificate.validBefore;

  /// Half its time gone: time to ask for the next one.
  bool dueAt(int nowSeconds) => nowSeconds >= validAfter + (validBefore - validAfter) ~/ 2;
}

extension OrchardTeamCertificates on OrchardService {
  /// This device's SSH key for [orchardId]'s certificates, made the first
  /// time it is needed.
  Future<TeamDeviceKey> teamDeviceKey(String orchardId) async {
    final store = LocalStateStore(await databases.open(orchardId));
    final raw = await store.read(_deviceKeyState);
    if (raw != null) {
      try {
        return await TeamDeviceKey.fromSeed(base64Decode((jsonDecode(raw) as Map)['seed'] as String));
      } catch (e) {
        AppLogger.warning('Orchards: the device key for certificates could not be read, a new one is made ($e)');
      }
    }
    final key = await TeamDeviceKey.generate();
    await store.write(_deviceKeyState, jsonEncode({'seed': base64Encode(key.seed)}));
    return key;
  }

  /// The certificate this device holds for [crateId] that the record's
  /// authority signed now, for this device's key, and has not expired
  /// (a minute to spare); or null.
  Future<HeldCertificate?> heldCertificate(String orchardId, String crateId, {OrchardRecord? record}) async {
    final db = await databases.open(orchardId);
    final raw = await LocalStateStore(db).read('$_heldPrefix$crateId');
    if (raw == null) return null;
    final latest = record ?? (await LocalRecord.load(db, orchardId)).latest;
    final ca = latest.crates[crateId]?.ca;
    if (ca == null || !ca.on) return null;
    final Uint8List blob;
    try {
      blob = base64Decode(raw);
    } on FormatException {
      return null;
    }
    final key = await teamDeviceKey(orchardId);
    final cert = await readTeamCertificate(blob, caPublicKey: ca.publicKey, subject: key.publicKey);
    if (cert == null || cert.validBefore <= OrchardService._nowSeconds() + 60) return null;
    return HeldCertificate(cert);
  }

  /// What connects to [crateId]'s hosts as [userName]: this device's key
  /// with a certificate from the Crate's authority. Without a good one it
  /// asks, and waits up to [wait] for an owner's device to sign it; with
  /// [ask] false (nobody is there to wait: the monitor, automations) it uses
  /// only what this device holds and the record as it last had it, and asks
  /// nothing of the server. Throws [TeamCertificateUnavailable] when there is
  /// none to be had.
  Future<SSHKeyPair> teamCertificateKey(
    String orchardId,
    String crateId, {
    required String userName,
    bool ask = true,
    Duration wait = const Duration(seconds: 20),
    void Function(String line)? onLog,
  }) async {
    final me = await _me();
    final read = ask
        ? await _recordOrLast(orchardId)
        : (
            record: (await LocalRecord.load(await databases.open(orchardId), orchardId)).latest,
            turnedAway: false,
            fromServer: false,
          );
    final record = read.record;
    final names = _signsInAs(record, me.uid, crateId);
    if (!names.contains(userName)) {
      throw TeamCertificateUnavailable(TeamCertificateProblem.notThisUserName, userNames: names);
    }
    final key = await teamDeviceKey(orchardId);
    SSHKeyPair? usable(HeldCertificate? held) =>
        held != null && held.certificate.principals.contains(userName)
            ? SshCertificateKeyPair(innerKey: key.keyPair, certificate: held.certificate)
            : null;

    final now = usable(await heldCertificate(orchardId, crateId, record: record));
    if (now != null) return now;
    // An owner whose device holds the authority's key signs for it here and
    // now: nothing is asked of the server, and nobody is waited for. Not a
    // device the server just turned away: what it last knew stands in for
    // an answer the server could not give, never for one it gave.
    if (!read.turnedAway && await _signOwnCertificate(orchardId, crateId, record: record)) {
      final own = usable(await heldCertificate(orchardId, crateId, record: record));
      if (own != null) {
        onLog?.call('identity: Certificate signed on this device (an owner\'s)');
        return own;
      }
    }
    if (!ask) throw const TeamCertificateUnavailable(TeamCertificateProblem.waitingForOwner);
    if (cloudAway?.call() ?? false) throw const TeamCertificateNotAsked();
    onLog?.call('identity: Asking the team for a certificate...');
    await askForCertificate(orchardId, crateId, record: record);
    final deadline = DateTime.now().add(wait);
    while (true) {
      await collectCertificates(orchardId, record: record, only: {crateId});
      final got = usable(await heldCertificate(orchardId, crateId, record: record));
      if (got != null) {
        onLog?.call('identity: Certificate signed by an owner');
        return got;
      }
      if (!DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const TeamCertificateUnavailable(TeamCertificateProblem.waitingForOwner);
  }

  /// The user names [uid]'s role signs in as on the hosts of [crateId], by
  /// [record]. Throws [TeamCertificateUnavailable] when the Crate signs no
  /// certificates now, the account cannot open it now, or its role signs in
  /// as nobody: no owner's device signs a request then, so none is made.
  static List<String> _signsInAs(OrchardRecord record, String uid, String crateId) {
    final ca = record.crates[crateId]?.ca;
    if (ca == null || !ca.on) throw const TeamCertificateUnavailable(TeamCertificateProblem.noAuthority);
    final member = record.members[uid];
    if (member == null || !(record.entitlementsAt(OrchardService._nowSeconds())[uid]?.contains(crateId) ?? false)) {
      throw const TeamCertificateUnavailable(TeamCertificateProblem.noAccess);
    }
    final names = ca.principals[member.role] ?? const <String>[];
    if (names.isEmpty) throw const TeamCertificateUnavailable(TeamCertificateProblem.noUserNames);
    return names;
  }

  /// Asks for a certificate for this device's key in [crateId], unless a
  /// request for it is already waiting (for less than ten minutes).
  Future<void> askForCertificate(String orchardId, String crateId, {OrchardRecord? record}) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final store = LocalStateStore(db);
    final key = await teamDeviceKey(orchardId);
    final now = OrchardService._nowSeconds();
    final asked = await _asked(store, crateId);
    if (asked != null &&
        now - asked.at < _askAgainSeconds &&
        asked.keyVersion == me.keys.version &&
        OrchardService._eq(asked.key, key.publicKey)) {
      return;
    }
    final latest = record ?? await _recordForCertificates(orchardId);
    final mine = latest.members[me.uid];
    if (mine != null && mine.currentKeys.version != me.keys.version) {
      // The record does not have these keys yet: the server would refuse.
      throw const OrchardServerException(409, 'stale-account-keys');
    }
    final request = await _certRequest(orchardId, crateId, me, key, now);
    await server.askCertificate(crateId, request);
    await store.write(
      '$_askedPrefix$crateId',
      jsonEncode({'id': request.id, 'at': now, 'key_version': me.keys.version, 'key': base64Encode(key.publicKey)}),
    );
  }

  /// This device's request for a certificate for [key] in [crateId], signed
  /// with the account's keys.
  Future<CertRequest> _certRequest(
      String orchardId, String crateId, CrateAuthor me, TeamDeviceKey key, int now) async {
    final id = const Uuid().v4();
    final unsigned = CertRequest(
      id: id,
      uid: me.uid,
      keyVersion: me.keys.version,
      sshPublicKey: key.publicKey,
      requestedAt: now,
      signature: Uint8List(64),
    );
    // Which device asks, and its own signature under the request: an
    // owner's device signs only for a device the record lists, where the
    // Orchard lets in approved devices only.
    final message = unsigned.message(orchardId: orchardId, crateId: crateId);
    final device = await deviceKeys?.forAccount(me.uid);
    return CertRequest(
      id: id,
      uid: me.uid,
      keyVersion: me.keys.version,
      sshPublicKey: key.publicKey,
      requestedAt: now,
      signature: await me.keys.sign(message),
      deviceKey: device?.publicKey,
      deviceSignature: device == null ? null : await device.sign(certDeviceMessage(message)),
    );
  }

  /// Signs, on this device, a certificate for this device's own key in
  /// [crateId], when this account is an owner and the authority's key is
  /// here. An owner holds the key every certificate of the Crate is signed
  /// with, so they need nobody to sign for them and no server to carry a
  /// request: an owner can reach the Crate's hosts whatever ZestSSH Cloud is
  /// doing (SSH needs to work for teams).
  ///
  /// The request is made and checked as anybody's is ([certRequestProblem]):
  /// the record has this account's current keys, lets it into the Crate
  /// now, its role signs in as someone, and where only approved devices are
  /// let in, this device is one. The certificate is what any owner's device
  /// would have signed for it. Returns whether one was signed and kept.
  ///
  /// Nothing is signed on a device its own copy of the Orchard says is not
  /// let in ([_letInHere]): the server gives such a device no certificate,
  /// and holding the authority's key from before changes nothing about
  /// that. What this cannot know is what happened since the device last
  /// heard from ZestSSH Cloud: an owner who was made a member, or a device
  /// that was taken out, signs for itself until it learns of it (at its
  /// next look at the server, a quarter of an hour at most while it can
  /// reach it), as it could with any other tool, since it holds the key.
  /// Only a new key for the authority ends that
  /// ([authoritiesNeedingNewKey]), and an offline limit bounds it.
  Future<bool> _signOwnCertificate(String orchardId, String crateId, {required OrchardRecord record}) async {
    final me = await _me();
    if (!record.isOwner(me.uid)) return false;
    final ca = record.crates[crateId]?.ca;
    if (ca == null) return false;
    final db = await databases.open(orchardId);
    if (!await _letInHere(db)) return false;
    final authority = await authorityKey(orchardId, crateId, record: record);
    if (authority == null) return false;
    final now = OrchardService._nowSeconds();
    final request = await _certRequest(orchardId, crateId, me, await teamDeviceKey(orchardId), now);
    final problem = await certRequestProblem(record, request, orchardId: orchardId, crateId: crateId, nowSeconds: now);
    if (problem != null) {
      AppLogger.warning('Orchards: this device did not sign its own certificate ($problem)');
      return false;
    }
    final blob = await _issue(db, record, ca, authority, request, crateId: crateId, nowSeconds: now);
    final store = LocalStateStore(db);
    await store.write('$_heldPrefix$crateId', base64Encode(blob));
    // What was asked of the others is no longer waited on.
    await store.remove('$_askedPrefix$crateId');
    return true;
  }

  /// Takes in the certificates the server has for this device's requests
  /// ([only] those Crates, else every Crate this device asked in): each
  /// kept only when the record's authority signed it for this device's
  /// key. Returns the Crates that got a newer one.
  Future<Set<String>> collectCertificates(String orchardId, {OrchardRecord? record, Set<String>? only}) async {
    final db = await databases.open(orchardId);
    final store = LocalStateStore(db);
    final crates = only ?? {for (final k in await store.keysWithPrefix(_askedPrefix)) k.substring(_askedPrefix.length)};
    if (crates.isEmpty) return const {};
    final latest = record ?? await _recordForCertificates(orchardId);
    final key = await teamDeviceKey(orchardId);
    final now = OrchardService._nowSeconds();
    final got = <String>{};
    for (final crateId in crates) {
      final ca = latest.crates[crateId]?.ca;
      if (ca == null || !ca.on) continue;
      final List<IssuedCertificate> issued;
      try {
        issued = await server.myCertificates(crateId);
      } catch (e) {
        AppLogger.info('Orchards: certificates could not be fetched ($e)');
        continue;
      }
      final held = await heldCertificate(orchardId, crateId, record: latest);
      SshCertificate? best;
      Uint8List? bestBlob;
      for (final c in issued) {
        if (!OrchardService._eq(c.sshPublicKey, key.publicKey)) continue;
        final cert = await readTeamCertificate(c.certificate, caPublicKey: ca.publicKey, subject: key.publicKey);
        if (cert == null || cert.validBefore <= now + 60) continue;
        if (best == null || cert.validBefore > best.validBefore) {
          best = cert;
          bestBlob = c.certificate;
        }
      }
      if (best == null || bestBlob == null) continue;
      if (held != null && held.validBefore >= best.validBefore) continue;
      await store.write('$_heldPrefix$crateId', base64Encode(bestBlob));
      final asked = await _asked(store, crateId);
      if (asked != null && issued.any((c) => c.requestId == asked.id)) await store.remove('$_askedPrefix$crateId');
      got.add(crateId);
    }
    return got;
  }

  /// Signs, as an owner, every request waiting in [orchardId]'s Crates that
  /// the record allows (see [certRequestProblem]), with each Crate's
  /// authority as its key Crate keeps it on this device. Returns how many
  /// it signed.
  Future<int> signWaitingCertificates(String orchardId) async {
    final me = await _me();
    final record = await _latestRecord(orchardId);
    if (!record.isOwner(me.uid)) return 0;
    final db = await databases.open(orchardId);
    final store = LocalStateStore(db);
    final now = OrchardService._nowSeconds();
    final signed = await _signedIds(store, now);
    var count = 0;
    for (final crate in record.crates.values) {
      final ca = crate.ca;
      if (ca == null || !ca.on) continue;
      final List<CertRequest> waiting;
      try {
        waiting = await server.waitingCertificates(crate.id);
      } catch (e) {
        AppLogger.info('Orchards: waiting certificate requests could not be read ($e)');
        continue;
      }
      if (waiting.isEmpty) continue;
      final authority = await authorityKey(orchardId, crate.id, record: record);
      if (authority == null) {
        AppLogger.warning('Orchards: a Crate\'s certificate authority key is not on this device yet');
        continue;
      }
      for (final request in waiting) {
        if (signed.containsKey(request.id)) continue;
        final problem =
            await certRequestProblem(record, request, orchardId: orchardId, crateId: crate.id, nowSeconds: now);
        if (problem != null) {
          AppLogger.warning('Orchards: a certificate request was not signed ($problem)');
          continue;
        }
        final blob = await _issue(db, record, ca, authority, request, crateId: crate.id, nowSeconds: now);
        try {
          await server.signCertificate(crate.id, request.id, blob);
          count++;
        } on OrchardServerException catch (e) {
          if (e.code != 'already-signed') {
            AppLogger.warning('Orchards: a signed certificate was not taken ($e)');
            continue;
          }
        }
        signed[request.id] = now;
        await store.write(_signedState, jsonEncode(signed));
      }
    }
    return count;
  }

  /// The certificate [authority] ([ca], [crateId]'s in [record]) gives
  /// [request], which [certRequestProblem] let through: the user names the
  /// member's role signs in as, what they may do in the Crate now, with what
  /// they hold until a set time, for as long as the authority's
  /// certificates last and no longer than that access does. One routine
  /// for what an owner's device signs for the others and for itself.
  Future<Uint8List> _issue(
    AppDatabase db,
    OrchardRecord record,
    RecordCa ca,
    SSHKeyPair authority,
    CertRequest request, {
    required String crateId,
    required int nowSeconds,
  }) async {
    final member = record.members[request.uid]!;
    return issueTeamCertificate(
      ca: authority,
      request: request,
      principals: ca.principals[member.role]!,
      extensions: certExtensions(record.switchesAt(request.uid, crateId, nowSeconds)),
      ttlMinutes: ca.ttlMinutes,
      nowSeconds: nowSeconds,
      notAfter: record.accessEndsAt(request.uid, crateId, nowSeconds, of: CrateSwitches.inCertificate),
      keyId: '${await _emailOf(db, request.uid) ?? request.uid} (zestssh ${request.id})',
    );
  }

  /// [crateId]'s authority as this device holds it: the key in the
  /// authority's key Crate whose public half is the one the record names
  /// now. Null when that key is not on this device.
  Future<SSHKeyPair?> authorityKey(String orchardId, String crateId, {OrchardRecord? record}) async {
    final db = await databases.open(orchardId);
    final latest = record ?? (await LocalRecord.load(db, orchardId)).latest;
    final ca = latest.crates[crateId]?.ca;
    if (ca == null) return null;
    // An authority signs nothing on a device where its Crate, or the Crate
    // that keeps its key, is closed by an offline limit of its own: as far
    // as this device goes, the key is not here.
    final closed = await closedCratesIn(db);
    if (closed.containsKey(crateId) || closed.containsKey(ca.keyCrate)) return null;
    final rows = await db.customSelect(
      'SELECT i.id, i.public_key_data FROM identities i '
      "JOIN crate_items_meta m ON m.kind = 'key' AND m.item_key = i.id "
      'WHERE m.crate_id = ?',
      variables: [Variable(ca.keyCrate)],
    ).get();
    for (final r in rows) {
      final public = _ed25519OfLine(r.read<String?>('public_key_data'));
      if (public == null || !OrchardService._eq(public, ca.publicKey)) continue;
      final pem = await OrchardIdentitySecrets(db).read(r.read<String>('id'), IdentitySecret.privateKey);
      if (pem == null) continue;
      try {
        for (final pair in SSHKeyPair.fromPem(pem)) {
          if (pair is OpenSSHEd25519KeyPair && OrchardService._eq(pair.publicKey, ca.publicKey)) return pair;
        }
      } catch (e) {
        AppLogger.warning('Orchards: a certificate authority key could not be read ($e)');
      }
    }
    return null;
  }

  /// One round after a sync: an owner's device signs what waits, this device
  /// takes in what was signed for it and asks again for certificates past
  /// half their time. Forgets certificates of Crates whose authority went.
  /// Never throws: certificates are never why a sync fails.
  Future<void> certificateRound(String orchardId) async {
    try {
      final db = await databases.open(orchardId);
      final store = LocalStateStore(db);
      final record = await _latestRecord(orchardId);
      if (!record.crates.values.any((c) => c.ca?.on ?? false) &&
          (await store.keysWithPrefix(_heldPrefix)).isEmpty &&
          (await store.keysWithPrefix(_askedPrefix)).isEmpty) {
        return;
      }
      await signWaitingCertificates(orchardId);
      await collectCertificates(orchardId, record: record);
      final now = OrchardService._nowSeconds();
      for (final k in await store.keysWithPrefix(_heldPrefix)) {
        final crateId = k.substring(_heldPrefix.length);
        final ca = record.crates[crateId]?.ca;
        if (ca == null || !ca.on) {
          await store.remove(k);
          await store.remove('$_askedPrefix$crateId');
          continue;
        }
        final held = await heldCertificate(orchardId, crateId, record: record);
        if (held == null || held.dueAt(now)) {
          try {
            // An owner's device signs its next one itself.
            if (!await _signOwnCertificate(orchardId, crateId, record: record)) {
              await askForCertificate(orchardId, crateId, record: record);
            }
          } catch (e) {
            AppLogger.info('Orchards: a certificate could not be asked for again ($e)');
          }
        }
      }
    } catch (e) {
      AppLogger.info('Orchards: certificates were not brought up to date ($e)');
    }
  }

  /// Gives [crateId] a certificate authority, or its authority a new key
  /// (owners): a new Ed25519 key, kept as a key named [keyLabel] in
  /// [keyCrate] (a Crate only owners open), and the record's ca.set naming
  /// its public key, how long certificates last ([ttlMinutes]) and the user
  /// names each role signs in as ([principals]; a role left out, or given
  /// none, gets no certificate). The next sync takes the key to the other
  /// owners' devices. After a new key, the old one's copy leaves the key
  /// Crate: it signs nothing any more.
  Future<void> setAuthorityKey(
    String orchardId,
    String crateId, {
    required String keyCrate,
    required int ttlMinutes,
    required Map<String, List<String>> principals,
    required String keyLabel,
  }) async {
    final names = certPrincipalsBody(principals);
    if (names.isEmpty) throw const OrchardRecordRefused('no role signs in as anyone');
    final record = await _latestRecord(orchardId);
    final old = record.crates[crateId]?.ca;
    final generation = old == null ? 1 : old.generation + 1;
    final key = await TeamDeviceKey.generate();
    final db = await databases.open(orchardId);
    final comment = 'zestssh-ca-$generation';
    final line = OpenSSHKeySerializer.encodeEd25519Public(key.publicKey, comment);
    final id = const Uuid().v4();
    await db.identitiesDao.insertIdentity(IdentitiesCompanion(
      id: Value(id),
      label: Value(keyLabel),
      username: const Value('ca'),
      authMethod: const Value('publicKey'),
      keyType: const Value('ed25519'),
      publicKeyFingerprint: Value(OpenSSHKeySerializer.fingerprintFromPublicKeyString(line)),
      publicKeyData: Value(line),
      isDefault: const Value(false),
      createdAt: Value(DateTime.now()),
    ));
    await OrchardIdentitySecrets(db)
        .write(id, IdentitySecret.privateKey, OpenSSHKeySerializer.encodeEd25519Private(key.seed, key.publicKey, comment));
    await CratePlacement(db).place('key', id, keyCrate);
    db.notifyOrchardItemsChanged();
    try {
      await change(orchardId, RecordTypes.caSet, {
        'crate': crateId,
        'on': true,
        'generation': generation,
        'public_key': base64Encode(key.publicKey),
        'ttl_minutes': ttlMinutes,
        'key_crate': keyCrate,
        'principals': names,
      });
    } catch (_) {
      await _dropKey(db, id);
      rethrow;
    }
    if (old != null) {
      for (final previous in await _authorityItems(db, old.keyCrate, old.publicKey)) {
        await _dropKey(db, previous);
      }
    }
  }

  /// Changes how long [crateId]'s certificates last and the user names each
  /// role signs in as, keeping the authority's key; turns it back on when it
  /// was off.
  Future<void> changeAuthority(
    String orchardId,
    String crateId, {
    required int ttlMinutes,
    required Map<String, List<String>> principals,
  }) async {
    final names = certPrincipalsBody(principals);
    if (names.isEmpty) throw const OrchardRecordRefused('no role signs in as anyone');
    final ca = (await _latestRecord(orchardId)).crates[crateId]?.ca;
    if (ca == null) throw const OrchardRecordRefused('the Crate has no certificate authority');
    await change(orchardId, RecordTypes.caSet, {
      'crate': crateId,
      'on': true,
      'generation': ca.generation,
      'public_key': base64Encode(ca.publicKey),
      'ttl_minutes': ttlMinutes,
      'key_crate': ca.keyCrate,
      'principals': names,
    });
  }

  /// Turns [crateId]'s authority off: owners' devices sign nothing more for
  /// it. Certificates already signed last until they expire.
  Future<void> turnAuthorityOff(String orchardId, String crateId) =>
      change(orchardId, RecordTypes.caSet, {'crate': crateId, 'on': false});

  /// The keys in [keyCrate] whose public half is [publicKey].
  Future<List<String>> _authorityItems(AppDatabase db, String keyCrate, List<int> publicKey) async {
    final rows = await db.customSelect(
      'SELECT i.id, i.public_key_data FROM identities i '
      "JOIN crate_items_meta m ON m.kind = 'key' AND m.item_key = i.id "
      'WHERE m.crate_id = ?',
      variables: [Variable(keyCrate)],
    ).get();
    return [
      for (final r in rows)
        if (OrchardService._eq(_ed25519OfLine(r.read<String?>('public_key_data')) ?? const [], publicKey))
          r.read<String>('id'),
    ];
  }

  static Future<void> _dropKey(AppDatabase db, String id) async {
    await OrchardIdentitySecrets(db).deleteAll(id);
    await db.identitiesDao.deleteIdentity(id);
    db.notifyOrchardItemsChanged();
  }

  /// The record as the server has it now, or as this device last had it
  /// when the server cannot be reached.
  Future<OrchardRecord> _recordForCertificates(String orchardId) async => (await _recordOrLast(orchardId)).record;

  /// The record as the server has it now, or as this device last had it,
  /// and then whether the server turned this device away: it answered, and
  /// would not give the record to this sign-in (signed out there, held back
  /// by the Orchard's rules, no longer in the Orchard). No answer, a fault
  /// of the server's own and "too many requests" are not that: the server
  /// could not be asked. A device held back by the rules has that noted,
  /// so that it signs nothing for itself later either, on the strength of
  /// an older copy, where nothing is asked of the server.
  ///
  /// A server the app knows is not answering is not asked ([cloudAway]),
  /// and one that takes its time is waited on for [loginRecordWait] and no
  /// longer: someone is watching a login, and what the device holds works
  /// meanwhile. Whether the record is the server's is said with it
  /// (fromServer), for whoever has to tell a person what it was checked by.
  Future<({OrchardRecord record, bool turnedAway, bool fromServer})> _recordOrLast(String orchardId) async {
    final db = await databases.open(orchardId);
    Future<({OrchardRecord record, bool turnedAway, bool fromServer})> last({bool turnedAway = false}) async =>
        (record: (await LocalRecord.load(db, orchardId)).latest, turnedAway: turnedAway, fromServer: false);
    if (cloudAway?.call() ?? false) return last();
    try {
      return (
        record: await _latestRecord(orchardId).timeout(loginRecordWait),
        turnedAway: false,
        fromServer: true,
      );
    } on RecordProblem catch (e) {
      // An entry of a newer version's: the record this device has decides,
      // as when ZestSSH Cloud cannot be reached, rather than the login
      // failing. The server still checks what it signs.
      if (recordProblemIsNewer(e.reason)) {
        AppLogger.info('Orchards: a newer version wrote to the record; the one here is used for the login');
        return last();
      }
      rethrow;
    } catch (e) {
      final turnedAway = e is OrchardServerException && const {401, 403, 404}.contains(e.status);
      if (e is OrchardServerException && e.rulesUnmet) await _noteHeldByRules(db, e);
      AppLogger.info('Orchards: the record could not be read from the server, the one here is used ($e)');
      return last(turnedAway: turnedAway);
    }
  }

  /// Whether this device's own copy of the Orchard in [db] says it is let
  /// in: a member in good standing, not held back by a rule the server
  /// checks (a device nobody approved), not suspended, not waiting
  /// to be recovered.
  static Future<bool> _letInHere(AppDatabase db) async {
    final info = await db.customSelect('SELECT status FROM orchard_info WHERE id = 1').getSingleOrNull();
    return info?.read<String>('status') == 'active';
  }

  static Future<({String id, int at, int keyVersion, Uint8List key})?> _asked(
      LocalStateStore store, String crateId) async {
    final raw = await store.read('$_askedPrefix$crateId');
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        id: m['id'] as String,
        at: m['at'] as int,
        keyVersion: m['key_version'] as int,
        key: base64Decode(m['key'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  /// The requests this device signed, by id, from the last two days.
  static Future<Map<String, int>> _signedIds(LocalStateStore store, int now) async {
    final raw = await store.read(_signedState);
    final out = <String, int>{};
    if (raw == null) return out;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in m.entries) {
        if (e.value is int && (e.value as int) > now - 2 * kCertRequestLifetimeSeconds) out[e.key] = e.value as int;
      }
    } catch (_) {
      // Unreadable: counted as none, and the server refuses a second
      // signature of the same request anyway.
    }
    return out;
  }

  static Future<String?> _emailOf(AppDatabase db, String uid) async {
    try {
      final row = await db.customSelect('SELECT email FROM member_keys WHERE uid = ?',
          variables: [Variable(uid)]).getSingleOrNull();
      return row?.read<String?>('email');
    } catch (_) {
      return null;
    }
  }

  /// The 32 raw bytes of an `ssh-ed25519 <base64> [comment]` line; null
  /// for anything else.
  static Uint8List? _ed25519OfLine(String? line) {
    if (line == null) return null;
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts[0] != 'ssh-ed25519') return null;
    try {
      final r = SshWireReader(base64Decode(parts[1]));
      if (r.readUtf8String(maxLength: 64) != 'ssh-ed25519') return null;
      final key = r.readString(maxLength: 64);
      return r.isExhausted && key.length == 32 ? key : null;
    } catch (_) {
      return null;
    }
  }
}
