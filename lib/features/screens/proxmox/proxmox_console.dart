// Remote screens (4.0): a Proxmox guest's console, as the
// Proxmox web interface opens it, without a browser. The API's vncproxy
// call for the VM or container gives a one-time ticket, a password and a
// port; the console is then VNC inside the API's own websocket, over HTTPS
// with the certificate the person confirmed for that account. The VNC engine
// reads and writes through the websocket as it does through an SSH channel.
//
// Seen against Proxmox VE 9.2.2 (17 November 2026): an
// API token alone opens both the call and the websocket; the proxy offers
// classic VNC authentication only; the answer's 8-character password signs
// in. The token needs VM.Console on the guest (and VM.Audit to tell a VM from
// a container).
//
// Never kept or logged: the token (it stays in secure storage, with its
// account), the ticket and the password (used once, for this connection).
// Nothing here is plain VNC over a network: the websocket is inside TLS whose
// certificate is the system's trusted one or the account's pinned one.
//
// dart:io only, so a script can use it as the app does.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:zest_native/screen.dart' show ScreenChannel;
import 'package:zestssh/utils/type_name.dart';

/// Why a console did not open.
enum ProxmoxConsoleFailure {
  /// The token was refused (401): changed or deleted on the server.
  signIn,

  /// The token may not open this guest's console (403): it lacks VM.Console.
  permission,

  /// No such guest on that node (any more).
  notFound,

  /// The certificate is neither trusted by the system nor the pinned one.
  certificate,

  /// The server could not be reached.
  offline,

  /// No answer in time.
  timeout,

  /// The server answered something this version cannot read.
  unexpected,
}

class ProxmoxConsoleError implements Exception, HasTypeName {
  const ProxmoxConsoleError(this.failure, [this.detail = '']);
  final ProxmoxConsoleFailure failure;

  /// For Copy details: never the token, the ticket or the password.
  final String detail;

  @override
  String get typeName => 'ProxmoxConsoleError';

  @override
  String toString() => 'ProxmoxConsoleError(${failure.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// A guest of a Proxmox cluster, as an imported host's link names it
/// (`host:port/node/vmid`; the cluster's nodes themselves,
/// `host:port/node/<name>`, are not guests).
class ProxmoxGuest {
  const ProxmoxGuest({required this.host, required this.port, required this.node, required this.vmid});

  final String host;
  final int port;
  final String node;
  final int vmid;

  /// The guest a link's [machineId] names, or null for anything else.
  static ProxmoxGuest? parse(String machineId) {
    final parts = machineId.split('/');
    if (parts.length != 3 || parts[1] == 'node') return null;
    final at = parts[0].lastIndexOf(':');
    if (at <= 0) return null;
    var host = parts[0].substring(0, at);
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    final port = int.tryParse(parts[0].substring(at + 1));
    final vmid = int.tryParse(parts[2]);
    final node = parts[1];
    // A node's name is a host name; a guest's id is 100 to 999999999.
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    if (vmid == null || vmid < 100 || vmid > 999999999) return null;
    if (!RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$').hasMatch(node)) return null;
    return ProxmoxGuest(host: host, port: port, node: node, vmid: vmid);
  }

  /// The cluster's address as the account's `url` names it.
  bool isOn(Uri base) => base.host == host && base.port == port;
}

/// An open console: the channel the VNC engine reads and writes, and the
/// password it signs in with (classic VNC authentication).
class ProxmoxConsole {
  const ProxmoxConsole({required this.channel, required this.password, required this.kind});

  final ScreenChannel channel;

  /// Used once, for this connection: never kept, never logged.
  final String password;

  /// 'qemu' (a VM) or 'lxc' (a container: its text console as a picture).
  final String kind;
}

/// Whether [der] is the certificate pinned as [pinned] (`AB:CD:...`, as the
/// import keeps it), for [host] and [port] of [base] only.
bool proxmoxPinAccepts(List<int> der, String host, int port, {required Uri base, required String? pinned}) {
  if (pinned == null || pinned.isEmpty || host != base.host || port != base.port) return false;
  final hex = c.sha256.convert(der).toString().toUpperCase();
  final said = [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)].join(':');
  return said == pinned.toUpperCase();
}

/// The HTTPS client for [base]: the certificates the system trusts, and the
/// one [pinned] for that address.
HttpClient proxmoxClient(Uri base, {String? pinned}) => HttpClient()
  ..connectionTimeout = const Duration(seconds: 10)
  ..badCertificateCallback = (cert, host, port) => proxmoxPinAccepts(cert.der, host, port, base: base, pinned: pinned);

/// Opens [guest]'s console on the cluster at [base] with the API [token]
/// (`user@realm!name=secret`). [client] is the HTTPS client
/// ([proxmoxClient]; tests give their own); [timeout] bounds each step.
Future<ProxmoxConsole> openProxmoxConsole({
  required Uri base,
  required String token,
  required ProxmoxGuest guest,
  required HttpClient client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final auth = 'PVEAPIToken=$token';
  String scrub(String s) => s.replaceAll(token, '<token>');
  final node = Uri.encodeComponent(guest.node);

  Future<(int, Object?)> call(String method, String path, [Map<String, String>? form]) async {
    try {
      final req = await client.openUrl(method, base.replace(path: '/api2/json/$path')).timeout(timeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.authorizationHeader, auth);
      if (form != null) {
        // With its length: Proxmox's server answers a chunked body with 501.
        final body = utf8.encode(Uri(queryParameters: form).query);
        req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(timeout);
      // A console's answer is small: read up to 64 KiB, and anything longer
      // is not one.
      final body = StringBuffer();
      var tooLong = false;
      await for (final chunk in res.transform(utf8.decoder).timeout(timeout)) {
        body.write(chunk);
        if (body.length > 65536) {
          tooLong = true;
          break;
        }
      }
      Object? data;
      try {
        final json = tooLong ? null : jsonDecode(body.toString());
        if (json is Map) data = json['data'];
      } on FormatException {
        data = null;
      }
      return (res.statusCode, data);
    } on HandshakeException catch (e) {
      throw ProxmoxConsoleError(ProxmoxConsoleFailure.certificate, scrub('$e'));
    } on SocketException catch (e) {
      throw ProxmoxConsoleError(ProxmoxConsoleFailure.offline, scrub('$e'));
    } on TimeoutException {
      throw ProxmoxConsoleError(ProxmoxConsoleFailure.timeout, '$method $path');
    } on HttpException catch (e) {
      throw ProxmoxConsoleError(ProxmoxConsoleFailure.unexpected, scrub('$e'));
    }
  }

  Never refused(int status, String what) {
    throw ProxmoxConsoleError(
      switch (status) {
        401 => ProxmoxConsoleFailure.signIn,
        403 => ProxmoxConsoleFailure.permission,
        404 || 500 => ProxmoxConsoleFailure.notFound,
        _ => ProxmoxConsoleFailure.unexpected,
      },
      '$what: $status',
    );
  }

  // A VM or a container: the link does not say (VM.Audit tells).
  var kind = 'qemu';
  var (status, _) = await call('GET', 'nodes/$node/qemu/${guest.vmid}/status/current');
  if (status != 200) {
    kind = 'lxc';
    (status, _) = await call('GET', 'nodes/$node/lxc/${guest.vmid}/status/current');
    if (status != 200) refused(status, 'the guest');
  }

  final (proxyStatus, proxy) = await call('POST', 'nodes/$node/$kind/${guest.vmid}/vncproxy', {'websocket': '1'});
  if (proxyStatus != 200) refused(proxyStatus, 'vncproxy');
  final port = proxy is Map ? int.tryParse('${proxy['port']}') : null;
  final ticket = proxy is Map ? proxy['ticket'] : null;
  final password = proxy is Map ? proxy['password'] : null;
  if (port == null || port < 1 || port > 65535 || ticket is! String || ticket.isEmpty || ticket.length > 4096) {
    throw const ProxmoxConsoleError(ProxmoxConsoleFailure.unexpected, 'vncproxy: no port or ticket');
  }
  // The answer's own password where it gives one (Proxmox 8 and later), else
  // the ticket: VNC's DES takes the first 8 bytes of either.
  final secret = password is String && password.isNotEmpty && password.length <= 64 ? password : ticket;

  final wsUri = base.replace(
    scheme: base.scheme == 'http' ? 'ws' : 'wss',
    path: '/api2/json/nodes/$node/$kind/${guest.vmid}/vncwebsocket',
    queryParameters: {'port': '$port', 'vncticket': ticket},
  );
  final WebSocket ws;
  try {
    ws = await WebSocket.connect(
      '$wsUri',
      protocols: const ['binary'],
      headers: {HttpHeaders.authorizationHeader: auth},
      customClient: client,
    ).timeout(timeout);
  } on WebSocketException catch (e) {
    throw ProxmoxConsoleError(ProxmoxConsoleFailure.unexpected, scrub('the console: $e').replaceAll(ticket, '<ticket>'));
  } on HandshakeException catch (e) {
    throw ProxmoxConsoleError(ProxmoxConsoleFailure.certificate, scrub('$e'));
  } on SocketException catch (e) {
    throw ProxmoxConsoleError(ProxmoxConsoleFailure.offline, scrub('$e'));
  } on TimeoutException {
    throw const ProxmoxConsoleError(ProxmoxConsoleFailure.timeout, 'the console');
  }
  // Binary frames only: a text frame is not VNC.
  final input = ws.where((m) => m is List<int>).map((m) => m is Uint8List ? m : Uint8List.fromList(m as List<int>));
  return ProxmoxConsole(channel: ScreenChannel(input, _WebSocketSink(ws)), password: secret, kind: kind);
}

/// What the engine writes, as binary frames of the websocket.
class _WebSocketSink implements StreamSink<List<int>> {
  _WebSocketSink(this.ws);
  final WebSocket ws;

  @override
  void add(List<int> data) => ws.add(data is Uint8List ? data : Uint8List.fromList(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) => ws.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() => ws.close();

  @override
  Future<void> get done => ws.done;
}
