import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';

/// Hosts from a CSV file (3.0): read as a spreadsheet writes it, columns
/// known by their names, every field cleaned and bounded, and a line with
/// something wrong said with why.
void main() {
  group('the lines of a file', () {
    test('fields split by the delimiter; quotes hold delimiters, line ends and quotes; empty lines left out', () {
      expect(
        parseCsvLines('a,b,c\r\n"one, two","say ""hi""","line\nbreak"\n\n,,\nlast,,', ','),
        [
          ['a', 'b', 'c'],
          ['one, two', 'say "hi"', 'line\nbreak'],
          ['last', '', ''],
        ],
      );
      expect(parseCsvLines('x;y\n1;2', ';'), [
        ['x', 'y'],
        ['1', '2'],
      ]);
      expect(parseCsvLines('', ','), isEmpty);
      expect(parseCsvLines('"open quote', ','), [
        ['open quote'],
      ]);
    });

    test('the delimiter is the one that splits the first line most, outside quotes; a comma otherwise', () {
      expect(csvDelimiterOf('name;host;port'), ';');
      expect(csvDelimiterOf('name\thost\tport'), '\t');
      expect(csvDelimiterOf('name,host,port'), ',');
      expect(csvDelimiterOf('"a;b;c",host'), ',');
      expect(csvDelimiterOf('host'), ',');
    });
  });

  group('a host file', () {
    test('columns by their names in any order and case, with what is left out said', () {
      final file = readCsvHosts('\uFEFFIP Address,Display Name,SSH Port,User Name,Folder,Tags,Key,Protocol,Notes,Owner\n'
          'web-01.example.com,Web 1,2222,deploy,Production,web; eu,Deploy key,ssh,Front end,Alex\n');
      expect(file.problem, isNull);
      expect(file.ignored, ['Owner']);
      expect(file.columns.keys.toSet(), CsvHostColumn.values.toSet());
      final row = file.rows.single;
      expect((row.line, row.name, row.host, row.port, row.user, row.group), (2, 'Web 1', 'web-01.example.com', 2222, 'deploy', 'Production'));
      expect(row.tags, ['web', 'eu']);
      expect((row.key, row.protocol, row.note, row.problem), ('Deploy key', 'ssh', 'Front end', null));

      final quoted = readCsvHosts('\uFEFF"host","name"\na.example.com,A\n');
      expect(quoted.problem, isNull, reason: "a spreadsheet's mark before a quoted first column");
      expect(quoted.rows.single.name, 'A');
      final twice = readCsvHosts('host,Hostname\na.example.com,b.example.com\n');
      expect(twice.rows.single.host, 'a.example.com', reason: 'the first column of a kind is read');
      expect(twice.ignored, ['Hostname']);
    });

    test('a host field may carry its user and port; a separate port wins; the name is the host where none is given',
        () {
      final file = readCsvHosts('host,port\n'
          'deploy@web-01.example.com:2222,\n'
          '[2001:db8::1]:2200,\n'
          '2001:db8::5,\n'
          'db.example.com:2222,22\n');
      expect([for (final r in file.rows) (r.host, r.port, r.user)], [
        ('web-01.example.com', 2222, 'deploy'),
        ('2001:db8::1', 2200, null),
        ('2001:db8::5', 22, null),
        ('db.example.com', 22, null),
      ]);
      expect(file.rows.first.name, 'web-01.example.com');
      expect([for (final r in file.rows) r.problem], everyElement(isNull));
    });

    test('a line with no host, an address that is none, a bad port or an unknown protocol says why', () {
      final file = readCsvHosts('name,host,port,protocol\n'
          'empty,,22,ssh\n'
          'spaces,web 01,22,ssh\n'
          'slash,web/01,22,ssh\n'
          'port,web-02,70000,ssh\n'
          'word port,web-03,ssh,ssh\n'
          'in host,web-04:0,,ssh\n'
          'protocol,web-05,22,rdp\n'
          'fine,web-06,,TELNET\n');
      expect([for (final r in file.rows) r.problem], [
        CsvRowProblem.noHost,
        CsvRowProblem.badHost,
        CsvRowProblem.badHost,
        CsvRowProblem.badPort,
        CsvRowProblem.badPort,
        CsvRowProblem.badPort,
        CsvRowProblem.badProtocol,
        null,
      ]);
      expect(file.rows.last.protocol, 'telnet');
      expect(file.rows.last.port, 22);
    });

    test('an address with a dash in front is none: it reads as an option wherever it is passed later', () {
      final file = readCsvHosts('name,host\nevil,-oProxyCommand=calc\nspaced, -oProxyCommand=calc\nfine,web-06\n');
      expect([for (final r in file.rows) r.problem], [CsvRowProblem.badHost, CsvRowProblem.badHost, null]);
    });

    test('fields are cleaned and bounded; tags normalised, twelve at most, each once', () {
      final file = readCsvHosts('host,name,tags,note\n'
          'web-01,"Web\u202e 1\u0007 ${'x' * 400}","${List.generate(20, (i) => 'T$i').join(';')};t0","line one\nline two"\n');
      final row = file.rows.single;
      expect(row.name.startsWith('Web 1 x'), isTrue);
      expect(row.name.length, 255);
      expect(row.tags, [for (var i = 0; i < 12; i++) 't$i']);
      expect(row.note, 'line one line two');
      expect(readCsvHosts('host,tags\nweb-02,web;WEB;eu\n').rows.single.tags, ['web', 'eu'], reason: 'each once');
    });

    test('a file with nothing in it, with no host column, or too large is said as that', () {
      expect(readCsvHosts('').problem, CsvFileProblem.empty);
      expect(readCsvHosts('\n\n').problem, CsvFileProblem.empty);
      final noHost = readCsvHosts('name,port\nweb,22\n');
      expect(noHost.problem, CsvFileProblem.noHostColumn);
      expect(noHost.ignored, isEmpty);
      expect(noHost.columns.keys.toSet(), {CsvHostColumn.name, CsvHostColumn.port});
      expect(readCsvHosts('host\n${'a' * kCsvMaxBytes}').problem, CsvFileProblem.tooLarge);
    });

    test('at most so many hosts are read, and it says so', () {
      final file = readCsvHosts('host\n${List.generate(kCsvMaxHosts + 3, (i) => 'web-$i.example.com').join('\n')}');
      expect(file.rows, hasLength(kCsvMaxHosts));
      expect(file.cut, isTrue);
      expect(readCsvHosts('host\nweb-1\n').cut, isFalse);
    });

    test('a semicolon file, as a spreadsheet in many languages writes it', () {
      final file = readCsvHosts('Name;Host;Port\r\n"Web; one";web-01.example.com;22\r\n');
      expect((file.rows.single.name, file.rows.single.host), ('Web; one', 'web-01.example.com'));
    });
  });

  test('what an import does with each line: new, here already (address in any case, and port), named twice, or a '
      'problem', () {
    final file = readCsvHosts('host,port\n'
        'web-01.example.com,22\n'
        'WEB-01.example.com,2222\n'
        'Web-02.Example.com,22\n'
        'web-01.example.com,22\n'
        ',22\n');
    final seen = <String>{};
    final existing = {csvAddressKey('web-02.example.com', 22)};
    expect([for (final r in file.rows) csvRowStatus(r, existing, seen)], [
      CsvRowStatus.fresh,
      CsvRowStatus.fresh,
      CsvRowStatus.here,
      CsvRowStatus.twice,
      CsvRowStatus.problem,
    ]);
  });

  test("a file's bytes: UTF-16 after its byte order mark, either way round; else UTF-8; else Latin-1, as a "
      'spreadsheet writes in its own code page', () {
    const text = 'name,host\nCafé Ü 🍊,web-01.example.com\n';
    final units = text.codeUnits;
    final little = [0xFF, 0xFE, for (final u in units) ...[u & 0xFF, u >> 8]];
    final big = [0xFE, 0xFF, for (final u in units) ...[u >> 8, u & 0xFF]];
    expect(decodeCsvBytes(little), text);
    expect(decodeCsvBytes(big), text);
    expect(decodeCsvBytes([...little, 0x41]), text, reason: 'an odd byte at the end is no unit');
    expect(decodeCsvBytes(utf8.encode(text)), text);
    expect(decodeCsvBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]), text, reason: "UTF-8's own mark taken off");
    expect(readCsvHosts(decodeCsvBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(text)])).rows.single.name, 'Café Ü 🍊');
    expect(decodeCsvBytes(latin1.encode('name,host\nCafé,web-01.example.com\n')),
        'name,host\nCafé,web-01.example.com\n');
    expect(decodeCsvBytes(const []), '');
    expect(decodeCsvBytes(const [0xFF]), '\u00FF', reason: 'one byte is no byte order mark');
  });
}
