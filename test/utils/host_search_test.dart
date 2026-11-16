import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/utils/host_search.dart';

/// The phone's search (2.2.1, Android, German) found no connections:
/// typing isp did not find the connection ispconfig.
/// In 2.2.1 the phone's search field wrote the query and the
/// host list never read it. The list now filters with [hostMatchesQuery]
/// (pinned on the screen itself in test/ui/phone_home_test.dart); this pins
/// what counts as a match.

final _when = DateTime.utc(2026, 1, 1);

ConnectionWithDetails _host(
  String label,
  String address, {
  String? user,
  String? group,
}) =>
    ConnectionWithDetails(
      connection: Connection(
        id: 'c-$label',
        label: label,
        host: address,
        port: 22,
        colorIndex: 0,
        protocol: 'ssh',
        zlibCompression: false,
        keepAliveSeconds: 0,
        envVars: '',
        forwardAgent: false,
        compatibilityMode: false,
        sortOrder: 0,
        sizeTier: 1,
        pinned: false,
        monitored: false,
        createdAt: _when,
        updatedAt: _when,
      ),
      identity: user == null
          ? null
          : Identity(
              id: 'i-$user',
              label: user,
              username: user,
              authMethod: 'password',
              usesAgent: false,
              colorIndex: 0,
              isDefault: false,
              allowUnattended: false,
              passwordAfterKey: false,
              createdAt: _when,
            ),
      group: group == null
          ? null
          : ConnectionGroup(
              id: 'g-$group',
              name: group,
              sortOrder: 0,
              isExpanded: true,
              createdAt: _when,
            ),
    );

void main() {
  final ispconfig =
      _host('ispconfig', '192.168.10.41', user: 'deploy', group: 'Hosting');
  final web = _host('web-01', '192.168.10.21', user: 'root', group: 'Web');

  test('the reported case: "isp" finds the host called ispconfig', () {
    expect(hostMatchesQuery(ispconfig, 'isp'), isTrue);
    expect(hostMatchesQuery(web, 'isp'), isFalse);
  });

  test('any part of the name, whatever the case, with stray spaces', () {
    expect(hostMatchesQuery(ispconfig, 'config'), isTrue);
    expect(hostMatchesQuery(ispconfig, 'ISP'), isTrue);
    expect(hostMatchesQuery(ispconfig, '  pco  '), isTrue);
    expect(hostMatchesQuery(_host('ISPConfig', '192.168.10.41'), 'ispc'),
        isTrue);
  });

  test('the address, the user and the group match too', () {
    expect(hostMatchesQuery(ispconfig, '10.41'), isTrue);
    expect(hostMatchesQuery(ispconfig, 'deploy'), isTrue);
    expect(hostMatchesQuery(ispconfig, 'hosting'), isTrue);
    expect(hostMatchesQuery(web, 'hosting'), isFalse);
  });

  test('nothing typed shows every host; no match shows none', () {
    expect(hostMatchesQuery(ispconfig, ''), isTrue);
    expect(hostMatchesQuery(ispconfig, '   '), isTrue);
    expect(hostMatchesQuery(ispconfig, 'nothing-like-it'), isFalse);
  });

  test('a host with no user and no group is still found by name', () {
    final bare = _host('ispconfig', '192.168.10.41');
    expect(hostMatchesQuery(bare, 'isp'), isTrue);
    expect(hostMatchesQuery(bare, 'deploy'), isFalse);
  });
}
