import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/cloud_scans.dart';
import 'package:zestssh/features/hosts/connect_link.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';
import 'package:zestssh/features/password_managers/password_manager_import.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/utils/host_address.dart';

/// IPv6 addresses wherever an address is read or written with its port
/// (3.0): an IPv6 address is written between brackets
/// before a port and in a URL ("[2001:db8::1]:22"), and connected to without
/// them. Eight places read or wrote one wrong: a host's editor saved
/// "[2001:db8::1]:2222" whole, as a name no lookup finds; a password
/// manager's item, a share link and a quick connect link kept the brackets
/// or put them on twice; an SSH config's ProxyJump through an IPv6 host was
/// cut at its first colon; a Prometheus target was matched with its
/// brackets, or without its last group; the Proxmox field did not read an
/// address typed bare; and S3 sync to an IPv6 endpoint built a URL that did
/// not parse, or signed a Host that was not the one sent.
void main() {
  group('the rule', () {
    test('an IPv6 address is bracketed before a port, and bare to connect to', () {
      expect(isBareIpv6('2001:db8::1'), isTrue);
      expect(isBareIpv6('[2001:db8::1]'), isFalse);
      expect(isBareIpv6('192.0.2.10'), isFalse);
      expect(isBareIpv6('web.example.com'), isFalse);
      expect(bracketIpv6('2001:db8::1'), '[2001:db8::1]');
      expect(bracketIpv6('web.example.com'), 'web.example.com');
      expect(unbracketHost('[2001:db8::1]'), '2001:db8::1');
      expect(unbracketHost('2001:db8::1'), '2001:db8::1');
      expect(unbracketHost('web.example.com'), 'web.example.com');
      expect(hostWithPort('2001:db8::1', 22), '[2001:db8::1]:22');
      expect(hostWithPort('192.0.2.10', 2222), '192.0.2.10:2222');
    });

    test('a host and the port written after it, the last group of a bare IPv6 address never taken for one', () {
      expect(splitHostPort('web.example.com'), (host: 'web.example.com', port: null));
      expect(splitHostPort('web.example.com:2222'), (host: 'web.example.com', port: 2222));
      expect(splitHostPort('[2001:db8::1]'), (host: '2001:db8::1', port: null));
      expect(splitHostPort('[2001:db8::1]:2222'), (host: '2001:db8::1', port: 2222));
      expect(splitHostPort('2001:db8::1'), (host: '2001:db8::1', port: null));
      expect(splitHostPort('2001:db8::1:2222'), (host: '2001:db8::1:2222', port: null));
      for (final no in ['[2001:db8::1', '[2001:db8::1]x', '[2001:db8::1]:0', 'web:70000', 'web:abc']) {
        expect(splitHostPort(no), isNull, reason: no);
      }
    });
  });

  test("a host's editor saves the host bare and a port typed after it as the port", () {
    expect(savedAddress('[2001:db8::1]:2222', 22), (host: '2001:db8::1', port: 2222));
    expect(savedAddress('[2001:db8::1]', 22), (host: '2001:db8::1', port: 22));
    expect(savedAddress('2001:db8::1', 2200), (host: '2001:db8::1', port: 2200));
    expect(savedAddress('web.example.com:2200', 22), (host: 'web.example.com', port: 2200));
    expect(savedAddress(' web.example.com ', 2222), (host: 'web.example.com', port: 2222));
  });

  test("a password manager's item that names an IPv6 host makes a host without the brackets", () {
    expect(sshTargetOf('ssh://admin@[2001:db8::1]:2222'), (host: '2001:db8::1', port: 2222, user: 'admin'));
    expect(sshTargetOf('[2001:db8::1]'), (host: '2001:db8::1', port: 22, user: null));
  });

  test('a share link that names an IPv6 host adds it without the brackets', () {
    final share = ConnectionShareUrlService.tryParse(
        Uri(scheme: 'zestssh', host: 'add-host', queryParameters: {'host': '[2001:db8::1]', 'port': '2222'}))!;
    expect(share.host, '2001:db8::1');
    expect(share.port, 2222);
  });

  test('a quick connect link that names an IPv6 host between brackets opens Quick connect with it', () {
    for (final host in ['[2001:db8::1]', '2001:db8::1']) {
      final text = quickConnectLinkOf(
          Uri(scheme: 'zestssh', host: 'connect', queryParameters: {'host': host, 'port': '2222'})).text;
      expect(text, isNotNull, reason: host);
      final target = parseQuickTarget(text!)!;
      expect((target.host, target.port), ('2001:db8::1', 2222), reason: host);
    }
  });

  test("an SSH config's ProxyJump through an IPv6 host names that host", () {
    String? jump(String via) => OnboardingSshEntry(alias: 'web', hostname: 'web.example.com', proxyJump: via).proxyJumpHost;
    expect(jump('[2001:db8::1]:22'), '2001:db8::1');
    expect(jump('deploy@[2001:db8::1]:2222'), '2001:db8::1');
    expect(jump('2001:db8::1'), '2001:db8::1');
    expect(jump('jump.example.com:2222'), 'jump.example.com');
    expect(jump('ops@jump.example.com, second.example.com'), 'jump.example.com');
  });

  test('a Prometheus target is matched by its host, an IPv6 one too', () {
    expect(prometheusInstanceHost('[2001:db8::1]:9100'), '2001:db8::1');
    expect(prometheusInstanceHost('2001:db8::1'), '2001:db8::1');
    expect(prometheusInstanceHost('192.168.10.21:9100'), '192.168.10.21');
    expect(prometheusInstanceHost('https://traefik.home.lan/'), 'traefik.home.lan');
    expect(prometheusInstanceHost('http://Node-A.example.com:9100/metrics'), 'node-a.example.com');
    expect(prometheusInstanceHost('db-primary'), 'db-primary');
  });

  test('the Proxmox field reads an IPv6 address typed bare', () {
    final bare = proxmoxBase('2001:db8::1')!;
    expect((bare.host, bare.port), ('2001:db8::1', 8006));
    expect(bare.toString(), 'https://[2001:db8::1]:8006');
    final withPort = proxmoxBase('[2001:db8::1]:9006')!;
    expect((withPort.host, withPort.port), ('2001:db8::1', 9006));
  });

  group('S3 sync', () {
    S3SyncBackend store(String endpoint, {bool pathStyle = true}) {
      final s = S3SyncBackend(
        endpoint: endpoint,
        region: 'us-east-1',
        bucket: 'zest-demo',
        accessKeyId: 'demo-key',
        secretAccessKey: 'demo-secret',
        usePathStyle: pathStyle,
      );
      addTearDown(s.dispose);
      return s;
    }

    test('to an IPv6 endpoint: the URL has its brackets, and the signed Host is the one sent', () {
      final t = store('http://[fd00::5]:9000').objectTargetForTest;
      expect(t.uri.host, 'fd00::5');
      expect(t.uri.port, 9000);
      expect(t.uri.toString(), startsWith('http://[fd00::5]:9000/zest-demo/'));
      expect(t.host, '[fd00::5]:9000');
    });

    test('to an address, by its path whatever is chosen; to a name, as chosen', () {
      final byAddress = store('http://192.0.2.10:9000', pathStyle: false).objectTargetForTest;
      expect(byAddress.uri.path, startsWith('/zest-demo/'));
      expect(byAddress.host, '192.0.2.10:9000');
      final byName = store('https://minio.example.com', pathStyle: false).objectTargetForTest;
      expect(byName.host, 'zest-demo.minio.example.com');
      expect(byName.uri.path, isNot(startsWith('/zest-demo/')));
    });
  });
}
