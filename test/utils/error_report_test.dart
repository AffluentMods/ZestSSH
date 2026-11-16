import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// The details of a failure as a person copies them, and the lines of the
/// app's log they end with. Every name and address here is made up.
void main() {
  final at = DateTime.utc(2026, 10, 2, 14, 3, 22);

  LogRecord record(Level level, String message, [Object? error]) => LogRecord(level, message, 'ZestSSH', error);

  setUp(() {
    AppLogger.forget();
    ReportScrub.clearFolders();
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..enabled = false;
    ErrorReport.app = 'ZestSSH 3.0.0 (build 256)';
    ErrorReport.system = () => 'windows "Windows 11 Pro" 10.0 (Build 26200)';
  });

  tearDown(() {
    AppLogger.forget();
    ReportScrub.clearFolders();
    Redactor.instance.clearNames();
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  group('The lines the app keeps of its log', () {
    test('are the last of this run, oldest first, and no more than it keeps', () {
      expect(AppLogger.recent(), isEmpty);
      for (var i = 0; i < AppLogger.kKeptLines + 30; i++) {
        AppLogger.remember(record(Level.INFO, 'line $i'));
      }
      final all = AppLogger.recent(AppLogger.kKeptLines + 100);
      expect(all, hasLength(AppLogger.kKeptLines));
      expect(all.first, endsWith('INFO: line 30'));
      expect(all.last, endsWith('INFO: line ${AppLogger.kKeptLines + 29}'));
      final three = AppLogger.recent(3);
      expect([for (final l in three) l.split('INFO: ').last], [
        'line ${AppLogger.kKeptLines + 27}',
        'line ${AppLogger.kKeptLines + 28}',
        'line ${AppLogger.kKeptLines + 29}',
      ]);
      expect(AppLogger.recent(0), isEmpty);
      expect(AppLogger.recent(-1), isEmpty);
      AppLogger.forget();
      expect(AppLogger.recent(), isEmpty);
    });

    test('hold what counts: info, warnings and errors with what was caught, not the chatter', () {
      AppLogger.remember(record(Level.FINE, 'chatter'));
      AppLogger.remember(record(Level.INFO, 'started'));
      AppLogger.remember(record(Level.WARNING, 'slow'));
      AppLogger.remember(record(Level.SEVERE, 'failed', const FormatException('bad\n  input')));
      final lines = AppLogger.recent();
      expect(lines, hasLength(3));
      expect(lines[0], matches(RegExp(r'^\[\d\d:\d\d:\d\d\.\d\d\d\] INFO: started$')));
      expect(lines[1], endsWith('WARNING: slow'));
      expect(lines[2], endsWith('SEVERE: failed (FormatException: bad input)'), reason: 'one line each');
    });

    test('a line that runs on keeps its start', () {
      AppLogger.remember(record(Level.WARNING, 'x' * 5000));
      final line = AppLogger.recent().single;
      expect(line.length, lessThan(AppLogger.kLineMax + 40));
      expect(line, endsWith('...'));
    });

    test('what is logged through the app\'s own calls is kept once logging has begun', () {
      AppLogger.init();
      AppLogger.warning('a warning of its own');
      AppLogger.error('an error of its own', StateError('why'));
      AppLogger.info('a note of its own');
      final lines = AppLogger.recent();
      expect(lines.where((l) => l.endsWith('WARNING: a warning of its own')), hasLength(1));
      expect(lines.where((l) => l.endsWith('SEVERE: an error of its own (Bad state: why)')), hasLength(1));
      expect(lines.where((l) => l.endsWith('INFO: a note of its own')), hasLength(1));
    });
  });

  group('The details of a failure', () {
    test('say what failed, where, the error, which app and system, and when', () {
      final report = ErrorReport.build(
        what: 'The database could not be opened.',
        where: 'Starting the app',
        error: const FormatException('file is not a database'),
        now: at,
      );
      expect(report.split('\n'), [
        'ZestSSH error details',
        'What: The database could not be opened.',
        'Where: Starting the app',
        'Error: FormatException: file is not a database',
        'App: ZestSSH 3.0.0 (build 256)',
        'System: windows "Windows 11 Pro" 10.0 (Build 26200)',
        'Time: 2026-10-02 14:03:22 UTC',
        '',
        ErrorReport.kNotice,
      ]);
    });

    test('with nothing but what failed, they are still whole', () {
      final report = ErrorReport.build(what: '  Sync did not finish.\n', where: ' ', details: '', now: at);
      expect(report.split('\n'), [
        'ZestSSH error details',
        'What: Sync did not finish.',
        'App: ZestSSH 3.0.0 (build 256)',
        'System: windows "Windows 11 Pro" 10.0 (Build 26200)',
        'Time: 2026-10-02 14:03:22 UTC',
        '',
        ErrorReport.kNotice,
      ]);
    });

    test('the time is said in UTC, whatever zone the device is in', () {
      final local = DateTime(2026, 3, 4, 5, 6, 7);
      final u = local.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      expect(ErrorReport.build(what: 'x', now: local),
          contains('Time: ${u.year}-${two(u.month)}-${two(u.day)} ${two(u.hour)}:${two(u.minute)}:${two(u.second)} UTC'));
    });

    test('carry no name, address, folder or secret, wherever it stood', () {
      Redactor.instance.registerNames(['web-01']);
      ReportScrub.registerFolder('/home/demo/.local/share/zestssh', '<app data>');
      AppLogger.remember(record(Level.INFO, 'Connecting to web-01 at 10.50.0.11'));
      AppLogger.remember(
          record(Level.WARNING, 'sync failed', 'HTTP 401 for https://dav.northwind.example/files?token=abc'));
      final report = ErrorReport.build(
        what: 'Could not connect to web-01.',
        where: 'Connecting to demo@10.50.0.11',
        error: "FileSystemException: Cannot open file, path = '/home/demo/.local/share/zestssh/zestssh.db'",
        details: 'password=hunter2\nlast host key SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8',
        now: at,
      );
      for (final leak in ['web-01', '10.50.0.11', 'demo', 'northwind', 'hunter2', 'nThbg6k', 'token=abc']) {
        expect(report, isNot(contains(leak)), reason: leak);
      }
      expect(report, contains("path = '<app data>/zestssh.db'"));
      expect(report, contains('  password=[removed]'));
      expect(report, contains('  last host key SHA256:[removed]'));
      expect(report, contains('WARNING: sync failed (HTTP 401 for https://host-'));
      expect(report, endsWith(ErrorReport.kNotice));
    });

    test('what is told in several lines stays in its place: one line for what and where, the rest indented', () {
      final report = ErrorReport.build(
        what: 'It failed.\nTry again.',
        where: 'Saving\nthe file',
        error: 'first line\nsecond line\n',
        details: 'one\ntwo',
        now: at,
        logLines: 0,
      );
      expect(report.split('\n').take(8), [
        'ZestSSH error details',
        'What: It failed. Try again.',
        'Where: Saving the file',
        'Error: first line',
        '  second line',
        'Details:',
        '  one',
        '  two',
      ]);
    });

    test('end with the last lines of the log, as many as asked for and none when none are', () {
      for (var i = 0; i < 50; i++) {
        AppLogger.remember(record(Level.INFO, 'line $i'));
      }
      final lines = ErrorReport.build(what: 'x', now: at).split('\n');
      final from = lines.indexOf('Log, the last lines before it (oldest first):');
      expect(from, greaterThan(0));
      expect(lines[from - 1], isEmpty);
      final log = lines.sublist(from + 1, lines.length - 2);
      expect(log, hasLength(40));
      expect(log.first, endsWith('INFO: line 10'));
      expect(log.last, endsWith('INFO: line 49'));
      expect(log.every((l) => l.startsWith('  [')), isTrue);
      expect(ErrorReport.build(what: 'x', now: at, logLines: 5).split('\n').where((l) => l.contains('INFO: line')),
          hasLength(5));
      expect(ErrorReport.build(what: 'x', now: at, logLines: 0), isNot(contains('Log, the last lines')));
    });

    test('a stack that reads is carried, its first lines; one from a release build is left out', () {
      final frames = [
        for (var i = 0; i < 20; i++) '#$i      Thing.does$i (package:zestssh/features/thing/thing.dart:${10 + i}:5)',
      ];
      final report = ErrorReport.build(what: 'x', stack: StackTrace.fromString(frames.join('\n')), now: at, logLines: 0);
      final lines = report.split('\n');
      final from = lines.indexOf('Stack:');
      expect(lines[from - 1], isEmpty);
      expect(lines.sublist(from + 1, from + 1 + ErrorReport.kStackLines),
          [for (final f in frames.take(ErrorReport.kStackLines)) '  $f']);
      expect(lines[from + 1 + ErrorReport.kStackLines], '  ... ${20 - ErrorReport.kStackLines} more');
      // A short one is carried whole, with nothing said about more.
      final short = ErrorReport.build(what: 'x', stack: StackTrace.fromString(frames.take(3).join('\n')), now: at);
      expect(short, contains('  ${frames[2]}'));
      expect(short, isNot(contains('more')));
      // A stack from a release build is numbers for a file the build left behind.
      const numbers = 'Warning: This VM has been configured to produce stack traces that violate the Dart standard.\n'
          '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n'
          'pid: 4242, tid: 4243, name 1.ui\n'
          'isolate_dso_base: 7ff600000000, vm_dso_base: 7ff600000000\n'
          '    #00 abs 00007ff6001ab2c3 _kDartIsolateSnapshotInstructions+0x1ab2c3';
      final release = ErrorReport.build(what: 'x', stack: StackTrace.fromString(numbers), now: at);
      expect(release, isNot(contains('Stack:')));
      expect(release, isNot(contains('7ff6')));
      expect(ErrorReport.build(what: 'x', stack: StackTrace.empty, now: at), isNot(contains('Stack:')));
    });

    test('the system is named without the name of the machine', () {
      // (As this machine names itself: the first words of it at most.)
      final label = ErrorReport.systemLabel();
      expect(label, isNotEmpty);
      expect(label.split(' ').first, isIn(['windows', 'linux', 'macos', 'android', 'ios']));
    });

    test('a stack is scrubbed line by line, like everything else in it', () {
      final report = ErrorReport.build(
        what: 'x',
        stack: StackTrace.fromString('#0      main (file:///home/demo/northwind/bin/run.dart:3:1)\n'
            '#1      Thing.go (/srv/northwind/app/thing.dart:4:2)'),
        now: at,
        logLines: 0,
      );
      expect(report, contains('  #0      main (/home/<user>/<name>/bin/run.dart:3:1)'));
      expect(report, contains('  #1      Thing.go (/srv/<name>/<name>/thing.dart:4:2)'));
      for (final leak in ['demo', 'northwind']) {
        expect(report, isNot(contains(leak)), reason: leak);
      }
    });

    test('of Android and Linux, only the first words of the system\'s line, and no more than 40 characters', () {
      expect(
        ErrorReport.systemLabelOf('linux', 'Linux 6.8.0-124-generic #124-Ubuntu SMP PREEMPT_DYNAMIC Fri Sep 12 web-01'),
        'linux Linux 6.8.0-124-generic #124-Ubuntu',
      );
      expect(ErrorReport.systemLabelOf('android', '  5.10.198-android12 #1 SMP PREEMPT build-host  '),
          'android 5.10.198-android12 #1 SMP');
      expect(ErrorReport.systemLabelOf('linux', '${'x' * 50} y z'), 'linux ${'x' * 40}');
      // The others say only what the system is, and are kept whole.
      expect(ErrorReport.systemLabelOf('windows', ' "Windows 11 Pro" 10.0 (Build 26200) '),
          'windows "Windows 11 Pro" 10.0 (Build 26200)');
      expect(ErrorReport.systemLabelOf('macos', 'Version 15.1 (Build 24B83)'), 'macos Version 15.1 (Build 24B83)');
    });
  });
}
