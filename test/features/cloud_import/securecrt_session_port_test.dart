import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';

/// A SecureCRT session file holds every protocol's settings, whatever its own
/// protocol is (it starts as a copy of Default.ini), so a Telnet session
/// carries `[SSH2] Port` (22) beside its own `Port`. The import took
/// `[SSH2] Port` first for every protocol, so a Telnet session came in on
/// port 22. Each protocol's own port is read
/// first now.
void main() {
  String ini(String protocol, {String ssh2 = '00000016', String sftp = '00000016', String port = '00000913'}) =>
      'S:"Protocol Name"=$protocol\r\n'
      'S:"Hostname"=switch.example.com\r\n'
      'S:"Username"=\r\n'
      'D:"[SSH1] Port"=00000016\r\n'
      'D:"[SSH2] Port"=$ssh2\r\n'
      'D:"[SFTP] Port"=$sftp\r\n'
      'D:"Port"=$port\r\n';

  test('a SecureCRT Telnet session .ini is imported with its Telnet port', () {
    final row = readSecureCrtHosts(ini('Telnet')).rows.single;
    expect(row.protocol, 'telnet');
    expect(row.port, 2323, reason: 'the Telnet port is D:"Port"; [SSH2] Port is only the SSH default');
  });

  test('an SSH2 session keeps its [SSH2] Port, and an SFTP one its [SFTP] Port', () {
    expect(readSecureCrtHosts(ini('SSH2', ssh2: '000008ae', port: '00000017')).rows.single.port, 2222);
    final sftp = readSecureCrtHosts(ini('SFTP', ssh2: '00000016', sftp: '000008af')).rows.single;
    expect((sftp.protocol, sftp.port), ('sftp', 2223));
  });

  test('a SecureCRT XML export: a Telnet session keeps its Telnet port, an SSH2 one its SSH port', () {
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<VanDyke version="3.0">
  <key name="Sessions">
    <key name="lab-switch">
      <string name="Hostname">switch.example.com</string>
      <string name="Protocol Name">Telnet</string>
      <dword name="[SSH2] Port">22</dword>
      <dword name="Port">2323</dword>
    </key>
    <key name="web-01">
      <string name="Hostname">web-01.example.com</string>
      <string name="Protocol Name">SSH2</string>
      <dword name="[SSH2] Port">2222</dword>
      <dword name="Port">23</dword>
    </key>
  </key>
</VanDyke>
''';
    final rows = readSecureCrtHosts(xml).rows;
    expect([for (final r in rows) (r.protocol, r.port)], [('telnet', 2323), ('ssh', 2222)]);
  });
}
