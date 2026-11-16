import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/rust_advisories.dart' show accepted, acceptedPath;

/// The advisories for Rust crates that were looked at and taken (4.0, RDP):
/// packages/zest_native/rust/advisories-accepted.txt, which tool/rust_advisories.dart holds every
/// published advisory against (that tool asks OSV, so it is run by hand; here, without the
/// network, the list itself is held to its form and to Cargo.lock).
void main() {
  final lock = File('packages/zest_native/rust/Cargo.lock').readAsStringSync();
  final locked = {for (final m in RegExp(r'^name = "([^"]+)"', multiLine: true).allMatches(lock)) m.group(1)!};

  test('each accepted advisory names a crate that is still locked, and says why at some length', () {
    final list = accepted();
    expect(list, isNotEmpty);
    for (final MapEntry(key: id, value: entry) in list.entries) {
      expect(id, matches(RegExp(r'^(RUSTSEC|GHSA|CVE)-')), reason: id);
      expect(locked, contains(entry.crate), reason: '$id: ${entry.crate} is gone from Cargo.lock, so the entry goes');
      expect(entry.why.length, greaterThan(80), reason: '$id: a reason, not a word');
      expect(entry.why, matches(RegExp(r'Looked at \d+ \w+ 20\d\d')), reason: '$id: when it was looked at');
    }
  });

  test('a line that is not "ID | crate | why" is refused', () {
    final file = File('${Directory.systemTemp.createTempSync('adv').path}/a.txt')..writeAsStringSync('RUSTSEC-1 | rsa\n');
    expect(() => accepted(file.path), throwsFormatException);
    file.parent.deleteSync(recursive: true);
    expect(File(acceptedPath).existsSync(), isTrue);
  });
}
