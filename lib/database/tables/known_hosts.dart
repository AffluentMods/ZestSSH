import 'package:drift/drift.dart';

/// Known host key fingerprints for TOFU verification.
///
/// When connecting to a host for the first time, ZestSSH prompts
/// the user to trust the host key. On subsequent connections, the
/// stored fingerprint is compared - a mismatch triggers a warning.
@TableIndex(name: 'idx_known_hosts_host', columns: {#host})
class KnownHosts extends Table {
  TextColumn get id => text()();
  TextColumn get host => text()();
  IntColumn get port => integer()();
  TextColumn get keyType => text()(); // 'ssh-rsa', 'ssh-ed25519', etc.
  TextColumn get fingerprint => text()(); // SHA-256 fingerprint
  TextColumn get publicKeyBase64 => text()(); // full public key for comparison
  DateTimeColumn get firstSeen => dateTime()();
  DateTimeColumn get lastSeen => dateTime()();

  /// The machine that FIRST recorded this key (Platform.localHostname), so a
  /// key that arrived via cloud sync can be shown with its provenance ("recorded
  /// on web-laptop-01 on 14 Aug") instead of a vague "another device". SYNCED
  /// (rides the blob). Null on pre-provenance rows (treated as this device).
  TextColumn get recordedDevice => text().nullable()();

  /// Whether THIS device has connected and matched this key at least once.
  /// DEVICE-LOCAL (NOT synced): a key adopted from the vault starts false, and
  /// the first local connect that matches it flips it true and fires the
  /// one-time provenance notice. Existing rows were all local TOFU → true.
  BoolColumn get locallyVerified =>
      boolean().withDefault(const Constant(true))();

  /// The ROUTE used to reach this endpoint, so two DIFFERENT servers that share
  /// one destination host:port but are reached through different jump hosts do
  /// not collide into one trust record (the false "Host key changed" bug).
  /// NULL = a direct connection (no jump), which keeps every pre-v32 pinned key
  /// matching byte-for-byte. For a jumped connection it is the nearest jump
  /// hop's normalized `host:port`. SYNCED (rides the blob) so the same scoped
  /// trust travels across devices.
  TextColumn get viaScope => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {host, port, keyType, viaScope},
      ];
}
