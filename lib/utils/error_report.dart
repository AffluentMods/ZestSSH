import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHAuthAbortError, SSHHandshakeError;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_service.dart' show nothingInCommonText;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// The details of a failure, as text a person can copy.
///
/// Every error the app shows can be copied with what stands behind it: what
/// failed, the error as the system gave it, where in the app it happened,
/// which app and system this is, and the last lines the app logged before
/// it. The text is written to be pasted to support, to Astryx or to another
/// assistant, so its labels are English whatever language the app speaks,
/// and every name, address, folder and secret is taken out first
/// ([ReportScrub]). The app sends it nowhere: it is put on the clipboard
/// when the person asks, and that is all.
abstract final class ErrorReport {
  /// The app as a report names it: its version and build, once the app has
  /// read them ([prime]).
  static String app = 'ZestSSH';

  /// The system as a report names it; a test's own stands in.
  static String Function() system = systemLabel;

  /// How many lines of a stack a report carries: the place it happened and
  /// the way there, without the framework's own plumbing below it.
  static const int kStackLines = 14;

  /// Reads which app this is and tells [ReportScrub] the folders it writes
  /// to, so that a path in a report says `<app data>` and not the name of
  /// the person's account. Safe to call more than once; whatever of it
  /// cannot be read is left as it was.
  static Future<void> prime() async {
    try {
      final info = await PackageInfo.fromPlatform();
      // A build that is not the release says so in what it copies:
      // whoever reads a report must be able to tell.
      final kind = zestOfficial ? '' : ', ${zestBuildNameShown != '' ? zestBuildNameShown : 'community build'}';
      app = 'ZestSSH ${info.version} (build ${info.buildNumber}$kind)';
    } catch (_) {
      // (Not known: the report says ZestSSH.)
    }
    Future<void> folder(Future<dynamic> Function() dir, String token) async {
      try {
        final path = (await dir())?.path as String?;
        if (path != null) ReportScrub.registerFolder(path, token);
      } catch (_) {
        // (This system has no such folder.)
      }
    }

    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home != null) ReportScrub.registerFolder(home, '<home>');
    await folder(getApplicationSupportDirectory, '<app data>');
    await folder(getApplicationDocumentsDirectory, '<documents>');
    await folder(getTemporaryDirectory, '<temp>');
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await folder(getDownloadsDirectory, '<downloads>');
    }
  }

  /// The system and its version. Android and Linux give a whole line there
  /// (the kernel's build, the name of the machine, a date), which says more
  /// about the device than a report should: only its first words are kept.
  static String systemLabel() => systemLabelOf(Platform.operatingSystem, Platform.operatingSystemVersion);

  /// [systemLabel] of the system [system] (as [Platform.operatingSystem]
  /// names it) whose version reads [version].
  @visibleForTesting
  static String systemLabelOf(String system, String version) {
    final raw = version.trim();
    if (system != 'android' && system != 'linux') return '$system $raw';
    final words = raw.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final short = words.take(3).join(' ');
    return '$system ${short.length <= 40 ? short : short.substring(0, 40)}';
  }

  /// The report of one failure.
  ///
  /// [what] is what the person was told (the message on screen); [where],
  /// what the app was doing, in English; [error] and [stack], what was
  /// caught; [details], anything else worth knowing (lines of a connection
  /// log, what a server answered). [logLines] of the app's own log come
  /// last, none when 0. Everything given is scrubbed; nothing is scrubbed
  /// twice into something else.
  ///
  /// Of [error] the report has what it prints, and two things it may not
  /// print. What cut a sign-in off, where it was one that was cut off (the
  /// error says only that the connection closed), under the error. And the
  /// name of its type, where what it prints does not have it: many of the
  /// app's own errors print a sentence, and a report from a released app
  /// carries no stack that would say what was caught.
  static String build({
    required String what,
    String? where,
    Object? error,
    StackTrace? stack,
    String? details,
    int logLines = 40,
    DateTime? now,
  }) {
    final out = <String>['ZestSSH error details', 'What: ${_one(what)}'];
    // A message that names a code: the code again with what it stands for,
    // in English, for whoever reads a report whose message is in a language
    // they do not read.
    final code = ErrorCodes.codeIn(what);
    if (code != null) out.add('Code: ${code.code} (${code.title})');
    if (where != null && where.trim().isNotEmpty) out.add('Where: ${_one(where)}');
    if (error != null) {
      final cut = _cutOffBy(error);
      final text = ReportScrub.scrub(cut == null ? _said(error) : '$error\nWhat cut it off: ${_said(cut)}').trim();
      if (text.isNotEmpty) {
        final lines = text.split('\n');
        out.add('Error: ${lines.first.trimRight()}');
        out.addAll([for (final l in lines.skip(1)) '  ${l.trimRight()}']);
      }
      // (What is no error of any kind has no type to name: a text that was handed in, most often.)
      final kind = errorKind(error);
      if (kind != 'Object' && !text.contains(kind)) out.add('Error type: $kind');
    }
    if (details != null && details.trim().isNotEmpty) {
      out.add('Details:');
      out.addAll([for (final l in ReportScrub.scrub(details.trim()).split('\n')) '  ${l.trimRight()}']);
    }
    out
      ..add('App: $app')
      ..add('System: ${system()}')
      ..add('Time: ${_utc(now ?? DateTime.now())}');

    final frames = _frames(stack);
    if (frames.isNotEmpty) {
      out
        ..add('')
        ..add('Stack:')
        ..addAll([for (final f in frames) '  $f']);
    }

    final log = AppLogger.recent(logLines);
    if (log.isNotEmpty) {
      out
        ..add('')
        ..add('Log, the last lines before it (oldest first):')
        ..addAll([for (final l in log) '  ${ReportScrub.scrub(l)}']);
    }
    out
      ..add('')
      ..add(kNotice);
    return out.join('\n');
  }

  /// What a report ends with, so that whoever reads it knows why a host is
  /// called host-12 in it, and whoever copies it knows what it holds.
  static const String kNotice =
      'Names of hosts, people and folders, addresses, keys and passwords were taken out of this text before it was copied.';

  static String _one(String text) => ReportScrub.scrub(text.trim()).replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');

  /// What cut the sign-in off that [error] is, where it is one and knows:
  /// at the host, or at a jump host on the way to it.
  static Object? _cutOffBy(Object error) {
    final signIn = error is JumpHostFailure ? error.cause : error;
    return signIn is SSHAuthAbortError ? signIn.reason : null;
  }

  /// [e] as a report says it: what it prints, and for a key exchange that
  /// ended with nothing in common what each side offered as well, which
  /// the error does not print ([nothingInCommonText]). A session that
  /// failed keeps that in its text; whatever hands over the thing it
  /// caught (the host editor's test, Server Monitor) gets it here.
  static String _said(Object e) => e is SSHHandshakeError && e.nothingInCommon ? nothingInCommonText(e) : '$e';

  static String _utc(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}-${two(u.month)}-${two(u.day)} ${two(u.hour)}:${two(u.minute)}:${two(u.second)} UTC';
  }

  // A stack from a build made for release names no functions (it is a list
  // of numbers for a file the build left behind): it helps nobody who reads
  // the report, and is left out.
  static final RegExp _unreadable = RegExp(r'\*\*\* \*\*\*|_kDartIsolateSnapshotInstructions|isolate_dso_base');

  static List<String> _frames(StackTrace? stack) {
    if (stack == null) return const [];
    final text = '$stack'.trim();
    if (text.isEmpty || _unreadable.hasMatch(text)) return const [];
    final lines = [
      for (final l in text.split('\n'))
        if (l.trim().isNotEmpty) ReportScrub.scrub(l.trimRight()),
    ];
    if (lines.length <= kStackLines) return lines;
    return [...lines.take(kStackLines), '... ${lines.length - kStackLines} more'];
  }
}
