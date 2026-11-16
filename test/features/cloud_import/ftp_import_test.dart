import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_writer.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';

/// FTPS in the importers (3.4: imports turn FTP rows
/// into FTPS hosts; plain FTP never). Every importer that reads FTP or FTPS rows
/// (a CSV file's protocol column, MobaXterm, SecureCRT and SecureFX, FileZilla's
/// Site Manager, WinSCP's sites) brings them in as FTPS hosts: explicit TLS for
/// FTP and FTPES (21), implicit for FTPS (990), and says which were plain FTP.
/// FTPS hosts stay in a person's own space for now: going to a team, they are
/// left out. All hosts below are made up.

const _fileZilla = '''<?xml version="1.0" encoding="UTF-8"?>
<FileZilla3 version="3.69.1" platform="windows">
  <Servers>
    <Server>
      <Host>ftp.example.com</Host>
      <Port>21</Port>
      <Protocol>0</Protocol>
      <Type>0</Type>
      <User>alice</User>
      <Pass encoding="base64">bWFkZS11cC1wYXNzd29yZA==</Pass>
      <Logontype>1</Logontype>
      <Name>Shop</Name>
    </Server>
    <Folder expanded="1">Clients
      <Server>
        <Host>files.example.org</Host>
        <Port>990</Port>
        <Protocol>3</Protocol>
        <User>bob</User>
        <Name>Old NAS</Name>
      </Server>
      <Folder expanded="0">EU
        <Server>
          <Host>eu.example.net</Host>
          <Port>2121</Port>
          <Protocol>4</Protocol>
          <User>carol</User>
          <Name>EU drop</Name>
        </Server>
        <Server>
          <Host>bare.example.net</Host>
          <Port>21</Port>
          <Protocol>6</Protocol>
          <Name>Insecure</Name>
        </Server>
      </Folder>
    </Folder>
    <Server>
      <Host>sftp.example.com</Host>
      <Port>22</Port>
      <Protocol>1</Protocol>
      <User>deploy</User>
      <Name>Web SFTP</Name>
    </Server>
    <Server>
      <Host>s3.example.com</Host>
      <Port>443</Port>
      <Protocol>7</Protocol>
      <Name>Bucket</Name>
    </Server>
  </Servers>
</FileZilla3>
''';

const _winScpIni = '[Configuration\\Interface]\r\n'
    'Theme=Light\r\n'
    '\r\n'
    '[Sessions\\Default%20Settings]\r\n'
    'HostName=\r\n'
    '\r\n'
    '[Sessions\\Clients/Shop%20FTP]\r\n'
    'HostName=ftp.example.com\r\n'
    'UserName=alice\r\n'
    'FSProtocol=5\r\n'
    'Password=A35C4E5D6B6C\r\n'
    '\r\n'
    '[Sessions\\Clients/Old%20NAS]\r\n'
    'HostName=files.example.org\r\n'
    'UserName=bob\r\n'
    'FSProtocol=5\r\n'
    'Ftps=1\r\n'
    '\r\n'
    '[Sessions\\Explicit]\r\n'
    'HostName=eu.example.net\r\n'
    'PortNumber=2121\r\n'
    'FSProtocol=5\r\n'
    'Ftps=3\r\n'
    '\r\n'
    '[Sessions\\Web]\r\n'
    'HostName=web.example.com\r\n'
    'UserName=deploy\r\n'
    '\r\n'
    '[Sessions\\Dav]\r\n'
    'HostName=dav.example.com\r\n'
    'FSProtocol=6\r\n';

const _winScpReg = 'Windows Registry Editor Version 5.00\r\n'
    '\r\n'
    '[HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\Sessions\\Shop%20FTP]\r\n'
    '"HostName"="ftp.example.com"\r\n'
    '"PortNumber"=dword:00000015\r\n'
    '"UserName"="alice"\r\n'
    '"FSProtocol"=dword:00000005\r\n';

void main() {
  group('a CSV file', () {
    test('ftp, ftpes and ftps come in as FTPS, with the port of their TLS where none is given', () {
      final file = readCsvHosts('name,host,port,protocol\n'
          'Plain,a.example.com,,ftp\n'
          'Explicit,b.example.com,,FTPES\n'
          'Implicit,c.example.com,,ftps\n'
          'FTPS on 21,d.example.com,21,ftps\n'
          'FTP on 990,e.example.com,990,ftp\n'
          'Custom,f.example.com,2121,ftp\n'
          'SSH,g.example.com,,\n');
      final rows = {for (final r in file.rows) r.name: r};
      expect(rows.values.map((r) => r.problem).nonNulls, isEmpty);
      expect((rows['Plain']!.protocol, rows['Plain']!.port, rows['Plain']!.wasPlainFtp), ('ftps', 21, true));
      expect((rows['Explicit']!.protocol, rows['Explicit']!.port, rows['Explicit']!.wasPlainFtp), ('ftps', 21, false));
      expect((rows['Implicit']!.protocol, rows['Implicit']!.port), ('ftpsImplicit', 990));
      expect((rows['FTPS on 21']!.protocol, rows['FTPS on 21']!.port), ('ftps', 21));
      expect((rows['FTP on 990']!.protocol, rows['FTP on 990']!.port), ('ftpsImplicit', 990));
      expect((rows['Custom']!.protocol, rows['Custom']!.port), ('ftps', 2121));
      expect((rows['SSH']!.protocol, rows['SSH']!.port), ('ssh', 22));
      expect(rows.values.where((r) => r.isFtps), hasLength(6));
    });

    test('a protocol that is none is still said as one, ftp no longer among them', () {
      final file = readCsvHosts('host,protocol\na.example.com,gopher\nb.example.com,ftp\n');
      expect(file.rows.first.problem, CsvRowProblem.badProtocol);
      expect(file.rows.last.problem, isNull);
    });
  });

  test('MobaXterm: FTP sessions (kind 6, icon 130) come in as FTPS', () {
    const moba = '[Bookmarks]\r\n'
        'SubRep=\r\n'
        'ImgNum=42\r\n'
        'Shop=#130#6%ftp.example.com%21%alice%%-1\r\n'
        'NAS=#130#6%files.example.org%990%bob%%-1\r\n'
        'Jump=#109#0%jump.example.com%22%ops%%-1\r\n';
    final rows = readMobaXtermHosts(moba).rows;
    expect([for (final r in rows) (r.name, r.protocol, r.port, r.wasPlainFtp)], [
      ('Shop', 'ftps', 21, true),
      ('NAS', 'ftpsImplicit', 990, true),
      ('Jump', 'ssh', 22, false),
    ]);
  });

  test('SecureFX: FTP and FTP over TLS come in as FTPS, with FTP\'s own port', () {
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<VanDyke version="3.0">
  <key name="Sessions">
    <key name="Shop">
      <string name="Hostname">ftp.example.com</string>
      <string name="Protocol Name">FTP</string>
      <dword name="Port">23</dword>
      <dword name="[SSH2] Port">22</dword>
      <string name="Username">alice</string>
    </key>
    <key name="NAS">
      <string name="Hostname">files.example.org</string>
      <string name="Protocol Name">FTPS</string>
      <dword name="[FTP] Port">990</dword>
    </key>
    <key name="TLS">
      <string name="Hostname">eu.example.net</string>
      <string name="Protocol Name">FTP/TLS</string>
    </key>
  </key>
</VanDyke>''';
    final rows = readSecureCrtHosts(xml).rows;
    expect([for (final r in rows) (r.name, r.protocol, r.port, r.wasPlainFtp)], [
      ('Shop', 'ftps', 21, true),
      ('NAS', 'ftpsImplicit', 990, false),
      ('TLS', 'ftps', 21, false),
    ]);
  });

  group('FileZilla', () {
    test('is told from other files, and its FTP and FTPS sites come in as FTPS, folders as groups', () {
      expect(importKindOf(utf8.encode(_fileZilla)), ImportKind.fileZilla);
      expect(hostFileKindOf(_fileZilla), HostFileKind.filezilla);
      final file = readHostFile(_fileZilla);
      expect([for (final r in file.rows) (r.name, r.host, r.port, r.protocol, r.group, r.wasPlainFtp)], [
        ('Shop', 'ftp.example.com', 21, 'ftps', null, true),
        ('Old NAS', 'files.example.org', 990, 'ftpsImplicit', 'Clients', false),
        ('EU drop', 'eu.example.net', 2121, 'ftps', 'Clients / EU', false),
        ('Insecure', 'bare.example.net', 21, 'ftps', 'Clients / EU', true),
        ('Web SFTP', 'sftp.example.com', 22, 'sftp', null, false),
      ], reason: 'S3 is left out');
      expect(file.rows.first.user, 'alice');
    });

    test('its password is never read', () {
      final file = readFileZillaHosts(_fileZilla);
      for (final r in file.rows) {
        expect('${r.name} ${r.host} ${r.user} ${r.note}', isNot(contains('bWFkZS11cC1wYXNzd29yZA')));
      }
    });

    test('a FileZilla settings file with no servers is no host file', () {
      const settings = '<?xml version="1.0"?>\n<FileZilla3 version="3.69.1"><Settings><Setting name="x">1</Setting></Settings></FileZilla3>';
      expect(hostFileKindOf(settings), isNot(HostFileKind.filezilla));
    });
  });

  group('WinSCP', () {
    test('WinSCP.ini: FTP comes in as FTPS (implicit where Ftps is 1), SFTP as SFTP only, folders as groups', () {
      expect(importKindOf(utf8.encode(_winScpIni)), ImportKind.winScp);
      final file = readHostFile(_winScpIni);
      expect([for (final r in file.rows) (r.name, r.host, r.port, r.protocol, r.group, r.wasPlainFtp)], [
        ('Shop FTP', 'ftp.example.com', 21, 'ftps', 'Clients', true),
        ('Old NAS', 'files.example.org', 990, 'ftpsImplicit', 'Clients', false),
        ('Explicit', 'eu.example.net', 2121, 'ftps', null, false),
        ('Web', 'web.example.com', 22, 'sftp', null, false),
      ], reason: 'Default Settings and WebDAV are left out');
    });

    test('its registry exported to a .reg file', () {
      expect(importKindOf(utf8.encode(_winScpReg)), ImportKind.winScp);
      final rows = readHostFile(_winScpReg).rows;
      expect([for (final r in rows) (r.name, r.host, r.port, r.protocol, r.user)], [
        ('Shop FTP', 'ftp.example.com', 21, 'ftps', 'alice'),
      ]);
    });
  });

  test('an FTPS host is new wherever it goes, a team as the Tree (3.4)', () {
    final rows = readCsvHosts('host,protocol\nftp.example.com,ftp\nweb.example.com,ssh\n').rows;
    expect(csvRowStatus(rows.first, {}, {}), CsvRowStatus.fresh);
    expect(csvRowStatus(rows.last, {}, {}), CsvRowStatus.fresh);
  });

  group('written', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));
    var n = 0;
    String ids() => 'id-${++n}';
    String userKey(String user) => '$user (imported)';

    test('into the Tree, as FTPS hosts', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final out = await applyCsvImport(
        CsvImportTarget(db: db, userKeyLabel: userKey),
        readHostFile(_fileZilla).rows,
        newId: ids,
      );
      expect(out.failures, isEmpty);
      final hosts = await db.connectionsDao.getAll();
      expect({for (final h in hosts) h.host: (h.protocol, h.port)}, {
        'ftp.example.com': ('ftps', 21),
        'files.example.org': ('ftpsImplicit', 990),
        'eu.example.net': ('ftps', 2121),
        'bare.example.net': ('ftps', 21),
        'sftp.example.com': ('sftp', 22),
      });
      expect(hosts.where((h) => h.protocol == 'ftp'), isEmpty, reason: 'never plain FTP');
    });

    test('into a team, an FTPS host comes in as an FTPS host of its vault, queued to be sealed (3.4)', () async {
      const crate = '11111111-1111-4111-8111-111111111111';
      final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      addTearDown(db.close);
      await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
          "VALUES (1, '66666666-6666-4666-8666-666666666666', 'Acme', 'member-role', 1, ?)",
          [crate]);
      await db.customStatement(
          "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'use', ?, 1)",
          [crate, jsonEncode(switchList(levelSwitches(CrateLevel.edit)))]);
      final out = await applyCsvImport(
        CsvImportTarget(db: db, crateId: crate, userKeyLabel: userKey),
        readCsvHosts('name,host,protocol\nShop,ftp.example.com,ftp\nWeb,web.example.com,ssh\n').rows,
        newId: ids,
      );
      expect(out.added, 2);
      expect(out.failures, isEmpty);
      final hosts = await db.connectionsDao.getAll();
      expect({for (final h in hosts) h.host: h.protocol}, {'ftp.example.com': 'ftps', 'web.example.com': 'ssh'});
      final shop = hosts.firstWhere((h) => h.host == 'ftp.example.com');
      expect(await CratePlacement(db).crateOf('host', shop.id), crate);
      final queued = await db.customSelect("SELECT item_key FROM crate_outbox WHERE kind = 'host'").get();
      expect(queued.map((r) => r.read<String>('item_key')), contains(shop.id));
    });
  });
}
