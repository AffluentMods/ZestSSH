import 'dart:io' show Platform;

/// Authentication method for an identity.
///
/// Persisted as the lowerCamel `name` of the enum value (e.g.
/// `'password'`, `'publicKey'`, `'certificate'`, `'hardwareToken'`).
/// New values append at the end so existing serialised values stay
/// stable.
enum AuthMethod {
  /// Plain password.
  password,

  /// Static keypair held by us (PEM in secure storage).
  publicKey,

  /// Static keypair we hold AND an OpenSSH user certificate signed by
  /// a CA. During pubkey auth we present the cert algorithm
  /// (e.g. `ssh-ed25519-cert-v01@openssh.com`) instead of the bare
  /// algorithm; the underlying private key still produces the
  /// signature.
  certificate,

  /// Private key lives outside our process - typically in the OS
  /// ssh-agent (which may itself be backed by a FIDO2 device,
  /// smart card, or PKCS#11 token). All signing operations are
  /// proxied through the agent so the key material never reaches us.
  hardwareToken,

  /// A team certificate (3.0): a key in a Crate whose
  /// certificate authority is on. It holds no secret and only names the
  /// user to sign in as; each device connects with its own SSH key and a
  /// short-lived certificate the Crate's authority signed for it.
  teamCertificate,

  /// A password that lives in the person's password manager (3.0):
  /// the identity keeps only a reference to it (`passwordRef`), and
  /// the password is fetched when connecting (1Password, Bitwarden or
  /// KeePassXC on a desktop; typed, or filled by the phone's password
  /// manager, on a phone) and never kept.
  passwordManager,
}

extension AuthMethodX on AuthMethod {
  static AuthMethod fromDb(String name) {
    return AuthMethod.values.firstWhere(
      (m) => m.name == name,
      orElse: () => AuthMethod.password,
    );
  }
}

/// The kinds of identity that sign in with a key and may also hold a
/// password, tried after the key where a server does not take it (3.0,
/// accounts per host), by the names identities keep them by. Not a team
/// certificate: its Crate's authority decides how its keys sign in.
const kKeysWithPasswordAfter = {'publicKey', 'certificate', 'hardwareToken'};

/// SSH key type for key generation and display.
enum KeyType {
  ed25519('Ed25519', 'ssh-ed25519'),
  rsa2048('RSA 2048', 'ssh-rsa'),
  rsa4096('RSA 4096', 'ssh-rsa'),
  ecdsaP256('ECDSA P-256', 'ecdsa-sha2-nistp256'),
  ecdsaP384('ECDSA P-384', 'ecdsa-sha2-nistp384'),
  ecdsaP521('ECDSA P-521', 'ecdsa-sha2-nistp521'),

  /// FIDO2-backed Ed25519 (sk-ssh-ed25519@openssh.com). YubiKey 5
  /// firmware 5.2.3+ supports this. Keypair lives on the token; we
  /// only store the public key + key handle.
  skEd25519('Ed25519 (FIDO2)', 'sk-ssh-ed25519@openssh.com'),

  /// FIDO2-backed ECDSA-P-256 (sk-ecdsa-sha2-nistp256@openssh.com).
  /// Universal across all FIDO2 authenticators.
  skEcdsaP256('ECDSA P-256 (FIDO2)', 'sk-ecdsa-sha2-nistp256@openssh.com');

  const KeyType(this.displayName, this.sshName);

  final String displayName;
  final String sshName;

  /// True for FIDO2 / hardware-token-resident key types. These are
  /// surfaced by the OS ssh-agent and never have private material on
  /// disk in our app.
  bool get isHardwareBound =>
      this == skEd25519 || this == skEcdsaP256;
}

/// Connection protocol.
enum ConnectionProtocol {
  ssh('SSH'),

  /// A host that gives files only: SSH's sign-in, then its SFTP and never
  /// a terminal (a server set to ForceCommand internal-sftp refuses one).
  /// The enum name is the stored protocol string, `sftp`; a version from
  /// before it reads the string as SSH.
  sftp('SFTP only'),
  mosh('Mosh'),

  /// Eternal Terminal: the system `et` client, like Mosh. The enum name is
  /// the stored protocol string, so it is the short `et`.
  et('Eternal Terminal'),
  telnet('Telnet'),
  serial('Serial (SSH)'),
  localShell('Local Shell'),
  demo('Demo'),

  /// FTPS (3.4): FTP over TLS, explicit (AUTH TLS after the greeting, port
  /// 21 by default). Files only, like [sftp]; plain FTP is never spoken. A
  /// version from before it never sees such a host: sync carries FTPS hosts
  /// in a list of their own, `ftps_hosts`, which older versions do not read
  /// (SyncDataService.gatherAll).
  ftps('FTPS'),

  /// FTPS with implicit TLS (TLS from the first byte, port 990 by default):
  /// the same kind of host as [ftps], the editor's other choice for it.
  ftpsImplicit('FTPS (implicit TLS)'),

  /// A remote screen over VNC (4.0): reached through one of the person's SSH
  /// hosts, its carrier (`connectViaId`), or directly over VeNCrypt TLS only.
  /// Its options are the host's `screen_options` (ScreenOptions). A version
  /// from before it never sees such a host: sync carries screens in a list of
  /// their own, `screen_hosts`, and a team's record of one is of a format
  /// older versions refuse (orchard_crypto.dart, kItemRecordFormat).
  vnc('VNC'),

  /// A remote screen over RDP (4.0): reached through one of the
  /// person's SSH hosts, its carrier (`connectViaId`), or directly, always
  /// inside TLS with the server's certificate pinned. A screen like [vnc],
  /// with the same `screen_options`, but a kind of its own ([kindClassRdp]):
  /// an RDP host gives its key's password to whatever answers at its address,
  /// so a team's VNC host must never become one by an edit or a record. A
  /// version from before it never sees such a host: sync carries RDP hosts in
  /// a list of their own, `rdp_hosts`, and a team's record of one is of a
  /// format older versions refuse.
  rdp('RDP');

  const ConnectionProtocol(this.englishName);

  /// Whether this is FTPS, explicit or implicit.
  bool get isFtps => this == ftps || this == ftpsImplicit;

  /// Whether this host opens a remote screen (VNC or RDP).
  bool get isScreen => this == vnc || this == rdp;

  /// Whether [protocol], as stored, is FTPS (explicit or implicit).
  static bool storedIsFtps(String? protocol) => protocol == ftps.name || protocol == ftpsImplicit.name;

  /// Whether [protocol], as stored, is a remote screen (VNC or RDP).
  static bool storedIsScreen(String? protocol) => protocol == vnc.name || protocol == rdp.name;

  /// The kind class of a host saved with [protocol]: [kindClassShell] for
  /// anything a version before 3.4 reads (an unknown or missing protocol
  /// too, which such a version reads as SSH), [kindClassFtps] for FTPS and
  /// [kindClassScreen] for a VNC screen and [kindClassRdp] for an RDP one.
  /// Personal sync keeps each class
  /// above the first in a list of its own, a team's record of one is of a
  /// format older versions refuse, and a team's host never changes class
  /// (the trigger trg_gd_connections_kind).
  static int kindClassOf(String? protocol) => storedIsFtps(protocol)
      ? kindClassFtps
      : protocol == rdp.name
          ? kindClassRdp
          : storedIsScreen(protocol)
              ? kindClassScreen
              : kindClassShell;

  /// Whether a host saved with [protocol] can be a jump host, a hop an SSH
  /// connection goes through: SSH, SFTP only, Mosh and Eternal Terminal (each
  /// signed in to over SSH), and a host saved before protocols were. Never a
  /// remote screen or FTPS, which would be dialled as an SSH server at their
  /// address and offered their own key's password (found in a 4.0 security
  /// review), nor Telnet, a serial line, the local shell or the demo.
  static bool storedCanBeJumpHost(String? protocol) =>
      protocol == null || protocol.isEmpty || _jumpHostKinds.contains(protocol);

  static final _jumpHostKinds = {ssh.name, sftp.name, mosh.name, et.name};

  /// The kind classes ([kindClassOf]).
  static const kindClassShell = 1;
  static const kindClassFtps = 2;
  static const kindClassScreen = 3;
  static const kindClassRdp = 4;

  /// Every kind class there is, in order.
  static const kindClasses = [kindClassShell, kindClassFtps, kindClassScreen, kindClassRdp];

  /// The stored names of the protocols of [kindClass], from the enum itself,
  /// so a list built from them cannot drift from it.
  static List<String> storedNamesOfClass(int kindClass) => [
        for (final p in values)
          if (kindClassOf(p.name) == kindClass) p.name,
      ];

  /// Its name in English, for the log: screens show it in the
  /// person's language (lib/l10n/list_names.dart; it was shown as it is,
  /// in English, whatever the language).
  final String englishName;
}

/// Security lock method.
enum SecurityLockMethod {
  none,
  biometric,
  pin,
  both,
}

/// Authentication type for Prometheus connection.
enum PrometheusAuthType {
  none('none', 'None'),
  basicAuth('basicAuth', 'Basic Auth'),
  bearerToken('bearerToken', 'Bearer Token'),
  customHeader('customHeader', 'Custom Header');

  const PrometheusAuthType(this.key, this.displayName);

  final String key;
  final String displayName;

  static PrometheusAuthType fromKey(String? key) {
    if (key == null) return PrometheusAuthType.none;
    return PrometheusAuthType.values.firstWhere(
      (e) => e.key == key,
      orElse: () => PrometheusAuthType.none,
    );
  }
}

/// Terminal cursor style.
enum TerminalCursorShape {
  verticalBar('Vertical Bar |', 'verticalBar'),
  block('Block █', 'block'),
  underline('Underline _', 'underline');

  const TerminalCursorShape(this.englishName, this.key);

  /// Its name in English, for the log: screens show it in the
  /// person's language (lib/l10n/list_names.dart; it was shown as it is,
  /// in English, whatever the language).
  final String englishName;
  final String key;
}

/// When the terminal draws its cursor (4.0): always, not
/// while output that moves it about is arriving (a full-screen program
/// redrawing, where it jumps around), or never. A program's own request to
/// hide it (ESC [ ? 25 l) is obeyed in every case.
enum TerminalCursorVisibility {
  always('always'),
  notDuringOutput('notDuringOutput'),
  never('never');

  const TerminalCursorVisibility(this.key);

  /// How it is kept in the settings.
  final String key;
}

/// Terminal font family.
enum TerminalFontFamily {
  jetBrainsMono('JetBrainsMono', 'JetBrains Mono'),
  firaCode('FiraCode', 'Fira Code'),
  sourceCodePro('SourceCodePro', 'Source Code Pro'),
  cascadiaCode('CascadiaCode', 'Cascadia Code'),
  hack('Hack', 'Hack'),
  system('monospace', 'System Default');

  const TerminalFontFamily(this._family, this.englishName);

  final String _family;

  /// The font family string used by Flutter's [TextStyle]. The system's own
  /// is the monospace font each system has by its name: 'monospace' is a
  /// name Android and Linux resolve, and Windows, macOS and iOS do not, which
  /// drew a proportional font in its place.
  String get fontFamily => this == system ? systemMonospaceFamily : _family;

  /// Its name in English, for the log: screens show it in the
  /// person's language (lib/l10n/list_names.dart; it was shown as it is,
  /// in English, whatever the language).
  final String englishName;
}

/// The monospace font each system has by its name.
String get systemMonospaceFamily {
  if (Platform.isWindows) return 'Consolas';
  if (Platform.isMacOS || Platform.isIOS) return 'Menlo';
  return 'monospace';
}
