import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/type_name.dart';

/// Starting a Mosh session (4.0, the built-in client): mosh-server is started
/// on the host over the app's own SSH connection, and prints the UDP port it
/// listens on and the session's key on a line of its own:
///
///     MOSH CONNECT 60001 4NeCCgvZFe2RnPgrcU1PQw
///
/// which the client then takes over UDP. What the host says otherwise (no
/// mosh-server, no UTF-8 locale for it) is read here as a [MoshStartFailure]
/// with its code. The key is never written to a log or into an error's
/// details ([redactMoshKeys]).

/// The UDP ports mosh-server is asked to choose from: the ones the system
/// mosh client asks for (the app's integration before 4.0 passed the same).
const kMoshPortRange = '60000:61000';

/// The locales mosh-server is asked to run its shell in, in order: the first
/// is the one most hosts have, the second the one a minimal system has.
const kMoshLocales = ['LANG=en_US.UTF-8', 'LANG=C.UTF-8'];

/// Where mosh-server is looked for when the host's shell does not find it by
/// name (a non-login shell without Homebrew's or MacPorts' folders on its
/// PATH, a snap).
const kMoshServerPaths = [
  'mosh-server',
  '/usr/local/bin/mosh-server',
  '/opt/homebrew/bin/mosh-server',
  '/opt/local/bin/mosh-server',
  '/usr/bin/mosh-server',
  '/snap/bin/mosh-server',
];

/// The command that starts mosh-server: a new session, 256 colours, the
/// ports of [kMoshPortRange], [locale] for its shell. [bindToSsh] (`-s`)
/// makes it listen on the address the SSH connection came in on, which is
/// the address the client sends to; through a jump host that address is the
/// jump host's way in, so it is left out there. The shell is the account's
/// own (nothing after `--`).
String moshServerCommand({String server = 'mosh-server', required String locale, bool bindToSsh = true}) =>
    [server, 'new', if (bindToSsh) '-s', '-c', '256', '-p', kMoshPortRange, '-l', locale].join(' ');

/// What mosh-server said it listens on.
class MoshServerStart {
  const MoshServerStart({required this.port, required this.key});
  final int port;

  /// 22 characters of base64. Never logged, never shown.
  final String key;

  @override
  String toString() => 'MoshServerStart(port: $port, key: <redacted>)';
}

/// Why mosh-server did not start.
enum MoshStartProblem {
  /// The host has no mosh-server (the shell could not find it).
  notInstalled,

  /// mosh-server found no UTF-8 locale to run in.
  locale,

  /// It said something else, or nothing, and printed no MOSH CONNECT line.
  noConnectLine,
}

/// A Mosh session that did not start, before any UDP was sent.
class MoshStartFailure implements Exception, HasTypeName {
  const MoshStartFailure(this.problem, {this.said = ''});
  final MoshStartProblem problem;

  /// What the host printed (keys taken out, at most a few lines), for the
  /// details.
  final String said;

  ErrorCode get code => switch (problem) {
        MoshStartProblem.notInstalled => ErrorCodes.moshServerMissing,
        MoshStartProblem.locale => ErrorCodes.moshServerLocale,
        MoshStartProblem.noConnectLine => ErrorCodes.moshServerDidNotStart,
      };

  @override
  String toString() => 'MoshStartFailure: ${problem.name}${said.isEmpty ? '' : ': $said'}';

  @override
  String get typeName => 'MoshStartFailure';
}

/// The words for [e], in the person's language, with its code.
String moshStartFailureText(AppLocalizations l10n, MoshStartFailure e) {
  final said = switch (e.problem) {
    MoshStartProblem.notInstalled => l10n.connMoshServerMissing,
    MoshStartProblem.locale => l10n.connMoshServerLocale,
    MoshStartProblem.noConnectLine => l10n.connMoshServerNoStart,
  };
  final text = ErrorCodes.withCode(said, e.code);
  return e.said.isEmpty || e.problem == MoshStartProblem.notInstalled ? text : '$text\n\n${e.said}';
}

final _connectLine = RegExp(r'^MOSH CONNECT (\d{1,5}) ([A-Za-z0-9/+]{22})\s*$', multiLine: true);
final _anyKey = RegExp(r'MOSH CONNECT (\d{1,5}) \S+');

/// [text] with any session key on a MOSH CONNECT line taken out.
String redactMoshKeys(String text) => text.replaceAllMapped(_anyKey, (m) => 'MOSH CONNECT ${m[1]} <key>');

/// What mosh-server printed on its standard output ([stdout]) and error
/// ([stderr], where its banner and its complaints go), and how it ended
/// ([exitCode]: 127 is a shell's "command not found"), read as a start or a
/// [MoshStartFailure]. A terminal's carriage returns are allowed (a host
/// that runs it in a terminal).
MoshServerStart parseMoshServerOutput(String stdout, String stderr, int? exitCode) {
  final out = stdout.replaceAll('\r', '');
  final err = stderr.replaceAll('\r', '');
  final m = _connectLine.firstMatch(out) ?? _connectLine.firstMatch(err);
  if (m != null) {
    final port = int.parse(m[1]!);
    if (port > 0 && port < 65536) return MoshServerStart(port: port, key: m[2]!);
  }
  final both = '$out\n$err';
  if (both.contains('needs a UTF-8 native locale')) {
    throw MoshStartFailure(MoshStartProblem.locale, said: _shortened(both));
  }
  final lower = both.toLowerCase();
  final notFound = exitCode == 127 ||
      lower.contains('mosh-server: command not found') ||
      lower.contains('mosh-server: not found') ||
      lower.contains('mosh-server: no such file') ||
      (lower.contains('mosh-server') && lower.contains('unknown command')) ||
      lower.contains("'mosh-server' is not recognized");
  if (notFound) throw MoshStartFailure(MoshStartProblem.notInstalled, said: _shortened(both));
  throw MoshStartFailure(MoshStartProblem.noConnectLine, said: _shortened(both));
}

/// At most [lines] lines of what the host said that are not its banner,
/// keys taken out.
String _shortened(String text, {int lines = 8}) {
  final kept = [
    for (final l in redactMoshKeys(text).split('\n'))
      if (l.trim().isNotEmpty &&
          !l.startsWith('Copyright') &&
          !l.startsWith('License GPL') &&
          !l.startsWith('This is free software') &&
          !l.startsWith('There is NO WARRANTY') &&
          !RegExp(r'^LC_[A-Z]+=|^LANG=|^LANGUAGE=').hasMatch(l))
        l.trimRight(),
  ];
  final shown = kept.take(lines).map((l) => l.length > 200 ? '${l.substring(0, 200)}...' : l).join('\n');
  return shown;
}

/// One command's output and how it ended.
typedef MoshCommandResult = ({String stdout, String stderr, int? exitCode});

/// Runs a command on the host (over SSH, no terminal) and gives back what it
/// printed: the bootstrap's one way of reaching the host, so tests give
/// their own.
typedef MoshCommandRunner = Future<MoshCommandResult> Function(String command);

/// Starts mosh-server through [run]: by name first, then where package
/// managers put it when the host's shell does not find it, each with the
/// first locale and, where mosh-server finds no UTF-8 locale, the next.
/// [onLog] hears each try, never the key.
Future<MoshServerStart> startMoshServer(
  MoshCommandRunner run, {
  bool bindToSsh = true,
  void Function(String line)? onLog,
}) async {
  MoshStartFailure? last;
  for (final server in kMoshServerPaths) {
    for (final locale in kMoshLocales) {
      final command = moshServerCommand(server: server, locale: locale, bindToSsh: bindToSsh);
      onLog?.call('mosh: Running on the host: $command');
      final r = await run(command);
      try {
        final start = parseMoshServerOutput(r.stdout, r.stderr, r.exitCode);
        onLog?.call('mosh: mosh-server listens on UDP port ${start.port}');
        return start;
      } on MoshStartFailure catch (e) {
        last = e;
        onLog?.call('mosh: mosh-server did not start (${e.problem.name})');
        // Another locale only helps a locale problem; another path only a
        // missing program.
        if (e.problem != MoshStartProblem.locale) break;
      }
    }
    if (last?.problem != MoshStartProblem.notInstalled) break;
  }
  throw last ?? const MoshStartFailure(MoshStartProblem.noConnectLine);
}

/// The most of a bootstrap command's output that is read.
const kMoshBootstrapMaxBytes = 64 * 1024;

/// How long a bootstrap command may take.
const kMoshBootstrapTimeout = Duration(seconds: 20);

/// Collects a command's output streams (at most [kMoshBootstrapMaxBytes]
/// each) until both end.
Future<MoshCommandResult> collectMoshCommand({
  required Stream<Uint8List> stdout,
  required Stream<Uint8List> stderr,
  required Future<void> done,
  required int? Function() exitCode,
}) async {
  Future<String> read(Stream<Uint8List> s) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in s) {
      final room = kMoshBootstrapMaxBytes - b.length;
      if (room > 0) b.add(chunk.length <= room ? chunk : Uint8List.sublistView(chunk, 0, room));
    }
    return utf8.decode(b.takeBytes(), allowMalformed: true);
  }

  final outs = await Future.wait([read(stdout), read(stderr)]).timeout(kMoshBootstrapTimeout);
  await done.timeout(const Duration(seconds: 2), onTimeout: () {});
  return (stdout: outs[0], stderr: outs[1], exitCode: exitCode());
}
