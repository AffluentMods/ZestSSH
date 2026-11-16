import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';

/// The Migration Assistant (3.0) reads another app's own file: MobaXterm's
/// sessions (its .mxtsessions export or MobaXterm.ini) and SecureCRT's (its
/// Export Settings XML or a session's .ini). SSH and Telnet sessions come in
/// with their folders as groups; the app's other kinds are left out; each
/// host is checked as a CSV line is.

const _moba = '[Bookmarks]\r\n'
    'SubRep=\r\n'
    'ImgNum=42\r\n'
    'Jump box=#109#0%jump.example.com%22%ops%%-1%-1%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%%xterm%-1%-1%_Std_Colors_0_%80%24%0%1%-1%<none>%%0%0%-1#0# #-1\r\n'
    'Desktop=#91#4%win.example.com%3389%admin%0%-1%-1%-1%-1%0%0%-1\r\n'
    '\r\n'
    '[Bookmarks_1]\r\n'
    'SubRep=Production\\Web\r\n'
    'ImgNum=41\r\n'
    'web-01=#109#0%web-01.example.com%2222%deploy%%-1%-1%%%%%0%0%0\r\n'
    'Old switch=#98#2%switch.example.com%23%%%2%%%%%0%0\r\n'
    'Bad port=#109#0%db.example.com%99999%%%-1\r\n'
    '\r\n'
    '[Misc]\r\n'
    'Other=#109#0%not-a-session.example.com%22%%\r\n';

const _crtXml = '''<?xml version="1.0" encoding="UTF-8"?>
<VanDyke version="3.0">
  <key name="Sessions">
    <key name="Default">
      <string name="Hostname"></string>
      <string name="Protocol Name">SSH2</string>
    </key>
    <key name="Production">
      <key name="EU">
        <key name="api-01">
          <string name="Hostname">api-01.example.com</string>
          <dword name="[SSH2] Port">2200</dword>
          <string name="Username">deploy</string>
          <string name="Protocol Name">SSH2</string>
        </key>
      </key>
      <key name="console">
        <string name="Hostname">console.example.com</string>
        <string name="Protocol Name">Serial</string>
      </key>
    </key>
    <key name="lab">
      <string name="Hostname">lab.example.com</string>
      <string name="Protocol Name">Telnet</string>
      <dword name="Port">23</dword>
    </key>
  </key>
</VanDyke>
''';

const _crtIni = 'S:"Protocol Name"=SSH2\r\n'
    'S:"Hostname"=bastion.example.com\r\n'
    'S:"Username"=ops\r\n'
    'D:"[SSH2] Port"=00000a2a\r\n';

void main() {
  test('a file is read as what it is: MobaXterm, SecureCRT (XML or a session), else CSV', () {
    expect(hostFileKindOf(_moba), HostFileKind.mobaxterm);
    expect(hostFileKindOf(_crtXml), HostFileKind.securecrt);
    expect(hostFileKindOf(_crtIni), HostFileKind.securecrt);
    expect(hostFileKindOf('name,host\nweb,web.example.com\n'), HostFileKind.csv);
    expect(readHostFile('﻿$_moba').rows, hasLength(4), reason: 'a byte order mark first changes nothing');
  });

  test('MobaXterm: SSH and Telnet sessions with their folder as group; RDP and other sections left out', () {
    final f = readMobaXtermHosts(_moba);
    expect(f.problem, isNull);
    expect([for (final r in f.rows) r.name], ['Jump box', 'web-01', 'Old switch', 'Bad port']);
    final jump = f.rows[0];
    expect((jump.host, jump.port, jump.user, jump.group, jump.protocol), ('jump.example.com', 22, 'ops', null, 'ssh'));
    final web = f.rows[1];
    expect((web.host, web.port, web.user, web.group, web.protocol),
        ('web-01.example.com', 2222, 'deploy', 'Production / Web', 'ssh'));
    final sw = f.rows[2];
    expect((sw.host, sw.port, sw.user, sw.protocol), ('switch.example.com', 23, null, 'telnet'));
    expect(f.rows[3].problem, CsvRowProblem.badPort, reason: 'checked as a CSV line is');
    expect(f.rows.every((r) => r.line > 0), isTrue);
  });

  test('MobaXterm: a file without SSH or Telnet sessions is empty', () {
    expect(readMobaXtermHosts('[Bookmarks]\nSubRep=\nDesktop=#91#4%win.example.com%3389%admin\n').problem,
        CsvFileProblem.empty);
  });

  test('SecureCRT XML: sessions in folders as groups; Default and serial left out; the port where it is', () {
    final f = readSecureCrtHosts(_crtXml);
    expect(f.problem, isNull);
    expect([for (final r in f.rows) r.name], ['api-01', 'lab']);
    final api = f.rows[0];
    expect((api.host, api.port, api.user, api.group, api.protocol),
        ('api-01.example.com', 2200, 'deploy', 'Production / EU', 'ssh'));
    final lab = f.rows[1];
    expect((lab.host, lab.port, lab.group, lab.protocol), ('lab.example.com', 23, null, 'telnet'));
  });

  test('SecureCRT session .ini: one host, its port from hexadecimal', () {
    final f = readSecureCrtHosts(_crtIni);
    expect(f.rows, hasLength(1));
    final r = f.rows.single;
    expect((r.name, r.host, r.port, r.user, r.protocol), ('bastion.example.com', 'bastion.example.com', 2602, 'ops', 'ssh'));
  });

  test('SecureCRT: broken XML, no Sessions, or only the Default session is empty', () {
    expect(readSecureCrtHosts('<VanDyke><key name="Sessions">').problem, CsvFileProblem.empty);
    expect(readSecureCrtHosts('<VanDyke version="3.0"><key name="Options"/></VanDyke>').problem, CsvFileProblem.empty);
    expect(readSecureCrtHosts('S:"Hostname"=\r\nS:"Protocol Name"=SSH2\r\n').problem, CsvFileProblem.empty);
  });

  // SFTP sessions were left out of both (now they come in as hosts
  // that are SFTP only). MobaXterm writes each session as #icon#kind%...: an
  // SFTP session's icon is 140 and its kind 7, an SSH one's 109 and 0, and
  // either icon can be changed by its person.
  test('MobaXterm: an SFTP session comes in as a host that is SFTP only, by its kind whatever its icon', () {
    final f = readMobaXtermHosts('[Bookmarks]\r\n'
        'SubRep=Backups\r\n'
        'files-01=#140#7%files-01.example.com%2222%backup%%-1%-1%%%0\r\n'
        'files-02=#109#7%files-02.example.com%22%backup%%-1%-1%%%0\r\n'
        'web-02=#140#0%web-02.example.com%22%deploy%%-1%-1%%%%%0%0%0\r\n'
        'ftp-01=#130#6%ftp.example.com%21%anon%%-1\r\n');
    expect([for (final r in f.rows) (r.name, r.protocol)], [
      ('files-01', 'sftp'),
      ('files-02', 'sftp'),
      ('web-02', 'ssh'),
      // (3.4: FTP comes in as FTPS, never as plain FTP: test/features/cloud_import/ftp_import_test.dart.)
      ('ftp-01', 'ftps'),
    ]);
    final files = f.rows.first;
    expect((files.host, files.port, files.user, files.group), ('files-01.example.com', 2222, 'backup', 'Backups'));
  });

  test('SecureCRT and SecureFX: a session whose protocol is SFTP comes in as a host that is SFTP only', () {
    final xml = readSecureCrtHosts('''<?xml version="1.0" encoding="UTF-8"?>
<VanDyke version="3.0">
  <key name="Sessions">
    <key name="files-01">
      <string name="Hostname">files-01.example.com</string>
      <string name="Protocol Name">SFTP</string>
      <dword name="[SSH2] Port">2222</dword>
      <string name="Username">backup</string>
    </key>
    <key name="ftp-01">
      <string name="Hostname">ftp.example.com</string>
      <string name="Protocol Name">FTP</string>
    </key>
  </key>
</VanDyke>
''');
    expect([for (final r in xml.rows) (r.name, r.host, r.port, r.user, r.protocol)], [
      ('files-01', 'files-01.example.com', 2222, 'backup', 'sftp'),
      // (3.4: SecureFX's FTP comes in as FTPS, never as plain FTP.)
      ('ftp-01', 'ftp.example.com', 21, null, 'ftps'),
    ]);
    final ini = readSecureCrtHosts('S:"Protocol Name"=SFTP\r\n'
        'S:"Hostname"=files-02.example.com\r\n'
        'D:"[SFTP] Port"=000008ae\r\n');
    expect([for (final r in ini.rows) (r.host, r.port, r.protocol)], [('files-02.example.com', 2222, 'sftp')]);
  });

  test('a CSV file may name a host that is SFTP only too', () {
    final f = readCsvHosts('name,host,protocol\nfiles-01,files-01.example.com,SFTP\nweb-01,web-01.example.com,ssh\n');
    expect([for (final r in f.rows) (r.name, r.protocol, r.problem)], [
      ('files-01', 'sftp', null),
      ('web-01', 'ssh', null),
    ]);
  });

  test('an address with a dash in front is no host, from any app: it reads as an option wherever it is passed later', () {
    final reg = readPuttyRegHosts('Windows Registry Editor Version 5.00\n\n'
        '[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\evil]\n'
        '"HostName"="-oProxyCommand=calc"\n"Protocol"="ssh"\n\n'
        '[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\fine]\n'
        '"HostName"="fine.example.com"\n"Protocol"="ssh"\n');
    expect({for (final r in reg.rows) r.name: r.problem}, {'evil': CsvRowProblem.badHost, 'fine': null});
    final moba = readMobaXtermHosts('[Bookmarks]\nevil=#109#0%-oProxyCommand=calc%22%%\nfine=#109#0%fine.example.com%22%%\n');
    expect({for (final r in moba.rows) r.name: r.problem}, {'evil': CsvRowProblem.badHost, 'fine': null});
    final session = readSecureCrtHosts('S:"Protocol Name"=SSH2\nS:"Hostname"=-oProxyCommand=calc\nD:"[SSH2] Port"=00000016\n');
    expect(session.rows.single.problem, CsvRowProblem.badHost);
    final xml = readSecureCrtHosts('<?xml version="1.0"?>\n<VanDyke version="3.0"><key name="Sessions"><key name="evil">'
        '<string name="Hostname">-oProxyCommand=calc</string><string name="Protocol Name">SSH2</string></key></key></VanDyke>\n');
    expect(xml.rows.single.problem, CsvRowProblem.badHost);
  });

  test('a host that is no address is a problem, not a host; past the limit the file is cut', () {
    final bad = readMobaXtermHosts('[Bookmarks]\nweird=#109#0%bad host/with slash%22%%\n');
    expect(bad.rows.single.problem, CsvRowProblem.badHost);
    final many = StringBuffer('[Bookmarks]\n');
    for (var i = 0; i <= kCsvMaxHosts; i++) {
      many.writeln('h$i=#109#0%h$i.example.com%22%%');
    }
    final cut = readMobaXtermHosts('$many');
    expect(cut.rows, hasLength(kCsvMaxHosts));
    expect(cut.cut, isTrue);
  });
}
