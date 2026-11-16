import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// Application-wide logging utility.
///
/// Nothing is written to disk. Nothing is sent anywhere. Lines go to the
/// console (in release mode, only warnings and errors, with every name and
/// secret taken out as Copy details takes them out, [consoleLine]), which
/// someone sees when the app was started from a terminal, or in a phone's
/// own log of the device.
///
/// The last [kKeptLines] lines are also kept in memory until the app is
/// closed, for one purpose: when something fails, the error's "Copy
/// details" puts the last of them, with every name and secret taken out
/// (ReportScrub), into what the person copies. Whether that goes anywhere is
/// theirs to decide; the app sends none of it.
///
/// ZestSSH collects no telemetry, no analytics, no crash reports,
/// and no log files. This is a privacy promise.
abstract final class AppLogger {
  static final Logger _logger = Logger('ZestSSH');
  static bool _initialized = false;

  /// How many lines are kept in memory.
  static const int kKeptLines = 200;

  /// The longest a kept line is: one that runs on (an error that prints a
  /// whole document) keeps its start.
  static const int kLineMax = 600;

  static final Queue<String> _kept = ListQueue<String>();

  /// Initialise the logging system. Call once from [main].
  static void init() {
    if (_initialized) return;
    _initialized = true;

    // Everything from "info" up is looked at: in release mode it is kept in
    // memory for an error's details, and only warnings and errors are
    // printed.
    Logger.root.level = kReleaseMode ? Level.INFO : Level.ALL;

    Logger.root.onRecord.listen((record) {
      remember(record);
      if (kReleaseMode && record.level < Level.WARNING) return;
      debugPrint(consoleLine(record, released: kReleaseMode));
    });
  }

  /// What [record] is printed to the console as. In a released app (on a
  /// phone, the device's own log keeps it) it is scrubbed as Copy details
  /// scrubs (ReportScrub: no key, password, token, host, address or folder
  /// of the person's), with no stack, which an obfuscated build names nothing
  /// in. (3.0, the client's security review of 16 October 2026: a released
  /// app printed its warnings and errors as they were.)
  @visibleForTesting
  static String consoleLine(LogRecord record, {required bool released}) {
    final msg = lineOf(record);
    final error = record.error;
    if (released) return ReportScrub.scrub(error == null ? msg : '$msg\n  Error: $error');
    return error == null ? msg : '$msg\n  Error: $error\n  Stack: ${record.stackTrace}';
  }

  /// A record as one line: when, how grave, what.
  static String lineOf(LogRecord record) {
    final time = record.time.toIso8601String().substring(11, 23);
    return '[$time] ${record.level.name}: ${record.message}';
  }

  /// Keeps [record] among the last lines. Debug chatter is not kept: it is
  /// too much, and says nothing about a failure that the lines above "info"
  /// do not.
  @visibleForTesting
  static void remember(LogRecord record) {
    if (record.level < Level.INFO) return;
    final error = record.error;
    final whole = error == null ? lineOf(record) : '${lineOf(record)} ($error)';
    final oneLine = whole.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');
    _kept.addLast(oneLine.length > kLineMax ? '${oneLine.substring(0, kLineMax)}...' : oneLine);
    while (_kept.length > kKeptLines) {
      _kept.removeFirst();
    }
  }

  /// The last [max] lines of this run of the app, oldest first, as they
  /// were logged: whoever shows or copies them scrubs them first.
  static List<String> recent([int max = 40]) {
    if (max <= 0) return const [];
    final all = _kept.toList();
    return all.length <= max ? all : all.sublist(all.length - max);
  }

  /// Forgets the kept lines (tests; signing out).
  static void forget() => _kept.clear();

  static void info(String message) => _logger.info(message);
  static void warning(String message) => _logger.warning(message);
  static void error(String message, [Object? error, StackTrace? stack]) =>
      _logger.severe(message, error, stack);
  static void debug(String message) => _logger.fine(message);
}
