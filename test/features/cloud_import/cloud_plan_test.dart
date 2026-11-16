import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';

/// Cloud import (3.0): what an import does with what a provider lists. A
/// machine imported before is found by its id (a new address updates the
/// host, never a second host); one already here by address is linked, not
/// added; the person's own edits stay theirs; hosts the account no longer
/// lists show as gone.

CloudMachine _m(String id, String name, {String? pub, String? priv, CloudOs os = CloudOs.linux}) =>
    CloudMachine(provider: CloudProvider.aws, id: id, name: name, publicAddress: pub, privateAddress: priv, os: os);

CloudExistingHost _h(String id, String label, String host, {CloudLink? link, int port = 22}) =>
    CloudExistingHost(id: id, label: label, host: host, port: port, link: link);

CloudLink _link(String machineId, {String label = 'AWS main', String? address, String? name, bool gone = false, CloudProvider p = CloudProvider.aws}) =>
    CloudLink(provider: p, machineId: machineId, label: label, address: address, name: name, gone: gone);

void main() {
  group('the link on a host', () {
    test('round-trips, and anything else reads as no link', () {
      final link = _link('i-1', address: '3.3.3.3', name: 'api', gone: true);
      final back = CloudLink.decode(link.encode())!;
      expect(back.provider, CloudProvider.aws);
      expect(back.machineId, 'i-1');
      expect(back.label, 'AWS main');
      expect(back.address, '3.3.3.3');
      expect(back.name, 'api');
      expect(back.gone, isTrue);
      for (final bad in [
        null,
        '',
        'not json',
        '[]',
        '{"v":2,"p":"aws","id":"i-1"}',
        '{"v":1,"p":"gcp","id":"i-1"}',
        '{"v":1,"p":"aws","id":""}',
        '{"v":1,"p":"aws"}',
        'x' * 5000,
      ]) {
        expect(CloudLink.decode(bad), isNull, reason: bad);
      }
    });

    test('what it holds is cleaned like anything else from outside', () {
      final back = CloudLink.decode('{"v":1,"p":"aws","id":"i-1","a":"-oProxyCommand=x","n":"a\\u202eb","l":"x\\u0000y"}')!;
      expect(back.address, isNull);
      expect(back.name, 'a b');
      expect(back.label, 'x y');
    });
  });

  test('new machines are ticked; phones and Windows are not; no address cannot be', () {
    final rows = planCloudImport(
      provider: CloudProvider.aws,
      machines: [
        _m('i-1', 'web', pub: '3.3.3.3'),
        _m('i-2', 'dc', pub: '4.4.4.4', os: CloudOs.windows),
        _m('i-3', 'no-ip'),
        _m('i-1', 'web again', pub: '3.3.3.3'),
      ],
      hosts: const [],
      label: 'AWS main',
      preferPrivate: false,
    );
    expect(rows.map((r) => (r.machine!.id, r.status, r.selected)), [
      ('i-2', CloudRowStatus.noSsh, false),
      ('i-3', CloudRowStatus.noAddress, false),
      ('i-1', CloudRowStatus.fresh, true),
    ], reason: 'name order; the same machine twice is listed once');
    expect(rows[1].selectable, isFalse);
    expect(rows[0].selectable, isTrue, reason: 'Windows can be ticked by hand');
  });

  test('private addresses when asked for and there are some', () {
    final rows = planCloudImport(
      provider: CloudProvider.aws,
      machines: [_m('i-1', 'a', pub: '3.3.3.3', priv: '10.0.0.1'), _m('i-2', 'b', pub: '3.3.3.4')],
      hosts: const [],
      label: 'x',
      preferPrivate: true,
    );
    expect(rows.map((r) => r.address), ['10.0.0.1', '3.3.3.4']);
  });

  test('a host with the same address (port 22) is here already: linked, not added again', () {
    final rows = planCloudImport(
      provider: CloudProvider.aws,
      machines: [_m('i-1', 'web', pub: '3.3.3.3'), _m('i-2', 'db', pub: '5.5.5.5')],
      hosts: [_h('h1', 'my web', '3.3.3.3'), _h('h2', 'db on 2222', '5.5.5.5', port: 2222)],
      label: 'AWS main',
      preferPrivate: false,
    );
    expect(rows[0].status, CloudRowStatus.fresh, reason: 'db: the host on another port is another service');
    expect(rows[1].status, CloudRowStatus.here);
    expect(rows[1].existing!.id, 'h1');
    expect(rows[1].selected, isFalse);
  });

  test('imported before: unchanged is left alone; a new address or name is an update', () {
    final hosts = [
      _h('h1', 'web', '3.3.3.3', link: _link('i-1', address: '3.3.3.3', name: 'web')),
      _h('h2', 'db', '4.4.4.4', link: _link('i-2', address: '4.4.4.4', name: 'db')),
      _h('h3', 'cache', '6.6.6.6', link: _link('i-3', address: '6.6.6.6', name: 'cache')),
    ];
    final rows = planCloudImport(
      provider: CloudProvider.aws,
      machines: [_m('i-1', 'web', pub: '3.3.3.3'), _m('i-2', 'db', pub: '9.9.9.9'), _m('i-3', 'cache-2', pub: '6.6.6.6')],
      hosts: hosts,
      label: 'AWS main',
      preferPrivate: false,
    );
    final by = {for (final r in rows) r.machine!.id: r};
    expect(by['i-1']!.status, CloudRowStatus.imported);
    expect(by['i-1']!.selectable, isFalse);
    expect(by['i-2']!.status, CloudRowStatus.changed);
    expect(by['i-2']!.selected, isTrue);
    expect(by['i-3']!.status, CloudRowStatus.changed, reason: 'renamed at the provider');
  });

  test('what the person changed stays theirs', () {
    // They set their own address; the provider's changed too.
    final mine = _h('h1', 'web', '10.8.0.5', link: _link('i-1', address: '3.3.3.3', name: 'web'));
    final rows = planCloudImport(
      provider: CloudProvider.aws,
      machines: [_m('i-1', 'web', pub: '3.3.3.9')],
      hosts: [mine],
      label: 'AWS main',
      preferPrivate: false,
    );
    expect(rows.single.status, CloudRowStatus.imported, reason: 'nothing of theirs would change');
    final update = cloudUpdateFor(mine, _m('i-1', 'web-renamed', pub: '3.3.3.9'), address: '3.3.3.9', label: 'AWS main');
    expect(update.host, isNull, reason: 'their address stays');
    expect(update.label, 'web-renamed', reason: 'they renamed nothing: "web" is what the import set, so the new name applies');
  });

  test('an update sets what the import set before, and records the new values', () {
    final host = _h('h1', 'web', '3.3.3.3', link: _link('i-1', address: '3.3.3.3', name: 'web'));
    final u = cloudUpdateFor(host, _m('i-1', 'web-2', pub: '3.3.3.9'), address: '3.3.3.9', label: 'AWS main');
    expect(u.host, '3.3.3.9');
    expect(u.label, 'web-2');
    expect(u.link.address, '3.3.3.9');
    expect(u.link.name, 'web-2');
    expect(u.link.gone, isFalse);
    // Renamed by the person: the name stays theirs.
    final renamed = _h('h1', 'My Web', '3.3.3.3', link: _link('i-1', address: '3.3.3.3', name: 'web'));
    expect(cloudUpdateFor(renamed, _m('i-1', 'web-2', pub: '3.3.3.3'), address: '3.3.3.3', label: 'AWS main').label, isNull);
  });

  test('gone: only hosts from this account name, this provider, not already gone', () {
    final rows = planCloudImport(
      provider: CloudProvider.aws,
      machines: [_m('i-1', 'web', pub: '3.3.3.3')],
      hosts: [
        _h('h1', 'web', '3.3.3.3', link: _link('i-1', address: '3.3.3.3', name: 'web')),
        _h('h2', 'old', '7.7.7.7', link: _link('i-9', address: '7.7.7.7', name: 'old', label: 'aws MAIN ')),
        _h('h3', 'other account', '8.8.8.8', link: _link('i-8', label: 'AWS work')),
        _h('h4', 'already gone', '9.9.9.9', link: _link('i-7', gone: true)),
        _h('h5', 'droplet', '1.1.1.1', link: _link('123', p: CloudProvider.digitalocean)),
        _h('h6', 'mine', '2.2.2.2'),
      ],
      label: 'AWS main',
      preferPrivate: false,
    );
    final gone = rows.where((r) => r.status == CloudRowStatus.gone).map((r) => r.existing!.id);
    expect(gone, ['h2']);
    expect(rows.last.status, CloudRowStatus.gone, reason: 'after the machines');
  });

  test('a gone host that comes back is an update (it clears the mark)', () {
    final rows = planCloudImport(
      provider: CloudProvider.aws,
      machines: [_m('i-1', 'web', pub: '3.3.3.3')],
      hosts: [_h('h1', 'web', '3.3.3.3', link: _link('i-1', address: '3.3.3.3', name: 'web', gone: true))],
      label: 'AWS main',
      preferPrivate: false,
    );
    expect(rows.single.status, CloudRowStatus.changed);
  });
}
