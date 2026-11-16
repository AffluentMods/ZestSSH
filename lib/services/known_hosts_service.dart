import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/daos/known_hosts_dao.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';

/// Result of host key verification.
enum HostKeyVerifyResult {
  /// Key matches the stored fingerprint.
  trusted,

  /// First time connecting to this host - prompt user to accept.
  newHost,

  /// Key does NOT match the stored fingerprint - possible MITM attack.
  changed,
}

/// Provenance of a host key that was ADOPTED from cloud sync (recorded on
/// another device) and is being confirmed on THIS device for the first time.
/// Non-null [HostKeyVerifyOutcome.adoptedFrom] drives a one-time, non-blocking
/// notice ("This key was recorded on web-laptop-01 on 14 Aug") so a synced
/// fingerprint is never trusted silently - a vault-injected key stays visible.
class HostKeyProvenance {
  final String device;
  final DateTime recordedAt;
  const HostKeyProvenance({required this.device, required this.recordedAt});
}

/// [verify]'s result plus, when a synced key is confirmed here for the first
/// time, its provenance for the notice.
typedef HostKeyVerifyOutcome = ({
  HostKeyVerifyResult result,
  HostKeyProvenance? adoptedFrom,
});

/// Details of the currently-trusted key for a host+port, used to populate the
/// changed-key warning dialog (F2): the expected fingerprint and the date it
/// was first trusted.
class TrustedHostKeyInfo {
  /// The stored/expected SHA-256 fingerprint. Null when the stored record is a
  /// legacy MD5 digest that predates real-fingerprint storage - the caller
  /// then shows the expected fingerprint as "unknown".
  final String? fingerprint;

  /// The stored key type (e.g. 'ssh-ed25519').
  final String keyType;

  /// When this key was first trusted (`firstSeen`), i.e. the trust date.
  final DateTime trustedAt;

  const TrustedHostKeyInfo({
    required this.fingerprint,
    required this.keyType,
    required this.trustedAt,
  });
}

/// Manages the known hosts database (TOFU - Trust On First Use).
class KnownHostsService {
  final KnownHostsDao _dao;

  KnownHostsService(this._dao);

  /// Verify a host key against the known hosts database.
  ///
  /// Security: checks for both fingerprint changes AND key-type changes.
  /// A MITM attacker presenting a different key type (e.g. ed25519 when
  /// we previously saw rsa) would bypass a type-scoped lookup, so we also
  /// check if ANY key exists for this host+port with a different type.
  /// This machine's name, for stamping/comparing key provenance. Empty if the
  /// platform can't report it (then a synced key just never claims "this
  /// device", which is the safe direction - it stays visibly foreign).
  String get _thisDevice {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }

  static const HostKeyVerifyOutcome _trusted =
      (result: HostKeyVerifyResult.trusted, adoptedFrom: null);
  static const HostKeyVerifyOutcome _newHost =
      (result: HostKeyVerifyResult.newHost, adoptedFrom: null);
  static const HostKeyVerifyOutcome _changed =
      (result: HostKeyVerifyResult.changed, adoptedFrom: null);

  ///
  /// [tellsPerson]: whether the caller shows a person what comes back in
  /// `adoptedFrom` (a session someone opens does). A caller that reads the
  /// verdict only (the Server Monitor, the host editor's Test, an automation
  /// run) passes false: it is answered the same, but a key that came by sync
  /// or a restore is not marked as confirmed on this device by it, so the
  /// first session a person opens still tells them where the key came from.
  /// Marked by such a caller, the notice was used up in the background and
  /// never shown: a monitored host is polled as soon as the app runs (found in a
  /// security audit).
  Future<HostKeyVerifyOutcome> verify(
      String host, int port, SSHHostKey hostKey,
      {String? viaScope, bool tellsPerson = true}) async {
    // Canonicalise the host and key type BEFORE any lookup so that trivial
    // string variants ("Example.com", "example.com.", "[::1]") and RSA
    // signature-algorithm aliases (rsa-sha2-256/512 vs ssh-rsa) all map to a
    // single trust record. Otherwise an attacker could force a re-TOFU prompt
    // by presenting a cosmetically different host/type for an already-trusted
    // host.
    host = _normalizeHost(host);
    final keyType = _normalizeKeyType(hostKey.type);
    final fingerprint =
        OpenSSHKeySerializer.fingerprintFromBlob(hostKey.bytes);
    var existing = await _dao.findHost(host, port, keyType, viaScope: viaScope);

    // Migration compatibility (v31->v32): pre-v32 pins for this endpoint were
    // stored with via_scope NULL (route scoping did not exist). On the FIRST
    // scoped connect to a bastion-reached target, any NULL-scope rows for this
    // host:port are COPIED into the current route, so the pinned key AND its
    // changed-key detection hold there instead of silently re-TOFU'ing. Only
    // when no route has a row for this host:port yet; other routes to the same
    // endpoint then TOFU separately, which untangles the old same-IP
    // collision. The NULL rows stay where they are: a NULL row is also what a
    // direct connection trusted, and moving it to the route left a later
    // direct connection with no pin, so a man in the middle there met "new
    // host" where it should have met "changed" (found in a security
    // review). Direct connections keep matching the NULL rows
    // unchanged (viaScope == null skips this).
    if (existing == null && viaScope != null) {
      final scoped =
          await _dao.findAllForHostPort(host, port, viaScope: viaScope);
      if (scoped.isEmpty && !await _dao.hasRoutedRows(host, port)) {
        final legacy =
            await _dao.findAllForHostPort(host, port, viaScope: null);
        for (final row in legacy) {
          await _dao.copyToScope(row, viaScope, id: const Uuid().v4());
        }
        if (legacy.isNotEmpty) {
          existing =
              await _dao.findHost(host, port, keyType, viaScope: viaScope);
        }
      }
    }

    if (existing == null) {
      // No entry for this exact key type. Check if the host is known
      // with a DIFFERENT key type - treat that as a key change (possible MITM).
      // Evaluate ALL stored records for this host+port together (deterministic)
      // rather than an arbitrary single row.
      // (An FTPS server's certificate kept for the same address and port is
      // no SSH key of it.)
      final others = (await _dao.findAllForHostPort(host, port, viaScope: viaScope))
          .where((r) => r.keyType != certificateKeyType)
          .toList();
      if (others.isNotEmpty) {
        // The host IS known, just under a different key type - that is a
        // key-type change and must be surfaced, not silently trusted.
        //
        // This used to exempt legacy MD5 records (`&& !_isLegacyMd5(...)`),
        // which inverted the guard exactly where it mattered: against a host
        // whose only stored record was legacy, an attacker presenting a
        // DIFFERENT key type skipped the change check entirely and was
        // treated as a brand-new host, i.e. re-opened TOFU for a host the
        // user had already trusted. The legacy record cannot verify a
        // different key (its MD5 is of the old key), so "cannot verify"
        // must fail closed here. Same-key-type legacy records are still
        // upgraded losslessly below.
        return _changed;
      }
      // A direct connection with no direct row is a new host, whatever a
      // route (a jump host) has for the same address and port: a private
      // address names another machine on each network (10.0.0.5 behind the
      // office's jump host is not 10.0.0.5 at home), so a route's key is
      // never what the direct path expects. (For one day, 5 November 2026,
      // the keys this device confirmed on a route counted here, and another
      // machine at the same address reached directly for the first time was
      // called changed. A direct pin that an app before 3.3 moved to a route
      // is asked about once as a new host; since 3.3 a direct pin is copied,
      // never moved, so it stays.)
      return _newHost;
    }

    // A key that only came by sync or a restore, never matched on this device,
    // for a host this device has itself confirmed with another key, on this
    // route or any other (direct, or through any jump host): a key change, as
    // it would be had the row not come. Otherwise a restored backup could plant
    // a second key type for a trusted host, or a key for the same host reached
    // through a jump host, and a man in the middle offering only that key would
    // be trusted (found in security reviews, for any
    // route). Asked before a legacy row
    // is upgraded, so a planted row in the legacy MD5 form is not trusted and
    // marked confirmed either. A key this device confirmed itself on
    // another route, the same bytes, is no change.
    if (!existing.locallyVerified) {
      final confirmedHere = (await _dao.findAllForHostPortAnyRoute(host, port))
          .where((r) => r.keyType != certificateKeyType);
      if (confirmedHere.any((r) => r.locallyVerified && r.fingerprint != fingerprint)) {
        return _changed;
      }
    }

    // Legacy migration: entries written before the host-key fix stored the
    // 16-byte MD5 of the ORIGINAL key (so their SHA256(MD5) fingerprint can
    // never match the real key's SHA256). Rather than a scary "changed"
    // warning OR a blind re-TOFU (which would let a MITM slip a new key in
    // during the upgrade window), compare the presented key's MD5 to the
    // stored MD5: a match means it's genuinely the same host - silently
    // upgrade the record to the real key blob + correct fingerprint, no
    // prompt; a mismatch is a real key change and surfaces as "changed".
    // Only a row this device confirmed itself: one in that form that came by
    // sync or a restore names no key anyone confirmed (a crafted backup plants
    // the MD5 of an attacker's key beside the server's real key of another
    // type), so it is asked about as a key never seen here, never upgraded
    // unasked.
    if (_isLegacyMd5(existing.publicKeyBase64)) {
      if (!existing.locallyVerified) return _newHost;
      final storedMd5 = base64Decode(existing.publicKeyBase64);
      final presentedMd5 = md5.convert(hostKey.bytes).bytes;
      if (_bytesEqual(storedMd5, presentedMd5)) {
        await _dao.upsertHost(KnownHostsCompanion(
          id: Value(existing.id),
          host: Value(host),
          port: Value(port),
          keyType: Value(keyType),
          viaScope: Value(viaScope),
          fingerprint: Value(fingerprint),
          publicKeyBase64: Value(base64Encode(hostKey.bytes)),
          firstSeen: Value(existing.firstSeen),
          lastSeen: Value(DateTime.now()),
          recordedDevice: Value(existing.recordedDevice),
          locallyVerified: const Value(true),
        ));
        return _trusted;
      }
      return _changed;
    }
    if (existing.fingerprint != fingerprint) {
      return _changed;
    }

    // A match. If this key was ADOPTED from the vault (recorded on another
    // device) and this is the FIRST time this device has confirmed it, flip it
    // to locally-verified and surface its provenance once - so a synced key is
    // never trusted silently.
    final firstLocalConfirm = !existing.locallyVerified;
    HostKeyProvenance? adoptedFrom;
    if (firstLocalConfirm &&
        existing.recordedDevice != null &&
        existing.recordedDevice!.isNotEmpty &&
        existing.recordedDevice != _thisDevice) {
      adoptedFrom = HostKeyProvenance(
        device: existing.recordedDevice!,
        recordedAt: existing.firstSeen,
      );
    }
    // Nobody is told now: the row stays as one this device has not confirmed.
    final leftForPerson = adoptedFrom != null && !tellsPerson;

    // Update lastSeen timestamp
    await _dao.upsertHost(KnownHostsCompanion(
      id: Value(existing.id),
      host: Value(host),
      port: Value(port),
      keyType: Value(keyType),
      viaScope: Value(viaScope),
      fingerprint: Value(fingerprint),
      publicKeyBase64: Value(base64Encode(hostKey.bytes)),
      firstSeen: Value(existing.firstSeen),
      lastSeen: Value(DateTime.now()),
      recordedDevice: Value(existing.recordedDevice),
      locallyVerified: Value(!leftForPerson),
    ));

    return (result: HostKeyVerifyResult.trusted, adoptedFrom: adoptedFrom);
  }

  /// Trust a new or changed host key.
  Future<void> trustHost(
      String host, int port, SSHHostKey hostKey,
      {String? viaScope}) async {
    // Store under the same canonical host/key-type used by verify(), so a
    // trusted key is found again regardless of host-string cosmetics or RSA
    // signature-algorithm aliasing.
    host = _normalizeHost(host);
    final keyType = _normalizeKeyType(hostKey.type);
    final fingerprint =
        OpenSSHKeySerializer.fingerprintFromBlob(hostKey.bytes);
    final now = DateTime.now();

    // Delete any existing entry for this host/port/keyType
    final existing = await _dao.findHost(host, port, keyType, viaScope: viaScope);

    await _dao.upsertHost(KnownHostsCompanion(
      id: Value(existing?.id ?? const Uuid().v4()),
      host: Value(host),
      port: Value(port),
      keyType: Value(keyType),
      viaScope: Value(viaScope),
      fingerprint: Value(fingerprint),
      publicKeyBase64: Value(base64Encode(hostKey.bytes)),
      firstSeen: Value(existing?.firstSeen ?? now),
      lastSeen: Value(now),
      // A key the user trusts HERE (a new host, or accepting a changed key) is
      // stamped with THIS machine's name and marked locally-verified - it
      // becomes the provenance other devices see once it syncs. (A key that
      // merely re-matches on connect doesn't come through here; verify()
      // preserves its original recording device.)
      recordedDevice: Value(_thisDevice),
      locallyVerified: const Value(true),
    ));
  }

  /// Get the fingerprint string for display.
  String getFingerprint(SSHHostKey hostKey) {
    return OpenSSHKeySerializer.fingerprintFromBlob(hostKey.bytes);
  }

  /// The currently-trusted key for a host+port, for the changed-key warning.
  ///
  /// Returns the EXPECTED (stored) fingerprint the received key is being
  /// compared against plus the date it was first trusted. Prefers the record
  /// matching [receivedKeyType]; on a key-TYPE change (no same-type record)
  /// falls back to the first stored record so the warning still has an expected
  /// fingerprint to show. Returns null only when nothing is stored (shouldn't
  /// happen on the changed path, but handled so callers can degrade
  /// gracefully). A legacy MD5 record yields a null [fingerprint].
  Future<TrustedHostKeyInfo?> trustedKeyInfo(
      String host, int port, String receivedKeyType,
      {String? viaScope}) async {
    host = _normalizeHost(host);
    final keyType = _normalizeKeyType(receivedKeyType);
    final all = (await _dao.findAllForHostPort(host, port, viaScope: viaScope))
        .where((r) => r.keyType != certificateKeyType)
        .toList();
    if (all.isEmpty) return null;
    final sameType = all.where((r) => r.keyType == keyType).toList();
    // What this device confirmed itself comes first: a key of the received
    // type that only came from a sync or a restore is not what this device
    // expects when it confirmed another key itself, and showing it
    // would show the received key as the expected one.
    final chosen = sameType.where((r) => r.locallyVerified).firstOrNull ??
        all.where((r) => r.locallyVerified).firstOrNull ??
        (sameType.isNotEmpty ? sameType.first : all.first);
    final legacy = _isLegacyMd5(chosen.publicKeyBase64);
    return TrustedHostKeyInfo(
      fingerprint: legacy ? null : chosen.fingerprint,
      keyType: chosen.keyType,
      trustedAt: chosen.firstSeen,
    );
  }

  /// Forget every trusted host key. Each server will re-prompt on the next
  /// connection (trust on first use again).
  Future<void> clearAll() => _dao.deleteAll();

  // ── FTPS certificates (3.4) ───────────────────────────────────────
  //
  // A server certificate the person accepted for an FTPS host is kept here,
  // beside the SSH host keys, the way they are: by address and port, with
  // this key type, its SHA-256 fingerprint (as `openssl x509 -fingerprint
  // -sha256` prints it) and the certificate itself (DER, base64), and it
  // syncs with them. An SSH key check never takes one for a host key.
  //
  // A remote screen's VeNCrypt certificate (4.0) is kept the same way. One
  // reached through a carrier SSH host is kept for the route [viaScope] (the
  // carrier's normalized host:port, as a jump host scopes a host key), so
  // localhost:5900 behind two carriers is two records; one reached directly,
  // and every FTPS certificate, has none (null), exactly as before.

  /// The key type of a kept FTPS server certificate.
  static const certificateKeyType = 'x509-sha256';

  /// The SHA-256 (64 lower-case hexadecimal digits) of the certificate kept
  /// for [host]:[port] (through [viaScope], null when direct), or null.
  Future<String?> pinnedCertificate(String host, int port, {String? viaScope}) async {
    final row = await _dao.findHost(_normalizeHost(host), port, certificateKeyType, viaScope: viaScope);
    if (row == null) return null;
    final hex = row.fingerprint.replaceAll(':', '').toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
  }

  /// The kept certificate's fingerprint and when it was first trusted, for a
  /// changed certificate's warning; null where none is kept.
  Future<({String fingerprint, DateTime trustedAt})?> certificateInfo(String host, int port,
      {String? viaScope}) async {
    final row = await _dao.findHost(_normalizeHost(host), port, certificateKeyType, viaScope: viaScope);
    return row == null ? null : (fingerprint: row.fingerprint, trustedAt: row.firstSeen);
  }

  /// [host]:[port] showed the certificate kept for it ([sha256Hex]): its
  /// last seen time moves on, and where this is the first time this device
  /// confirms one another device kept (it came with sync), it is this
  /// device's from now on and where it came from is given back, to tell the
  /// person once, as a synced host key is ([verify]'s adoptedFrom).
  Future<HostKeyProvenance?> confirmCertificate(String host, int port, String sha256Hex, {String? viaScope}) async {
    host = _normalizeHost(host);
    final existing = await _dao.findHost(host, port, certificateKeyType, viaScope: viaScope);
    if (existing == null || existing.fingerprint != certificateFingerprint(sha256Hex)) return null;
    final device = existing.recordedDevice;
    final adopted = !existing.locallyVerified && device != null && device.isNotEmpty && device != _thisDevice
        ? HostKeyProvenance(device: device, recordedAt: existing.firstSeen)
        : null;
    await _dao.upsertHost(existing.toCompanion(true).copyWith(
          lastSeen: Value(DateTime.now()),
          locallyVerified: const Value(true),
        ));
    return adopted;
  }

  /// Whether [keyType] is a kept FTPS server certificate's rather than an SSH
  /// host key's.
  static bool isCertificate(String keyType) => keyType == certificateKeyType;

  /// Keeps [der] (whose SHA-256 is [sha256Hex]) as the certificate of
  /// [host]:[port] (through [viaScope], null when direct), in place of any
  /// before it on that route.
  Future<void> trustCertificate(String host, int port,
      {required String sha256Hex, required List<int> der, String? viaScope}) async {
    host = _normalizeHost(host);
    final existing = await _dao.findHost(host, port, certificateKeyType, viaScope: viaScope);
    final now = DateTime.now();
    final fingerprint = certificateFingerprint(sha256Hex);
    final same = existing != null && existing.fingerprint == fingerprint;
    await _dao.upsertHost(KnownHostsCompanion(
      id: Value(existing?.id ?? const Uuid().v4()),
      host: Value(host),
      port: Value(port),
      keyType: const Value(certificateKeyType),
      viaScope: Value(viaScope),
      fingerprint: Value(fingerprint),
      publicKeyBase64: Value(base64Encode(der)),
      firstSeen: Value(same ? existing.firstSeen : now),
      lastSeen: Value(now),
      recordedDevice: Value(same ? existing.recordedDevice : _thisDevice),
      locallyVerified: const Value(true),
    ));
  }

  /// [sha256Hex] as server tools print a certificate's fingerprint: pairs of
  /// upper-case hexadecimal digits with colons between them.
  static String certificateFingerprint(String sha256Hex) {
    final up = sha256Hex.toUpperCase();
    return [for (var i = 0; i + 1 < up.length; i += 2) up.substring(i, i + 2)].join(':');
  }

  /// True if a stored `publicKeyBase64` is a legacy 16-byte MD5 digest
  /// rather than a real host public-key blob (real keys are always well
  /// over 16 bytes). Used to migrate pre-fix known_hosts entries.
  bool _isLegacyMd5(String publicKeyBase64) {
    try {
      return base64Decode(publicKeyBase64).length == 16;
    } catch (_) {
      return false;
    }
  }

  /// Canonicalise a host string for trust lookups/storage.
  ///
  /// Lowercases (DNS is case-insensitive), trims whitespace, strips a single
  /// trailing FQDN dot, and removes IPv6 literal brackets so that "example.com",
  /// "Example.com.", and "[::1]" each resolve to one stable trust record. Full
  /// IDNA/punycode is intentionally not attempted here (no bundled IDNA table);
  /// ASCII host strings - the overwhelmingly common case - are fully covered.
  String _normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    if (h.endsWith('.') && h.length > 1) {
      h = h.substring(0, h.length - 1);
    }
    if (h.startsWith('[') && h.endsWith(']') && h.length > 2) {
      h = h.substring(1, h.length - 1);
    }
    return h;
  }

  /// Collapse RSA signature-algorithm aliases to the underlying host-key type.
  ///
  /// A single RSA host key is presented as "ssh-rsa" in its blob but may be
  /// advertised via rsa-sha2-256 / rsa-sha2-512 signature algorithms. Storing
  /// them as distinct key types would let the same key look like a key-TYPE
  /// change. Other key types (ssh-ed25519, ecdsa-*, ssh-ed448…) pass through
  /// unchanged.
  String _normalizeKeyType(String keyType) {
    if (keyType == 'rsa-sha2-256' || keyType == 'rsa-sha2-512') {
      return 'ssh-rsa';
    }
    return keyType;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
