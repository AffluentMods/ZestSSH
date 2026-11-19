import 'dart:convert';

/// Where a remote screen's server listens, as its carrier sees it: an address
/// and port (the host's own `host` and `port`), or a Unix socket on the
/// carrier ([ScreenOptions.socket]).
enum ScreenTargetKind { tcp, unix }

/// How a remote screen signs in: what the server offers (VNC password,
/// VeNCrypt, none inside SSH), or Apple's Remote Desktop login, which takes
/// the key's user name and password.
enum ScreenAuth { auto, apple }

/// How the picture fits the tab: scaled to fit, one remote pixel to one
/// pixel, or the remote desktop resized to the tab where the server allows.
enum ScreenScaling { fit, oneToOne, remoteResize }

/// What the server is asked to send: chosen by the link, sharper, or lighter.
enum ScreenQuality { auto, high, low }

/// What an RDP host is asked to draw with (4.0): the app's choice
/// (the graphics pipeline, RemoteFX by itself for a server without it), the
/// graphics pipeline, RemoteFX surface commands, or plain bitmaps.
enum ScreenGraphics { auto, modern, remotefx, basic }

/// The RD Gateway an RDP host is reached through (4.0): the gateway's
/// address and port, and the key it signs in with ([keyId]; null: the PC's
/// own sign-in, the host's key or the account asked for).
///
/// In the column as `"gateway": {"host": "rdg.example.test", "port": 443,
/// "key": "k1"}`, the port only where it is not 443 and the key only
/// where there is one. A gateway the column names and this version cannot
/// read is [unreadable]: kept as it came, and the host refused, never opened
/// without it (a host that goes through a gateway is not one to reach
/// directly).
class ScreenGateway {
  const ScreenGateway({required this.host, this.port = 443, this.keyId});

  /// What a gateway this version cannot read stands for.
  static const unreadable = ScreenGateway(host: '');

  /// The longest address taken (a DNS name's own limit).
  static const maxHostChars = 253;

  /// The longest key id taken.
  static const maxKeyChars = 64;

  final String host;
  final int port;

  /// The key its sign-in uses, or null for the PC's own.
  final String? keyId;

  /// Whether this is a gateway this version can go through.
  bool get readable => hostOk(host) && port >= 1 && port <= 65535;

  /// Whether [v] is an address a gateway may have: within [maxHostChars],
  /// not beginning with a dash, with no space, control character, slash,
  /// backslash, at sign or any character an address does not hold (an IPv6
  /// address in brackets or not).
  static bool hostOk(Object? v) {
    if (v is! String) return false;
    final h = v.trim();
    if (h.isEmpty || h.length > maxHostChars || h != v || h.startsWith('-')) return false;
    return RegExp(r'^[A-Za-z0-9.\-_:\[\]%]+$').hasMatch(h);
  }

  static bool _keyOk(Object? v) =>
      v is String && v.isNotEmpty && v.length <= maxKeyChars && !v.codeUnits.any((c) => c < 0x21 || c == 0x7f);

  /// The gateway [json] names: null where it names none, [unreadable] where
  /// it names one this version cannot read.
  static ScreenGateway? fromJson(Object? json) {
    if (json == null) return null;
    if (json is! Map) return unreadable;
    final host = json['host'];
    final port = json['port'] ?? 443;
    final key = json['key'];
    if (!hostOk(host) || port is! int || port < 1 || port > 65535 || (key != null && !_keyOk(key))) return unreadable;
    return ScreenGateway(host: host as String, port: port, keyId: key as String?);
  }

  Map<String, Object?> toJson() => {'host': host, if (port != 443) 'port': port, 'key': ?keyId};

  @override
  bool operator ==(Object other) =>
      other is ScreenGateway && other.host == host && other.port == port && other.keyId == keyId;

  @override
  int get hashCode => Object.hash(host, port, keyId);
}

/// A remote screen's options (4.0): the JSON of a VNC host's
/// `connections.screen_options` column.
///
/// ```json
/// {"v": 1, "target": "tcp" | "unix", "socket": "/run/user/1000/vnc.sock",
///  "auth": "auto" | "apple", "clipboard": "on" | "off", "clipboard_locked": false,
///  "scaling": "fit" | "one_to_one" | "remote_resize", "quality": "auto" | "high" | "low",
///  "view_only": false, "shared": true}
/// ```
///
/// An RDP host (4.0) has the same column, with two keys of its own,
/// written only where they are not the default (so a VNC host's column is
/// byte for byte what it was): `"nla": false` (sign in without Network Level
/// Authentication, to the server's own sign-in screen) and
/// `"graphics": "modern" | "remotefx" | "basic"`.
///
/// An RDP host may also say how many displays its remote has (4.0):
/// `"displays": 2` to 4, written only where it is more than one; and
/// whether its sessions ask the server for relative mouse movement:
/// `"relative_mouse": true`, written only where it is on; and how large
/// the remote draws its text and windows: `"text_scale": 150` (one of
/// [textScales], in percent), written only where the app says one.
///
/// An RDP host may say whether its sessions play the remote's sound (4.0):
/// `"sound": "on" | "off"`, written only where its person chose;
/// without it a computer plays it and a phone does not ([soundOn]).
///
/// Any screen host may limit how many pictures a second are drawn (4.0):
/// `"frame_limit": 30` (one of [frameLimits]), written only where
/// there is a limit.
///
/// An RDP host may be reached through an RD Gateway (4.0):
/// `"gateway": {...}` ([ScreenGateway]), written only where it has one.
///
/// Read leniently: every value is checked, and a bad one falls back to its
/// default, so a record a member made by hand, or a later 4.x version wrote,
/// never stops a host from opening. Keys this version does not know are kept
/// and written back, so a later version's options survive an edit here. The
/// whole is bounded at [maxChars]: a longer column reads as the defaults, and
/// kept keys that would make it longer are dropped.
class ScreenOptions {
  const ScreenOptions({
    this.target = ScreenTargetKind.tcp,
    this.socket,
    this.auth = ScreenAuth.auto,
    this.clipboard,
    this.clipboardLocked = false,
    this.clipboardOnPaste = false,
    this.scaling = ScreenScaling.fit,
    this.quality = ScreenQuality.auto,
    this.viewOnly = false,
    this.shared = true,
    this.nla = true,
    this.graphics = ScreenGraphics.auto,
    this.displays = 1,
    this.relativeMouse = false,
    this.textScale = 0,
    this.frameLimit = 0,
    this.sound,
    this.gateway,
    this.unknown = const {},
  });

  /// The format this version writes.
  static const version = 1;

  /// The most the column holds, in characters of its JSON.
  static const maxChars = 4096;

  /// The longest socket path taken (a Unix socket's own limit is about 108
  /// bytes; a leading `~/` is expanded on the carrier).
  static const maxSocketChars = 255;

  /// The options a new VNC host starts with.
  static const defaults = ScreenOptions();

  /// What a host made now starts with: [defaults], and this device's
  /// clipboard sent to the remote only on a paste ([clipboardOnPaste]).
  static const forNewHost = ScreenOptions(clipboardOnPaste: true);

  /// The options column [raw] of a host that is being made, with what a new
  /// host says and [raw] does not: where it does not say when the clipboard
  /// is sent, it is on a paste. What it does say is kept as it is (a host
  /// copied from one that sends on taking the keyboard stays so).
  static String withNewHostDefaults(String? raw) {
    if (raw == null || raw.isEmpty) return forNewHost.encode();
    try {
      final json = jsonDecode(raw);
      if (json is Map && json.containsKey('clipboard_send')) return raw;
    } catch (_) {
      // Not options at all: read as the defaults, as everywhere.
    }
    return decode(raw).copyWith(clipboardOnPaste: true).encode();
  }

  final ScreenTargetKind target;

  /// The Unix socket's path on the carrier, for [ScreenTargetKind.unix]; may
  /// start with `~/`. Null for a TCP target.
  final String? socket;

  final ScreenAuth auth;

  /// Whether the clipboard is shared with the remote screen: null for the
  /// space's default ([clipboardOnByDefault]).
  final bool? clipboard;

  /// A team host only: the clipboard stays off and members cannot turn it
  /// on. Part of the host's record, so only someone who may edit the host in
  /// its Crate sets it.
  final bool clipboardLocked;

  /// On a computer, when this device's clipboard goes to the remote while
  /// the clipboard is shared: only when its person pastes into the screen
  /// (true), or whenever the picture takes the keyboard (false). What the
  /// remote copies comes to this device either way. A host made before this
  /// was asked says nothing ("clipboard_send" is not in its options) and
  /// stays as it was, on taking the keyboard; a host made since is made
  /// with "paste" ([forNewHost], [withNewHostDefaults]). A phone sends its
  /// clipboard only when asked, whatever this says.
  final bool clipboardOnPaste;

  final ScreenScaling scaling;
  final ScreenQuality quality;

  /// The picture only: no key or pointer is sent.
  final bool viewOnly;

  /// Whether others may stay on the screen while this session is open (the
  /// RFB "shared" flag).
  final bool shared;

  /// RDP: sign in with Network Level Authentication (CredSSP), the default.
  /// False is the per-host "without NLA": the server shows its own sign-in
  /// screen before it knows who asks.
  final bool nla;

  /// RDP: what the server is asked to draw with.
  final ScreenGraphics graphics;

  /// RDP: how many displays the remote is asked for, 1 to [maxDisplays]
  /// (4.0). Each takes the size of the view that shows it, on a
  /// phone as on a computer (a phone asks for
  /// as many, shows one at a time and switches quickly).
  final int displays;

  /// RDP: its sessions ask the server for relative mouse movement (4.0),
  /// so the session's switch can be turned on. Off: the session
  /// connects as it always did.
  final bool relativeMouse;

  /// RDP: whether its sessions play the remote's sound (4.0); null
  /// leaves it to the device ([soundOn]).
  final bool? sound;

  /// RDP: the RD Gateway its sessions go through (4.0), or null.
  /// [ScreenGateway.unreadable] where the column names one this version
  /// cannot read (its JSON kept in [unknown]).
  final ScreenGateway? gateway;

  /// Whether a session of this host plays the remote's sound on this
  /// device: as its person chose, else on a computer and not on a phone
  /// (a phone's speaker in a quiet room is the surprise to avoid).
  bool soundOn({required bool phone}) => sound ?? !phone;

  /// RDP: how large the remote is asked to draw its text and windows, in
  /// percent (4.0): one of [textScales]. 0 says nothing, and the
  /// remote keeps its own.
  final int textScale;

  /// The most pictures a second a session of this host draws (4.0, step
  /// 4): one of [frameLimits]. 0 is no limit. It limits what this device
  /// draws, to save battery and processor time; the server sends as it
  /// does.
  final int frameLimit;

  /// What [frameLimit] may be: none, or so many a second.
  static const frameLimits = [0, 60, 30, 15];

  /// What [textScale] may be: nothing said, or a percentage Windows itself
  /// offers.
  static const textScales = [0, 100, 125, 150, 200];

  /// The most displays a host may ask for (the engine's own ceiling).
  static const maxDisplays = 4;

  /// The most pixels a phone or tablet's remote desktop has, all its
  /// displays together: one 4K picture. The engine and the app each hold
  /// the whole desktop in memory, several times over, and a phone has less
  /// of it than a computer. Displays the size of a phone or tablet's own
  /// view never reach it (four of the largest tablet's are 5.6 million
  /// pixels); it is here for the day a host names a size of its own.
  static const maxDesktopPixelsOnPhone = 3840 * 2160;

  /// How many displays a session of this host asks for: 1 to
  /// [maxDisplays], on every kind of device.
  int get displayCount => displays < 1 ? 1 : (displays > maxDisplays ? maxDisplays : displays);

  /// The most pixels a desktop of this host may have on this kind of
  /// device, or null for no ceiling of the app's own (the engine has its).
  static int? maxDesktopPixelsOn({required bool phone}) => phone ? maxDesktopPixelsOnPhone : null;

  /// Keys this version does not know, kept as they came.
  final Map<String, Object?> unknown;

  /// The clipboard's default on a host of a team ([inTeam]) or of the
  /// person's own space: on in their own space, off in a team, and off for
  /// good on a team host whose editor locked it.
  bool clipboardOnByDefault({required bool inTeam, bool ownDefault = true}) {
    if (inTeam && clipboardLocked) return false;
    return clipboard ?? (inTeam ? false : ownDefault);
  }

  /// Whether a member may turn the clipboard on for themselves on this
  /// device: always in their own space; in a team, unless it is locked.
  bool clipboardTogglable({required bool inTeam}) => !(inTeam && clipboardLocked);

  static const _known = {
    'v',
    'target',
    'socket',
    'auth',
    'clipboard',
    'clipboard_locked',
    'clipboard_send',
    'scaling',
    'quality',
    'view_only',
    'shared',
    'nla',
    'graphics',
    'displays',
    'relative_mouse',
    'text_scale',
    'frame_limit',
    'sound',
    'gateway',
  };

  static const _scalingNames = {
    ScreenScaling.fit: 'fit',
    ScreenScaling.oneToOne: 'one_to_one',
    ScreenScaling.remoteResize: 'remote_resize',
  };

  /// The options [raw] holds, as the column keeps them: the defaults for
  /// null, an empty or over-long column, or anything that is not a JSON
  /// object.
  static ScreenOptions decode(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    // A column this version cannot read that names a gateway is a host with a gateway it cannot
    // read (refused, never opened directly), not one with none.
    final unreadable = raw.contains('"gateway"') ? _unreadableGateway : defaults;
    if (raw.length > maxChars) return unreadable;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return unreadable;
    }
    if (json is! Map<String, dynamic>) return unreadable;
    return fromJson(json);
  }

  /// The defaults, with a gateway that cannot be read (written back as such).
  static const _unreadableGateway =
      ScreenOptions(gateway: ScreenGateway.unreadable, unknown: {'gateway': {'unreadable': true}});

  /// The options [json] holds, each value checked.
  static ScreenOptions fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? v, T fallback, [String Function(T)? nameOf]) {
      if (v is! String) return fallback;
      for (final value in values) {
        if ((nameOf?.call(value) ?? value.name) == v) return value;
      }
      return fallback;
    }

    bool flag(Object? v, bool fallback) => v is bool ? v : fallback;

    final target = pick(ScreenTargetKind.values, json['target'], ScreenTargetKind.tcp);
    final socket = socketOk(json['socket']) ? json['socket'] as String : null;
    final clipboard = switch (json['clipboard']) {
      'on' => true,
      'off' => false,
      _ => null,
    };
    final gateway = ScreenGateway.fromJson(json['gateway']);
    return ScreenOptions(
      // A socket target without a path to it cannot be reached: the address
      // and port then are what it has.
      target: target == ScreenTargetKind.unix && socket == null ? ScreenTargetKind.tcp : target,
      socket: socket,
      auth: pick(ScreenAuth.values, json['auth'], ScreenAuth.auto),
      clipboard: clipboard,
      clipboardLocked: flag(json['clipboard_locked'], false),
      clipboardOnPaste: json['clipboard_send'] == 'paste',
      scaling: pick(ScreenScaling.values, json['scaling'], ScreenScaling.fit, (s) => _scalingNames[s]!),
      quality: pick(ScreenQuality.values, json['quality'], ScreenQuality.auto),
      viewOnly: flag(json['view_only'], false),
      shared: flag(json['shared'], true),
      nla: flag(json['nla'], true),
      graphics: pick(ScreenGraphics.values, json['graphics'], ScreenGraphics.auto),
      displays: switch (json['displays']) {
        final int n when n >= 1 && n <= maxDisplays => n,
        _ => 1,
      },
      relativeMouse: flag(json['relative_mouse'], false),
      textScale: switch (json['text_scale']) {
        final int n when textScales.contains(n) => n,
        _ => 0,
      },
      frameLimit: switch (json['frame_limit']) {
        final int n when frameLimits.contains(n) => n,
        _ => 0,
      },
      sound: switch (json['sound']) {
        'on' => true,
        'off' => false,
        _ => null,
      },
      gateway: gateway,
      unknown: {
        for (final e in json.entries)
          if (!_known.contains(e.key)) e.key: e.value,
        // A gateway this version cannot read is written back as it came.
        if (gateway == ScreenGateway.unreadable) 'gateway': json['gateway'],
      },
    );
  }

  /// Whether [v] is a socket path this version takes: text, not empty, not
  /// over [maxSocketChars], with no control character (C0 and DEL: NUL,
  /// line breaks, ESC, TAB...; found in a security review).
  static bool socketOk(Object? v) =>
      v is String &&
      v.trim().isNotEmpty &&
      v.length <= maxSocketChars &&
      !v.codeUnits.any((c) => c < 0x20 || c == 0x7f);

  Map<String, Object?> toJson() => {
        // Kept keys first, so a known key always wins.
        ...unknown,
        'v': version,
        'target': target.name,
        if (target == ScreenTargetKind.unix && socket != null) 'socket': socket,
        'auth': auth.name,
        if (clipboard != null) 'clipboard': clipboard! ? 'on' : 'off',
        'clipboard_locked': clipboardLocked,
        'clipboard_send': clipboardOnPaste ? 'paste' : 'focus',
        'scaling': _scalingNames[scaling],
        'quality': quality.name,
        'view_only': viewOnly,
        'shared': shared,
        // RDP's two, only where they are not the default.
        if (!nla) 'nla': false,
        if (graphics != ScreenGraphics.auto) 'graphics': graphics.name,
        if (displays > 1 && displays <= maxDisplays) 'displays': displays,
        if (relativeMouse) 'relative_mouse': true,
        if (textScale != 0 && textScales.contains(textScale)) 'text_scale': textScale,
        if (frameLimit != 0 && frameLimits.contains(frameLimit)) 'frame_limit': frameLimit,
        if (sound != null) 'sound': sound! ? 'on' : 'off',
        if (gateway != null && gateway!.readable) 'gateway': gateway!.toJson(),
      };

  /// The column's text: within [maxChars], dropping the kept keys if they
  /// alone would take it over.
  String encode() {
    final whole = jsonEncode(toJson());
    if (whole.length <= maxChars || unknown.isEmpty) return whole;
    // A gateway this version cannot read stays: without it the host would open directly.
    return jsonEncode(copyWith(unknown: {if (unknown.containsKey('gateway')) 'gateway': unknown['gateway']}).toJson());
  }

  ScreenOptions copyWith({
    ScreenTargetKind? target,
    String? socket,
    bool clearSocket = false,
    ScreenAuth? auth,
    bool? clipboard,
    bool clearClipboard = false,
    bool? clipboardLocked,
    bool? clipboardOnPaste,
    ScreenScaling? scaling,
    ScreenQuality? quality,
    bool? viewOnly,
    bool? shared,
    bool? nla,
    ScreenGraphics? graphics,
    int? displays,
    bool? relativeMouse,
    int? textScale,
    int? frameLimit,
    bool? sound,
    bool clearSound = false,
    ScreenGateway? gateway,
    bool clearGateway = false,
    Map<String, Object?>? unknown,
  }) =>
      ScreenOptions(
        target: target ?? this.target,
        socket: clearSocket ? null : socket ?? this.socket,
        auth: auth ?? this.auth,
        clipboard: clearClipboard ? null : clipboard ?? this.clipboard,
        clipboardLocked: clipboardLocked ?? this.clipboardLocked,
        clipboardOnPaste: clipboardOnPaste ?? this.clipboardOnPaste,
        scaling: scaling ?? this.scaling,
        quality: quality ?? this.quality,
        viewOnly: viewOnly ?? this.viewOnly,
        shared: shared ?? this.shared,
        nla: nla ?? this.nla,
        graphics: graphics ?? this.graphics,
        displays: displays ?? this.displays,
        relativeMouse: relativeMouse ?? this.relativeMouse,
        textScale: textScale ?? this.textScale,
        frameLimit: frameLimit ?? this.frameLimit,
        sound: clearSound ? null : sound ?? this.sound,
        gateway: clearGateway ? null : gateway ?? this.gateway,
        // A gateway set or taken away here replaces one kept unread.
        unknown: (gateway != null || clearGateway) && (unknown ?? this.unknown).containsKey('gateway')
            ? (Map.of(unknown ?? this.unknown)..remove('gateway'))
            : unknown ?? this.unknown,
      );

  /// What a new VNC host's column holds.
  static String encodeDefaults() => defaults.encode();

  /// [raw] as the column may keep it, for what arrives from outside (a
  /// restore, a team's record): null for anything that is not a JSON object
  /// within [maxChars], else [raw] as it came (each value is checked when it
  /// is read, [decode]), so what a newer version wrote is not rewritten.
  static String? sanitize(Object? raw) {
    if (raw is! String || raw.isEmpty || raw.length > maxChars) return null;
    try {
      return jsonDecode(raw) is Map<String, dynamic> ? raw : null;
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is ScreenOptions && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}
