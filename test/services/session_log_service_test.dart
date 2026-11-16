import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/session_log_service.dart';
import 'package:zestssh/utils/file_manager.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zestssh_session_log_');
  });

  tearDown(() async {
    await SessionLogService.endAll();
    SessionLogService.onError = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<String> start(String id, {bool timestamps = false}) async {
    final path = await SessionLogService.start(
      id,
      label: 'prod db: web/01',
      target: 'root@10.0.0.5:22',
      directory: tmp.path,
      timestamps: timestamps,
    );
    expect(path, isNotNull);
    return path!;
  }

  group('SessionLogService', () {
    test('file name is filesystem-safe and stamped', () {
      final name = SessionLogService.fileNameFor(
        ' prod db: web/01 <x>?* . ',
        DateTime(2026, 9, 22, 14, 3, 7),
      );
      expect(name, 'prod db_ web_01 _x____2026-09-22_14-03-07.log');
      expect(SessionLogService.fileNameFor('', DateTime(2026, 1, 1)),
          startsWith('session_'));
      expect(
        SessionLogService.fileNameFor('a' * 200, DateTime(2026, 1, 1)).length,
        lessThan(90),
      );
    });

    test('writes header, filtered output and footer', () async {
      final path = await start('s1');
      expect(path, startsWith(tmp.path));
      SessionLogService.append('s1', '\x1b[32mhello\x1b[0m\r\n');
      SessionLogService.append('s1', '\x1b]0;title\x07world');
      await SessionLogService.end('s1');

      final text = File(path).readAsStringSync();
      expect(text, startsWith('=== ZestSSH session log ===\n'));
      expect(text, contains('Connection: root@10.0.0.5:22\n'));
      expect(text, contains('Started: 20'));
      expect(text, contains('\nhello\nworld\n'));
      expect(text, endsWith(' ===\n'));
      expect(text, contains('=== Session ended: 20'));
      expect(text, isNot(contains('\x1b')));
      expect(SessionLogService.isLogging('s1'), isFalse);
    });

    test('timestamps prefix every line, including across chunks', () async {
      final path = await start('s2', timestamps: true);
      SessionLogService.append('s2', 'one\ntw');
      SessionLogService.append('s2', 'o\nthree');
      await SessionLogService.end('s2');

      final lines = File(path).readAsLinesSync();
      final stamped = lines.where((l) => RegExp(r'^\[\d\d:\d\d:\d\d\] ').hasMatch(l));
      expect(stamped.map((l) => l.substring(11)), ['one', 'two', 'three']);
    });

    test('a reconnect appends to the same file with a marker', () async {
      final first = await start('s3');
      SessionLogService.append('s3', 'before\n');
      await SessionLogService.end('s3');
      final again = await start('s3');
      expect(again, first);
      SessionLogService.append('s3', 'after\n');
      await SessionLogService.end('s3');

      final text = File(first).readAsStringSync();
      expect(text, contains('before\n'));
      expect(text, contains('=== Reconnected: 20'));
      expect(text, contains('after\n'));
      expect('=== ZestSSH session log ==='.allMatches(text).length, 1);
      expect('=== Session ended'.allMatches(text).length, 2);
    });

    test('forget() starts a new file for the same id', () async {
      final first = await start('s4');
      await SessionLogService.end('s4');
      SessionLogService.forget('s4');
      // Same second could collide on the name; wait for a fresh stamp.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final second = await start('s4');
      expect(second, isNot(first));
      await SessionLogService.end('s4');
    });

    test('tmux panes are separated by marker lines', () async {
      final path = await start('s5');
      SessionLogService.appendPane('s5', '%1', 'left\n');
      SessionLogService.appendPane('s5', '%2', 'right\n');
      SessionLogService.appendPane('s5', '%2', 'more right\n');
      SessionLogService.appendPane('s5', '%1', '\x1b[2K'); // nothing visible
      SessionLogService.appendPane('s5', '%1', 'left again\n');
      await SessionLogService.end('s5');

      final text = File(path).readAsStringSync();
      expect(
        text,
        contains('--- pane %1 ---\nleft\n--- pane %2 ---\nright\nmore right\n'
            '--- pane %1 ---\nleft again\n'),
      );
    });

    // Output faster than one flush: the second 16 KB was written into the
    // IOSink while the flush of the first ran, which throws "StreamSink is
    // bound to a stream", and the log stopped for the rest of the session
    // (found in a review of the SSH code).
    test('a log keeps going through output that comes faster than one flush', () async {
      final errors = <String>[];
      SessionLogService.onError = (id, message) => errors.add(message);
      final path = await start('s-burst');

      // cat of a log file: SSH packets of output in one read of the socket,
      // each handed to the log as it is decoded.
      final packet = '${'x' * 79}\n' * 300; // 24,000 characters
      SessionLogService.append('s-burst', packet);
      SessionLogService.append('s-burst', packet);
      SessionLogService.append('s-burst', packet);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(errors, isEmpty, reason: 'the log stopped: $errors');
      expect(SessionLogService.isLogging('s-burst'), isTrue);
      SessionLogService.append('s-burst', 'after the burst\n');

      await SessionLogService.end('s-burst');
      final written = File(path).readAsStringSync();
      expect('x'.allMatches(written).length, 79 * 300 * 3);
      expect(written, contains('\nafter the burst\n'));
      expect(written, contains('=== Session ended: 20'));
    });

    test('a log ended while a flush runs keeps the rest and its footer', () async {
      final errors = <String>[];
      SessionLogService.onError = (id, message) => errors.add(message);
      final path = await start('s-end');
      SessionLogService.append('s-end', '${'y' * 79}\n' * 300);
      SessionLogService.append('s-end', 'the last line\n');
      await SessionLogService.end('s-end');

      expect(errors, isEmpty);
      final written = File(path).readAsStringSync();
      expect('y'.allMatches(written).length, 79 * 300);
      expect(written, contains('\nthe last line\n'));
      expect(written, endsWith(' ===\n'));
      expect(written, contains('=== Session ended: 20'));
    });

    test('a new log on Linux or a Mac is kept to its owner before a line is written; a reconnect does not ask '
        'again', () async {
      final asked = <String>[];
      final sizes = <int>[];
      debugRestrictFileToOwner = (file) async {
        asked.add(file.path);
        sizes.add(file.lengthSync());
        return true;
      };
      addTearDown(() => debugRestrictFileToOwner = null);
      Future<String?> begin() => SessionLogService.start('s9',
          label: 'web-1', target: 'deploy@10.0.0.5:22', directory: tmp.path, timestamps: false, ownerOnly: true);

      final path = await begin();
      expect(asked, [path]);
      expect(sizes, [0], reason: 'before the header');
      SessionLogService.append('s9', 'hello');
      await SessionLogService.end('s9');

      expect(await begin(), path, reason: 'the same file goes on');
      expect(asked, hasLength(1));
      await SessionLogService.end('s9');
      expect(File(path!).readAsStringSync(), contains('hello'));
    });

    test('where the file cannot be kept to its owner the log is written all the same; and Windows is not asked',
        () async {
      var asked = 0;
      debugRestrictFileToOwner = (file) async {
        asked++;
        return false;
      };
      addTearDown(() => debugRestrictFileToOwner = null);
      final path = await SessionLogService.start('s10',
          label: 'web-1', target: 'deploy@10.0.0.5:22', directory: tmp.path, timestamps: false, ownerOnly: true);
      SessionLogService.append('s10', 'kept');
      await SessionLogService.end('s10');
      expect(asked, 1);
      expect(File(path!).readAsStringSync(), contains('kept'));

      asked = 0;
      await SessionLogService.start('s11',
          label: 'web-2', target: 'deploy@10.0.0.6:22', directory: tmp.path, timestamps: false, ownerOnly: false);
      await SessionLogService.end('s11');
      expect(asked, 0);
    });

    test('append is a no-op for a session that is not logging', () {
      SessionLogService.append('nobody', 'ignored');
      expect(SessionLogService.isLogging('nobody'), isFalse);
      expect(SessionLogService.pathOf('nobody'), isNull);
    });

    test('an unusable folder reports through onError instead of throwing',
        () async {
      String? reported;
      SessionLogService.onError = (id, msg) => reported = '$id: $msg';
      // A FILE where the folder should be, so the directory cannot be made.
      final blocker = File('${tmp.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('x');
      final path = await SessionLogService.start(
        's6',
        label: 'x',
        target: 'x',
        directory: '${blocker.path}${Platform.pathSeparator}sub',
        timestamps: false,
      );
      // resolveDirectory falls back to the app's default folder; under the
      // test runner there is no platform channel for it, so the open fails
      // and is REPORTED. What must never happen is a throw.
      expect(path, isNull);
      expect(reported, contains('s6: log: could not open'));
      expect(SessionLogService.isLogging('s6'), isFalse);
    });
  });
}
