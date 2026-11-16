// Importing hosts: an address that carries a mark which hides or reorders
// the text beside it (a zero-width character, a right-to-left override) is
// no address. Left in, the host would read as another address wherever it is
// shown: in the list, and in the question about its server's key.
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';

void main() {
  // Built from their numbers: no such character is written in this file.
  final marks = {
    'a zero-width space': String.fromCharCode(0x200b),
    'a zero-width joiner': String.fromCharCode(0x200d),
    'a right-to-left mark': String.fromCharCode(0x200f),
    'a right-to-left override': String.fromCharCode(0x202e),
    'a word joiner': String.fromCharCode(0x2060),
    'a right-to-left isolate': String.fromCharCode(0x2067),
    'a byte order mark': String.fromCharCode(0xfeff),
  };

  test('a CSV host whose address carries one is a problem, not a host', () {
    for (final MapEntry(key: what, value: mark) in marks.entries) {
      // Reads as "safe.example.test" then something else, or hides a letter.
      final file = readCsvHosts('name,host\nweb,safe${mark}moc.elpmaxe.live\n');
      final row = file.rows.single;
      expect(row.problem, CsvRowProblem.badHost, reason: what);
      expect(row.host, isNot(contains(mark)), reason: '$what is not kept even to show the line');
    }
    // An address without one is a host as before, also one in another alphabet.
    expect(readCsvHosts('name,host\nweb,web-01.example.test\n').rows.single.problem, isNull);
    expect(readCsvHosts('name,host\nweb,b${String.fromCharCode(0xfc)}cher.example.test\n').rows.single.problem, isNull);
  });

  test('so is one in a pasted list, and one built by another app\'s reader', () {
    final rlo = marks['a right-to-left override']!;
    final pasted = readPastedHosts('safe${rlo}moc.elpmaxe.live\nweb-01.example.test\n');
    expect(pasted.rows.where((r) => r.problem == null).map((r) => r.host), ['web-01.example.test']);
    expect(pasted.rows.any((r) => r.host.contains(rlo)), isFalse);
    final row = importedHostRow(line: 1, name: 'pc', host: 'pc$rlo.example.test');
    expect(row.problem, CsvRowProblem.badHost);
    expect(row.host, isNot(contains(rlo)));
  });
}
