import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/setup/setup_command.dart';
import 'package:zestssh/features/orchards/setup/setup_runner.dart';
import 'package:zestssh/features/orchards/setup/setup_terminal.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

// The app started with "admin ..." (3.0): the setup file's command
// line. The app starts as it always does, so its lock screen stands in
// front of everything a locked app holds; once it is unlocked and signed
// in, the one command runs, what it says goes to the terminal (and to the
// file --out names), and the app ends with the command's code.

/// The words for a terminal before the app chose its language: the
/// system's language where the app speaks it, English otherwise.
AppLocalizations adminWordsFor(String localeName) {
  final code = localeName.split(RegExp('[_.@-]')).first.toLowerCase();
  final speaks = AppLocalizations.supportedLocales.any((l) => l.languageCode == code);
  return lookupAppLocalizations(Locale(speaks ? code : 'en'));
}

/// What holds a command back: the app cannot run it yet.
enum AdminHold {
  /// The app is locked, or was not unlocked yet since it started.
  locked,

  /// No account is signed in, or this account's keys are not on this
  /// device (yet).
  signedOut,

  /// Whether an account is signed in could not be asked: ZestSSH Cloud was
  /// not reached.
  unreachable,
}

/// Asks [held] every [every] until nothing holds the command (null), for
/// [within] at most. Null when that came in time; what held it at the last
/// ask otherwise. A check that fails counts as not reached. [onWaiting] is
/// told once, when the first answer is a hold and there is time to wait.
Future<AdminHold?> waitUntilReady(
  Future<AdminHold?> Function() held, {
  required Duration within,
  Duration every = const Duration(milliseconds: 500),
  Future<void> Function(Duration) sleep = _sleep,
  DateTime Function() clock = DateTime.now,
  void Function()? onWaiting,
}) async {
  final until = clock().add(within);
  var said = false;
  while (true) {
    AdminHold? hold;
    try {
      hold = await held();
    } catch (_) {
      hold = AdminHold.unreachable;
    }
    if (hold == null) return null;
    if (!clock().isBefore(until)) return hold;
    if (!said) {
      said = true;
      onWaiting?.call();
    }
    await sleep(every);
  }
}

/// What a command that was held back for all of its wait says.
String adminHoldWords(AdminHold hold, AppLocalizations l10n) => switch (hold) {
      AdminHold.locked => l10n.setupCliNotUnlocked,
      AdminHold.signedOut => l10n.setupCliNotSignedIn,
      AdminHold.unreachable => l10n.setupCliNoCloud,
    };

Future<void> _sleep(Duration d) => Future<void>.delayed(d);

/// What was typed is not a command: says how it is used. Null when it is
/// one (the app then starts, and runs it). Called before anything of the
/// app is started, so that a slip of the keyboard opens no window.
AdminResult? adminUsageResult(List<String> args, AppLocalizations l10n, {String program = 'zestssh'}) {
  final parsed = parseAdminCommand(args);
  if (parsed.command != null) return null;
  final unknown = parsed.unknown;
  return AdminResult(parsed.help ? AdminExit.ok : AdminExit.failed, [
    if (unknown != null && unknown.isNotEmpty) l10n.setupCliBadArgument(unknown),
    ...adminUsage(l10n, program: program),
  ]);
}

/// Runs the command of [args] once [held] says nothing holds it (the app is
/// unlocked and signed in), says what came of it through [out] (and into
/// the file --out names), and returns the code to end with.
Future<int> runAdminHosted(
  List<String> args, {
  required AppLocalizations Function() words,
  required Future<AdminHold?> Function() held,
  required Future<List<AdminOrchard>> Function() orchards,
  required SetupRunner Function() runner,
  required Future<String> Function(String path) readFile,
  required Future<void> Function(String path, String text) writeFile,
  required void Function(String line) out,
  String program = 'zestssh',
  Future<void> Function(Duration) sleep = _sleep,
  DateTime Function() clock = DateTime.now,
}) async {
  final usage = adminUsageResult(args, words(), program: program);
  if (usage != null) {
    usage.lines.forEach(out);
    return usage.code;
  }
  final command = parseAdminCommand(args).command!;
  final said = <String>[];
  void say(String line) {
    said.add(line);
    out(line);
  }

  var code = AdminExit.failed;
  final hold = await waitUntilReady(
    held,
    within: Duration(seconds: command.waitSeconds),
    sleep: sleep,
    clock: clock,
    onWaiting: () => say(words().setupCliWaiting('${command.waitSeconds}')),
  );
  if (hold != null) {
    say(adminHoldWords(hold, words()));
  } else {
    try {
      final result = await runAdminCommand(
        command,
        orchards: orchards,
        runner: runner(),
        l10n: words(),
        readFile: readFile,
        writeFile: writeFile,
        progress: say,
      );
      code = result.code;
    } catch (e) {
      // Nothing a command meets should come here; one that does ends as
      // "could not run", with what it was.
      AppLogger.warning('Setup file: the command failed (${errorKind(e)})');
      say(words().setupCliFailed('$e'));
    }
  }
  final outFile = command.out;
  if (outFile != null) {
    try {
      await writeFile(outFile, '${said.join('\n')}\n');
    } catch (_) {
      out(words().setupCliCannotWrite(outFile));
      if (code == AdminExit.ok) code = AdminExit.failed;
    }
  }
  return code;
}

/// The name this program was started by, for the usage line.
String adminProgramName() {
  final path = Platform.resolvedExecutable;
  final name = path.split(RegExp(r'[\\/]')).last;
  return name.toLowerCase().endsWith('.exe') ? name.substring(0, name.length - 4) : name;
}

void _print(String line) {
  try {
    stdout.writeln(line);
  } catch (_) {
    // No terminal to write to (started from a shortcut): --out has it.
  }
}

/// Whether this run of the app was started for a command (`zestssh admin
/// ...`): it runs the command and ends. Such a run leaves the tabs saved at
/// the last close alone: it opened every one of them (dialling those hosts)
/// and then cleared the saved copy, so the next ordinary start had no tabs
/// to bring back.
bool startedForACommand = false;

/// Whether the tabs saved at the last close come back at this start: not in
/// a run for a command ([startedForACommand]).
bool restoresSavedTabsAtStart() => !startedForACommand;

/// Before the app starts: points the app's output at the terminal it was
/// started from, and, when [args] (what follows "admin") is not a command,
/// says how it is used and ends the program.
Future<void> startAdminCommandLine(List<String> args) async {
  AdminTerminal.open();
  final usage = adminUsageResult(args, adminWordsFor(Platform.localeName), program: adminProgramName());
  if (usage == null) {
    startedForACommand = true;
    return;
  }
  usage.lines.forEach(_print);
  await _endWith(usage.code);
}

/// ZestSSH is open on this computer (it holds AppInstanceLock): the command
/// does not run beside it, which ran sync and the team rounds a second time
/// on the same data.
Future<void> endAdminBesideOpenApp() async {
  _print(adminWordsFor(Platform.localeName).setupCliAppOpen);
  await _endWith(AdminExit.failed);
}

/// The app could not open its own data (it says why on its own screen when
/// it is started without a command): the command cannot run.
Future<void> endAdminWithoutData() async {
  _print(adminWordsFor(Platform.localeName).setupCliNoData);
  await _endWith(AdminExit.failed);
}

/// Once the app is up: runs the command of [args] with the app's own
/// services from [container], and ends the program with its code.
Future<void> runAdminFromCommandLine(ProviderContainer container, List<String> args) async {
  final code = await runAdminHosted(
    args,
    words: () => gl10n,
    held: () async {
      if (container.read(databaseSessionProvider) == null || container.read(isAppLockedProvider)) {
        return AdminHold.locked;
      }
      // (Asking for the account's keys throws when ZestSSH Cloud is not
      // reached, which the wait takes for exactly that.)
      return await container.read(orchardAuthorProvider).call() == null ? AdminHold.signedOut : null;
    },
    orchards: () async {
      try {
        await container.read(orchardServiceProvider).refresh();
      } catch (e) {
        // Not reached: the Orchards as this device has them.
        AppLogger.info('Setup file: ZestSSH Cloud was not reached (${errorKind(e)})');
      }
      final all = await container.refresh(orchardSummariesProvider.future);
      return [
        for (final o in all)
          if (o.active && o.name != null) (id: o.id, name: o.name!),
      ];
    },
    runner: () => container.read(setupRunnerProvider),
    readFile: (path) => File(path).readAsString(),
    writeFile: (path, text) => File(path).writeAsString(text, flush: true),
    out: _print,
    program: adminProgramName(),
  );
  await _endWith(code);
}

Future<Never> _endWith(int code) async {
  try {
    await stdout.flush();
  } catch (_) {
    // Nothing to flush to.
  }
  AdminTerminal.close();
  exit(code);
}
