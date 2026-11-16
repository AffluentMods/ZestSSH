import 'package:drift/drift.dart';

/// Reusable SSH identities (username + auth method).
///
/// Sensitive material is stored in [FlutterSecureStorage], keyed as:
///   `identity_password_{id}` - password string
///   `identity_key_{id}`      - PEM-encoded private key
///   `identity_cert_{id}`     - OpenSSH SSH user certificate blob
///                              (only the public cert; the underlying
///                              private key still lives at `identity_key_{id}`)
///
/// Hardware-token-backed identities are different: the private key never
/// leaves the OS ssh-agent / FIDO2 device. We persist:
///   * `agentSocketPath`  - path to ssh-agent socket / Windows named pipe,
///                          or `null` to use the platform default.
///   * `keyHandle`        - opaque FIDO2 credential id (only for sk- keys
///                          where we'll talk CTAP2 directly; agent-backed
///                          keys use the public-key blob to address the
///                          right key in the agent).
class Identities extends Table {
  TextColumn get id => text()();
  TextColumn get label => text().withLength(min: 1, max: 255)();
  TextColumn get username => text().withLength(min: 1, max: 255)();

  /// 'password' | 'publicKey' | 'certificate' | 'hardwareToken' |
  /// 'teamCertificate' | 'passwordManager'
  TextColumn get authMethod => text()();

  /// 'ed25519' | 'rsa2048' | 'rsa4096' | 'ecdsaP256' | … |
  /// 'sk-ssh-ed25519' | 'sk-ecdsa-sha2-nistp256'
  TextColumn get keyType => text().nullable()();

  TextColumn get publicKeyFingerprint => text().nullable()();
  TextColumn get publicKeyData => text().nullable()();

  /// Cached fields parsed out of the SSH certificate the first time we
  /// import / generate it. Source of truth is the cert blob in secure
  /// storage; these mirrors exist so the UI can render expiry / principal
  /// / serial without re-parsing on every list build.
  ///
  /// `certSerial` - uint64 serial assigned by the CA, hex-encoded.
  /// `certKeyId` - free-form "key id" string (CA's audit label).
  /// `certPrincipals` - comma-separated list of allowed remote usernames.
  /// `certCaFingerprint` - SHA-256 fingerprint of the CA public key.
  /// `certValidBefore` - expiry; null = no expiry.
  /// `certValidAfter` - issue time.
  TextColumn get certSerial => text().nullable()();
  TextColumn get certKeyId => text().nullable()();
  TextColumn get certPrincipals => text().nullable()();
  TextColumn get certCaFingerprint => text().nullable()();
  DateTimeColumn get certValidBefore => dateTime().nullable()();
  DateTimeColumn get certValidAfter => dateTime().nullable()();

  /// For hardware-token / agent-backed identities.
  ///
  /// `agentSocketPath` is a pointer to where the agent listens. Empty
  /// string means "use platform default" (`$SSH_AUTH_SOCK` on Unix,
  /// `\\.\pipe\openssh-ssh-agent` on Windows).
  TextColumn get agentSocketPath => text().nullable()();

  /// `True` when this identity authenticates by talking to an external
  /// ssh-agent rather than holding the private key ourselves. Lets the
  /// identity-edit UI pick the right surface (file picker vs. agent
  /// browser) without inferring from authMethod alone.
  BoolColumn get usesAgent =>
      boolean().withDefault(const Constant(false))();

  /// Whose agent holds an agent-backed identity's key (3.0):
  /// '1password', 'bitwarden' or 'system' (null: the system agent, as
  /// before). Synced: each device finds that agent's socket or pipe itself
  /// ([agentSocketPath] stays a device-local override).
  TextColumn get agentSource => text().nullable()();

  /// For a 'passwordManager' identity (3.0): where its password
  /// lives, as `PasswordRef.encode()` writes it (a 1Password reference, a
  /// Bitwarden item id or a KeePassXC entry). Never the password itself.
  /// Synced; checked again every time it is read.
  TextColumn get passwordRef => text().nullable()();

  IntColumn get colorIndex => integer().withDefault(const Constant(0))();

  /// Optional custom colour label (ARGB int). Overrides [colorIndex] when set;
  /// NULL = no custom colour (the default is "no colour" for identities).
  IntColumn get colorValue => integer().nullable()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  /// Whether this identity is authorised for UNATTENDED (headless) runs -
  /// scheduled workflows, `zestssh://` deep-link commands, and API-key-driven
  /// automation that fire with no user present. Default `false`: a saved
  /// credential is NEVER used by a headless run until the user explicitly opts
  /// it in from the Keys screen.
  ///
  /// SECURITY / SYNC: this flag is DEVICE-LOCAL and deliberately NOT included
  /// in the cloud-sync blob (see [SyncDataService]). Authorising a credential
  /// for silent, no-user-present use is a per-device trust decision - the same
  /// reason the underlying secret is stored device-local
  /// (`first_unlock_this_device` / `encryptedSharedPreferences` / DPAPI) and
  /// never leaves the machine. Enabling it on your laptop must not silently
  /// arm it on every other synced device, so it stays out of sync entirely.
  BoolColumn get allowUnattended =>
      boolean().withDefault(const Constant(false))();

  /// For a key (publicKey, certificate or hardwareToken): whether the
  /// password saved with it (`identity_password_{id}`) is tried after the
  /// key, where a server does not take the key and takes passwords (3.0,
  /// accounts per host). Set only where a password was saved with the key
  /// as that: a password left from before the identity became a key is
  /// never sent. Synced, and in an Orchard part of the key's record.
  BoolColumn get passwordAfterKey =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();

  /// Last-modified time - bumped on every edit; drives cloud-sync tombstone
  /// "newest wins". Nullable: pre-v29 rows are backfilled to createdAt in the
  /// migration; a row never edited on v29+ stays null (delete-wins).
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
