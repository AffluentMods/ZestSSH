/// Remote screens (4.0): a session of the Rust screen engine fed through Dart, so the bytes travel
/// over the app's own SSH channel (zest_ssh_core) and no local port is opened.
///
/// The engine is in the library only when it is built with the feature "vnc" (or "rdp");
/// hook/build.dart takes the features from the app's pubspec.
///
/// ```dart
/// final session = await ScreenSession.connectTrusting(
///   ScreenConnectOptions.vnc(password: vncPassword),
///   openChannel: () async {
///     final channel = await ssh.forwardLocalUnix('/run/user/1000/vnc.sock');
///     return ScreenChannel(channel.stream, channel.sink, connectionDone: ssh.done);
///   },
///   trust: hostTrust,
/// );
/// session.events.listen((e) { if (e is ScreenFrameReady) { final f = session.takeFrame(); ... } });
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'src/screen_native.dart';

export 'src/screen_native.dart' show RustScreenNative, ScreenFrame, ScreenNative, ScreenNativeEvent, ScreenTile;

/// Words a remote screen's server chose (its desktop's name, why it refused or ended a session, its
/// certificate's subject), made fit to show and log: control characters (C0, DEL, C1) become
/// spaces, the marks that turn text around or hide (bidirectional controls, zero-width
/// characters, the byte order mark) are dropped, runs of spaces become one, and what is left is at
/// most [max] characters, an ellipsis ending one that was longer. So a server cannot draw over the
/// app's own words, reorder them, or flood a dialog or the connection log (found in a security
/// review).
String screenServerText(String text, {int max = 200}) {
  final out = StringBuffer();
  var space = false;
  for (final rune in text.runes) {
    final control = rune < 0x20 || (rune >= 0x7f && rune <= 0x9f);
    final hidden = rune == 0x061c ||
        (rune >= 0x200b && rune <= 0x200f) ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2060 && rune <= 0x2069) ||
        rune == 0xfeff;
    if (hidden) continue;
    if (control || rune == 0x20) {
      space = out.isNotEmpty;
      continue;
    }
    if (space) out.write(' ');
    space = false;
    out.writeCharCode(rune);
  }
  final clean = out.toString();
  final runes = clean.runes.toList();
  if (runes.length <= max) return clean;
  return '${String.fromCharCodes(runes.take(max - 3))}...';
}

/// The remote screen protocols the engine speaks.
enum ScreenProtocol {
  vnc,

  /// Not in the app's builds until RDP's step (the feature "rdp").
  rdp,
}

/// One display to ask an RDP server for (4.0): its size, its place among the others in
/// pixels from any origin, its scale factor in percent (0: none said), and whether it is the
/// primary one (the first is, where none or several say so). The engine takes several only as
/// a server takes them: 200 to 8192 a side, the width even, none over another, each touching
/// another, four at most.
class ScreenDisplaySpec {
  const ScreenDisplaySpec({
    this.x = 0,
    this.y = 0,
    required this.width,
    required this.height,
    this.scale = 0,
    this.primary = false,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final int scale;
  final bool primary;

  /// rust/src/screen/rdp_layout.rs DisplaySpec.
  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    if (scale != 0) 'scale': scale,
    if (primary) 'primary': true,
  };

  @override
  bool operator ==(Object other) =>
      other is ScreenDisplaySpec &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.scale == scale &&
      other.primary == primary;

  @override
  int get hashCode => Object.hash(x, y, width, height, scale, primary);

  @override
  String toString() => 'ScreenDisplaySpec(${width}x$height at $x,$y${scale == 0 ? '' : ' $scale%'}${primary ? ' primary' : ''})';
}

/// One of the remote's displays as the engine tells it: a rectangle of the picture, in its
/// pixels.
class ScreenDisplayRect {
  const ScreenDisplayRect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;

  /// The most rectangles read from one list: more than any session has displays
  /// (the engine's ceiling is 4).
  static const mostRead = 16;

  /// The largest place or side a rectangle may name: a remote picture's side is a 16 bit
  /// number in both protocols.
  static const largest = 0xffff;

  /// The rectangles of an engine's `displays` (lists of four whole numbers, none below zero
  /// or above [largest], none without a size); anything else in the list is left out,
  /// anything but a list is no displays, and what comes after the first [mostRead] entries
  /// is not looked at. The engine names only displays the app asked for; these bounds are
  /// for whatever else hands a list in (a window of its own is handed one as text), so that
  /// no sum of a place and a side can pass what a whole number holds.
  static List<ScreenDisplayRect> listFrom(Object? json) => [
    if (json is List)
      for (final r in json.take(mostRead))
        if (r is List &&
            r.length == 4 &&
            r.every((v) => v is int && v >= 0 && v <= largest) &&
            (r[2] as int) > 0 &&
            (r[3] as int) > 0)
          ScreenDisplayRect(r[0] as int, r[1] as int, r[2] as int, r[3] as int),
  ];

  @override
  bool operator ==(Object other) =>
      other is ScreenDisplayRect && other.x == x && other.y == y && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'ScreenDisplayRect(${width}x$height at $x,$y)';
}

/// The RD Gateway an RDP session goes through (4.0; rust/src/screen/rdp_gateway.rs).
/// The channel the session is given is then the connection to the gateway, and the session's own
/// connection to the PC (its TLS, its pin, NLA) runs inside the gateway's channel to [target].
/// [toString] never shows the password.
class ScreenGatewayOptions {
  const ScreenGatewayOptions({
    required this.host,
    this.port = 443,
    required this.target,
    this.targetPort = 3389,
    this.username,
    this.password,
    this.domain,
    this.tlsPin,
  });

  /// The gateway's name, as its certificate is checked and its HTTP request says it.
  final String host;
  final int port;

  /// The PC as the gateway is asked for it, and its RDP port.
  final String target;
  final int targetPort;

  /// The gateway's sign-in (NTLM): the PC's own account, or a key of its own.
  final String? username;
  final String? password;
  final String? domain;

  /// The SHA-256 (hex) of the gateway's certificate the person accepted, apart from the PC's.
  /// One an authority vouches for needs none.
  final String? tlsPin;

  ScreenGatewayOptions copyWith({String? tlsPin}) => ScreenGatewayOptions(
    host: host,
    port: port,
    target: target,
    targetPort: targetPort,
    username: username,
    password: password,
    domain: domain,
    tlsPin: tlsPin ?? this.tlsPin,
  );

  /// rust/src/screen/mod.rs GatewayRequest. Holds the password: never log it.
  Map<String, Object?> toRequest() => {
    'host': host,
    'port': port,
    'tls_pin': ?tlsPin,
    'username': ?username,
    'password': ?password,
    'domain': ?domain,
    'target': target,
    'target_port': targetPort,
  };

  @override
  String toString() =>
      'ScreenGatewayOptions($host:$port to $target:$targetPort, username: ${username == null ? 'none' : 'set'}, '
      'password: ${password == null ? 'none' : 'set'}, pinned: ${tlsPin != null})';
}

/// How a session connects: everything the engine is told at its start. [toString] never shows
/// the password.
class ScreenConnectOptions {
  const ScreenConnectOptions({
    required this.protocol,
    this.username,
    this.password,
    this.tlsPin,
    this.requireTls = false,
    this.shared = true,
    this.tileSize = 256,
    this.encodings,
    this.continuousUpdates,
    this.width,
    this.height,
    this.domain,
    this.serverName,
    this.rdpGraphics,
    this.rdpH264,
    this.rdpNla,
    this.rdpClipboard,
    this.rdpSound,
    this.allowAppleSignIn = false,
    this.displays,
    this.scale,
    this.rdpRelativeMouse = false,
    this.gateway,
  });

  /// An RDP session: always inside TLS, the certificate pinned by [tlsPin]. With [nla] (the
  /// default) Network Level Authentication and nothing less is asked for; without it, TLS
  /// alone, and no [password] is handed to the engine at all (the server shows its own sign-in
  /// screen). [clipboard]: whether the session has RDP's clipboard channel at all; without it
  /// the server has nothing to send a clipboard on or ask for one through. With it, nothing is
  /// shared until [ScreenSession.shareClipboard] says so. [sound]: whether the server is told
  /// this device plays the remote's sound (4.0); with it the session plays from the
  /// start where [soundOn], else silently until [ScreenSession.playSound] says so.
  const ScreenConnectOptions.rdp({
    String? username,
    String? password,
    String? domain,
    String? serverName,
    String? tlsPin,
    bool nla = true,
    bool clipboard = false,
    bool sound = false,
    bool soundOn = true,
    String? graphics,
    String? h264,
    int? width,
    int? height,
    int tileSize = 256,
    List<ScreenDisplaySpec>? displays,
    int? scale,
    bool relativeMouse = false,
    ScreenGatewayOptions? gateway,
  }) : this(
         protocol: ScreenProtocol.rdp,
         username: username,
         password: nla ? password : null,
         domain: domain,
         serverName: serverName,
         tlsPin: tlsPin,
         rdpNla: nla,
         rdpClipboard: clipboard ? 'off' : 'none',
         rdpSound: sound ? (soundOn ? 'on' : 'off') : null,
         rdpGraphics: graphics,
         rdpH264: h264,
         width: width,
         height: height,
         tileSize: tileSize,
         displays: displays,
         scale: scale,
         rdpRelativeMouse: relativeMouse,
         gateway: gateway,
       );

  /// A VNC session. [requireTls] refuses every security type but VeNCrypt (a VNC server reached
  /// without SSH); [shared] leaves other viewers connected.
  const ScreenConnectOptions.vnc({
    String? username,
    String? password,
    String? tlsPin,
    bool requireTls = false,
    bool shared = true,
    int tileSize = 256,
    List<String>? encodings,
    bool? continuousUpdates,
    bool allowAppleSignIn = false,
  }) : this(
         protocol: ScreenProtocol.vnc,
         username: username,
         password: password,
         tlsPin: tlsPin,
         requireTls: requireTls,
         shared: shared,
         tileSize: tileSize,
         encodings: encodings,
         continuousUpdates: continuousUpdates,
         allowAppleSignIn: allowAppleSignIn,
       );

  final ScreenProtocol protocol;

  /// VNC: for Apple Remote Desktop and VeNCrypt X509Plain. RDP: the account.
  final String? username;

  /// VNC: the VNC password (or the account's, for ARD and X509Plain); RDP: the account's. Handed
  /// to the engine only inside the start request, which is wiped natively once read; the engine
  /// wipes its own copy after the handshake.
  final String? password;

  /// The SHA-256 (hex, colons allowed) of the TLS certificate the person accepted (VeNCrypt,
  /// RDP): any other ends the session with [ScreenCloseReason.certificate].
  final String? tlsPin;
  final bool requireTls;
  final bool shared;

  /// Tiles' side in pixels (0: the whole screen as one image).
  final int tileSize;

  /// VNC encodings by name, in order (the engine's defaults when null).
  final List<String>? encodings;

  /// VNC: continuous updates when the server has them (null or true); false asks for each update.
  final bool? continuousUpdates;

  /// RDP: the desktop asked for, the Windows domain, the name TLS and NLA use, the picture's
  /// codecs ("gfx", "remotefx", "bitmap") and H.264 ("avc444", "avc420", "off").
  final int? width;
  final int? height;
  final String? domain;
  final String? serverName;
  final String? rdpGraphics;
  final String? rdpH264;

  /// RDP: false is a host's "Sign in without NLA" (TLS alone is asked for; the engine sends no
  /// password); true or null asks for Network Level Authentication and nothing less.
  final bool? rdpNla;

  /// RDP: the clipboard's channel. "none" (or null): the session has no such channel; "off": it
  /// has one and shares nothing until [ScreenSession.shareClipboard]; "on": shared from the
  /// start.
  final String? rdpClipboard;

  /// RDP: the remote's sound. Null or "none": the server is told there is no sound here and
  /// sends none; "on": played from the start; "off": silent until
  /// [ScreenSession.playSound] says so. A device without an output, or a build without sound,
  /// connects without it and says so ([ScreenConnected.soundUnavailable]).
  final String? rdpSound;

  /// RDP: the remote's displays (4.0). Null, or one: a single screen (of [width] by
  /// [height] when null). A layout the engine does not take ends the session before a byte
  /// is sent ([ScreenCloseReason.internal]).
  final List<ScreenDisplaySpec>? displays;

  /// RDP: a single screen's scale factor in percent (100 to 500; null or 0: the server's own).
  final int? scale;

  /// RDP: ask the server for relative mouse movement (a host whose person turned it on). It
  /// changes the client version the connection says, so it is asked only then;
  /// [ScreenConnected.relativeMouse] says whether the server takes it.
  final bool rdpRelativeMouse;

  /// VNC: whether Apple Remote Desktop's sign-in (security type 30) may be used, as the host's
  /// options chose it. ARD hands the server the user name and the password themselves (encrypted
  /// to a key the server picks), so it is never chosen by itself: off, the type is taken out of
  /// the server's offer before the engine reads it ([VncSecurityOfferFilter]). Kept on this side;
  /// the engine's request has no field for it.
  final bool allowAppleSignIn;

  /// RDP: the RD Gateway it goes through (4.0), or null for none.
  final ScreenGatewayOptions? gateway;

  /// [gatewayPin]: the gateway's pin ([ScreenGatewayOptions.tlsPin]).
  ScreenConnectOptions copyWith({String? tlsPin, String? gatewayPin}) => ScreenConnectOptions(
    protocol: protocol,
    username: username,
    password: password,
    tlsPin: tlsPin ?? this.tlsPin,
    requireTls: requireTls,
    shared: shared,
    tileSize: tileSize,
    encodings: encodings,
    continuousUpdates: continuousUpdates,
    width: width,
    height: height,
    domain: domain,
    serverName: serverName,
    rdpGraphics: rdpGraphics,
    rdpH264: rdpH264,
    rdpNla: rdpNla,
    rdpClipboard: rdpClipboard,
    rdpSound: rdpSound,
    allowAppleSignIn: allowAppleSignIn,
    displays: displays,
    scale: scale,
    rdpRelativeMouse: rdpRelativeMouse,
    gateway: gatewayPin == null ? gateway : gateway?.copyWith(tlsPin: gatewayPin),
  );

  /// rust/src/screen/mod.rs OpenRequest. Holds the password: never log it.
  Map<String, Object?> toRequest() => {
    'kind': protocol.name,
    'username': ?username,
    'password': ?password,
    'tls_pin': ?tlsPin,
    'require_tls': requireTls,
    'shared': shared,
    'tile_size': tileSize,
    'encodings': ?encodings,
    'continuous_updates': ?continuousUpdates,
    'width': ?width,
    'height': ?height,
    'domain': ?domain,
    'server_name': ?serverName,
    'rdp_graphics': ?rdpGraphics,
    'rdp_h264': ?rdpH264,
    'rdp_nla': ?rdpNla,
    'rdp_clipboard': ?rdpClipboard,
    'rdp_sound': ?rdpSound,
    if (displays != null && displays!.isNotEmpty) 'displays': [for (final d in displays!) d.toJson()],
    if (scale != null && scale != 0) 'scale': scale,
    if (rdpRelativeMouse) 'rdp_relative_mouse': true,
    if (protocol == ScreenProtocol.rdp && gateway != null) 'rdp_gateway': gateway!.toRequest(),
  };

  @override
  String toString() =>
      'ScreenConnectOptions(${protocol.name}, '
      'username: ${username == null ? 'none' : 'set'}, password: ${password == null ? 'none' : 'set'}, '
      'tlsPin: ${tlsPin ?? 'none'}, requireTls: $requireTls, shared: $shared, tileSize: $tileSize, '
      'apple: $allowAppleSignIn${gateway == null ? '' : ', gateway: $gateway'})';
}

/// Takes Apple Remote Desktop's sign-in (RFB security type 30) out of a VNC server's offer
/// before the engine reads it, for a host whose options did not choose it
/// ([ScreenConnectOptions.allowAppleSignIn]): the engine picks ARD by itself whenever it has a
/// user name and a password, and ARD gives the server both. Every other byte passes as it came,
/// at once: the greeting, and everything after the offer. Only the offer (its count and its
/// types, RFB 3.7 and 3.8) is held until it is whole. A server that offers ARD alone is answered
/// as one that offers nothing ([appleOnlyReason], a count of 0 and that reason, which the engine
/// reports as a protocol failure); nothing it sends after that reaches the engine. Under RFB 3.3
/// the server picks the type, and the engine takes only None and VNC authentication there.
class VncSecurityOfferFilter {
  VncSecurityOfferFilter();

  /// RFB's number for Apple Remote Desktop.
  static const appleType = 30;

  /// What the engine is told where the server offers Apple's sign-in alone (English, for the
  /// connection log and Copy details).
  static const appleOnlyReason =
      "the server offers only Apple's sign-in (Apple Remote Desktop), which this host does not use; "
      "on the Mac, turn on 'VNC viewers may control screen with password' in Screen Sharing";

  final _greeting = <int>[];
  final _offer = <int>[];
  bool _done = false;
  bool _dropRest = false;

  /// What of [data] goes to the engine now (possibly nothing yet).
  Uint8List take(Uint8List data) {
    if (_dropRest) return Uint8List(0);
    if (_done) return data;
    var i = 0;
    while (i < data.length && _greeting.length < 12) {
      _greeting.add(data[i++]);
    }
    if (_greeting.length < 12) return data;
    // The greeting goes as it came.
    final out = BytesBuilder()..add(Uint8List.sublistView(data, 0, i));
    if (_minorOf(_greeting) == 3) {
      _done = true;
      out.add(Uint8List.sublistView(data, i));
      return out.toBytes();
    }
    _offer.addAll(Uint8List.sublistView(data, i));
    if (_offer.isEmpty) return out.toBytes();
    final count = _offer[0];
    if (count == 0) {
      // No type at all: the server's reason follows, for the engine.
      _done = true;
      out.add(_offer);
      _offer.clear();
      return out.toBytes();
    }
    if (_offer.length < 1 + count) return out.toBytes();
    _done = true;
    final types = _offer.sublist(1, 1 + count);
    final rest = _offer.sublist(1 + count);
    _offer.clear();
    final kept = [
      for (final t in types)
        if (t != appleType) t,
    ];
    if (kept.isEmpty) {
      _dropRest = true;
      final reason = utf8.encode(appleOnlyReason);
      out
        ..addByte(0)
        ..add((ByteData(4)..setUint32(0, reason.length)).buffer.asUint8List())
        ..add(reason);
      return out.toBytes();
    }
    out
      ..addByte(kept.length)
      ..add(kept)
      ..add(rest);
    return out.toBytes();
  }

  /// The RFB minor version the engine answers a [greeting] with, as
  /// rust/src/vnc/engine/client/connect.rs reads it: 7, 8, or 3 for anything else.
  static int _minorOf(List<int> greeting) {
    final text = String.fromCharCodes(greeting);
    if (text == 'RFB 003.007\n') return 7;
    if (text.startsWith('RFB 003.') && text.substring(8, 11).compareTo('008') >= 0) return 8;
    if (text.startsWith('RFB 004.') || text.startsWith('RFB 005.')) return 8;
    return 3;
  }
}

/// The byte channel a session runs over: an SSH channel's stream and sink (or a socket's).
class ScreenChannel {
  const ScreenChannel(this.input, this.output, {this.connectionDone});
  final Stream<Uint8List> input;
  final StreamSink<List<int>> output;

  /// The SSH connection's `done`, so a channel ending with its connection is reported as that.
  final Future<void>? connectionDone;
}

/// A server's TLS certificate a session refused (not the pinned one, or none was pinned).
class ScreenCertificate {
  const ScreenCertificate({
    required this.sha256,
    required this.der,
    this.subject = '',
    this.notBefore,
    this.notAfter,
  });

  /// The SHA-256 of [der], 64 lower-case hexadecimal digits.
  final String sha256;

  /// The certificate itself (empty when the engine did not send it).
  final Uint8List der;

  /// RFC 4514 ("CN=host,O=Example"); empty when it did not parse.
  final String subject;

  /// Valid from and until (UTC); null when it did not parse.
  final DateTime? notBefore;
  final DateTime? notAfter;

  /// As server tools print it (`openssl x509 -fingerprint -sha256`): upper-case pairs with colons.
  String get fingerprint {
    final up = sha256.toUpperCase();
    return [for (var i = 0; i + 1 < up.length; i += 2) up.substring(i, i + 2)].join(':');
  }

  static ScreenCertificate? fromClosed(Map<Object?, Object?> json) {
    final sha = json['sha256'];
    if (sha is! String) return null;
    Uint8List der;
    try {
      der = json['der'] is String ? base64.decode(json['der'] as String) : Uint8List(0);
    } on FormatException {
      der = Uint8List(0);
    }
    DateTime? time(Object? s) =>
        s is num ? DateTime.fromMillisecondsSinceEpoch(s.toInt() * 1000, isUtc: true) : null;
    return ScreenCertificate(
      sha256: sha,
      der: der,
      subject: screenServerText((json['subject'] as String?) ?? ''),
      notBefore: time(json['not_before']),
      notAfter: time(json['not_after']),
    );
  }
}

/// What a session says.
sealed class ScreenEvent {
  const ScreenEvent();
}

/// The handshake is done: the server's facts.
final class ScreenConnected extends ScreenEvent {
  const ScreenConnected(this.info);
  final Map<String, Object?> info;

  /// RDP: the remote's sound plays at this rate and channel count (the speaker's own), where
  /// the session asked for sound and the device has an output; null otherwise.
  ({int rate, int channels})? get sound {
    final s = info['sound'];
    if (s is! Map) return null;
    final (rate, channels) = (s['rate'], s['channels']);
    return rate is int && channels is int && rate > 0 && channels > 0 ? (rate: rate, channels: channels) : null;
  }

  /// RDP: the session asked for sound and connected without it: why (no output on this
  /// device, or no sound in this build), in the engine's words; null otherwise.
  String? get soundUnavailable {
    final s = info['sound'];
    final why = s is Map ? s['unavailable'] : null;
    return why is String ? screenServerText(why) : null;
  }

  /// The desktop's name (the server's words: [screenServerText]) and size.
  String get name => screenServerText((info['name'] as String?) ?? '');
  int get width => (info['width'] as num?)?.toInt() ?? 0;
  int get height => (info['height'] as num?)?.toInt() ?? 0;

  /// The security type used ("None", "VncAuth", "VeNCrypt", "AppleRemoteDesktop").
  String get security => (info['security'] as String?) ?? '';

  /// VeNCrypt's TLS: `subtype`, `protocol`, `cipher_suite`, `cert_sha256`; null without TLS.
  Map<String, Object?>? get tls => (info['tls'] as Map?)?.cast<String, Object?>();

  /// RDP: the session asked for relative mouse movement and this server takes it
  /// ([ScreenSession.pointerRelative] sends nothing otherwise).
  bool get relativeMouse => info['relative_mouse'] == true;

  /// RDP: the remote's displays as rectangles of the picture; empty where the engine told
  /// none (VNC).
  List<ScreenDisplayRect> get displays => ScreenDisplayRect.listFrom(info['displays']);
}

/// The remote's displays changed (RDP): rectangles of the picture, in the order they were
/// asked for; one, the whole picture, where the server made another desktop than the one
/// asked for. It follows the [ScreenResized] of the same change.
final class ScreenDisplaysChanged extends ScreenEvent {
  const ScreenDisplaysChanged(this.displays);
  final List<ScreenDisplayRect> displays;
}

/// New pixels: take them with [ScreenSession.takeFrame].
final class ScreenFrameReady extends ScreenEvent {
  const ScreenFrameReady(this.seq);
  final int seq;
}

final class ScreenResized extends ScreenEvent {
  const ScreenResized(this.width, this.height);
  final int width;
  final int height;
}

/// The remote clipboard (text). Never log it.
final class ScreenClipboard extends ScreenEvent {
  const ScreenClipboard(this.text);
  final String text;

  @override
  String toString() => 'ScreenClipboard(${text.length} characters)';
}

final class ScreenBell extends ScreenEvent {
  const ScreenBell();
}

/// The remote cursor's shape, for the app to draw over the picture: [rgba] is `width * height * 4`
/// bytes (VNC: alpha 0 or 255; RDP: any alpha, the colours multiplied by it), its hot spot at
/// ([hotX], [hotY]). [hidden] when the server hides it; [system] when the server has no shape of
/// its own just now and the system's own pointer is the one to show (RDP).
final class ScreenCursor extends ScreenEvent {
  const ScreenCursor(this.width, this.height, this.hotX, this.hotY, this.rgba, {this.system = false});

  /// The system's own pointer.
  ScreenCursor.systemPointer() : this(0, 0, 0, 0, Uint8List(0), system: true);
  final int width;
  final int height;
  final int hotX;
  final int hotY;
  final Uint8List rgba;
  final bool system;
  bool get hidden => !system && (width == 0 || height == 0);

  /// [data] as the engine sends it; [a] is the event's number (1: the system's own pointer).
  static ScreenCursor? parse(Uint8List data, {int a = 0}) {
    if (a == 1) return ScreenCursor.systemPointer();
    if (data.length < 8) return null;
    final b = ByteData.sublistView(data);
    final (w, h) = (b.getUint16(0, Endian.little), b.getUint16(2, Endian.little));
    final (x, y) = (b.getUint16(4, Endian.little), b.getUint16(6, Endian.little));
    final pixels = Uint8List.sublistView(data, 8);
    if (pixels.length != w * h * 4) return ScreenCursor(0, 0, x, y, Uint8List(0));
    return ScreenCursor(w, h, x, y, pixels);
  }
}

/// Something about the session changed (for the log): `{"continuous_updates": true}`,
/// `{"paused": true, "how": "suppress_output"}`.
final class ScreenInfo extends ScreenEvent {
  const ScreenInfo(this.info);
  final Map<String, Object?> info;
}

/// Why a session ended (rust/src/screen/mod.rs CloseReason).
enum ScreenCloseReason {
  /// The app closed it.
  local,

  /// The remote screen's server ended it or closed the connection (a log off, the server
  /// stopping, another viewer taking over).
  serverClosed,

  /// The SSH connection or channel failed or closed.
  ssh,

  /// The network under the SSH connection failed.
  network,

  /// The server refused the credentials.
  auth,

  /// The server's TLS certificate is not the trusted one ([ScreenClosed.certificate] has it).
  certificate,

  /// TLS failed otherwise.
  tls,

  /// The server said something the engine cannot take, or offers nothing it can use.
  protocol,

  /// A bug, or something the device refused.
  internal;

  static ScreenCloseReason parse(String? name) => switch (name) {
    'local' => local,
    'server_closed' => serverClosed,
    'ssh' => ssh,
    'network' => network,
    'auth' => auth,
    'certificate' => certificate,
    'tls' => tls,
    'protocol' => protocol,
    _ => internal,
  };

  /// A dropped connection, which reconnecting may mend (the others need the person, or a
  /// change on the server).
  bool get isDrop => this == ssh || this == network;
}

/// The session ended: why ([reason]), in words ([message], English, for logs and Copy details;
/// screens word it from [reason]).
final class ScreenClosed extends ScreenEvent {
  const ScreenClosed(this.reason, this.message, {this.certificate, this.detail});
  final ScreenCloseReason reason;
  final String message;

  /// What exactly, where the app has words of its own for it: for RDP, `nla_missing` (the
  /// server has no Network Level Authentication and the host asks for it) and `nla_required`
  /// (the server insists on it and the host says without). Null otherwise.
  final String? detail;

  /// The certificate shown, for [ScreenCloseReason.certificate].
  final ScreenCertificate? certificate;

  String? get sha256 => certificate?.sha256;

  /// [message], unless the app closed it.
  String? get error => reason == ScreenCloseReason.local ? null : message;

  /// [message] may hold the server's own words (a refusal's reason): made fit to show and log
  /// ([screenServerText]), at most 400 characters.
  static ScreenClosed fromJson(Map<Object?, Object?> json) => ScreenClosed(
    ScreenCloseReason.parse(json['reason'] as String?),
    screenServerText((json['message'] as String?) ?? (json['error'] as String?) ?? 'closed', max: 400),
    certificate: ScreenCertificate.fromClosed(json),
    // One of the engine's own words (lower case, digits, an underscore), never a server's.
    detail: switch (json['detail']) {
      final String d when RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(d) => d,
      _ => null,
    },
  );

  @override
  String toString() => 'ScreenClosed(${reason.name}: $message)';
}

/// A session that ended before it connected.
class ScreenConnectException implements Exception {
  const ScreenConnectException(this.closed);
  final ScreenClosed closed;
  ScreenCloseReason get reason => closed.reason;

  @override
  String toString() => 'ScreenConnectException(${closed.reason.name}: ${closed.message})';
}

/// What an app keeps of the certificates people accepted for one screen host, and how it asks
/// about one. The app binds it to the host's scope (its address, and the SSH host it is reached
/// through), so this side knows none of it.
abstract interface class ScreenTrust {
  /// The SHA-256 (hex) of the certificate accepted for this host, or null.
  Future<String?> pinned();

  /// Asks whether to trust [presented]. [previous] is the one accepted before, where there was
  /// one (a changed certificate, asked about as loudly as a changed host key). False: the
  /// connection stops.
  Future<bool> ask(ScreenCertificate presented, {String? previous});

  /// Keeps [cert] as this host's.
  Future<void> remember(ScreenCertificate cert);
}

/// A rectangle of a session's picture read by a reader of its own (4.0): a window that
/// shows one of the remote's displays, or a small picture of one. It is opened by the session's
/// number ([ScreenSession.handle]), from the engine that owns the session or from another engine
/// of the same process (a window of its own), which has no session object.
///
/// A view is never told of a change: [takeFrame] is asked when its reader draws, and gives null
/// when nothing in it changed. Tiles' places are counted from the view's own corner, and the
/// frame's size is the view's. A session that ends takes its views with it: [alive] is then
/// false and [takeFrame] null. Close it when its reader goes; one left open costs the engine a
/// few flags until its session ends.
class ScreenViewReader {
  ScreenViewReader._(this._native, this.sessionHandle, this.id, this.x, this.y, this.width, this.height);

  /// Opens a view on [x], [y], [width], [height] of the picture of session [sessionHandle], its
  /// own picture [divide] times smaller a side (1: as it is; up to 16). Null where the engine
  /// opened none: no such session, an empty rectangle, sixteen views open already.
  static ScreenViewReader? open(
    int sessionHandle, {
    required int x,
    required int y,
    required int width,
    required int height,
    int divide = 1,
    ScreenNative? native,
  }) {
    if (sessionHandle == 0 || x < 0 || y < 0 || width <= 0 || height <= 0 || divide < 1 || divide > 16) return null;
    final n = native ?? RustScreenNative();
    final id = n.viewOpen(sessionHandle, x, y, width, height, divide);
    return id == 0 ? null : ScreenViewReader._(n, sessionHandle, id, x, y, width, height);
  }

  final ScreenNative _native;
  final int sessionHandle;

  /// The engine's number for this view (from 1).
  final int id;

  /// The rectangle of the picture it was opened on.
  final int x;
  final int y;
  final int width;
  final int height;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Whether the session is still there with this view open.
  bool get alive => !_closed && _native.viewAlive(sessionHandle, id);

  /// The view's tiles that changed since the last call, or null. Free it once its pixels are
  /// copied.
  ScreenFrame? takeFrame() => _closed ? null : _native.viewTakeFrame(sessionHandle, id);

  /// Lets the view go. Twice is once.
  void close() {
    if (_closed) return;
    _closed = true;
    _native.viewClose(sessionHandle, id);
  }
}

/// Where a session is.
enum ScreenSessionState { connecting, connected, closed }

/// One remote screen session (VNC, or RDP in a build with it), running on a Rust thread of its own.
class ScreenSession {
  ScreenSession._(this._native, this.options, {bool reader = false})
    : isReader = reader,
      _offerFilter = options.protocol == ScreenProtocol.vnc && !options.allowAppleSignIn
          ? VncSecurityOfferFilter()
          : null;

  /// Bytes waiting in the engine above which the channel is paused (the SSH window then holds the
  /// server back), as rust/src/screen/mod.rs FEED_HIGH_MARK; the engine says DRAINED below its low
  /// mark and the channel resumes.
  static const feedHighMark = 4 << 20;

  final ScreenNative _native;
  final ScreenConnectOptions options;
  final VncSecurityOfferFilter? _offerFilter;
  int _handle = 0;
  final _events = StreamController<ScreenEvent>.broadcast(sync: true);
  final _connected = Completer<ScreenConnected>();
  StreamSubscription<Uint8List>? _input;
  StreamSink<List<int>>? _output;
  ScreenSessionState _state = ScreenSessionState.connecting;
  ScreenClosed? _closedWith;
  bool _paused = false;
  bool _released = false;

  /// This object reads and drives a session another engine of the process owns
  /// ([ScreenSession.reader]): it never ends that session.
  final bool isReader;

  // A reader's: its view on the picture, the frame it found waiting, and the timer that looks.
  ScreenViewReader? _view;
  ScreenFrame? _waiting;
  Timer? _look;
  int _looks = 0;

  /// A side no picture has: a view asked for this much shows all there is.
  static const _all = 1 << 16;

  /// How many looks pass between two checks that the session is still there.
  static const _aliveEvery = 32;

  /// Bytes each way through the bridge.
  int bytesIn = 0;
  int bytesOut = 0;

  /// Starts a session. Throws [ArgumentError] when the engine refuses the request (no engine for
  /// the protocol in this build). Nothing is sent until [attach].
  factory ScreenSession.open(ScreenConnectOptions options, {ScreenNative? native}) {
    final n = native ?? RustScreenNative();
    final session = ScreenSession._(n, options);
    session._handle = n.open(jsonEncode(options.toRequest()), session._onNative);
    if (session._handle == 0) {
      throw ArgumentError('the screen engine refused the request (${options.protocol.name} in this build?)');
    }
    // Nothing waits on it before attach; a failure to connect is also an event.
    session._connected.future.ignore();
    return session;
  }

  /// A session that another engine of this process owns, read and driven from here: a window
  /// of its own showing a screen (4.0). [handle] is that session's
  /// ([ScreenSession.handle]), [info] what its [ScreenConnected] said.
  ///
  /// The picture comes through a view of the engine, which is never told of a change: this
  /// object looks [every] so often, and says [ScreenFrameReady] when there is something to
  /// take. Keys, the pointer, a resize, a layout and a refresh go to the session by its
  /// number. What only its owner can know (the remote's cursor, its displays changing, why it
  /// ended) is handed in with [relayed]. Pausing stops this reader's looking, not the
  /// server; the clipboard stays the owner's; [close] lets go of the view and leaves the
  /// session running.
  ///
  /// A session that is gone already gives a session that is closed.
  factory ScreenSession.reader(
    int handle, {
    required ScreenProtocol protocol,
    Map<String, Object?> info = const {},
    ScreenNative? native,
    Duration every = const Duration(milliseconds: 8),
  }) {
    final n = native ?? RustScreenNative();
    final session = ScreenSession._(n, ScreenConnectOptions(protocol: protocol), reader: true);
    session._handle = handle;
    session._state = ScreenSessionState.connected;
    session._connected.complete(ScreenConnected(info));
    session._view = ScreenViewReader.open(handle, x: 0, y: 0, width: _all, height: _all, native: n);
    if (session._view == null) {
      session._finish(const ScreenClosed(ScreenCloseReason.local, 'the session is gone'));
    } else {
      session._look = Timer.periodic(every, (_) => session._lookNow());
    }
    return session;
  }

  void _lookNow() {
    final view = _view;
    if (isClosed || _paused || view == null) return;
    if (_waiting == null) {
      final frame = view.takeFrame();
      if (frame != null) {
        _waiting = frame;
        _events.add(ScreenFrameReady(frame.seq));
        return;
      }
    }
    // Now and then: the session ended, and its owner did not say so (it may be gone itself).
    if (++_looks % _aliveEvery == 0 && !view.alive) {
      _finish(const ScreenClosed(ScreenCloseReason.local, 'the session ended'));
    }
  }

  /// A reader's view on another part of the picture (or all of it), starting with all of it.
  void _viewOn(int x, int y, int width, int height) {
    _view?.close();
    _waiting?.free();
    _waiting = null;
    _view = ScreenViewReader.open(_handle, x: x, y: y, width: width, height: height, native: _native);
    if (_view == null) _finish(const ScreenClosed(ScreenCloseReason.local, 'the session ended'));
  }

  /// For a reader ([isReader]): an event of the session that its owner passed on (the
  /// remote's cursor, its displays, a new size, what the server says, why it ended). A
  /// [ScreenClosed] ends this reader with that reason. Frames are found by looking and
  /// clipboard text stays the owner's: neither is taken here.
  void relayed(ScreenEvent event) {
    if (!isReader || isClosed) return;
    switch (event) {
      case ScreenClosed():
        _finish(event);
      case ScreenFrameReady() || ScreenClipboard() || ScreenConnected():
        break;
      default:
        _events.add(event);
    }
  }

  /// Opens a session over [openChannel]'s channel with [trust]'s rule: the certificate accepted
  /// before for the host (if any); a different or first certificate is asked about, and on a yes
  /// kept and the connection made again (a new channel) with exactly that one. Completes once
  /// connected; throws [ScreenConnectException] when it ends first (the certificate refused,
  /// the credentials, the channel...).
  ///
  /// [handshakeTimeout]: how long each try may take from its channel to connected. A server that
  /// takes the connection and then says nothing (or stops half way) is closed then, its engine
  /// and channel with it, with [ScreenCloseReason.network] and the detail [handshakeTimedOut].
  /// [onSession] is given each try's session as soon as it is open, so whoever started it can
  /// close it before it has connected (a Disconnect while it is still connecting).
  static Future<ScreenSession> connectTrusting(
    ScreenConnectOptions options, {
    required Future<ScreenChannel> Function() openChannel,
    required ScreenTrust trust,
    ScreenTrust? gatewayTrust,
    ScreenNative? native,
    Duration? handshakeTimeout,
    void Function(ScreenSession session)? onSession,
  }) async {
    final pinned = await trust.pinned();
    // Through an RD Gateway (4.0) there are two certificates, each asked about and kept
    // on its own: the gateway's (the engine says `gateway` of it) and the PC's. Each is asked
    // about once a try; a gateway without [gatewayTrust] is never trusted by a question.
    final gatewayPinned = options.gateway == null ? null : await gatewayTrust?.pinned();
    var tryWith = options.copyWith(tlsPin: pinned, gatewayPin: gatewayPinned);
    final askedAbout = <bool>{};
    while (true) {
      try {
        return await _connectOnce(tryWith, openChannel, native, handshakeTimeout, onSession);
      } on ScreenConnectException catch (e) {
        final shown = e.closed.certificate;
        if (e.reason != ScreenCloseReason.certificate || shown == null) rethrow;
        final forGateway = e.closed.detail == 'gateway';
        final ask = forGateway ? gatewayTrust : trust;
        if (ask == null || !askedAbout.add(forGateway)) rethrow;
        if (!await ask.ask(shown, previous: forGateway ? gatewayPinned : pinned)) rethrow;
        // Kept once the person says yes, as an SSH host key is: before the credentials are sent
        // (VeNCrypt sends them only inside TLS, after this check; the gateway's sign-in goes
        // only inside its TLS).
        await ask.remember(shown);
        tryWith = forGateway ? tryWith.copyWith(gatewayPin: shown.sha256) : tryWith.copyWith(tlsPin: shown.sha256);
      }
    }
  }

  /// What a session closed by [connectTrusting]'s handshake deadline says
  /// ([ScreenClosed.detail]).
  static const handshakeTimedOut = 'handshake_timeout';

  static Future<ScreenSession> _connectOnce(
    ScreenConnectOptions options,
    Future<ScreenChannel> Function() openChannel,
    ScreenNative? native,
    Duration? handshakeTimeout,
    void Function(ScreenSession session)? onSession,
  ) async {
    final channel = await openChannel();
    final ScreenSession session;
    try {
      session = ScreenSession.open(options, native: native);
    } catch (_) {
      await channel.output.close();
      rethrow;
    }
    session.attach(channel.input, channel.output, connectionDone: channel.connectionDone);
    onSession?.call(session);
    if (handshakeTimeout == null) {
      await session.connected;
      return session;
    }
    await session.connected.timeout(handshakeTimeout, onTimeout: () {
      // The engine stops (its pipe ends) and the channel closes, as on any end.
      session._finish(ScreenClosed(
        ScreenCloseReason.network,
        'the server did not finish connecting within ${handshakeTimeout.inSeconds} seconds',
        detail: handshakeTimedOut,
      ));
      return session.connected;
    });
    return session;
  }

  /// Microseconds on the clock frames are stamped with (the real engine's).
  static int nowUs() => RustScreenNative().nowUs();

  Stream<ScreenEvent> get events => _events.stream;
  ScreenSessionState get state => _state;
  bool get isClosed => _state == ScreenSessionState.closed;
  bool get isPaused => _paused;

  /// How it ended, once it has.
  ScreenClosed? get closedWith => _closedWith;

  /// Completes when the handshake is done; fails with [ScreenConnectException] when the session
  /// ends first.
  Future<ScreenConnected> get connected => _connected.future;

  /// Connects the session to a byte channel (an SSH channel's stream and sink): what it receives
  /// goes to the engine, what the engine writes goes to [output]. The channel is paused while the
  /// engine is more than [feedHighMark] behind.
  ///
  /// [connectionDone] is the SSH connection's `done`: when the channel ends because the connection
  /// failed or closed, the session ends with that reason ([ScreenCloseReason.network] or
  /// [ScreenCloseReason.ssh]) instead of "the server closed the connection". A channel's end can
  /// come a moment before the connection's error, so a clean end waits up to [settle] for it.
  void attach(
    Stream<Uint8List> input,
    StreamSink<List<int>> output, {
    Future<void>? connectionDone,
    Duration settle = const Duration(milliseconds: 150),
  }) {
    if (isReader) throw StateError('a reader has no channel: its session is another engine\'s');
    if (_input != null) throw StateError('the session is attached already');
    if (isClosed) {
      unawaited(output.close());
      return;
    }
    _output = output;
    Object? connectionError;
    var connectionClosed = false;
    // Typed void with block bodies: an arrow body's value as onError's result threw
    // ("must return a value of the returned future's type") the moment the connection failed.
    connectionDone?.then<void>(
      (_) {
        connectionClosed = true;
      },
      onError: (Object e) {
        connectionError = e;
      },
    );
    void ended(Object? channelError) {
      if (isClosed) return;
      if (channelError != null) return transportFailed(channelError);
      if (connectionDone == null) return _native.feedEnd(_handle);
      Future<void>.delayed(Duration.zero).then((_) async {
        final deadline = DateTime.now().add(settle);
        while (connectionError == null && !connectionClosed && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (isClosed) return;
        if (connectionError != null) {
          transportFailed(connectionError!);
        } else if (connectionClosed) {
          transportFailed('the SSH connection closed');
        } else {
          _native.feedEnd(_handle);
        }
      });
    }

    _input = input.listen(
      (data) {
        final queued = feed(data);
        if (queued > feedHighMark && !(_input?.isPaused ?? true)) _input?.pause();
      },
      onDone: () => ended(null),
      onError: (Object e) => ended(e),
    );
  }

  /// The channel under the session failed with [error]: the session ends with it as the reason
  /// (a socket error or a time out is [ScreenCloseReason.network], anything else
  /// [ScreenCloseReason.ssh]).
  void transportFailed(Object error) {
    if (isClosed || isReader) return;
    final network = error is SocketException || error is TimeoutException || error is OSError;
    _native.feedFail(_handle, network: network, message: error is String ? error : 'SSH: $error');
  }

  /// Bytes for the engine; returns how many wait unread.
  int feed(Uint8List data) {
    if (isClosed || isReader || data.isEmpty) return 0;
    bytesIn += data.length;
    final filter = _offerFilter;
    final out = filter == null ? data : filter.take(data);
    if (out.isEmpty) return 0;
    return _native.feed(_handle, out);
  }

  /// The pointer at ([x], [y]) in remote pixels with these [buttons] (bit 0 left, 1 middle,
  /// 2 right, 3 wheel up, 4 wheel down, 5 and 6 wheel left and right).
  void pointer(int x, int y, int buttons) {
    if (!isClosed) _native.pointer(_handle, x < 0 ? 0 : x, y < 0 ? 0 : y, buttons & 0xff);
  }

  /// A key by its X keysym and its scancode (XT set 1 in QEMU's numbering: 0x80 added for the
  /// keys that come after an 0xE0 prefix; 0 when not known). VNC sends both (QEMU extended key
  /// events) once the server confirmed them, else the keysym; RDP sends the scancode, or the
  /// character as Unicode when there is none.
  /// The mouse moved by ([dx], [dy]) with [buttons] down (as [pointer]'s): sent as movement
  /// where the session asked for relative mouse and the server takes it
  /// ([ScreenConnected.relativeMouse]); nothing otherwise (a [ScreenInfo] says so once:
  /// `relative_mouse_unavailable`).
  void pointerRelative(int dx, int dy, int buttons) {
    if (!isClosed) _native.pointerRelative(_handle, dx, dy, buttons);
  }

  void key(int keysym, {required bool down, int scancode = 0}) {
    if (!isClosed) _native.key(_handle, keysym, scancode, down: down);
  }

  /// Text for the remote clipboard (VNC: the extended clipboard's UTF-8 when the server has it,
  /// else Latin-1; text over 1 MiB is cut). Whether the clipboard may go is the app's rule.
  void sendClipboard(String text) {
    if (!isClosed && !isReader) _native.clipboard(_handle, text);
  }

  /// Whether the clipboard is shared with the remote from now on (the app's switch for this
  /// screen). For an RDP session with the clipboard's channel: off wipes the text last given
  /// with [sendClipboard], tells the server there is none and takes none of the server's; on
  /// asks for the server's text where it has some. VNC has nothing to do: its text comes and
  /// goes as the app lets it.
  void shareClipboard({required bool on}) {
    if (!isClosed && !isReader) _native.clipboardShare(_handle, on: on);
  }

  /// Whether the remote's sound is played from now on (an RDP session whose options asked for
  /// sound, on a device with an output): off empties what waits to be played. Nothing
  /// otherwise, and nothing from a reader (a window of its own): sound is the owner's.
  void playSound({required bool on}) {
    if (!isClosed && !isReader) _native.sound(_handle, on: on);
  }

  /// The view's size in remote pixels: an RDP server resizes its desktop to it when it allows
  /// (a [ScreenResized] follows); VNC ignores it for now.
  void resize(int width, int height) {
    if (!isClosed && width > 0 && height > 0) _native.resize(_handle, width, height);
  }

  /// The displays the remote should have from now on (RDP's display control channel; nothing
  /// for VNC). A [ScreenResized] and a [ScreenDisplaysChanged] follow where the server takes
  /// them; a layout it does not take is said in a [ScreenInfo] (`layout_refused`). False where
  /// the session is closed, the list is empty, or the engine did not take it.
  bool setDisplays(List<ScreenDisplaySpec> displays) {
    if (isClosed || displays.isEmpty) return false;
    return _native.displays(_handle, jsonEncode([for (final d in displays) d.toJson()]));
  }

  /// What [takeFrame] gives from now on: the rectangle [x], [y], [width], [height] of the
  /// picture (one of the remote's displays), counted from that rectangle's corner and of its
  /// size, starting with all of it; take a frame after this without waiting for a
  /// [ScreenFrameReady]. [pointer] still takes places in the whole picture.
  void showPart(int x, int y, int width, int height) {
    if (isClosed || x < 0 || y < 0 || width <= 0 || height <= 0) return;
    // A reader has a view of its own: what the session's own reader is shown is its owner's.
    if (isReader) return _viewOn(x, y, width, height);
    _native.show(_handle, x, y, width, height);
  }

  /// [takeFrame] gives the whole picture again, starting with all of it.
  void showAll() {
    if (isClosed) return;
    if (isReader) return _viewOn(0, 0, _all, _all);
    _native.show(_handle, 0, 0, 0, 0);
  }

  /// The engine's number for this session: what a [ScreenViewReader] opened elsewhere in the process
  /// (a window of its own) reads the picture by. It names the session and nothing about it.
  int get handle => _handle;

  /// A view on a rectangle of this session's picture, or null (closed, an empty rectangle,
  /// sixteen views open already).
  ScreenViewReader? openView({required int x, required int y, required int width, required int height, int divide = 1}) =>
      isClosed ? null : ScreenViewReader.open(_handle, x: x, y: y, width: width, height: height, divide: divide, native: _native);

  /// Asks the server for the whole screen again.
  void fullRefresh() {
    if (!isClosed) _native.fullRefresh(_handle);
  }

  /// The view is hidden: the server stops sending (VNC: no update requests, continuous updates
  /// off; RDP: Suppress Output). Input still goes; a [ScreenInfo] says how. Twice is once.
  void pause() {
    if (isClosed || _paused) return;
    _paused = true;
    // A reader stops looking; whether the server sends is its owner's to say.
    if (isReader) return;
    _native.pause(_handle);
  }

  /// Back from [pause]: updates again, the whole screen first.
  void resume() {
    if (isClosed || !_paused) return;
    _paused = false;
    // A reader starts with all of the part it shows again, as a resumed session does.
    if (isReader) {
      final at = _view;
      if (at != null) _viewOn(at.x, at.y, at.width, at.height);
      return;
    }
    _native.resume(_handle);
  }

  /// The tiles that changed since the last call, or null. Free it once its pixels are copied.
  ScreenFrame? takeFrame() {
    if (isClosed) return null;
    if (!isReader) return _native.takeFrame(_handle);
    final waiting = _waiting;
    _waiting = null;
    return waiting ?? _view?.takeFrame();
  }

  void _onNative(int kind, int a, Uint8List? bytes) {
    if (kind == ScreenEventKind.closed) {
      _finish(_closedFrom(bytes));
      // CLOSED is the native side's last event: its callback can go.
      if (!_released) {
        _released = true;
        _native.release(_handle);
      }
      return;
    }
    if (isClosed) return;
    switch (kind) {
      case ScreenEventKind.send:
        if (bytes == null) return;
        bytesOut += bytes.length;
        _output?.add(bytes);
      case ScreenEventKind.connected:
        final info = _json(bytes) ?? const <String, Object?>{};
        final e = ScreenConnected(info);
        _state = ScreenSessionState.connected;
        if (!_connected.isCompleted) _connected.complete(e);
        _events.add(e);
      case ScreenEventKind.frame:
        _events.add(ScreenFrameReady(a));
      case ScreenEventKind.drained:
        if (_input?.isPaused ?? false) _input?.resume();
      case ScreenEventKind.clipboard:
        if (bytes != null) _events.add(ScreenClipboard(utf8.decode(bytes, allowMalformed: true)));
      case ScreenEventKind.bell:
        _events.add(const ScreenBell());
      case ScreenEventKind.resize:
        _events.add(ScreenResized(a >> 32, a & 0xffffffff));
      case ScreenEventKind.displays:
        final displays = ScreenDisplayRect.listFrom(_json(bytes)?['displays']);
        if (displays.isNotEmpty) _events.add(ScreenDisplaysChanged(displays));
      case ScreenEventKind.info:
        final info = _json(bytes);
        if (info != null) _events.add(ScreenInfo(info));
      case ScreenEventKind.cursor:
        final cursor = bytes == null ? null : ScreenCursor.parse(bytes, a: a);
        if (cursor != null) _events.add(cursor);
    }
  }

  static Map<String, Object?>? _json(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      final v = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return v is Map ? v.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  static ScreenClosed _closedFrom(Uint8List? bytes) {
    final json = _json(bytes);
    return json == null
        ? const ScreenClosed(ScreenCloseReason.internal, 'the engine ended the session without a reason')
        : ScreenClosed.fromJson(json);
  }

  void _finish(ScreenClosed closed) {
    if (isClosed) return;
    _state = ScreenSessionState.closed;
    _closedWith = closed;
    unawaited(_input?.cancel());
    _input = null;
    if (isReader) {
      // Its view goes; the session is its owner's to end.
      _look?.cancel();
      _look = null;
      _waiting?.free();
      _waiting = null;
      _view?.close();
      _view = null;
    } else {
      // The engine stops at once (close never waits on it for long): nothing but CLOSED follows,
      // and what comes before it is ignored now.
      _native.close(_handle);
    }
    unawaited(_output?.close().catchError((Object _) {}));
    if (!_connected.isCompleted) _connected.completeError(ScreenConnectException(closed));
    _events.add(closed);
    unawaited(_events.close());
  }

  /// Ends the session (and closes the channel's sink). Its [events] end with a
  /// [ScreenCloseReason.local] [ScreenClosed]; the engine's own CLOSED, which follows, releases
  /// its callback.
  void close() => _finish(const ScreenClosed(ScreenCloseReason.local, 'closed'));
}
