// ZestSSH 4.0 spike, developer only (never shipped): SSH X11 forwarding over zest_ssh_core, what
// OpenSSH's `ssh -X` and `ssh -Y` do on the client side, in pure Dart (no Flutter, so the CLI
// probe in bin/ runs it too).
//
// 1. A random fake MIT-MAGIC-COOKIE-1 goes to the server in `x11-req` (RFC 4254, 6.3); sshd puts
//    it in the remote account's Xauthority and opens an `x11` channel back to us for each X client.
// 2. Each channel starts with the X connection setup (X11 protocol, "Connection Setup"): byte
//    order, version, the authorization protocol name and data. We read it whole, check that it
//    carries exactly the fake cookie (else the channel is closed: a remote program that did not
//    get the cookie from this session's sshd gets nothing), and write it on to the local X server
//    with the real authorization instead (the local cookie, or none when the server has no access
//    control), then splice the two.
// 3. Untrusted (-X): before the first channel, the SECURITY extension of the local X server is
//    asked for a new cookie of trust level Untrusted (SecurityGenerateAuthorization), which is what
//    the remote clients then get; it is revoked when the forwarder closes. Trusted (-Y): the real
//    cookie itself.
//
// The local X server: `DISPLAY`-style text. "host:N" is TCP 6000 + N; ":N" or "unix:N" is the Unix
// socket /tmp/.X11-unix/XN (Linux, macOS), or TCP 127.0.0.1:6000 + N on Windows (VcXsrv, X410 and
// Xming listen there); a path before the colon (XQuartz's launchd socket,
// "/private/tmp/com.apple.launchd.<id>/org.xquartz:0") is that socket.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zest_ssh_core/zest_ssh_core.dart';

const mitMagicCookie = 'MIT-MAGIC-COOKIE-1';

/// Where the local X server takes connections.
class X11Display {
  X11Display.tcp(this.host, this.number, {this.screen = 0}) : unixPath = null;
  X11Display.unix(String path, this.number, {this.screen = 0})
      : unixPath = path,
        host = null;

  final String? host;
  final String? unixPath;
  final int number;
  final int screen;

  int get port => 6000 + number;

  /// Parses DISPLAY-style text: "host:N[.S]", ":N[.S]", "unix:N", "/path/to/socket:N".
  static X11Display parse(String text, {bool? windows}) {
    final isWindows = windows ?? Platform.isWindows;
    final colon = text.lastIndexOf(':');
    if (colon < 0) throw FormatException('not an X display: $text');
    final head = text.substring(0, colon);
    final tail = text.substring(colon + 1);
    final dot = tail.indexOf('.');
    final number = int.parse(dot < 0 ? tail : tail.substring(0, dot));
    final screen = dot < 0 ? 0 : int.parse(tail.substring(dot + 1));
    if (number < 0 || number > 59535) throw FormatException('display number out of range: $text');
    if (head.startsWith('/')) return X11Display.unix(head, number, screen: screen);
    if (head.isEmpty || head == 'unix') {
      if (isWindows) return X11Display.tcp('127.0.0.1', number, screen: screen);
      return X11Display.unix('/tmp/.X11-unix/X$number', number, screen: screen);
    }
    return X11Display.tcp(head, number, screen: screen);
  }

  Future<Socket> connect({Duration timeout = const Duration(seconds: 5)}) {
    final path = unixPath;
    if (path != null) {
      return Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0, timeout: timeout);
    }
    return Socket.connect(host!, port, timeout: timeout);
  }

  @override
  String toString() => unixPath != null ? '$unixPath (:$number)' : '$host:$number';
}

/// The authorization a connection to the local X server carries ([name] empty: none).
class X11Auth {
  const X11Auth(this.name, this.data);
  const X11Auth.none()
      : name = '',
        data = const [];
  X11Auth.cookie(List<int> cookie)
      : name = mitMagicCookie,
        data = cookie;

  final String name;
  final List<int> data;
  bool get isNone => name.isEmpty;
}

/// Hex text to bytes ("" gives none).
Uint8List hexBytes(String hex) {
  final h = hex.trim();
  if (h.length.isOdd) throw const FormatException('odd hex length');
  return Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
}

String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

int _pad4(int n) => (4 - n % 4) % 4;

/// The client's X connection setup, as read from a forwarded channel.
class X11Setup {
  X11Setup(this.bigEndian, this.major, this.minor, this.authName, this.authData, this.length);

  final bool bigEndian;
  final int major;
  final int minor;
  final String authName;
  final Uint8List authData;

  /// Bytes the setup took in the stream.
  final int length;

  /// The setup in [buf] when it is all there; null while bytes are missing. Throws on a setup
  /// that is not X11's.
  static X11Setup? tryParse(Uint8List buf) {
    if (buf.isEmpty) return null;
    final order = buf[0];
    if (order != 0x42 && order != 0x6c) throw const FormatException('not an X11 connection setup (byte order)');
    if (buf.length < 12) return null;
    final big = order == 0x42;
    final bd = ByteData.sublistView(buf);
    final e = big ? Endian.big : Endian.little;
    final major = bd.getUint16(2, e), minor = bd.getUint16(4, e);
    final n = bd.getUint16(6, e), d = bd.getUint16(8, e);
    if (major != 11) throw FormatException('X protocol $major is not 11');
    final total = 12 + n + _pad4(n) + d + _pad4(d);
    if (buf.length < total) return null;
    final name = String.fromCharCodes(buf.sublist(12, 12 + n));
    final dataAt = 12 + n + _pad4(n);
    return X11Setup(big, major, minor, name, Uint8List.fromList(buf.sublist(dataAt, dataAt + d)), total);
  }

  /// The setup again with [auth] in place of what the client sent, in the client's byte order.
  Uint8List rewrite(X11Auth auth) => build(auth, bigEndian: bigEndian, major: major, minor: minor);

  static Uint8List build(X11Auth auth, {bool bigEndian = false, int major = 11, int minor = 0}) {
    final n = auth.name.length, d = auth.data.length;
    final out = Uint8List(12 + n + _pad4(n) + d + _pad4(d));
    final bd = ByteData.sublistView(out);
    final e = bigEndian ? Endian.big : Endian.little;
    out[0] = bigEndian ? 0x42 : 0x6c;
    bd.setUint16(2, major, e);
    bd.setUint16(4, minor, e);
    bd.setUint16(6, n, e);
    bd.setUint16(8, d, e);
    out.setRange(12, 12 + n, auth.name.codeUnits);
    out.setRange(12 + n + _pad4(n), 12 + n + _pad4(n) + d, auth.data);
    return out;
  }
}

/// Equal in time that does not depend on where they differ.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Reads the cookie for display [number] from an Xauthority file's bytes (the format xauth
/// writes: family, address, display number, name, data; each a big-endian length and bytes).
/// [hostname] picks a FamilyLocal entry of this machine; FamilyWild matches any.
Uint8List? xauthorityCookie(Uint8List file, int number, {String? hostname}) {
  final bd = ByteData.sublistView(file);
  var i = 0;
  Uint8List? field() {
    if (i + 2 > file.length) return null;
    final n = bd.getUint16(i);
    if (i + 2 + n > file.length) return null;
    final v = Uint8List.sublistView(file, i + 2, i + 2 + n);
    i += 2 + n;
    return v;
  }

  Uint8List? fallback;
  while (i + 2 <= file.length) {
    final family = bd.getUint16(i);
    i += 2;
    final address = field(), num = field(), name = field(), data = field();
    if (address == null || num == null || name == null || data == null) break;
    if (String.fromCharCodes(name) != mitMagicCookie) continue;
    if (String.fromCharCodes(num) != '$number' && num.isNotEmpty) continue;
    // 256 FamilyLocal (the address is the host name), 65535 FamilyWild, 0 FamilyInternet.
    if (family == 256 && (hostname == null || String.fromCharCodes(address) == hostname)) return Uint8List.fromList(data);
    if (family == 65535) fallback ??= Uint8List.fromList(data);
    if (family == 0) fallback ??= Uint8List.fromList(data);
  }
  return fallback;
}

/// A small X client on one connection to the local X server, for the SECURITY extension's
/// requests (little-endian, as it says in its setup).
class X11ControlConnection {
  X11ControlConnection._(this._socket) {
    _sub = _socket.listen((d) {
      _buf.add(d);
      _wake?.complete();
      _wake = null;
    }, onDone: () {
      _closed = true;
      _wake?.complete();
      _wake = null;
    }, onError: (Object _) {
      _closed = true;
      _wake?.complete();
      _wake = null;
    });
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder();
  Completer<void>? _wake;
  bool _closed = false;

  /// Bytes after the setup: vendor, formats, screens (not parsed).
  late Uint8List serverInfo;

  static Future<X11ControlConnection> open(X11Display display, X11Auth auth) async {
    final s = await display.connect();
    final c = X11ControlConnection._(s);
    s.add(X11Setup.build(auth));
    final head = await c._read(8);
    final bd = ByteData.sublistView(head);
    final extra = bd.getUint16(6, Endian.little) * 4;
    final rest = await c._read(extra);
    if (head[0] != 1) {
      final reason = head[0] == 0 ? String.fromCharCodes(rest.take(head[1])) : 'more authentication asked for';
      await c.close();
      throw X11Refused('the local X server refused the connection: ${reason.trim()}');
    }
    c.serverInfo = rest;
    return c;
  }

  /// The vendor string and release number from the setup reply (after the 8-byte head:
  /// release, resource id base and mask, motion buffer size, vendor length at 16, then fixed
  /// fields to 32, where the vendor starts).
  String get vendor {
    final n = ByteData.sublistView(serverInfo).getUint16(16, Endian.little);
    return String.fromCharCodes(serverInfo.sublist(32, 32 + n));
  }

  int get release => ByteData.sublistView(serverInfo).getUint32(0, Endian.little);

  Future<Uint8List> _read(int n) async {
    while (_buf.length < n) {
      if (_closed) throw const SocketException('the local X server closed the connection');
      _wake = Completer<void>();
      await _wake!.future.timeout(const Duration(seconds: 5));
    }
    final all = _buf.takeBytes();
    _buf.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }

  /// Sends a request and reads its reply (32 bytes and the extra the reply says). An X error
  /// (first byte 0) throws.
  Future<Uint8List> _request(Uint8List req) async {
    _socket.add(req);
    final head = await _read(32);
    if (head[0] == 0) throw X11Refused('X error ${head[1]} for request ${req[0]}.${req[1]}');
    final extra = ByteData.sublistView(head).getUint32(4, Endian.little) * 4;
    final rest = await _read(extra);
    return Uint8List.fromList([...head, ...rest]);
  }

  /// Sends a request that has no reply, then a GetInputFocus (which has one) so an error comes
  /// back here.
  Future<void> _requestNoReply(Uint8List req) async {
    _socket.add(req);
    final sync = Uint8List(4);
    sync[0] = 43; // GetInputFocus
    ByteData.sublistView(sync).setUint16(2, 1, Endian.little);
    _socket.add(sync);
    final head = await _read(32);
    if (head[0] == 0) {
      // The error, then the GetInputFocus reply.
      await _read(32);
      throw X11Refused('X error ${head[1]} for request ${req[0]}.${req[1]}');
    }
  }

  /// The extension's major opcode, or null when the server does not have it.
  Future<int?> queryExtension(String name) async {
    final n = name.length;
    final req = Uint8List(8 + n + _pad4(n));
    final bd = ByteData.sublistView(req);
    req[0] = 98; // QueryExtension
    bd.setUint16(2, req.length ~/ 4, Endian.little);
    bd.setUint16(4, n, Endian.little);
    req.setRange(8, 8 + n, name.codeUnits);
    final r = await _request(req);
    return r[8] == 1 ? r[9] : null;
  }

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
  }
}

class X11Refused implements Exception {
  X11Refused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the SECURITY extension gave: a cookie of the asked trust level and its id (to revoke).
class X11GeneratedAuth {
  X11GeneratedAuth(this.id, this.cookie, this.opcode);
  final int id;
  final Uint8List cookie;
  final int opcode;
}

/// SECURITY extension (X11R6.4 "Security Extension Specification"): GenerateAuthorization with
/// trust level Untrusted (or Trusted) and a timeout in seconds (the authorization ends that long
/// after its last client has gone; OpenSSH uses its ForwardX11Timeout, 20 minutes, plus slack).
/// Returns null when the server has no SECURITY extension.
Future<X11GeneratedAuth?> generateAuthorization(X11Display display, X11Auth real,
    {bool untrusted = true, int timeoutSeconds = 1200}) async {
  final c = await X11ControlConnection.open(display, real);
  try {
    final op = await c.queryExtension('SECURITY');
    if (op == null) return null;
    // SecurityQueryVersion 1.0 (minor 0).
    final qv = Uint8List(8);
    qv[0] = op;
    qv[1] = 0;
    ByteData.sublistView(qv)
      ..setUint16(2, 2, Endian.little)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 0, Endian.little);
    await c._request(qv);
    // SecurityGenerateAuthorization (minor 1): protocol MIT-MAGIC-COOKIE-1, no data (the server
    // makes it), values: timeout (bit 0) and trust level (bit 1; 0 trusted, 1 untrusted).
    // Layout on the wire (the server's xSecurityGenerateAuthorizationReq; the specification's
    // text lists the mask after the strings, but the header carries it): opcode, minor, length,
    // name length, data length, value mask (12 bytes), the name and its pad, the data (none),
    // then the values in bit order.
    const name = mitMagicCookie;
    final n = name.length;
    final at = 12 + n + _pad4(n);
    final req = Uint8List(at + 8);
    final bd = ByteData.sublistView(req);
    req[0] = op;
    req[1] = 1;
    bd.setUint16(2, req.length ~/ 4, Endian.little);
    bd.setUint16(4, n, Endian.little);
    bd.setUint16(6, 0, Endian.little);
    bd.setUint32(8, 0x3, Endian.little);
    req.setRange(12, 12 + n, name.codeUnits);
    bd.setUint32(at, timeoutSeconds, Endian.little);
    bd.setUint32(at + 4, untrusted ? 1 : 0, Endian.little);
    final r = await c._request(req);
    final rb = ByteData.sublistView(r);
    final id = rb.getUint32(8, Endian.little);
    final dlen = rb.getUint16(12, Endian.little);
    return X11GeneratedAuth(id, Uint8List.fromList(r.sublist(32, 32 + dlen)), op);
  } finally {
    await c.close();
  }
}

/// SecurityRevokeAuthorization (minor 2): the cookie stops working; clients already connected
/// with it are disconnected by the server.
Future<void> revokeAuthorization(X11Display display, X11Auth real, X11GeneratedAuth auth) async {
  final c = await X11ControlConnection.open(display, real);
  try {
    final req = Uint8List(8);
    req[0] = auth.opcode;
    req[1] = 2;
    ByteData.sublistView(req)
      ..setUint16(2, 2, Endian.little)
      ..setUint32(4, auth.id, Endian.little);
    await c._requestNoReply(req);
  } finally {
    await c.close();
  }
}

/// What the app's X server detection would show: does it answer with this authorization, who
/// made it, and can it run remote programs untrusted (SECURITY). Never throws.
Future<Map<String, Object?>> probeX11(X11Display display, X11Auth auth) async {
  final sw = Stopwatch()..start();
  try {
    final c = await X11ControlConnection.open(display, auth);
    try {
      return {
        'display': '$display',
        'answers': true,
        'vendor': c.vendor,
        'release': c.release,
        'security_extension': await c.queryExtension('SECURITY') != null,
        'ms': sw.elapsedMicroseconds / 1000,
      };
    } finally {
      await c.close();
    }
  } catch (e) {
    return {'display': '$display', 'answers': false, 'error': '$e', 'ms': sw.elapsedMicroseconds / 1000};
  }
}

/// One SSH connection's X11 forwarding: hand [config] to `shell`/`execute` (x11: ...) and
/// [handle] to `SSHClient(onX11Forward: ...)`.
class X11Forwarder {
  X11Forwarder({required this.display, required this.real, this.trusted = false, this.log});

  final X11Display display;

  /// The local X server's own authorization (a cookie from its Xauthority, or none).
  final X11Auth real;

  /// -Y: the remote clients get the real cookie; -X (false): an Untrusted one from SECURITY.
  final bool trusted;
  final void Function(Map<String, Object?>)? log;

  /// The fake cookie the server and the remote programs see (16 random bytes, as OpenSSH).
  final Uint8List fakeCookie = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));

  X11GeneratedAuth? _generated;
  X11Auth? _forClients;
  bool _closed = false;
  int _channels = 0;
  final _open = <Socket>{};
  final _sw = Stopwatch()..start();

  /// What the remote clients' setups will carry towards the local X server.
  X11Auth get clientAuth => _forClients ?? real;

  /// True when untrusted was asked for and the X server gave an Untrusted cookie.
  bool get untrustedActive => _generated != null && !trusted;

  /// Prepares the local side (the Untrusted cookie for -X). Throws X11Refused when untrusted was
  /// asked for and the X server cannot give one (no SECURITY extension): the app then says this X
  /// server cannot limit what remote programs do, and offers the per-host trusted switch.
  Future<void> start() async {
    if (trusted) {
      _forClients = real;
      return;
    }
    final t0 = _sw.elapsedMicroseconds;
    final g = await generateAuthorization(display, real, untrusted: true);
    if (g == null) throw X11Refused('the local X server has no SECURITY extension: it cannot run remote programs untrusted');
    _generated = g;
    _forClients = X11Auth.cookie(g.cookie);
    log?.call({'event': 'x11_untrusted_cookie', 'auth_id': g.id, 'ms': (_sw.elapsedMicroseconds - t0) / 1000});
  }

  SSHX11Config get config => SSHX11Config(authenticationCookie: toHex(fakeCookie));

  /// An incoming `x11` channel (zest_ssh_core has confirmed it already).
  void handle(SSHX11Channel ch) {
    final id = ++_channels;
    final t0 = _sw.elapsedMicroseconds;
    if (_closed) {
      log?.call({'event': 'x11_channel_refused', 'id': id, 'why': 'forwarding closed'});
      ch.destroy();
      return;
    }
    final pending = BytesBuilder();
    late StreamSubscription<Uint8List> sub;
    var setupDone = false;
    sub = ch.stream.listen((data) async {
      if (setupDone) return;
      pending.add(data);
      final X11Setup? setup;
      try {
        setup = X11Setup.tryParse(pending.toBytes());
      } on FormatException catch (e) {
        log?.call({'event': 'x11_channel_refused', 'id': id, 'why': e.message});
        await sub.cancel();
        ch.destroy();
        return;
      }
      if (setup == null) {
        if (pending.length > 4096) {
          log?.call({'event': 'x11_channel_refused', 'id': id, 'why': 'setup too long'});
          await sub.cancel();
          ch.destroy();
        }
        return;
      }
      setupDone = true;
      sub.pause();
      // Only a client that carries this session's fake cookie gets through (OpenSSH: "X11
      // connection rejected because of wrong authentication").
      if (setup.authName != mitMagicCookie || !constantTimeEquals(setup.authData, fakeCookie)) {
        log?.call({'event': 'x11_channel_refused', 'id': id, 'why': 'wrong authentication'});
        await sub.cancel();
        ch.destroy();
        return;
      }
      final all = pending.takeBytes();
      final Socket local;
      try {
        local = await display.connect();
      } catch (e) {
        log?.call({'event': 'x11_channel_refused', 'id': id, 'why': 'local X server: $e'});
        await sub.cancel();
        ch.destroy();
        return;
      }
      local.setOption(SocketOption.tcpNoDelay, true);
      _open.add(local);
      final connectedUs = _sw.elapsedMicroseconds;
      local.add(setup.rewrite(clientAuth));
      if (all.length > setup.length) local.add(Uint8List.sublistView(all, setup.length));
      var firstReply = true;
      var bytesIn = 0, bytesOut = 0;
      // Local X server to the channel.
      local.listen((d) {
        if (firstReply) {
          firstReply = false;
          log?.call({
            'event': 'x11_channel',
            'id': id,
            'from': '${ch.originatorIP}:${ch.originatorPort}',
            'local_connect_ms': (connectedUs - t0) / 1000,
            'setup_reply_ms': (_sw.elapsedMicroseconds - t0) / 1000,
            'setup_status': d.isEmpty ? null : (d[0] == 1 ? 'success' : (d[0] == 0 ? 'failed' : 'authenticate')),
          });
        }
        bytesIn += d.length;
        ch.sink.add(d);
      }, onDone: () {
        _open.remove(local);
        log?.call({'event': 'x11_channel_closed', 'id': id, 'by': 'local', 'to_remote': bytesIn, 'to_local': bytesOut});
        ch.close();
      }, onError: (Object e) {
        _open.remove(local);
        ch.destroy();
      });
      // The channel to the local X server (pausing the subscription holds the SSH window).
      sub.onData((d) {
        bytesOut += d.length;
        local.add(d);
      });
      sub.onDone(() {
        log?.call({'event': 'x11_channel_closed', 'id': id, 'by': 'remote', 'to_remote': bytesIn, 'to_local': bytesOut});
        local.destroy();
        _open.remove(local);
      });
      sub.resume();
    }, onDone: () {
      if (!setupDone) log?.call({'event': 'x11_channel_closed', 'id': id, 'by': 'remote', 'before_setup': true});
    });
  }

  /// No more channels; open ones are cut; the Untrusted cookie revoked.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final s in _open.toList()) {
      s.destroy();
    }
    _open.clear();
    final g = _generated;
    if (g != null) {
      try {
        await revokeAuthorization(display, real, g);
        log?.call({'event': 'x11_untrusted_cookie_revoked', 'auth_id': g.id});
      } catch (e) {
        log?.call({'event': 'x11_revoke_failed', 'error': '$e'});
      }
    }
  }
}
