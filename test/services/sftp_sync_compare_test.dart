import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sftp_sync_compare.dart';

void main() {
  const cmp = SyncCompare();
  final t = DateTime.fromMillisecondsSinceEpoch(1_700_000_000 * 1000);

  group('SyncCompare.isIdentical', () {
    test('same size and same mtime is identical', () {
      expect(
        cmp.isIdentical(
            localSize: 100, localMtime: t, remoteSize: 100, remoteMtime: t),
        isTrue,
      );
    });

    test('different size is never identical, even with equal mtime', () {
      expect(
        cmp.isIdentical(
            localSize: 100, localMtime: t, remoteSize: 101, remoteMtime: t),
        isFalse,
      );
    });

    test('same size but mtime beyond tolerance is not identical', () {
      final later = t.add(const Duration(seconds: 5));
      expect(
        cmp.isIdentical(
            localSize: 100, localMtime: t, remoteSize: 100, remoteMtime: later),
        isFalse,
      );
    });

    test('sub-second / 1-second drift is tolerated by default', () {
      final almost = t.add(const Duration(milliseconds: 800));
      final oneSec = t.add(const Duration(seconds: 1));
      expect(
        cmp.isIdentical(
            localSize: 5,
            localMtime: t,
            remoteSize: 5,
            remoteMtime: almost),
        isTrue,
      );
      expect(
        cmp.isIdentical(
            localSize: 5, localMtime: t, remoteSize: 5, remoteMtime: oneSec),
        isTrue,
      );
    });

    test('zero tolerance rejects any whole-second difference', () {
      const strict = SyncCompare(mtimeToleranceSeconds: 0);
      final oneSec = t.add(const Duration(seconds: 1));
      expect(
        strict.isIdentical(
            localSize: 5, localMtime: t, remoteSize: 5, remoteMtime: oneSec),
        isFalse,
      );
    });

    test('comparison is timezone-independent (same instant, different zone)',
        () {
      final utc = DateTime.utc(2024, 1, 1, 12, 0, 0);
      final local = utc.toLocal();
      expect(
        cmp.isIdentical(
            localSize: 9,
            localMtime: local,
            remoteSize: 9,
            remoteMtime: utc),
        isTrue,
      );
    });
  });

  group('SyncCompare.classify', () {
    test('different size is different, whatever the mtimes', () {
      expect(
        cmp.classify(
            localSize: 1, localMtime: t, remoteSize: 2, remoteMtime: t),
        SyncVerdict.different,
      );
      expect(
        cmp.classify(
            localSize: 1, localMtime: null, remoteSize: 2, remoteMtime: null),
        SyncVerdict.different,
      );
    });

    test('same size and mtime is identical', () {
      expect(
        cmp.classify(
            localSize: 7, localMtime: t, remoteSize: 7, remoteMtime: t),
        SyncVerdict.identical,
      );
    });

    test('same size with a re-stamped or unknown mtime needs a hash', () {
      final later = t.add(const Duration(minutes: 3));
      expect(
        cmp.classify(
            localSize: 7, localMtime: t, remoteSize: 7, remoteMtime: later),
        SyncVerdict.sameSizeUnknownTime,
      );
      expect(
        cmp.classify(
            localSize: 7, localMtime: null, remoteSize: 7, remoteMtime: t),
        SyncVerdict.sameSizeUnknownTime,
      );
      expect(
        cmp.classify(
            localSize: 7, localMtime: t, remoteSize: 7, remoteMtime: null),
        SyncVerdict.sameSizeUnknownTime,
      );
    });
  });

  group('SyncCompare.isSameContent', () {
    final later = t.add(const Duration(hours: 1));
    const digest =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    /// Counts calls so a test can prove the hashers were (not) consulted.
    ({Future<String?> Function() fn, List<int> calls}) hasher(
        Future<String?> Function() body) {
      final calls = <int>[];
      return (
        fn: () {
          calls.add(1);
          return body();
        },
        calls: calls,
      );
    }

    test('same size and mtime: identical without hashing', () async {
      final l = hasher(() async => digest);
      final r = hasher(() async => digest);
      expect(
        await cmp.isSameContent(
            localSize: 10,
            localMtime: t,
            remoteSize: 10,
            remoteMtime: t,
            hashLocal: l.fn,
            hashRemote: r.fn),
        isTrue,
      );
      expect(l.calls, isEmpty);
      expect(r.calls, isEmpty);
    });

    test('different size: different without hashing', () async {
      final l = hasher(() async => digest);
      final r = hasher(() async => digest);
      expect(
        await cmp.isSameContent(
            localSize: 10,
            localMtime: t,
            remoteSize: 11,
            remoteMtime: t,
            hashLocal: l.fn,
            hashRemote: r.fn),
        isFalse,
      );
      expect(l.calls, isEmpty);
      expect(r.calls, isEmpty);
    });

    test('re-stamped file with matching digests is the same', () async {
      final l = hasher(() async => digest.toUpperCase());
      final r = hasher(() async => digest);
      expect(
        await cmp.isSameContent(
            localSize: 10,
            localMtime: t,
            remoteSize: 10,
            remoteMtime: later,
            hashLocal: l.fn,
            hashRemote: r.fn),
        isTrue,
      );
      expect(l.calls, hasLength(1));
      expect(r.calls, hasLength(1));
    });

    test('re-stamped file with differing digests is changed', () async {
      expect(
        await cmp.isSameContent(
            localSize: 10,
            localMtime: t,
            remoteSize: 10,
            remoteMtime: later,
            hashLocal: () async => digest,
            hashRemote: () async => '${digest.substring(1)}0'),
        isFalse,
      );
    });

    test('a hash that is unavailable, empty or throws means changed',
        () async {
      expect(
        await cmp.isSameContent(
            localSize: 10,
            localMtime: t,
            remoteSize: 10,
            remoteMtime: later,
            hashLocal: () async => digest,
            hashRemote: () async => null),
        isFalse,
      );
      expect(
        await cmp.isSameContent(
            localSize: 10,
            localMtime: t,
            remoteSize: 10,
            remoteMtime: later,
            hashLocal: () async => '',
            hashRemote: () async => ''),
        isFalse,
      );
      expect(
        await cmp.isSameContent(
            localSize: 10,
            localMtime: t,
            remoteSize: 10,
            remoteMtime: later,
            hashLocal: () async => throw StateError('no shell'),
            hashRemote: () async => digest),
        isFalse,
      );
    });

    test('two empty files are the same without hashing', () async {
      final l = hasher(() async => digest);
      expect(
        await cmp.isSameContent(
            localSize: 0,
            localMtime: t,
            remoteSize: 0,
            remoteMtime: later,
            hashLocal: l.fn,
            hashRemote: l.fn),
        isTrue,
      );
      expect(l.calls, isEmpty);
    });

    test('over the hash cap the file is transferred, not hashed', () async {
      final l = hasher(() async => digest);
      expect(
        await cmp.isSameContent(
            localSize: 1000,
            localMtime: t,
            remoteSize: 1000,
            remoteMtime: later,
            hashLocal: l.fn,
            hashRemote: l.fn,
            maxHashBytes: 999),
        isFalse,
      );
      expect(l.calls, isEmpty);
    });
  });

  group('source gate: no inline size+mtime comparison in the SFTP screen', () {
    test('the identity check goes through SyncCompare, not an inline copy', () {
      final src = File(
              'lib/ui/screens/sftp/sftp_dual_pane_screen.dart')
          .readAsStringSync();

      // The old inline predicate truncated both mtimes to whole seconds and
      // compared them for equality. If that shape reappears at either loop, the
      // single definition in SyncCompare has been forked again - which is the
      // exact drift this gate exists to stop.
      expect(
        src.contains('millisecondsSinceEpoch ~/ 1000 =='),
        isFalse,
        reason: 'Inline size+mtime identity comparison found. Use '
            'kSftpSyncCompare.isSameContent instead (lib/services/'
            'sftp_sync_compare.dart).',
      );

      // And prove the screen actually routes through the shared predicate:
      // the transfer loops through the content-aware check, the pre-scan
      // through the cheap verdict.
      expect(
        src.contains('kSftpSyncCompare.isSameContent'),
        isTrue,
        reason: 'The SFTP transfer loops no longer call the shared SyncCompare.',
      );
      // The pre-scan lives in its own library now (transfer_scan.dart), and
      // is held to the same rule.
      final scan =
          File('lib/ui/screens/sftp/transfer_scan.dart').readAsStringSync();
      expect(
        scan.contains('millisecondsSinceEpoch ~/ 1000 =='),
        isFalse,
        reason: 'Inline size+mtime identity comparison in the pre-scan.',
      );
      expect(
        scan.contains('kSftpSyncCompare.classify'),
        isTrue,
        reason: 'The SFTP pre-scan no longer calls the shared SyncCompare.',
      );
    });
  });
}
