// The 4.0 importers read as an attacker would hand them a file: mRemoteNG's
// XML, a Remmina file, a Remote Desktop file, MobaXterm's sessions and a CSV
// file with remote screens in it. Whatever the file holds, a reader answers
// in bounded time, throws nothing, reads nothing from outside the file, and
// hands on only text that is safe to show and an address that is one.
//
// The second half changes good files at random (the same changes every run:
// the seed is fixed) and holds every reader to the same rules.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/rdp_file.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';

String _c(int code) => String.fromCharCode(code);

/// Control characters, and the marks that hide text or turn its direction.
final _unsafe = RegExp('[${_c(0)}-${_c(0x1f)}${_c(0x7f)}-${_c(0x9f)}${_c(0x200b)}-${_c(0x200f)}'
    '${_c(0x202a)}-${_c(0x202e)}${_c(0x2060)}-${_c(0x2064)}${_c(0x2066)}-${_c(0x2069)}${_c(0xfeff)}]');

const _protocols = {'ssh', 'telnet', 'vnc', 'rdp', 'sftp', 'ftps', 'ftpsImplicit', 'mosh'};

/// What every reader owes whoever shows or writes its hosts.
void _holds(CsvHostFile file, String what) {
  expect(file.rows.length, lessThanOrEqualTo(kCsvMaxHosts), reason: what);
  for (final row in file.rows) {
    for (final (name, text, max) in [
      ('name', row.name, 255),
      ('host', row.host, 253),
      ('user', row.user ?? '', 255),
      ('group', row.group ?? '', 255),
      ('key', row.key ?? '', 255),
    ]) {
      expect(_unsafe.hasMatch(text), isFalse, reason: '$what: the $name of line ${row.line} carries a hidden character');
      expect(text.length, lessThanOrEqualTo(max), reason: '$what: the $name of line ${row.line} is too long');
    }
    expect(row.port, inInclusiveRange(1, 65535), reason: '$what: line ${row.line}');
    expect(_protocols, contains(row.protocol), reason: '$what: line ${row.line}');
    expect(row.displays, inInclusiveRange(1, 4), reason: '$what: line ${row.line}');
    if (row.problem == null) {
      expect(row.host, isNotEmpty, reason: '$what: line ${row.line} has no problem and no host');
      expect(row.host.startsWith('-'), isFalse, reason: '$what: line ${row.line}: an address that reads as an option');
      expect(RegExp(r'[\s/\\@]').hasMatch(row.host), isFalse, reason: '$what: line ${row.line}: "${row.host}"');
    }
  }
  final gateway = file.gateway;
  if (gateway != null) {
    expect(_unsafe.hasMatch(gateway), isFalse, reason: '$what: the gateway');
    expect(gateway.length, lessThanOrEqualTo(253), reason: '$what: the gateway');
    expect(gateway.startsWith('-'), isFalse, reason: '$what: the gateway');
  }
}

/// Reads [text] as every kind there is, each within [ms], throwing nothing.
void _readAll(String text, String what, {int ms = 6000}) {
  final readers = <String, CsvHostFile Function()>{
    'detected': () => readHostBytes(utf8.encode(text), rdp: true, name: 'Desk.rdp').file,
    'mRemoteNG': () => readMRemoteNgHosts(text, rdp: true),
    'Remmina': () => readRemminaHosts(text, rdp: true),
    'rdp': () => readRdpFileHosts(text, rdp: true, fileName: 'Desk.rdp'),
    'MobaXterm': () => readMobaXtermHosts(text, rdp: true),
    'CSV': () => readCsvHosts(text, rdp: true),
  };
  for (final MapEntry(key: kind, value: read) in readers.entries) {
    final watch = Stopwatch()..start();
    final CsvHostFile file;
    try {
      file = read();
    } catch (e) {
      fail('$what, read as $kind, threw ${e.runtimeType}');
    }
    expect(watch.elapsedMilliseconds, lessThan(ms), reason: '$what, read as $kind, took too long');
    _holds(file, '$what, read as $kind');
  }
}

const _mrngHead = '<?xml version="1.0" encoding="utf-8"?>\n';

String _mrng(String inside, {String doctype = ''}) => '$_mrngHead$doctype'
    '<mrng:Connections xmlns:mrng="http://mremoteng.org" Name="Connections" ConfVersion="2.6">$inside</mrng:Connections>';

String _node(String host, {String protocol = 'SSH2', String name = 'n', String more = ''}) =>
    '<Node Name="$name" Type="Connection" Hostname="$host" Protocol="$protocol" Port="22" Username="alex" $more/>';

const _remmina = '[remmina]\nname=Desk\ngroup=Office/Desks\nserver=10.50.0.5:5901\nprotocol=VNC\n'
    'username=alex\ndomain=CORP\npassword=bWFkZS11cC1jaXBoZXI=\n';

const _rdp = 'screen mode id:i:2\r\nuse multimon:i:1\r\nselectedmonitors:s:0,1\r\n'
    'full address:s:pc.example.test:3390\r\nusername:s:alex\r\ndomain:s:CORP\r\n'
    'redirectclipboard:i:0\r\ngatewayhostname:s:gw.example.test\r\ngatewayusagemethod:i:1\r\n'
    'enablecredsspsupport:i:0\r\nremoteapplicationmode:i:1\r\n'
    'password 51:b:01000000D08C9DDF0115D1118C7A00C04FC297EB\r\n';

const _moba = '[Bookmarks]\nSubRep=\nImgNum=42\nbuild=#109#0%build.example.test%22%alex%%-1%-1\n'
    '[Bookmarks_1]\nSubRep=Office\\Desks\nImgNum=41\nReception VNC=#128#5%10.50.0.5%5901%-1%0%%%0%\n'
    'Office PC=#91#4%pc.example.test%3390%CORP\\alex%0%-1\n';

const _csv = 'name,host,port,user,group,protocol\nDesk,10.50.0.5,5901,alex,Office,vnc\n'
    'PC,pc.example.test,3390,CORP\\alex,Office,rdp\nBuild,build.example.test,22,alex,,ssh\n';

void main() {
  group('mRemoteNG: XML from elsewhere', () {
    test('entities a file declares are never expanded: a few lines cannot become gigabytes', () {
      final lol = StringBuffer('<!DOCTYPE lolz [<!ENTITY lol0 "lollollollollollollollollollol">');
      for (var i = 1; i < 12; i++) {
        lol.write('<!ENTITY lol$i "${'&lol${i - 1};' * 10}">');
      }
      lol.write(']>\n');
      final text = _mrng(_node('&lol11;', name: '&lol11;') + _node('build.example.test', name: '&lol11;'),
          doctype: '$lol');
      final watch = Stopwatch()..start();
      final file = readMRemoteNgHosts(text, rdp: true);
      expect(watch.elapsedMilliseconds, lessThan(3000));
      _holds(file, 'entity expansion');
      for (final row in file.rows) {
        expect(row.name.length, lessThan(300));
        expect(row.name.contains('lollol'), isFalse, reason: 'the entity was not put in');
        expect(row.host.contains('lollol'), isFalse);
      }
      // The host whose address is an entity is no address, not ten billion letters.
      expect(file.rows.where((r) => r.problem == null).map((r) => r.host), ['build.example.test']);
    });

    test('an entity that names a file or an address outside is never fetched or read', () {
      const doctype = '<!DOCTYPE c [<!ENTITY xxe SYSTEM "file:///C:/Windows/win.ini">'
          '<!ENTITY net SYSTEM "http://192.0.2.10/secret"><!ENTITY % pe SYSTEM "http://192.0.2.10/x.dtd">%pe;]>\n';
      final file = readMRemoteNgHosts(_mrng(_node('&xxe;', name: 'a&xxe;b') + _node('&net;'), doctype: doctype), rdp: true);
      _holds(file, 'external entities');
      for (final row in file.rows) {
        expect(row.problem, isNotNull, reason: 'what an entity stands for is no address');
        expect(row.name.toLowerCase().contains('fonts'), isFalse);
        expect(row.name.contains('['), isFalse, reason: 'nothing of a file is in the name');
      }
    });

    test('folders nested as deep as the largest file allows are answered, not followed to the bottom', () {
      const open = '<Node Name="f" Type="Container">';
      const close = '</Node>';
      final depth = (kCsvMaxBytes - 600) ~/ (open.length + close.length);
      final text = _mrng('${open * depth}${_node('deep.example.test')}${close * depth}${_node('top.example.test')}');
      expect(text.length, lessThanOrEqualTo(kCsvMaxBytes));
      final watch = Stopwatch()..start();
      final CsvHostFile file;
      try {
        file = readMRemoteNgHosts(text, rdp: true);
      } catch (e) {
        fail('threw ${e.runtimeType}');
      }
      expect(watch.elapsedMilliseconds, lessThan(20000));
      _holds(file, 'deep nesting');
      // Either the file is refused whole, or what is read is the host at the top.
      expect(file.rows.map((r) => r.host), anyOf(isEmpty, ['top.example.test']));
    });

    test('the largest file of nothing but connections: the most hosts an import takes, and no more', () {
      final one = _node('h.example.test', more: 'Password="bWFkZS11cA==" ');
      final count = (kCsvMaxBytes - 400) ~/ one.length;
      final text = _mrng(one * count);
      final watch = Stopwatch()..start();
      final file = readMRemoteNgHosts(text, rdp: true);
      expect(watch.elapsedMilliseconds, lessThan(20000));
      expect(file.rows, hasLength(kCsvMaxHosts));
      expect(file.cut, isTrue);
      _holds(file, 'many nodes');
    });

    test('one value as long as the file, a name that hides text, a port that is none, an address that is an option',
        () {
      final long = 'a' * (kCsvMaxBytes - 600);
      _readAll(_mrng(_node(long, name: long)), 'a five megabyte address');
      final rlo = _c(0x202e);
      final file = readMRemoteNgHosts(
          _mrng(_node('build.example.test', name: 'safe${rlo}gpj.exe&#x202E;&#10;&#0;x') +
              _node('-oProxyCommand=calc', name: 'option') +
              _node('ok.example.test', name: 'port', more: 'InheritPort="false" ').replaceFirst('Port="22"', 'Port="22; rm"') +
              _node('ok2.example.test', name: 'big').replaceFirst('Port="22"', 'Port="99999999999999999999"') +
              _node('ok3.example.test', name: 'neg').replaceFirst('Port="22"', 'Port="-5"')),
          rdp: true);
      _holds(file, 'hostile values');
      final by = {for (final r in file.rows) r.name: r};
      expect(file.rows.first.name.contains(rlo), isFalse);
      expect(by['option']!.problem, CsvRowProblem.badHost);
      // A port that is written and is no port is said, not quietly made 22.
      expect(by['port']!.problem, CsvRowProblem.badPort);
      expect(by['big']!.problem, CsvRowProblem.badPort);
      expect(by['neg']!.problem, CsvRowProblem.badPort);
    });

    test('no password of the file is in anything read, wherever the file puts one', () {
      const secret = 'c2VjcmV0LW1hZGUtdXA';
      final text = _mrng('<Node Name="f" Type="Container" Password="$secret" InheritPassword="true">'
          '${_node('a.example.test', more: 'Password="$secret" RDGatewayPassword="$secret" VNCProxyPassword="$secret" ')}'
          '</Node>');
      final file = readMRemoteNgHosts(text, rdp: true);
      expect(file.rows, hasLength(1));
      final r = file.rows.single;
      expect('${r.name}|${r.host}|${r.user}|${r.group}|${r.note}|${r.key}|${file.ignored}|${file.gateway}'.contains(secret),
          isFalse);
    });
  });

  group('a Remmina file from elsewhere', () {
    test('lines without end, one line as long as the file, a file of line ends: each answered in time', () {
      _readAll('[remmina]\n${'server=10.50.0.5\n' * (kCsvMaxBytes ~/ 17 - 4)}', 'a file of server lines');
      _readAll('[remmina]\nprotocol=VNC\nserver=${'a' * (kCsvMaxBytes - 60)}\n', 'one long server');
      _readAll('[remmina]\nprotocol=VNC\nname=${'=' * (kCsvMaxBytes - 60)}\n', 'one long name');
      _readAll('\n' * (kCsvMaxBytes - 1), 'a file of line ends');
      _readAll('\r' * (kCsvMaxBytes - 1), 'a file of carriage returns');
      _readAll('[' * (kCsvMaxBytes - 1), 'a file of brackets');
    });

    test('an address that is an option, hides text, or carries an account is refused; a port that is none is said', () {
      for (final server in ['-oProxyCommand=calc', 'pc${_c(0x202e)}moc.elpmaxe', 'alex@pc.example.test', 'pc example', 'a/b']) {
        final file = readRemminaHosts('[remmina]\nprotocol=VNC\nserver=$server\n', rdp: true);
        _holds(file, server);
        expect(file.rows.single.problem, isNotNull, reason: server);
      }
      expect(readRemminaHosts('[remmina]\nprotocol=VNC\nserver=pc.example.test:abc\n').rows.single.problem,
          CsvRowProblem.badPort);
      expect(readRemminaHosts('[remmina]\nprotocol=VNC\nserver=pc.example.test:70000\n').rows.single.problem,
          CsvRowProblem.badPort);
    });
  });

  group('a Remote Desktop file from elsewhere', () {
    test('as Windows saves it, UTF-16 with its mark: read; UTF-16 without the mark: not read as anything', () {
      List<int> utf16(String text, {required bool mark, required bool little}) => [
            if (mark) ...(little ? [0xff, 0xfe] : [0xfe, 0xff]),
            for (final u in text.codeUnits) ...(little ? [u & 0xff, u >> 8] : [u >> 8, u & 0xff]),
          ];
      for (final little in [true, false]) {
        final marked = utf16(_rdp, mark: true, little: little);
        expect(importKindOf(marked), ImportKind.rdpFile);
        final read = readHostBytes(marked, rdp: true, name: 'Office PC.rdp');
        expect(read.kind, HostFileKind.rdpfile);
        expect((read.file.rows.single.host, read.file.rows.single.port), ('pc.example.test', 3390));
        _holds(read.file, 'UTF-16 with its mark');

        final bare = utf16(_rdp, mark: false, little: little);
        expect(importKindOf(bare), ImportKind.unknown, reason: 'no mark: not text, so nothing reads it');
        final other = readHostBytes(bare, rdp: true, name: 'Office PC.rdp');
        expect(other.file.rows.where((r) => r.problem == null), isEmpty);
        _holds(other.file, 'UTF-16 without its mark');
      }
    });

    test('the saved password is never kept, under any of its names, and is in nothing read', () {
      const blob = '01000000D08C9DDF0115D1118C7A00C04FC297EB';
      for (final line in ['password 51:b:$blob', 'Password 51:B:$blob', 'password:s:$blob', '  password 51:b:$blob']) {
        final text = 'full address:s:pc.example.test\r\n$line\r\nusername:s:alex\r\n';
        final plain = readRdpFile(text);
        expect(plain.hadPassword, isTrue, reason: line);
        final file = readRdpFileHosts(text, rdp: true, fileName: 'x.rdp');
        expect(file.notes, contains(HostFileNote.rdpPassword), reason: line);
        final r = file.rows.single;
        expect('${r.name}|${r.host}|${r.user}|${r.group}|${r.note}|${r.key}|${file.ignored}|${file.gateway}'.contains('D08C9DDF'),
            isFalse);
      }
      // A password given as the account's name is the file's own doing, cut like any name.
      final odd = readRdpFileHosts('full address:s:pc.example.test\r\nusername:s:${'p' * 5000}\r\n', rdp: true);
      expect(odd.rows.single.user!.length, lessThanOrEqualTo(255));
    });

    test('a program to start, NLA turned off and a gateway are said, never followed; a gateway that is no address is '
        'not kept', () {
      final file = readRdpFileHosts(_rdp, rdp: true, fileName: 'Office PC.rdp');
      expect(file.notes,
          [HostFileNote.rdpPassword, HostFileNote.rdpProgram, HostFileNote.rdpNlaOff, HostFileNote.rdpGateway]);
      for (final gateway in ['-oProxyCommand=calc', 'gw${_c(0x202e)}moc', 'alex@gw.example.test', 'gw example', '']) {
        final bad = readRdpFileHosts(
            'full address:s:pc.example.test\r\ngatewayusagemethod:i:1\r\ngatewayhostname:s:$gateway\r\n',
            rdp: true);
        _holds(bad, 'gateway "$gateway"');
        expect(bad.gateway, isNull, reason: gateway);
        expect(bad.notes, isNot(contains(HostFileNote.rdpGateway)), reason: gateway);
      }
      for (final program in ['alternate shell:s:cmd.exe /c calc', 'remoteapplicationprogram:s:||calc', 'remoteapplicationmode:i:1']) {
        final f = readRdpFileHosts('full address:s:pc.example.test\r\n$program\r\n', rdp: true);
        expect(f.notes, [HostFileNote.rdpProgram], reason: program);
        final r = f.rows.single;
        expect('${r.name}|${r.user}|${r.group}|${r.note}'.contains('calc'), isFalse);
      }
    });

    test('an address that is an option, hides text or carries an account is no host; the first word of a file counts', () {
      for (final address in ['-oProxyCommand=calc', 'pc${_c(0x202e)}moc.elpmaxe', 'alex@pc.example.test', 'a b', 'a/b', r'a\b', ':3389', 'pc:0', 'pc:70000', 'pc:x']) {
        final file = readRdpFileHosts('full address:s:$address\r\n', rdp: true);
        _holds(file, address);
        expect(file.rows.single.problem, isNotNull, reason: address);
      }
      // Said twice: the first is the file's word, as Windows reads it.
      final twice = readRdpFileHosts('full address:s:first.example.test\r\nfull address:s:second.example.test\r\n', rdp: true);
      expect(twice.rows.single.host, 'first.example.test');
    });

    test('lines without end, one line as long as the file, values as long as the file: each answered in time', () {
      _readAll('full address:s:pc.example.test\r\n${'x:s:y\r\n' * (kCsvMaxBytes ~/ 7 - 8)}', 'a file of lines');
      _readAll('full address:s:${'a' * (kCsvMaxBytes - 40)}', 'one long address');
      _readAll('full address:s:pc.example.test\r\nusername:s:${'a' * (kCsvMaxBytes - 80)}', 'one long account');
      _readAll('full address:s:pc.example.test\r\nselectedmonitors:s:${'1,' * ((kCsvMaxBytes - 80) ~/ 2)}', 'monitors');
      _readAll('${' ' * (kCsvMaxBytes - 40)}full address:s:pc.example.test', 'spaces before the address');
      _readAll('full address:s:pc.example.test\r\n${'${'a' * 60}:' * ((kCsvMaxBytes - 80) ~/ 61)}', 'a line of colons');
      // Every line as long as a line is read, of what a setting's name may hold and never its colon.
      for (final filler in [' ', 'a', '-', '\t']) {
        final watch = Stopwatch()..start();
        final file = readRdpFileHosts(
            'full address:s:pc.example.test\r\n${'${filler * 4095}\n' * (kCsvMaxBytes ~/ 4096 - 1)}',
            rdp: true);
        expect(watch.elapsedMilliseconds, lessThan(4000), reason: 'lines of "$filler"');
        expect(file.rows.single.host, 'pc.example.test');
      }
    });
  });

  group('MobaXterm sessions and CSV lines with remote screens, from elsewhere', () {
    test('a VNC or RDP session with an address that is an option or hides text is no host', () {
      for (final address in ['-oProxyCommand=calc', 'pc${_c(0x202e)}moc', 'a b']) {
        final moba = readMobaXtermHosts('[Bookmarks]\nSubRep=\nImgNum=42\nV=#128#5%$address%5901%-1%0%\nR=#91#4%$address%3389%alex%0%-1\n', rdp: true);
        _holds(moba, 'MobaXterm $address');
        expect(moba.rows.where((r) => r.problem == null), isEmpty, reason: address);
        final csv = readCsvHosts('host,protocol\n"$address",vnc\n"$address",rdp\n', rdp: true);
        _holds(csv, 'CSV $address');
        expect(csv.rows.where((r) => r.problem == null), isEmpty, reason: address);
      }
    });

    test('files made to be slow: sessions and lines without end, each answered in time', () {
      _readAll('[Bookmarks]\nSubRep=\nImgNum=42\n${'V=#128#5%10.50.0.5%5901%-1%0%\n' * (kCsvMaxBytes ~/ 31 - 4)}', 'VNC sessions');
      _readAll('[Bookmarks]\nSubRep=\nImgNum=42\nV=#128#5${'%' * (kCsvMaxBytes - 80)}', 'a session of percent signs');
      _readAll('host,protocol\n${'10.50.0.5,vnc\n' * (kCsvMaxBytes ~/ 14 - 4)}', 'vnc lines');
    });
  });

  group('good files changed at random', () {
    // What an attacker reaches for, put in at random places.
    final pieces = [
      _c(0), _c(0x1b), _c(0x7f), _c(0x85), _c(0x200b), _c(0x202e), _c(0x2066), _c(0xfeff), //
      '\n', '\r', '\r\n', '\t', ' ', '=', ':', ';', ',', '%', '#', '"', "'", '<', '>', '/', '\\', '&', '[', ']', '@', '-',
      '&lol;', '&#x202E;', '&#0;', ']]>', '<!--', '-->', '<![CDATA[', '<!DOCTYPE x [<!ENTITY a "b">]>', '<Node', '</Node>',
      '[remmina]', '[Bookmarks]', 'full address:s:', 'password 51:b:', 'server=', 'protocol=', 'Port="', 'Hostname="',
      '-oProxyCommand=x', '127.0.0.1', '::1', '[::1]:5900', '99999999999999999999', '-1', '0', '65536',
      'a' * 300, ' ' * 300, '%' * 40, '#' * 40, ':' * 40,
    ];

    String changed(String good, Random random) {
      var text = good;
      final changes = 1 + random.nextInt(6);
      for (var i = 0; i < changes; i++) {
        final at = text.isEmpty ? 0 : random.nextInt(text.length + 1);
        switch (random.nextInt(6)) {
          case 0:
            text = text.substring(0, at) + pieces[random.nextInt(pieces.length)] + text.substring(at);
          case 1:
            final end = min(text.length, at + random.nextInt(24));
            text = text.substring(0, at) + text.substring(end);
          case 2:
            final end = min(text.length, at + random.nextInt(60));
            text = text.substring(0, end) + text.substring(at, end) + text.substring(end);
          case 3:
            text = text.substring(0, at);
          case 4:
            if (at < text.length) {
              text = text.substring(0, at) + _c(random.nextInt(0x250)) + text.substring(at + 1);
            }
          default:
            final other = [_remmina, _rdp, _moba, _csv][random.nextInt(4)];
            text = text.substring(0, at) + other.substring(random.nextInt(other.length)) + text.substring(at);
        }
      }
      return text;
    }

    final goods = {
      'mRemoteNG': _mrng('<Node Name="Office" Type="Container" Protocol="VNC" Port="5901" Username="alex" Domain="CORP">'
          '${_node('10.50.0.5', protocol: 'VNC', name: 'Reception', more: 'InheritPort="true" ')}'
          '${_node('pc.example.test', protocol: 'RDP', name: 'Desk 2', more: 'Domain="CORP" Password="bWFkZS11cA==" ')}'
          '</Node>${_node('build.example.test')}'),
      'Remmina': _remmina,
      'rdp': _rdp,
      'MobaXterm': _moba,
      'CSV': _csv,
    };

    for (final MapEntry(key: kind, value: good) in goods.entries) {
      test('$kind: 1500 changed files, every one answered within the rules', () {
        // The good file reads as itself first: the rules are not vacuous.
        final first = readHostBytes(utf8.encode(good), rdp: true, name: 'Desk.rdp').file;
        expect(first.rows.where((r) => r.problem == null), isNotEmpty, reason: 'the good $kind file has hosts');
        _holds(first, 'the good $kind file');
        final random = Random(0x40A + kind.length);
        for (var i = 0; i < 1500; i++) {
          final text = changed(good, random);
          _readAll(text, '$kind, change $i', ms: 3000);
          // And whatever it is detected as, the detector answers too.
          try {
            importKindOf(utf8.encode(text));
            hostFileKindOf(text);
          } catch (e) {
            fail('$kind, change $i: the detector threw ${e.runtimeType}');
          }
        }
      });
    }
  });
}
