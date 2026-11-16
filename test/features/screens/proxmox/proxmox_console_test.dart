// Remote screens (4.0): a Proxmox guest's console, against a played Proxmox (a
// local server that answers the API's calls and upgrades its websocket as Proxmox 9 does).
// What is asked, with what, what comes back, and every way it can be refused, with nothing
// secret in what a failure says.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_console.dart';

const _token = 'zestssh@pve!console=0d7f1c2e-made-up-not-a-token';
const _ticket = 'PVEVNC:6AFB1976::made-up-ticket-not-a-real-one';

/// A played Proxmox: [guests] by vmid ('qemu' or 'lxc'); [refuse] answers a path with a status.
class _Pve {
  _Pve._(this.server);

  static Future<_Pve> start({Map<int, String> guests = const {100: 'qemu', 200: 'lxc'}}) async {
    final p = _Pve._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0))..guests = guests;
    p.server.listen(p._serve);
    addTearDown(() => p.server.close(force: true));
    return p;
  }

  final HttpServer server;
  late Map<int, String> guests;
  final asked = <String>[];
  final auths = <String?>[];
  final Map<String, int> refuse = {};
  String? proxyBody;
  final fromClient = <List<int>>[];
  WebSocket? socket;
  String? protocolAsked;

  Uri get base => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _serve(HttpRequest r) async {
    final path = r.uri.path;
    asked.add('${r.method} $path');
    auths.add(r.headers.value(HttpHeaders.authorizationHeader));
    if (r.headers.value(HttpHeaders.authorizationHeader) != 'PVEAPIToken=$_token') {
      r.response.statusCode = 401;
      return r.response.close();
    }
    for (final e in refuse.entries) {
      if (path.endsWith(e.key)) {
        r.response.statusCode = e.value;
        return r.response.close();
      }
    }
    final m = RegExp(r'^/api2/json/nodes/pve/(qemu|lxc)/(\d+)/(status/current|vncproxy|vncwebsocket)$').firstMatch(path);
    final kind = m?.group(1);
    final vmid = int.tryParse(m?.group(2) ?? '');
    if (m == null || guests[vmid] != kind) {
      r.response.statusCode = 500;
      r.response.write('{"data":null}');
      return r.response.close();
    }
    switch (m.group(3)) {
      case 'status/current':
        r.response.write(jsonEncode({'data': {'status': 'running'}}));
        return r.response.close();
      case 'vncproxy':
        final form = Uri.splitQueryString(await utf8.decoder.bind(r).join());
        expect(form['websocket'], '1');
        r.response.write(proxyBody ??
            jsonEncode({
              'data': {'port': '5900', 'ticket': _ticket, 'password': 'Ab3dE7gH', 'user': 'zestssh@pve!console', 'upid': 'x'},
            }));
        return r.response.close();
      default:
        expect(r.uri.queryParameters['vncticket'], _ticket);
        expect(r.uri.queryParameters['port'], '5900');
        protocolAsked = r.headers.value('sec-websocket-protocol');
        final ws = await WebSocketTransformer.upgrade(r, protocolSelector: (p) => p.first);
        socket = ws;
        ws.add(Uint8List.fromList(utf8.encode('RFB 003.008\n')));
        ws.listen((m) => fromClient.add(m is String ? utf8.encode(m) : m as List<int>));
    }
  }
}

void main() {
  group('which guest', () {
    test('a link names a guest as host:port/node/vmid; a node, or anything else, is none', () {
      final g = ProxmoxGuest.parse('192.0.2.66:8006/pve/100')!;
      expect((g.host, g.port, g.node, g.vmid), ('192.0.2.66', 8006, 'pve', 100));
      final v6 = ProxmoxGuest.parse('[2001:db8::5]:8006/pve-2/250')!;
      expect((v6.host, v6.port, v6.node, v6.vmid), ('2001:db8::5', 8006, 'pve-2', 250));
      expect(g.isOn(Uri.parse('https://192.0.2.66:8006')), isTrue);
      expect(g.isOn(Uri.parse('https://192.0.2.66:8007')), isFalse);
      for (final bad in [
        '192.0.2.66:8006/node/pve',
        '192.0.2.66/pve/100',
        '192.0.2.66:99999/pve/100',
        '192.0.2.66:8006/pve/99',
        '192.0.2.66:8006/pve/abc',
        '192.0.2.66:8006/../../access/100',
        '192.0.2.66:8006/pve x/100',
        '192.0.2.66:8006/pve/100/extra',
        '',
      ]) {
        expect(ProxmoxGuest.parse(bad), isNull, reason: bad);
      }
    });

    test("the pin is taken for the account's address only, and only that certificate", () {
      final base = Uri.parse('https://pve.example.test:8006');
      final der = utf8.encode('a made-up certificate');
      expect(proxmoxPinAccepts(der, 'pve.example.test', 8006, base: base, pinned: null), isFalse,
          reason: 'no pin: only what the system trusts');
      final real = _sha(der);
      expect(proxmoxPinAccepts(der, 'pve.example.test', 8006, base: base, pinned: real), isTrue);
      expect(proxmoxPinAccepts(der, 'pve.example.test', 8006, base: base, pinned: real.toLowerCase()), isTrue);
      expect(proxmoxPinAccepts(der, 'other.example.test', 8006, base: base, pinned: real), isFalse);
      expect(proxmoxPinAccepts(der, 'pve.example.test', 443, base: base, pinned: real), isFalse);
      expect(proxmoxPinAccepts(utf8.encode('another certificate'), 'pve.example.test', 8006, base: base, pinned: real),
          isFalse);
    });
  });

  group('the console', () {
    test('a VM: asked with the token, the websocket opened with it, VNC both ways as binary frames, its password '
        'handed over', () async {
      {
        final pve = await _Pve.start();
        final console = await openProxmoxConsole(
          base: pve.base,
          token: _token,
          guest: const ProxmoxGuest(host: '127.0.0.1', port: 0, node: 'pve', vmid: 100),
          client: HttpClient(),
        );
        expect(console.kind, 'qemu');
        expect(console.password, 'Ab3dE7gH');
        expect(pve.asked, [
          'GET /api2/json/nodes/pve/qemu/100/status/current',
          'POST /api2/json/nodes/pve/qemu/100/vncproxy',
          'GET /api2/json/nodes/pve/qemu/100/vncwebsocket',
        ]);
        expect(pve.auths, everyElement('PVEAPIToken=$_token'));
        expect(pve.protocolAsked, 'binary');
        final got = <List<int>>[];
        console.channel.input.listen(got.add);
        Future<void> until(bool Function() done) async {
          for (var i = 0; i < 300 && !done(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(done(), isTrue);
        }

        await until(() => got.isNotEmpty && pve.socket != null);
        expect(utf8.decode(got.single), 'RFB 003.008\n');
        console.channel.output.add(utf8.encode('RFB 003.008\n'));
        await until(() => pve.fromClient.isNotEmpty);
        expect(pve.fromClient.single, utf8.encode('RFB 003.008\n'));
        // A text frame from the server is not VNC: it is not handed on; the binary one after it is.
        pve.socket!.add('not vnc');
        pve.socket!.add(Uint8List.fromList([1, 2]));
        await until(() => got.length == 2);
        expect(got.last, [1, 2]);
        await console.channel.output.close();
      }
    });

    test('a container: asked as a VM first, then as what it is', () async {
      {
        final pve = await _Pve.start();
        final console = await openProxmoxConsole(
          base: pve.base,
          token: _token,
          guest: const ProxmoxGuest(host: '127.0.0.1', port: 0, node: 'pve', vmid: 200),
          client: HttpClient(),
        );
        expect(console.kind, 'lxc');
        expect(pve.asked.take(3), [
          'GET /api2/json/nodes/pve/qemu/200/status/current',
          'GET /api2/json/nodes/pve/lxc/200/status/current',
          'POST /api2/json/nodes/pve/lxc/200/vncproxy',
        ]);
        await console.channel.output.close();
      }
    });

    test('an answer without its own password: the ticket signs in, as on Proxmox before 8', () async {
      {
        final pve = await _Pve.start();
        pve.proxyBody = jsonEncode({
          'data': {'port': 5900, 'ticket': _ticket},
        });
        final console = await openProxmoxConsole(
          base: pve.base,
          token: _token,
          guest: const ProxmoxGuest(host: '127.0.0.1', port: 0, node: 'pve', vmid: 100),
          client: HttpClient(),
        );
        expect(console.password, _ticket);
        await console.channel.output.close();
      }
    });

    test('every refusal says what it is, and nothing secret', () async {
      {
        Future<ProxmoxConsoleError> refused(_Pve pve, {String token = _token, int vmid = 100}) async {
          try {
            await openProxmoxConsole(
              base: pve.base,
              token: token,
              guest: ProxmoxGuest(host: '127.0.0.1', port: 0, node: 'pve', vmid: vmid),
              client: HttpClient(),
              timeout: const Duration(seconds: 5),
            );
          } on ProxmoxConsoleError catch (e) {
            expect('$e'.contains(token), isFalse);
            expect('$e'.contains(_ticket), isFalse);
            expect('$e'.contains('Ab3dE7gH'), isFalse);
            return e;
          }
          fail('it opened');
        }

        final pve = await _Pve.start();
        expect((await refused(pve, token: 'zestssh@pve!console=a-changed-token')).failure, ProxmoxConsoleFailure.signIn);
        expect((await refused(pve, vmid: 777)).failure, ProxmoxConsoleFailure.notFound);
        pve.refuse['qemu/100/vncproxy'] = 403;
        expect((await refused(pve)).failure, ProxmoxConsoleFailure.permission, reason: 'no VM.Console');
        pve.refuse.clear();
        pve.proxyBody = '{"data":{"port":"99999","ticket":"x"}}';
        expect((await refused(pve)).failure, ProxmoxConsoleFailure.unexpected);
        pve.proxyBody = '{"data":{"port":"5900"}}';
        expect((await refused(pve)).failure, ProxmoxConsoleFailure.unexpected);
        pve.proxyBody = 'x' * (200 * 1024);
        expect((await refused(pve)).failure, ProxmoxConsoleFailure.unexpected, reason: 'a long answer is not read whole');
        pve.proxyBody = null;
        pve.refuse['qemu/100/vncwebsocket'] = 403;
        expect((await refused(pve)).failure, ProxmoxConsoleFailure.unexpected);

        // Nobody there.
        final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close(force: true);
        try {
          await openProxmoxConsole(
            base: Uri(scheme: 'http', host: '127.0.0.1', port: port),
            token: _token,
            guest: ProxmoxGuest(host: '127.0.0.1', port: port, node: 'pve', vmid: 100),
            client: HttpClient(),
          );
          fail('it opened');
        } on ProxmoxConsoleError catch (e) {
          expect(e.failure, ProxmoxConsoleFailure.offline);
        }
      }
    });
  });
}

String _sha(List<int> der) {
  // As the import writes a pin: upper-case pairs with colons.
  final hex = c.sha256.convert(der).toString().toUpperCase();
  return [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)].join(':');
}
