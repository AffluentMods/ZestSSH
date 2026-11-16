import 'package:drift/drift.dart';
import 'package:zestssh/database/tables/connection_groups.dart';
import 'package:zestssh/database/tables/identities.dart';
import 'package:zestssh/database/tables/snippets.dart';

/// SSH/Telnet/Mosh/Local Shell connections.
///
/// Sensitive credentials are NOT stored here - they live in
/// [FlutterSecureStorage] via the identity system.
@TableIndex(name: 'idx_connections_label', columns: {#label})
@TableIndex(name: 'idx_connections_host', columns: {#host})
class Connections extends Table {
  TextColumn get id => text()();
  TextColumn get label => text().withLength(min: 1, max: 255)();
  TextColumn get host => text().withLength(min: 1, max: 255)();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get identityId =>
      text().nullable().references(Identities, #id)();
  TextColumn get groupId =>
      text().nullable().references(ConnectionGroups, #id)();
  IntColumn get colorIndex => integer().withDefault(const Constant(0))();

  /// Optional custom colour label (ARGB int). When set it OVERRIDES
  /// [colorIndex] and can be any colour (not just a palette preset); NULL means
  /// "use the palette index / default". Additive + nullable so existing rows
  /// migrate untouched.
  IntColumn get colorValue => integer().nullable()();
  TextColumn get protocol =>
      text().withDefault(const Constant('ssh'))(); // ssh | mosh | et | telnet | serial | localShell | demo
  BoolColumn get zlibCompression =>
      boolean().withDefault(const Constant(false))();
  TextColumn get startupCommand => text().nullable()();
  TextColumn get snippetId =>
      text().nullable().references(Snippets, #id)();
  TextColumn get connectViaId => text().nullable()();
  IntColumn get keepAliveSeconds =>
      integer().withDefault(const Constant(0))();

  // Wake-on-LAN fields
  TextColumn get wolMacAddress => text().nullable()();
  TextColumn get wolBroadcastAddress =>
      text().withDefault(const Constant('255.255.255.255')).nullable()();
  IntColumn get wolPort => integer().withDefault(const Constant(9)).nullable()();

  /// JSON-encoded environment variables (key-value pairs) to export on shell start.
  /// Example: {"LANG":"en_US.UTF-8","MY_VAR":"value"}
  TextColumn get envVars => text().withDefault(const Constant(''))();

  /// Whether to enable SSH agent forwarding for this connection.
  /// When true, the remote server can use the client's SSH keys to
  /// authenticate to other servers (e.g. for git pull over SSH).
  BoolColumn get forwardAgent =>
      boolean().withDefault(const Constant(false))();

  /// Whether to enable legacy algorithm support for this connection.
  ///
  /// Some older SSH servers - notably default Proxmox LXC templates,
  /// OpenWrt routers, embedded devices, and OpenSSH < 7.6 - reject
  /// the modern-only cipher/MAC set we offer by default. Enabling
  /// compatibility mode appends `aes128-cbc`, `aes192-cbc`,
  /// `aes256-cbc`, `hmac-md5`, and `diffie-hellman-group1-sha1` to
  /// the offered algorithm lists so negotiation succeeds.
  ///
  /// Modern algorithms remain first in preference order, so a server
  /// that supports both still picks the strong option. This toggle
  /// only EXPANDS what we'll accept - it never weakens defaults
  /// against a server that already speaks modern SSH.
  BoolColumn get compatibilityMode =>
      boolean().withDefault(const Constant(false))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Home-screen card size code (Part B): 0 = Medium (half-row), 1 = Large
  /// (standard full card, the default), 2 = legacy Large, 3 = Small (square).
  /// 3.0 shows every host as one card and does not read it (per-host
  /// sizing removed); it is kept and synced so apps
  /// from before 3.0 keep each host's size.
  IntColumn get sizeTier => integer().withDefault(const Constant(1))();

  /// Host-card icon override (v40): a built-in catalog id (see [IconCatalog])
  /// the user picked in place of the auto-detected OS icon. Null = auto (fall
  /// back to the OS icon). Syncs across devices.
  TextColumn get iconId => text().nullable()();

  /// A user-uploaded custom host-card icon: a base64-encoded PNG downscaled to
  /// a small square at upload time so it never bloats the synced blob. Takes
  /// precedence over [iconId] and the auto OS icon. Null = none. Syncs.
  TextColumn get customIcon => text().nullable()();

  /// What colours the host's icon (v52), see `HostIconColor`: null = the
  /// icon's own colour (the default), 0 = the colour of the host's label (its
  /// own, else its group's), anything else = a custom colour as opaque ARGB.
  /// An uploaded picture is never tinted. Syncs.
  IntColumn get iconColor => integer().nullable()();

  /// Whether this host is pinned to the front of its section (Part B).
  /// A synced property of the host (was a per-device SharedPreferences set
  /// before v18). Pinned hosts sort ahead of the rest within their group.
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  /// Optional free-text note the user writes about the host. Surfaced on
  /// Large home-screen cards (Part B) and in the connection editor.
  TextColumn get note => text().nullable()();

  /// Whether this host is opted in to agentless SSH monitoring (v20). When
  /// true, the background AgentlessMonitorPoller periodically SSH-connects
  /// using the host's saved credentials and refreshes its server stats
  /// WITHOUT opening a terminal tab/PTY and WITHOUT counting against the
  /// terminal-session cap. A synced property of the host, mirroring [pinned].
  BoolColumn get monitored => boolean().withDefault(const Constant(false))();

  /// SFTP directory pins for this host (schema v30): a JSON
  /// array of `{"label":…,"path":…}` the user pins to the SFTP rail so their
  /// real working directories (`/home/deploy/site`) replace the
  /// default guess list. Lives on the host record so it rides the existing
  /// connection sync across devices, mirroring [pinned] / [monitored] / [note].
  /// Nullable + additive (existing rows migrate untouched); NULL / '' = none.
  TextColumn get pins => text().nullable()();

  /// The SFTP host default (remember-last-folder spec, section 2): the last
  /// remote folder a pane of this host settled in, ALWAYS the `realpath`
  /// absolute form, the username it was seen under (a network rewrite can
  /// change the user, and a path seen under another user is only a
  /// suggestion), and when. Rides on the record so it syncs (blob v14);
  /// cleared by "Forget last folder". Nullable + additive (v34).
  TextColumn get lastRemotePath => text().nullable()();
  TextColumn get lastRemoteUser => text().nullable()();
  DateTimeColumn get lastRemotePathAt => dateTime().nullable()();

  /// Where the host was imported from (3.0 cloud import): JSON naming the
  /// provider, the provider's machine id, the account name it came under and
  /// the address and name the import set, so a later check updates this host
  /// instead of adding another and leaves the person's own edits alone. See
  /// `CloudLink`. Synced (blob v20) and in Crate records, so every device and
  /// every member sees "from AWS"; never holds a token. Nullable + additive
  /// (v50); NULL = not imported from a cloud.
  TextColumn get cloudSource => text().nullable()();

  /// A remote screen's options (4.0, v55): JSON read by `ScreenOptions`
  /// (lib/features/screens/model/screen_options.dart), at most 4 KB, set on
  /// a VNC host only. NULL on every other host, and then left out of what
  /// syncs and of a team's record, so an SSH host travels exactly as it did
  /// before the column. Nullable + additive.
  TextColumn get screenOptions => text().nullable()();

  /// A team host's shared SFTP bookmarks (4.0, v56): the folders a team keeps
  /// for this server, in the format of [pins] (a JSON array of
  /// `{"label":...,"path":...}`, at most 50 of them). Unlike
  /// [pins], which are each member's own and stay on the device, these travel
  /// in the host's team record, so every member who can see the host sees
  /// them, and only a member whose vault lets them edit the host can change
  /// them (the write guard refuses anyone else). A personal host has none:
  /// NULL there, and never in what personal sync or a backup carries. NULL
  /// on a team host with none, and then left out of its record, so the
  /// record stays exactly what a version before the column wrote. Nullable
  /// and additive.
  TextColumn get sharedPins => text().nullable()();

  DateTimeColumn get lastConnected => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
