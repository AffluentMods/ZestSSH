import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/changelog/changelog_data.dart' show kChangelog;
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion;
import 'package:zestssh/features/orchards/record/orchard_record.dart' show RecordTypes;

// The version the app names when new kinds of team record entry need every
// member on it: the release that brings them. It is one
// constant, so the release sets it in one place; this fails if
// pubspec.yaml moves past it before that release has shipped.

List<int> _parts(String v) => [for (final p in v.split('.')) int.parse(p)];

/// The kinds of team record entry each release brought, newest last. A kind
/// added to [RecordTypes.all] fails the test below until it is listed here
/// under the release that brings it, and that release becomes
/// kNewRecordKindsVersion: the first test alone could not fail once 3.3.0
/// had shipped.
const _kindsBy = <String, Set<String>>{
  '3.0.0': {
    RecordTypes.create, RecordTypes.crateAdd, RecordTypes.crateSet, RecordTypes.roleSet, RecordTypes.roleDrop,
    RecordTypes.memberAdd, RecordTypes.memberSet, RecordTypes.memberKeys, RecordTypes.memberSuspend,
    RecordTypes.memberResume, RecordTypes.memberRemove, RecordTypes.keyRotate, RecordTypes.rulesSet,
    RecordTypes.recoverySet, RecordTypes.memberRecover, RecordTypes.caSet, RecordTypes.trackingSet,
    RecordTypes.accessGrant, RecordTypes.deviceTrust, RecordTypes.deviceRevoke, RecordTypes.exportSet,
    RecordTypes.sessionUnwatched,
  },
  '3.3.0': {RecordTypes.adminSet, RecordTypes.memberLimit, RecordTypes.teamDelete, RecordTypes.teamRestore},
};

void main() {
  test('the version named for new kinds of team record entry is this release or a later one', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true).firstMatch(pubspec)!;
    final app = _parts(m.group(1)!);
    final named = _parts(kNewRecordKindsVersion);
    var cmp = 0;
    for (var i = 0; i < 3 && cmp == 0; i++) {
      cmp = named[i].compareTo(app[i]);
    }
    // Before the release that brings them, the constant names that release
    // (this one or a later one). Once it has shipped (3.3.0, 5 November
    // 2026), it stays the release that brought them, which What's new lists.
    final shipped = kChangelog.any((e) => e.version == kNewRecordKindsVersion);
    expect(cmp >= 0 || shipped, isTrue,
        reason: 'pubspec.yaml is at ${m.group(1)}: kNewRecordKindsVersion ($kNewRecordKindsVersion) '
            'is the release that brings the new kinds, so it is set to that release');
  });

  test('every kind of record entry is listed under the release that brought it, the newest named by the constant', () {
    final listed = {for (final kinds in _kindsBy.values) ...kinds};
    expect(RecordTypes.all.difference(listed), isEmpty,
        reason: 'a kind of record entry no release brought: list it under the release that brings it, '
            'and set kNewRecordKindsVersion to that release');
    expect(listed.difference(RecordTypes.all), isEmpty, reason: 'listed kinds that are gone');
    expect(_kindsBy.keys.last, kNewRecordKindsVersion,
        reason: 'the newest release that brought kinds is the one the app names');
    expect(RecordTypes.newKinds, _kindsBy[kNewRecordKindsVersion],
        reason: 'the kinds an older app cannot read are the ones that release brought');
  });

  test('no string names that version outright: each takes it from the constant', () {
    for (final f in Directory('lib/l10n').listSync().whereType<File>().where((f) => f.path.endsWith('.arb'))) {
      final text = f.readAsStringSync();
      expect(text.contains(kNewRecordKindsVersion), isFalse,
          reason: '${f.path} names $kNewRecordKindsVersion; use a {version} placeholder');
    }
  });
}
