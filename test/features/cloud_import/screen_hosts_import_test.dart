// Remote screens in the imports (4.0): the remote desktop entries of other
// apps' files come in as VNC hosts, and as RDP hosts where this build offers
// RDP (the readers are told; an RDP entry is otherwise left out as every kind
// the app does not connect to). MobaXterm's VNC and RDP sessions, a CSV file's
// vnc and rdp lines, mRemoteNG's connections file and Remmina's connection
// files. No password is ever read from any of them.
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_writer.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/rdp_file.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';

/// A Remote Desktop file as Windows saves one, with everything this import
/// leaves on purpose in it. (The password's bytes are made up.)
const _rdpFile = 'screen mode id:i:2\r\n'
    'use multimon:i:1\r\n'
    'selectedmonitors:s:0,1\r\n'
    'full address:s:pc.example.test:3390\r\n'
    'username:s:alex\r\n'
    'domain:s:CORP\r\n'
    'redirectclipboard:i:0\r\n'
    'gatewayhostname:s:gw.example.test\r\n'
    'gatewayusagemethod:i:1\r\n'
    'enablecredsspsupport:i:0\r\n'
    'remoteapplicationmode:i:1\r\n'
    'password 51:b:01000000D08C9DDF0115D1118C7A00C04FC297EB\r\n';

const _moba = '''
[Bookmarks]
SubRep=
ImgNum=42
build=#109#0%build.example.test%22%alex%%-1%-1
[Bookmarks_1]
SubRep=Office\\Desks
ImgNum=41
Reception VNC=#128#5%10.50.0.5%5901%-1%0%%%0%
Bare VNC=#128#5%10.50.0.6%%-1%0%
Office PC=#91#4%pc.example.test%3390%CORP\\alex%0%-1
Bare RDP=#91#4%pc2.example.test%%alex%0%-1
Serial=#131#8%COM3%9600%
''';

const _mrng = '''<?xml version="1.0" encoding="utf-8"?>
<mrng:Connections xmlns:mrng="http://mremoteng.org" Name="Connections" Export="false" EncryptionEngine="AES" BlockCipherMode="GCM" KdfIterations="1000" FullFileEncryption="false" Protected="made-up-check" ConfVersion="2.6">
  <Node Name="build" Type="Connection" Hostname="build.example.test" Protocol="SSH2" Port="22" Username="alex" Password="bWFkZS11cC1jaXBoZXJ0ZXh0" />
  <Node Name="Office" Type="Container" Protocol="RDP" Port="3390" Username="alex" Domain="CORP" Password="bWFkZS11cA==">
    <Node Name="Reception" Type="Connection" Hostname="10.50.0.5" Protocol="VNC" Port="5901" Username="" />
    <Node Name="Desk 1" Type="Connection" Hostname="pc1.example.test" Protocol="RDP" Port="3389" Username="sam" Domain="" InheritDomain="True" />
    <Node Name="Desks" Type="Container" InheritProtocol="true" InheritPort="true" InheritUsername="true" InheritDomain="true">
      <Node Name="Desk 2" Type="Connection" Hostname="pc2.example.test" InheritProtocol="true" InheritPort="true" InheritUsername="true" InheritDomain="true" />
    </Node>
    <Node Name="Switch" Type="Connection" Hostname="10.50.0.1" Protocol="Telnet" Port="23" />
    <Node Name="Web" Type="Connection" Hostname="intranet.example.test" Protocol="HTTPS" Port="443" />
  </Node>
</mrng:Connections>
''';

String _remmina(String protocol, String server, {String more = ''}) => '''
[remmina]
password=bWFkZS11cC1jaXBoZXJ0ZXh0
name=Reception
group=Office/Desks
server=$server
protocol=$protocol
username=alex
$more
''';

void main() {
  CsvHostRow named(CsvHostFile file, String name) => file.rows.singleWhere((r) => r.name == name);

  group('MobaXterm', () {
    test('a VNC session comes in as a VNC host, on its port or the port VNC has, with no account', () {
      final file = readMobaXtermHosts(_moba);
      final vnc = named(file, 'Reception VNC');
      expect((vnc.protocol, vnc.host, vnc.port, vnc.user, vnc.group), ('vnc', '10.50.0.5', 5901, null, 'Office / Desks'));
      expect(named(file, 'Bare VNC').port, 5900);
      expect(vnc.problem, isNull);
    });

    test('an RDP session is left out where this build offers no RDP, and comes in where it does', () {
      final without = readMobaXtermHosts(_moba);
      expect(without.rows.map((r) => r.name), ['build', 'Reception VNC', 'Bare VNC']);
      final with_ = readMobaXtermHosts(_moba, rdp: true);
      final pc = named(with_, 'Office PC');
      expect((pc.protocol, pc.host, pc.port, pc.user), ('rdp', 'pc.example.test', 3390, r'CORP\alex'));
      expect(named(with_, 'Bare RDP').port, 3389);
      expect(with_.rows.map((r) => r.name), isNot(contains('Serial')));
    });
  });

  group('a CSV file', () {
    test('a vnc line is a VNC host, on port 5900 where it names none', () {
      final file = readCsvHosts('name,host,port,protocol\nDesk,10.50.0.5,,vnc\nOther,10.50.0.6,5902,VNC\n');
      expect(file.rows.map((r) => (r.protocol, r.port, r.problem)), [('vnc', 5900, null), ('vnc', 5902, null)]);
    });

    test('an rdp line is refused where this build offers no RDP, and is an RDP host on 3389 where it does', () {
      const text = 'name,host,protocol\nPC,pc.example.test,rdp\n';
      final without = readCsvHosts(text).rows.single;
      expect(without.problem, CsvRowProblem.badProtocol);
      final with_ = readCsvHosts(text, rdp: true).rows.single;
      expect((with_.protocol, with_.port, with_.problem), ('rdp', 3389, null));
      // Every other line is as it always was.
      expect(readCsvHosts('name,host\nA,a.example.test\n').rows.single.port, 22);
    });
  });

  group('mRemoteNG', () {
    test('it is told from every other file, and read as its own kind', () {
      expect(isMRemoteNgFile(_mrng), isTrue);
      expect(hostFileKindOf(_mrng), HostFileKind.mremoteng);
      expect(importKindOf(utf8.encode(_mrng)), ImportKind.mRemoteNg);
      expect(ImportKind.mRemoteNg.hostFile, HostFileKind.mremoteng);
      expect(isMRemoteNgFile('<FileZilla3><Servers><Server/></Servers></FileZilla3>'), isFalse);
      expect(isMRemoteNgFile('name,host\na,b\n'), isFalse);
    });

    test('SSH, Telnet and VNC connections come in with their folders; RDP ones only where RDP is offered', () {
      final file = readMRemoteNgHosts(_mrng);
      expect(file.problem, isNull);
      expect(file.rows.map((r) => (r.name, r.protocol, r.host, r.port, r.group)), [
        ('build', 'ssh', 'build.example.test', 22, null),
        ('Reception', 'vnc', '10.50.0.5', 5901, 'Office'),
        ('Switch', 'telnet', '10.50.0.1', 23, 'Office'),
      ]);
      expect(named(file, 'build').user, 'alex');

      final with_ = readMRemoteNgHosts(_mrng, rdp: true);
      expect(with_.rows.map((r) => r.name), ['build', 'Reception', 'Desk 1', 'Desk 2', 'Switch']);
      // Its own account, with the domain it inherits from its folder.
      final one = named(with_, 'Desk 1');
      expect((one.protocol, one.port, one.user, one.group), ('rdp', 3389, r'CORP\sam', 'Office'));
      // Everything inherited, through two folders.
      final two = named(with_, 'Desk 2');
      expect((two.protocol, two.port, two.user, two.group), ('rdp', 3390, r'CORP\alex', 'Office / Desks'));
    });

    test('no password is read, in any form', () {
      final file = readMRemoteNgHosts(_mrng, rdp: true);
      final all = [for (final r in file.rows) '${r.name}|${r.host}|${r.user}|${r.group}|${r.note}|${r.key}'].join('\n');
      expect(all.contains('bWFkZS11cC1jaXBoZXJ0ZXh0'), isFalse);
      expect(all.contains('bWFkZS11cA=='), isFalse);
      expect(all.contains('made-up-check'), isFalse);
    });

    test('a file encrypted as a whole, a file that is no XML, and one too large read as nothing to import', () {
      const whole = '<?xml version="1.0"?><mrng:Connections xmlns:mrng="http://mremoteng.org" FullFileEncryption="true" '
          'ConfVersion="2.6">bWFkZS11cC1jaXBoZXJ0ZXh0</mrng:Connections>';
      expect(readMRemoteNgHosts(whole).problem, CsvFileProblem.empty);
      expect(readMRemoteNgHosts('<mrng:Connections ConfVersion="2.6"><Node').problem, CsvFileProblem.empty);
      expect(readMRemoteNgHosts('<a>${'x' * (kCsvMaxBytes + 1)}</a>').problem, CsvFileProblem.tooLarge);
    });

    test('an address that hides or reorders text is refused, and folders nested past all reason are not followed', () {
      final rlo = String.fromCharCode(0x202E);
      final hidden = '<Connections ConfVersion="2.6"><Node Name="x" Type="Connection" Hostname="pc${rlo}moc.live" '
          'Protocol="VNC" /></Connections>';
      expect(readMRemoteNgHosts(hidden).rows.single.problem, CsvRowProblem.badHost);
      final deep = '<Connections ConfVersion="2.6">${'<Node Name="f" Type="Container">' * 200}'
          '<Node Name="x" Type="Connection" Hostname="10.0.0.1" Protocol="VNC" />${'</Node>' * 200}</Connections>';
      expect(readMRemoteNgHosts(deep).problem, CsvFileProblem.empty);
    });
  });

  group('Remmina', () {
    test('it is told from every other file, and read as its own kind', () {
      final text = _remmina('VNC', '10.50.0.5:5901');
      expect(isRemminaFile(text), isTrue);
      expect(hostFileKindOf(text), HostFileKind.remmina);
      expect(importKindOf(utf8.encode(text)), ImportKind.remmina);
      expect(isRemminaFile('[Bookmarks]\nSubRep=\n'), isFalse);
    });

    test('a VNC file: its address and port, a display number as VNC counts it, an IPv6 address in brackets', () {
      final vnc = readRemminaHosts(_remmina('VNC', '10.50.0.5:5901')).rows.single;
      expect((vnc.name, vnc.protocol, vnc.host, vnc.port, vnc.group), ('Reception', 'vnc', '10.50.0.5', 5901, 'Office / Desks'));
      expect(readRemminaHosts(_remmina('VNC', '10.50.0.5:1')).rows.single.port, 5901);
      expect(readRemminaHosts(_remmina('VNC', '10.50.0.5')).rows.single.port, 5900);
      final v6 = readRemminaHosts(_remmina('VNC', '[2001:db8::5]:5902')).rows.single;
      expect((v6.host, v6.port, v6.problem), ('2001:db8::5', 5902, null));
      final bare6 = readRemminaHosts(_remmina('VNC', '2001:db8::5')).rows.single;
      expect((bare6.host, bare6.port), ('2001:db8::5', 5900));
      expect(readRemminaHosts(_remmina('VNC', '10.50.0.5:abc')).rows.single.problem, CsvRowProblem.badPort);
    });

    test('SSH and SFTP files come in; an RDP file only where RDP is offered, with its domain; the rest are left out', () {
      final ssh = readRemminaHosts(_remmina('SSH', 'build.example.test:2222')).rows.single;
      expect((ssh.protocol, ssh.port, ssh.user), ('ssh', 2222, 'alex'));
      expect(readRemminaHosts(_remmina('SFTP', 'build.example.test')).rows.single.protocol, 'sftp');
      expect(readRemminaHosts(_remmina('RDP', 'pc.example.test')).problem, CsvFileProblem.empty);
      final rdp = readRemminaHosts(_remmina('RDP', 'pc.example.test', more: 'domain=CORP'), rdp: true).rows.single;
      expect((rdp.protocol, rdp.port, rdp.user), ('rdp', 3389, r'CORP\alex'));
      for (final other in ['SPICE', 'NX', 'VNCI', 'X2GO', '']) {
        expect(readRemminaHosts(_remmina(other, '10.0.0.1'), rdp: true).problem, CsvFileProblem.empty, reason: other);
      }
    });

    test('the password is never read, and only the remmina section counts', () {
      final row = readRemminaHosts(_remmina('VNC', '10.50.0.5')).rows.single;
      expect('${row.name}|${row.host}|${row.user}|${row.group}|${row.note}|${row.key}'.contains('bWFkZS11cC1jaXBo'), isFalse);
      const other = '[something]\nserver=evil.example.test\nprotocol=VNC\n[remmina]\nprotocol=VNC\nserver=10.50.0.5\n';
      expect(readRemminaHosts(other).rows.single.host, '10.50.0.5');
    });
  });

  group('a Remote Desktop file (.rdp)', () {
    test('it is told from every other file; whoever shows a file to a person calls it one only where RDP is offered',
        () {
      expect(hostFileKindOf(_rdpFile), HostFileKind.rdpfile);
      expect(importKindOf(utf8.encode(_rdpFile)), ImportKind.rdpFile);
      expect(ImportKind.rdpFile.isHostFile, isTrue);
      expect(ImportKind.rdpFile.hostFile, HostFileKind.rdpfile);
      final bytes = utf8.encode(_rdpFile);
      expect(importFileOf(name: 'Office PC.rdp', bytes: bytes).kind, ImportKind.unknown);
      expect(importFileOf(name: 'Office PC.rdp', bytes: bytes, rdp: true).kind, ImportKind.rdpFile);
      // Every other kind is what it was, whatever the build offers.
      expect(hostFileKindOf(_moba), HostFileKind.mobaxterm);
      expect(importKindOf(utf8.encode('host,port\na.example.test,22')), ImportKind.csv);
      // A file that only mentions an address line somewhere in a sentence is none.
      expect(hostFileKindOf('notes: the full address:s: line names the computer'), HostFileKind.csv);
    });

    test('where this build offers no RDP, nothing of it comes in', () {
      final file = readRdpFileHosts(_rdpFile);
      expect(file.problem, CsvFileProblem.empty);
      expect(file.rows, isEmpty);
      expect(file.notes, isEmpty);
      expect(readHostBytes(utf8.encode(_rdpFile)).file.problem, CsvFileProblem.empty);
    });

    test('its computer, port and account come in as one RDP host named after the file; what it asked for and is not '
        'followed is said', () {
      final read = readHostBytes(utf8.encode(_rdpFile), rdp: true, name: 'Office PC.rdp');
      expect(read.kind, HostFileKind.rdpfile);
      final file = read.file;
      expect(file.problem, isNull);
      final row = file.rows.single;
      expect(row.problem, isNull);
      expect(row.protocol, 'rdp');
      expect(row.name, 'Office PC');
      expect(row.host, 'pc.example.test');
      expect(row.port, 3390);
      expect(row.user, r'CORP\alex');
      // The clipboard was off in the file: off for the host. Two monitors picked: two displays.
      expect(row.clipboardOff, isTrue);
      expect(row.displays, 2);
      expect(file.notes,
          [HostFileNote.rdpPassword, HostFileNote.rdpProgram, HostFileNote.rdpNlaOff, HostFileNote.rdpGateway]);
      expect(file.gateway, 'gw.example.test');
    });

    test('a plain file asks for nothing more than a new host has; its name is the address where the file has none of '
        'its own', () {
      const plain = 'full address:s:10.50.0.7\r\nredirectclipboard:i:1\r\nuse multimon:i:1\r\n';
      for (final name in [null, 'Default.rdp', 'default.RDP', 'Pasted text', '.rdp']) {
        final row = readRdpFileHosts(plain, rdp: true, fileName: name).rows.single;
        expect(row.name, '10.50.0.7', reason: '$name');
        expect(row.port, 3389);
        expect(row.user, isNull);
        // Shared in the file changes nothing; every monitor, with none picked, is one display.
        expect(row.clipboardOff, isFalse);
        expect(row.displays, 1);
      }
      expect(readRdpFileHosts(plain, rdp: true).notes, isEmpty);
      expect(readRdpFileHosts(plain, rdp: true, fileName: 'Desk 4.RDP').rows.single.name, 'Desk 4');
      // More monitors picked than a host can ask for: as many as it can.
      final many = readRdpFileHosts('$plain' 'selectedmonitors:s:0,1,2,3,4,5' '\r\n', rdp: true).rows.single;
      expect(many.displays, 4);
    });

    test('a file that names no computer, or what is no address, is a line that cannot be imported; one too large is '
        'refused whole', () {
      final none = readRdpFileHosts('full address:s:' '\r\n' 'username:s:alex' '\r\n', rdp: true, fileName: 'x.rdp');
      expect(none.rows.single.problem, CsvRowProblem.noHost);
      final bad = readRdpFileHosts('full address:s:alex@pc.example.test' '\r\n', rdp: true);
      expect(bad.rows.single.problem, CsvRowProblem.noHost);
      final large = 'full address:s:pc.example.test' '\r\n' '${'x' * kCsvMaxBytes}';
      expect(readRdpFileHosts(large, rdp: true).problem, CsvFileProblem.tooLarge);
    });

    test('a file made to be slow to look at is not: the longest lines, and the most of them', () {
      final tabs = String.fromCharCode(9) * (kCsvMaxBytes - 40);
      final lines = '  \n' * (kCsvMaxBytes ~/ 3 - 20);
      for (final hostile in [tabs, lines, '$tabs' '\n' 'full address:s:pc.example.test']) {
        final watch = Stopwatch()..start();
        hostFileKindOf(hostile);
        readRdpFileHosts(hostile, rdp: true);
        expect(watch.elapsedMilliseconds, lessThan(3000));
      }
    });
  });

  group('written as hosts', () {
    late AppDatabase db;
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() => db.close());

    test('a remote screen gets the options a new one has in the editor; every other host has none', () async {
      var n = 0;
      final file = readMRemoteNgHosts(_mrng, rdp: true);
      final out = await applyCsvImport(
        CsvImportTarget(db: db, userKeyLabel: (u) => '$u (imported)'),
        file.rows,
        now: () => DateTime.utc(2026, 11, 15, 12),
        newId: () => 'id-${++n}',
      );
      expect(out.added, 5);
      final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c};
      expect(hosts['Reception']!.protocol, 'vnc');
      expect(hosts['Reception']!.port, 5901);
      expect(ScreenOptions.decode(hosts['Reception']!.screenOptions), ScreenOptions.defaults);
      expect(hosts['Reception']!.screenOptions, ScreenOptions.encodeDefaults());
      expect(hosts['Desk 2']!.protocol, 'rdp');
      expect(hosts['Desk 2']!.screenOptions, isNotNull);
      expect(hosts['build']!.screenOptions, isNull);
      expect(hosts['Switch']!.screenOptions, isNull);
    });

    test('a Remote Desktop file: the clipboard its file had off is off for the host, and the displays it picked are '
        'asked for; everything else is as a new host has it', () async {
      var n = 0;
      final file = readRdpFileHosts(_rdpFile, rdp: true, fileName: 'Office PC.rdp');
      final out = await applyCsvImport(
        CsvImportTarget(db: db, userKeyLabel: (u) => '$u (imported)'),
        file.rows,
        now: () => DateTime.utc(2026, 11, 16, 12),
        newId: () => 'id-${++n}',
      );
      expect(out.added, 1);
      final host = (await db.connectionsDao.getAll()).single;
      expect(host.label, 'Office PC');
      expect(host.protocol, 'rdp');
      expect((host.host, host.port), ('pc.example.test', 3390));
      final options = ScreenOptions.decode(host.screenOptions);
      expect(options, ScreenOptions.defaults.copyWith(clipboard: false, displays: 2));
      expect(options.clipboard, isFalse);
      expect(options.displayCount, 2);
      // NLA stays on, whatever the file said.
      expect(options.nla, isTrue);
      // Nothing of the file's password is anywhere in what was written.
      expect(host.toString(), isNot(contains('D08C9DDF')));
      expect(importedScreenOptions(const CsvHostRow(line: 1, name: 'a', host: 'a.example.test', protocol: 'vnc')),
          ScreenOptions.encodeDefaults());
    });
  });
}
