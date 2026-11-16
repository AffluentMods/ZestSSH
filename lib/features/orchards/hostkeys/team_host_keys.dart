import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/hostkeys/host_key_notices.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart' show normalizeKnownHost;
import 'package:zestssh/services/known_hosts_service.dart' show KnownHostsService;
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/utils/host_address.dart' show hostWithPort;
import 'package:zestssh/utils/openssh_key_serializer.dart';

/// Team-pinned host keys (3.0).
///
/// Someone who may edit a Crate pins the key a host presents, after checking
/// it, for everyone: each member's device then trusts exactly that key at
/// that endpoint when it connects to the hosts of that Crate, with no prompt
/// of its own, and a different key stops everyone until someone who may edit
/// the pin's Crate checks it and replaces the pin. A pin is an Orchard item
/// (kind 'hostkey'), sealed with its Crate's key and signed by its author
/// like every item, so the server can neither read nor change it; every
/// device takes one only from someone who could edit its Crate then.

/// The item key of the pin for [host] at [port], reached through the jump
/// route [viaScope] (known_hosts' via_scope; null when direct), for the
/// hosts of the Crate [crateId]: one pin per endpoint and route in each
/// Crate, and it counts only for the hosts of its own. (The key had no
/// Crate, and a pin counted for every host at its endpoint, whichever Crate
/// it was in: someone who may edit one Crate could pin a key of their
/// choosing for the address of another Crate's host, which every member of
/// both then trusted there, or was stopped by; and that Crate could not pin
/// its own while the other's was there.)
String teamHostKeyId(String host, int port, String? viaScope, {required String crateId}) =>
    '${_idWithoutCrate(host, port, viaScope)}|$crateId';

/// The item key of a pin made before pins carried their Crate: its endpoint
/// and route alone. Such a pin counts only for the hosts of the Crate it is
/// in, as any other does.
String _idWithoutCrate(String host, int port, String? viaScope) =>
    '${normalizeKnownHost(host)}|$port|${viaScope ?? ''}';

/// [key] as a pin keeps it: its type and its encoded public key, base64.
String hostKeyLine(SSHHostKey key) => '${_keyType(key.type)} ${base64Encode(key.bytes)}';

/// RSA's signature algorithm names are one key type.
String _keyType(String type) => type == 'rsa-sha2-256' || type == 'rsa-sha2-512' ? 'ssh-rsa' : type;

/// A pin: the keys the team trusts at an endpoint, and the Crate it is in.
class TeamHostKeyPin {
  const TeamHostKeyPin({
    required this.id,
    required this.host,
    required this.port,
    required this.viaScope,
    required this.keys,
    required this.crateId,
  });

  final String id;
  final String host;
  final int port;

  /// '' when reached directly.
  final String viaScope;

  /// "type base64" lines.
  final List<String> keys;

  /// The Crate that keeps it.
  final String? crateId;

  /// Whether [key] is one of the pinned keys: the same encoded key, byte for
  /// byte (the type written beside it is for people).
  bool matches(SSHHostKey key) {
    final presented = base64Encode(key.bytes);
    return keys.any((line) => line.split(' ').length == 2 && line.split(' ')[1] == presented);
  }

  /// The first pinned key's SHA256 fingerprint, as the changed-key dialog
  /// shows the expected one; a certificate's as server tools print it
  /// ([certificateSha256]).
  String? get fingerprint {
    if (keys.isEmpty) return null;
    final sha = certificateSha256;
    if (sha != null) return KnownHostsService.certificateFingerprint(sha);
    final parts = keys.first.split(' ');
    if (parts.length != 2) return null;
    try {
      return OpenSSHKeySerializer.fingerprintFromBlob(Uint8List.fromList(base64Decode(parts[1])));
    } on FormatException {
      return null;
    }
  }

  /// Whether what is pinned is an FTPS server's TLS certificate (3.4), kept
  /// as `x509-sha256` and the certificate (DER, base64), rather than an SSH
  /// host key.
  bool get isCertificate =>
      keys.isNotEmpty && keys.first.split(' ').first == KnownHostsService.certificateKeyType;

  /// The SHA-256 (64 lower-case hexadecimal digits) of the pinned
  /// certificate, as an FTPS connection is pinned to it; null where no
  /// certificate is pinned, or it does not read.
  String? get certificateSha256 {
    if (!isCertificate) return null;
    final parts = keys.first.split(' ');
    if (parts.length != 2) return null;
    try {
      return sha256.convert(base64Decode(parts[1])).toString();
    } on FormatException {
      return null;
    }
  }

  /// Whether it counts for the hosts of the Crate [crateId]: it is in that
  /// Crate, under the key a pin of its endpoint and route there has (or the
  /// one it had before pins carried their Crate). One whose key names
  /// another Crate counts for none, wherever it is.
  bool countsIn(String crateId) {
    final route = viaScope.isEmpty ? null : viaScope;
    return this.crateId == crateId &&
        (id == teamHostKeyId(host, port, route, crateId: crateId) || id == _idWithoutCrate(host, port, route));
  }

  /// The jump host it is for connections through, as the address and port
  /// that host was saved with ("bastion.example.com:22", an IPv6 address in
  /// brackets); null for a pin of direct connections, and for a route kept
  /// by the jump host's id ('via:' and the id, where that host was not found
  /// when the route was taken).
  String? get jumpHost {
    if (viaScope.isEmpty || viaScope.startsWith('via:')) return null;
    final colon = viaScope.lastIndexOf(':');
    final port = colon < 1 ? null : int.tryParse(viaScope.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) return null;
    return hostWithPort(viaScope.substring(0, colon), port);
  }
}

/// A host key prompt's part in team-pinned host keys (3.0), and an
/// FTPS server certificate's (3.4).
class TeamPinPrompt {
  TeamPinPrompt({required this.crateName, required this.mayChange, required this.pinned});

  /// The Crate the pin is in, or would go in (the host's).
  final String crateName;

  /// This account may edit that Crate: it may pin the key for everyone, or
  /// replace the team's pin.
  final bool mayChange;

  /// The team pinned another key here: the presented one is not it.
  final bool pinned;

  /// The person's choice, when [mayChange]: trust the key for everyone in
  /// the Crate (on unless they turn it off).
  bool forEveryone = true;
}

/// The pins of an Orchard's database [db].
class TeamHostKeys {
  TeamHostKeys(this.db);

  final AppDatabase db;

  /// The pin for [host]:[port] through [viaScope] that counts for the hosts
  /// of the Crate [crateId] (the host's, [crateOfHost]), or null: a pin of
  /// that endpoint in another Crate is not that host's, and the device
  /// decides there as it would with no pin. Beside one made before pins
  /// carried their Crate, the one made since is the one that counts. Only an
  /// Orchard has pins.
  Future<TeamHostKeyPin?> pinFor(String host, int port, {String? viaScope, required String? crateId}) async {
    if (!db.isOrchard || crateId == null) return null;
    final id = teamHostKeyId(host, port, viaScope, crateId: crateId);
    final rows = await db.customSelect('$_pins WHERE t.id IN (?, ?) ORDER BY t.id = ? DESC',
        variables: [Variable(id), Variable(_idWithoutCrate(host, port, viaScope)), Variable(id)]).get();
    for (final row in rows) {
      final pin = await _pin(row);
      if (pin.countsIn(crateId)) return pin;
    }
    return null;
  }

  /// Every pin for [host]:[port] that counts for the hosts of the Crate
  /// [crateId] (the host's), whatever route it is for: the one for direct
  /// connections first, then those through a jump host, by route. A
  /// connection finds its own by its route ([pinFor]); the host panel shows
  /// them all, so that a pin made through a jump host can be seen and
  /// removed. A pin of another Crate is not listed. Only an Orchard has
  /// pins.
  Future<List<TeamHostKeyPin>> pinsOf(String host, int port, {required String? crateId}) async {
    if (!db.isOrchard || crateId == null) return const [];
    final rows = await db.customSelect(
      '$_pins WHERE t.host = ? AND t.port = ? ORDER BY t.via_scope, t.id',
      variables: [Variable(normalizeKnownHost(host)), Variable(port)],
    ).get();
    final out = <TeamHostKeyPin>[];
    for (final row in rows) {
      final pin = await _pin(row);
      if (pin.countsIn(crateId)) out.add(pin);
    }
    return out;
  }

  /// The pins, each with the Crate it is in.
  static const _pins = 'SELECT t.id, t.host, t.port, t.via_scope, t.host_keys, m.crate_id FROM team_host_keys t '
      "LEFT JOIN crate_items_meta m ON m.kind = 'hostkey' AND m.item_key = t.id";

  /// A row of [_pins] as a pin: one in no Crate yet is in the Crate new
  /// items go into.
  Future<TeamHostKeyPin> _pin(QueryRow row) async {
    List<String> keys;
    try {
      keys = [
        for (final k in jsonDecode(row.read<String>('host_keys')) as List)
          if (k is String) k,
      ];
    } catch (_) {
      keys = const [];
    }
    return TeamHostKeyPin(
      id: row.read<String>('id'),
      host: row.read<String>('host'),
      port: row.read<int>('port'),
      viaScope: row.read<String>('via_scope'),
      keys: keys,
      crateId: row.read<String?>('crate_id') ?? await CratePlacement(db).defaultCrate(),
    );
  }

  /// The name of the Crate [crateId], as a prompt says it ('' where it is not
  /// known here).
  Future<String> crateName(String? crateId) async {
    if (crateId == null) return '';
    final row = await db.customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?',
        variables: [Variable<String>(crateId)]).getSingleOrNull();
    return row?.read<String?>('name') ?? '';
  }

  /// Whether this account may pin keys in [crateId] (edit there).
  Future<bool> mayPinIn(String? crateId) async =>
      crateId != null && (await CratePlacement(db).switchesOf(crateId)).contains(CrateSwitches.edit);

  /// The Crate the host [connectionId] is in: the one whose pins count for
  /// it. Null where this database has no such host (one of another space).
  Future<String?> crateOfHost(String connectionId) async {
    if (await db.connectionsDao.getById(connectionId) == null) return null;
    return CratePlacement(db).crateOf('host', connectionId);
  }

  /// Pins the TLS certificate [der] an FTPS server (3.4) or a remote screen's
  /// VeNCrypt server (4.0) showed at [host]:[port] for the hosts of the Crate
  /// [crateId], as [pin] pins an SSH host key: its record is one versions
  /// before 3.4 do not read (itemRecordFormatOf). FTPS has no jump hosts; a
  /// screen reached through its carrier is pinned for that route ([viaScope],
  /// the carrier's normalized host:port), as a host key behind a jump host is.
  Future<void> pinCertificate(String host, int port, List<int> der, {String? viaScope, required String crateId}) => pin(
      host, port, SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: Uint8List.fromList(der)),
      viaScope: viaScope, crateId: crateId);

  /// Pins [key] for [host]:[port] through [viaScope] for the hosts of the
  /// Crate [crateId] (the host's), in place of the pin that counts for them
  /// there ([pinFor]); a pin of another Crate is left as it is. The write
  /// guard refuses it without edit in [crateId].
  Future<void> pin(String host, int port, SSHHostKey key, {String? viaScope, required String crateId}) async {
    var id = teamHostKeyId(host, port, viaScope, crateId: crateId);
    final keys = jsonEncode([hostKeyLine(key)]);
    await db.transaction(() async {
      final existing = await pinFor(host, port, viaScope: viaScope, crateId: crateId);
      if (existing != null) {
        id = existing.id;
        await db.customStatement('UPDATE team_host_keys SET host_keys = ? WHERE id = ?', [keys, id]);
        return;
      }
      await CratePlacement(db).place(kHostKeyKind, id, crateId);
      await db.customStatement(
        'INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, ?, ?, ?, ?)',
        [id, normalizeKnownHost(host), port, viaScope ?? '', keys],
      );
    });
    // This device's person made the change: not told of it again.
    await markHostKeySeen(db, id);
    db.notifyOrchardItemsChanged();
  }

  /// Removes the pin [id]: each device decides on its own again for that
  /// host. The write guard refuses it without delete in the pin's Crate.
  Future<void> unpin(String id) async {
    await db.customStatement('DELETE FROM team_host_keys WHERE id = ?', [id]);
    await markHostKeySeen(db, id);
    db.notifyOrchardItemsChanged();
  }
}
