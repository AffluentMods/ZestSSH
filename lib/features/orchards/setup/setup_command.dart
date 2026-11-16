import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_runner.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

// The setup file from a terminal (3.0): what follows "admin" on
// the app's own command line, and what running it does and says. It does
// what the Team page's "Setup file" does, with the account signed in on
// this computer and its keys; the app starts as ever (and asks to be
// unlocked where it is locked), runs the one command, and ends with a code
// a script can read.

/// How a run ended.
abstract final class AdminExit {
  /// All is as the file says, or was made so; the Orchard was written.
  static const ok = 0;

  /// It could not run: the command is not one, a file could not be read
  /// or written, no Orchard to work on, the Orchard could not be read.
  static const failed = 1;

  /// plan: there are changes to make, and nothing in their way.
  static const changes = 2;

  /// Something stands in the way: nothing of the file is applied.
  static const inTheWay = 3;

  /// apply: it stopped at a step. What was made before it stays.
  static const stopped = 4;
}

enum AdminVerb { export, plan, apply }

/// A command as it was typed.
class AdminCommand {
  const AdminCommand({required this.verb, required this.file, this.orchard, this.out, this.waitSeconds = kAdminWait});

  final AdminVerb verb;

  /// The setup file: read by plan and apply, written by export.
  final String file;

  /// Which Orchard, by name; null to go by the file's own word, or by the
  /// one Orchard this device holds.
  final String? orchard;

  /// Where what was said is also written.
  final String? out;

  /// How long to wait for the app to be unlocked and signed in.
  final int waitSeconds;
}

/// How long a command waits for the app to be ready, unless it says.
const int kAdminWait = 120;

/// The longest wait a command may ask for: a day.
const int kAdminMaxWait = 86400;

/// What was typed, read: a command, a call for help, or what was not
/// understood ([unknown]: the word itself; empty when something is missing).
class AdminParse {
  const AdminParse.command(AdminCommand this.command)
      : help = false,
        unknown = null;
  const AdminParse.help()
      : command = null,
        help = true,
        unknown = null;
  const AdminParse.unknown(String this.unknown)
      : command = null,
        help = false;

  final AdminCommand? command;
  final bool help;
  final String? unknown;
}

/// Reads what follows "admin" on the command line:
/// `export|plan|apply FILE [--orchard NAME] [--out FILE] [--wait SECONDS]`,
/// the options in any place.
AdminParse parseAdminCommand(List<String> args) {
  if (args.isEmpty) return const AdminParse.help();
  if (args.any((a) => a == 'help' || a == '--help' || a == '-h')) return const AdminParse.help();
  final verb = AdminVerb.values.where((v) => v.name == args.first).firstOrNull;
  if (verb == null) return AdminParse.unknown(args.first);
  String? file, orchard, out;
  var wait = kAdminWait;
  for (var i = 1; i < args.length; i++) {
    final a = args[i];
    if (a == '--orchard' || a == '--out' || a == '--wait') {
      if (i + 1 >= args.length) return AdminParse.unknown(a);
      final value = args[++i];
      if (value.trim().isEmpty) return AdminParse.unknown(a);
      switch (a) {
        case '--orchard':
          orchard = value;
        case '--out':
          out = value;
        default:
          final seconds = int.tryParse(value);
          if (seconds == null || seconds < 0 || seconds > kAdminMaxWait) return AdminParse.unknown('$a $value');
          wait = seconds;
      }
    } else if (a.startsWith('--')) {
      return AdminParse.unknown(a);
    } else if (file == null) {
      file = a;
    } else {
      return AdminParse.unknown(a);
    }
  }
  if (file == null || file.trim().isEmpty) return const AdminParse.unknown('');
  return AdminParse.command(AdminCommand(verb: verb, file: file, orchard: orchard, out: out, waitSeconds: wait));
}

/// How the command is used, for someone who typed it wrong or asked.
List<String> adminUsage(AppLocalizations l10n, {String program = 'zestssh'}) => [
      l10n.setupCliUsageLine('$program admin export|plan|apply FILE [--orchard NAME] [--out FILE] [--wait SECONDS]'),
      '  ${l10n.setupCliUsageExport}',
      '  ${l10n.setupCliUsagePlan}',
      '  ${l10n.setupCliUsageApply}',
      '  ${l10n.setupCliUsageOrchard}',
      '  ${l10n.setupCliUsageOut}',
      '  ${l10n.setupCliUsageWait}',
      l10n.setupCliUsageCodes,
    ];

/// What a run said, and the code it ends with.
class AdminResult {
  const AdminResult(this.code, this.lines);

  final int code;
  final List<String> lines;

  String get text => lines.join('\n');
}

/// An Orchard this device holds that this account can use.
typedef AdminOrchard = ({String id, String name});

/// Runs [command] and returns what to say and how it ended.
///
/// [orchards] lists the Orchards to choose among; [runner] reads the one
/// chosen and makes the steps; [readFile] and [writeFile] reach the setup
/// file. [progress] is told each line as it comes, for a terminal that
/// shows a long apply while it runs.
Future<AdminResult> runAdminCommand(
  AdminCommand command, {
  required Future<List<AdminOrchard>> Function() orchards,
  required SetupRunner runner,
  required AppLocalizations l10n,
  required Future<String> Function(String path) readFile,
  required Future<void> Function(String path, String text) writeFile,
  void Function(String line)? progress,
}) async {
  final lines = <String>[];
  void say(String line) {
    lines.add(line);
    progress?.call(line);
  }

  AdminResult end(int code) => AdminResult(code, lines);

  // The file first: one that does not read is said before anything is asked
  // of the Orchard.
  SetupFile? file;
  if (command.verb != AdminVerb.export) {
    final String text;
    try {
      text = await readFile(command.file);
    } catch (_) {
      say(l10n.setupCliCannotRead(command.file));
      return end(AdminExit.failed);
    }
    final read = readSetupFile(text);
    if (!read.ok) {
      say(l10n.setupFileChosen(command.file));
      say(l10n.setupFileProblemsTitle);
      for (final p in read.problems) {
        say('  ! ${setupFileProblemWords(p, l10n)}');
      }
      return end(AdminExit.failed);
    }
    file = read.file;
  }

  // Which Orchard: the one named, else the one the file is for, else the
  // only one here.
  final List<AdminOrchard> all;
  try {
    all = await orchards();
  } catch (e) {
    say(setupErrorWords(e, l10n));
    return end(AdminExit.failed);
  }
  final wanted = command.orchard ?? file?.orchard;
  final AdminOrchard orchard;
  if (wanted != null) {
    final called = [
      for (final o in all)
        if (setupNameKey(o.name) == setupNameKey(wanted)) o,
    ];
    if (called.length != 1) {
      say(called.isEmpty ? l10n.setupCliNoOrchard(wanted) : l10n.setupCliManyOrchards(wanted));
      return end(AdminExit.failed);
    }
    orchard = called.single;
  } else if (all.length == 1) {
    orchard = all.single;
  } else {
    say(all.isEmpty
        ? l10n.setupCliNoOrchards
        : l10n.setupCliWhichOrchard([for (final o in all) o.name].join(l10n.listSeparator)));
    return end(AdminExit.failed);
  }
  say(l10n.setupCliOrchard(orchard.name));

  final OrchardSnapshot now;
  try {
    now = await runner.snapshot(orchard.id);
  } catch (e) {
    say(setupErrorWords(e, l10n));
    return end(AdminExit.failed);
  }

  if (command.verb == AdminVerb.export) {
    final export = exportSetup(now);
    try {
      await writeFile(command.file, export.text);
    } catch (_) {
      say(l10n.setupCliCannotWrite(command.file));
      return end(AdminExit.failed);
    }
    say(l10n.setupCliExported(command.file));
    if (export.leftOut.isNotEmpty) {
      say(l10n.setupLeftOutTitle);
      for (final x in export.leftOut) {
        say('  - ${setupLeftOutWords(x, l10n)}');
      }
    }
    return end(AdminExit.ok);
  }

  say(l10n.setupFileChosen(command.file));
  final plan = await planSetup(file!, now);
  for (final line in setupPlanText(plan, l10n).split('\n')) {
    say(line);
  }
  if (!plan.canApply) return end(AdminExit.inTheWay);
  if (plan.steps.isEmpty) return end(AdminExit.ok);
  // The first change in a team of a kind older versions cannot read (a
  // member's limit) is an owner's, after a question about those
  // versions that the app asks and a terminal cannot: until an owner made
  // one there, it stands in the way here, for plan as for apply.
  if (plan.writesNewKinds && !now.record.newKindsUsed) {
    say(l10n.setupCliNewKindsInApp(kNewRecordKindsVersion));
    return end(AdminExit.inTheWay);
  }
  // Said before anything is made: a terminal cannot ask for a sign-in, so
  // whoever runs this knows why it may stop where it does.
  if (plan.needsRecentSignIn) say(l10n.setupCliNeedsSignIn);
  if (command.verb == AdminVerb.plan) return end(AdminExit.changes);

  final outcome = await applySetup(
    plan,
    now,
    runner.actions(orchard.id),
    onStep: (step, i) =>
        say(l10n.setupPair(l10n.setupApplying(i + 1, plan.steps.length), setupStepWords(step, l10n).title)),
  );
  final failed = outcome.failed;
  if (failed == null) {
    say(l10n.setupDone(outcome.done.length));
    if (outcome.syncError != null) say(l10n.setupSyncLater);
    return end(AdminExit.ok);
  }
  final error = outcome.error ?? '';
  say(l10n.setupStoppedAt(setupStepWords(failed, l10n).title));
  say('  ! ${setupErrorWords(error, l10n)}');
  if (error is OrchardServerException && error.recentSignInRequired) say('  ${l10n.setupCliSignInFirst}');
  say(l10n.setupStopped(outcome.done.length, outcome.left.length));
  return end(AdminExit.stopped);
}
