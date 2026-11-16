import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_command.dart';
import 'package:zestssh/features/orchards/setup/setup_command_host.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_reader.dart';
import 'package:zestssh/features/orchards/setup/setup_runner.dart';
import 'package:zestssh/features/orchards/setup/setup_terminal.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion, newRecordKindsOn;
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'setup_world.dart';

// The setup file from a terminal (3.0): what follows "admin" on the
// app's command line, what each command does with the real Orchard service,
// what it says, and the code it ends with. How the words reach a terminal
// and how the program ends are tried with a program of their own; here the
// command is run the way the app runs it once it is up.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final l10n = lookupAppLocalizations(const Locale('en'));

  AdminCommand? typed(List<String> args) => parseAdminCommand(args).command;
  String? notUnderstood(List<String> args) => parseAdminCommand(args).unknown;

  group('what was typed', () {
    test('a command is export, plan or apply, and a file', () {
      for (final verb in AdminVerb.values) {
        final c = typed([verb.name, 'setup.json'])!;
        expect(c.verb, verb);
        expect(c.file, 'setup.json');
        expect(c.orchard, isNull);
        expect(c.out, isNull);
        expect(c.waitSeconds, 120);
        expect(parseAdminCommand([verb.name, 'setup.json']).help, isFalse);
      }
    });

    test('the options stand anywhere after it', () {
      final a = typed(['apply', 'setup.json', '--orchard', 'Northwind Ops', '--out', 'said.txt', '--wait', '5'])!;
      final b = typed(['apply', '--wait', '5', '--out', 'said.txt', 'setup.json', '--orchard', 'Northwind Ops'])!;
      for (final c in [a, b]) {
        expect(c.verb, AdminVerb.apply);
        expect(c.file, 'setup.json');
        expect(c.orchard, 'Northwind Ops');
        expect(c.out, 'said.txt');
        expect(c.waitSeconds, 5);
      }
      // A path with blanks is one word when it was typed in quotes.
      expect(typed(['plan', r'C:\Teams\Northwind Ops\setup.json'])!.file, r'C:\Teams\Northwind Ops\setup.json');
    });

    test('how long to wait is a number of seconds, none to a day', () {
      expect(typed(['plan', 'a.json', '--wait', '0'])!.waitSeconds, 0);
      expect(typed(['plan', 'a.json', '--wait', '86400'])!.waitSeconds, 86400);
      expect(notUnderstood(['plan', 'a.json', '--wait', '86401']), '--wait 86401');
      expect(notUnderstood(['plan', 'a.json', '--wait', '-1']), '--wait -1');
      expect(notUnderstood(['plan', 'a.json', '--wait', 'soon']), '--wait soon');
      expect(notUnderstood(['plan', 'a.json', '--wait', '1.5']), '--wait 1.5');
    });

    test('asking for help, in any place, is asking for help', () {
      for (final args in [
        <String>[],
        ['help'],
        ['--help'],
        ['-h'],
        ['plan', 'setup.json', '--help'],
        ['plan', '-h'],
        ['destroy', 'help'],
      ]) {
        final parsed = parseAdminCommand(args);
        expect(parsed.help, isTrue, reason: '$args');
        expect(parsed.command, isNull);
        expect(parsed.unknown, isNull);
      }
    });

    test('what is not understood is said, by the word that was not', () {
      expect(notUnderstood(['destroy', 'setup.json']), 'destroy');
      expect(notUnderstood(['Plan', 'setup.json']), 'Plan', reason: 'the commands are written small');
      expect(notUnderstood(['plan', 'a.json', 'b.json']), 'b.json');
      expect(notUnderstood(['plan', 'a.json', '--force']), '--force');
      // An option it does not know is never taken for the file: nothing is
      // read from, or written to, a file called like one.
      expect(notUnderstood(['plan', '--force', 'a.json']), '--force');
      expect(notUnderstood(['export', '--force']), '--force');
      expect(typed(['export', '--force']), isNull);
      expect(notUnderstood(['apply', '--', 'a.json']), '--');
      expect(notUnderstood(['plan', '--orchard']), '--orchard');
      expect(notUnderstood(['plan', 'a.json', '--out']), '--out');
      expect(notUnderstood(['plan', 'a.json', '--orchard', '  ']), '--orchard');
      for (final args in [
        ['plan'],
        ['apply', '--orchard', 'Northwind Ops'],
        ['export', '   '],
      ]) {
        final parsed = parseAdminCommand(args);
        expect(parsed.unknown, '', reason: '$args: the file is missing');
        expect(parsed.command, isNull);
        expect(parsed.help, isFalse);
      }
    });
  });

  group('how it is used', () {
    test('is said in full, with the program\'s own name', () {
      final usage = adminUsage(l10n, program: 'zestssh');
      expect(usage.first,
          'Usage: zestssh admin export|plan|apply FILE [--orchard NAME] [--out FILE] [--wait SECONDS]');
      expect(usage, hasLength(8));
      expect(usage.sublist(1, 7).every((line) => line.startsWith('  ')), isTrue);
      expect(usage[1], '  ${l10n.setupCliUsageExport}');
      expect(usage[2], '  ${l10n.setupCliUsagePlan}');
      expect(usage[3], '  ${l10n.setupCliUsageApply}');
      expect(usage[4], '  ${l10n.setupCliUsageOrchard}');
      expect(usage[5], '  ${l10n.setupCliUsageOut}');
      expect(usage[6], '  ${l10n.setupCliUsageWait}');
      expect(usage.last, l10n.setupCliUsageCodes);
      expect(adminUsage(l10n, program: 'ZestSSH').first, startsWith('Usage: ZestSSH admin '));
      // Each code the last line names is a code a run can end with.
      for (final code in [AdminExit.ok, AdminExit.failed, AdminExit.changes, AdminExit.inTheWay, AdminExit.stopped]) {
        expect(usage.last, contains(' $code '), reason: 'code $code');
      }
      expect({AdminExit.ok, AdminExit.failed, AdminExit.changes, AdminExit.inTheWay, AdminExit.stopped},
          {0, 1, 2, 3, 4});
    });

    test('to someone who asked, and to someone who typed something else', () {
      expect(adminUsageResult(['plan', 'setup.json'], l10n), isNull, reason: 'a command is run, not explained');

      final asked = adminUsageResult(['--help'], l10n)!;
      expect(asked.code, AdminExit.ok);
      expect(asked.lines, adminUsage(l10n));
      expect(asked.text, adminUsage(l10n).join('\n'));

      final wrong = adminUsageResult(['destroy', 'setup.json'], l10n, program: 'zestssh')!;
      expect(wrong.code, AdminExit.failed);
      expect(wrong.lines, ['Not understood: destroy', ...adminUsage(l10n)]);

      final noFile = adminUsageResult(['plan'], l10n)!;
      expect(noFile.code, AdminExit.failed);
      expect(noFile.lines, adminUsage(l10n), reason: 'nothing was typed wrong: something is missing');

      // The program is named as it was started, whatever its file is called.
      final renamed = adminUsageResult(['destroy'], l10n, program: 'ZestSSH-nightly')!;
      expect(renamed.lines, ['Not understood: destroy', ...adminUsage(l10n, program: 'ZestSSH-nightly')]);
      expect(renamed.lines[1], startsWith('Usage: ZestSSH-nightly admin '));
      expect(adminUsageResult(['help'], l10n, program: 'ZestSSH-nightly')!.lines.first,
          startsWith('Usage: ZestSSH-nightly admin '));
    });

    test('in the language of the system where the app speaks it, in English elsewhere', () {
      expect(adminWordsFor('de_DE').setupCliUsageLine('x'), 'Aufruf: x');
      expect(adminWordsFor('de').localeName, 'de');
      expect(adminWordsFor('pt-BR').localeName, 'pt');
      expect(adminWordsFor('zh_Hans_CN').localeName, 'zh');
      expect(adminWordsFor('JA_jp.UTF-8').localeName, 'ja');
      expect(adminWordsFor('fr_CA@euro').localeName, 'fr');
      for (final other in ['nl_NL', 'C', 'POSIX', '', 'xx']) {
        expect(adminWordsFor(other).localeName, 'en', reason: other);
      }
      for (final language in AppLocalizations.supportedLocales) {
        expect(adminWordsFor(language.languageCode).localeName, language.languageCode);
      }
    });

    test('the program is called by its file, without the folders it is in', () {
      final name = adminProgramName();
      expect(name, isNotEmpty);
      expect(name.contains('/') || name.contains(r'\'), isFalse);
      expect(name.toLowerCase().endsWith('.exe'), isFalse);
      expect(Platform.resolvedExecutable.toLowerCase(), contains(name.toLowerCase()));
    });

    test('a program started with its output sent elsewhere leaves the terminal alone', () {
      // (The tests' own output goes into a pipe, as a command's does when a
      // script takes it.)
      expect(AdminTerminal.open(), isFalse);
      AdminTerminal.close();
      expect(AdminTerminal.open(), isFalse);
    });
  });

  group('a command, run', () {
    late SetupWorld world;
    late SetupDevice owner;
    late ({String id, String production, String staging, String members}) o;
    late Map<String, String> files;
    late int asked;

    setUpAll(SetupWorld.makeKeys);

    setUp(() async {
      world = SetupWorld();
      await world.start();
      owner = world.device(SetupWorld.owner);
      o = await world.orchard(owner);
      files = {};
      asked = 0;
    });

    tearDown(() => world.stop());

    SetupRunner runnerOf(SetupDevice d) => SetupRunner(snapshot: (id) => d.snapshot(id), actions: d.actions);

    Future<String> read(String path) async => files[path] ?? (throw FileSystemException('no such file', path));

    Future<void> write(String path, String text) async {
      if (path.startsWith('readonly/')) throw FileSystemException('cannot write', path);
      files[path] = text;
    }

    void put(String path, Map<String, Object?> body) => files[path] = jsonEncode({kSetupFileMarker: 1, ...body});

    Future<AdminResult> run(
      List<String> args, {
      SetupDevice? device,
      List<AdminOrchard>? orchards,
      SetupRunner? runner,
      List<String>? progress,
    }) =>
        runAdminCommand(
          typed(args)!,
          orchards: () async {
            asked++;
            return orchards ?? [(id: o.id, name: 'Northwind Ops')];
          },
          runner: runner ?? runnerOf(device ?? owner),
          l10n: l10n,
          readFile: read,
          writeFile: write,
          progress: progress?.add,
        );

    Future<SetupPlan> planOf(String path) async =>
        planSetup(readSetupFile(files[path]!).file!, await owner.snapshot(o.id));

    const changes = {
      'crates': [
        {'name': 'Lab'},
        {
          'name': 'Production',
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11'},
          ],
        },
      ],
    };

    group('export', () {
      test('writes the Orchard to the file, which reads and changes nothing where it came from', () async {
        final result = await run(['export', 'northwind.json']);
        expect(result.code, AdminExit.ok);
        expect(result.lines, ['Team: Northwind Ops', 'Saved to northwind.json']);
        expect(files['northwind.json'], exportSetup(await owner.snapshot(o.id)).text);
        final back = readSetupFile(files['northwind.json']!);
        expect(back.problems, isEmpty);
        expect(back.file!.orchard, 'Northwind Ops');

        final plan = await run(['plan', 'northwind.json']);
        expect(plan.code, AdminExit.ok);
        expect(plan.lines, ['Team: Northwind Ops', 'File: northwind.json', l10n.setupPlanNothing]);
      });

      test('says what the file does not hold, for someone who cannot see all of it', () async {
        final ada = world.device(SetupWorld.ada);
        await world.join(owner, ada, o.id, o.members);
        final result = await run(['export', 'mine.json'], device: ada);
        expect(result.code, AdminExit.ok);
        final leftOut = exportSetup(await ada.snapshot(o.id)).leftOut;
        expect(leftOut, isNotEmpty);
        expect(result.lines, [
          'Team: Northwind Ops',
          'Saved to mine.json',
          l10n.setupLeftOutTitle,
          for (final x in leftOut) '  - ${setupLeftOutWords(x, l10n)}',
        ]);
      });

      test('a file that cannot be written is said, and nothing else is', () async {
        final result = await run(['export', 'readonly/northwind.json']);
        expect(result.code, AdminExit.failed);
        expect(result.lines, ['Team: Northwind Ops', 'readonly/northwind.json could not be written.']);
        expect(files, isEmpty);
      });
    });

    group('plan', () {
      test('says what the file would change, changes nothing, and ends with 2', () async {
        put('setup.json', changes);
        final before = world.server.recordOf(o.id).seq;
        final result = await run(['plan', 'setup.json']);
        expect(result.code, AdminExit.changes);
        final plan = await planOf('setup.json');
        expect(plan.steps, hasLength(2));
        expect(result.lines, [
          'Team: Northwind Ops',
          'File: setup.json',
          ...setupPlanText(plan, l10n).split('\n'),
        ]);
        expect(result.lines, contains('  + ${setupStepWords(plan.steps.first, l10n).title}'));
        expect(world.server.recordOf(o.id).seq, before);
        expect(await owner.hosts(o.id), isEmpty);
      });

      test('says so when some changes need a recent sign-in', () async {
        put('setup.json', {
          'crates': [
            {'name': 'Production', 'ask_again': true},
          ],
        });
        final result = await run(['plan', 'setup.json']);
        expect(result.code, AdminExit.changes);
        expect((await planOf('setup.json')).needsRecentSignIn, isTrue);
        expect(result.lines.last, l10n.setupCliNeedsSignIn);

        // Adding a Crate and a host needs none, and nothing is said of it.
        put('plain.json', changes);
        expect((await planOf('plain.json')).needsRecentSignIn, isFalse);
        expect((await run(['plan', 'plain.json'])).lines, isNot(contains(l10n.setupCliNeedsSignIn)));
      });

      test('ends with 3 when something stands in the way, and apply makes nothing of such a file', () async {
        put('setup.json', {
          'crates': [
            {'name': 'Lab'},
            {
              'name': 'Production',
              'hosts': [
                {'name': 'web-1'},
              ],
            },
          ],
        });
        final plan = await planOf('setup.json');
        expect(plan.problems, isNotEmpty);
        final before = world.server.recordOf(o.id).seq;
        for (final verb in ['plan', 'apply']) {
          final result = await run([verb, 'setup.json']);
          expect(result.code, AdminExit.inTheWay, reason: verb);
          expect(result.lines, [
            'Team: Northwind Ops',
            'File: setup.json',
            ...setupPlanText(plan, l10n).split('\n'),
          ]);
          expect(result.lines[2], l10n.setupPlanInTheWay(plan.problems.length));
        }
        expect(world.server.recordOf(o.id).seq, before, reason: 'not even the Crate that could be added');
      });
    });

    group('apply', () {
      test('makes the changes, says each as it is made, and ends with 0; again, there is nothing to do', () async {
        put('setup.json', changes);
        final plan = await planOf('setup.json');
        final titles = [for (final s in plan.steps) setupStepWords(s, l10n).title];
        final progress = <String>[];
        final result = await run(['apply', 'setup.json'], progress: progress);
        expect(result.code, AdminExit.ok);
        expect(result.lines, [
          'Team: Northwind Ops',
          'File: setup.json',
          ...setupPlanText(plan, l10n).split('\n'),
          '1 of 2: ${titles[0]}',
          '2 of 2: ${titles[1]}',
          '2 changes made.',
        ]);
        expect(progress, result.lines, reason: 'each line is said as it comes');
        expect((await world.record(owner, o.id)).where((line) => line.startsWith('crate Lab')), hasLength(1));
        expect(await owner.hosts(o.id), ['Production/web-1 10.50.0.11:22 ssh key=null group=null tags=']);

        final again = await run(['apply', 'setup.json']);
        expect(again.code, AdminExit.ok);
        expect(again.lines, [
          'Team: Northwind Ops',
          'File: setup.json',
          ...setupPlanText(await planOf('setup.json'), l10n).split('\n'),
        ]);
        expect(again.lines[2], l10n.setupPlanNothing);
        expect(again.lines, contains('  - The vault Staging is not in the file. It stays as it is.'),
            reason: 'what the file leaves alone is still said');
      });

      test('stops at the change the server refuses, says why and what to do, and ends with 4', () async {
        put('setup.json', {
          'crates': [
            {'name': 'Lab', 'ask_again': true},
            {'name': 'Production', 'ask_again': true},
          ],
        });
        final plan = await planOf('setup.json');
        final titles = [for (final s in plan.steps) setupStepWords(s, l10n).title];
        expect(titles, hasLength(3));
        // A sign-in from the last few minutes is wanted for a change to what
        // a Crate asks; adding one needs none.
        world.server.requireRecentSignIn = true;
        final result = await run(['apply', 'setup.json']);
        expect(result.code, AdminExit.stopped);
        final said = result.lines.sublist(2 + setupPlanText(plan, l10n).split('\n').length);
        expect(said.first, l10n.setupCliNeedsSignIn, reason: 'said before anything is made');
        expect(said.sublist(1, 3), ['1 of 3: ${titles[0]}', '2 of 3: ${titles[1]}']);
        expect(said[3], 'Stopped at: ${titles[1]}');
        expect(said[4], '  ! ZestSSH Cloud takes this change only after a sign-in from the last two hours.');
        expect(said[5], '  Sign in again in ZestSSH on this computer, then run this again.');
        expect(said[6], l10n.setupStopped(1, 1));
        expect(said, hasLength(7));
        // What was made before it stays; the same file goes on from there.
        expect((await world.record(owner, o.id)).where((line) => line.startsWith('crate Lab')), hasLength(1));
        world.server.requireRecentSignIn = false;
        final again = await run(['apply', 'setup.json']);
        expect(again.code, AdminExit.ok);
        expect(again.lines.last, '2 changes made.');
      });

      test('a refusal that is not about the sign-in does not ask for one', () async {
        put('setup.json', changes);
        world.server.failOrchards = false;
        final failing = _FailingActions(owner.actions(o.id), failAt: 1);
        final result = await run(['apply', 'setup.json'],
            runner: SetupRunner(snapshot: (id) => owner.snapshot(id), actions: (_) => failing));
        expect(result.code, AdminExit.stopped);
        expect(result.lines, isNot(contains('  ${l10n.setupCliSignInFirst}')));
        expect(result.lines.last, l10n.setupStopped(1, 0));
        expect(result.lines[result.lines.length - 2], '  ! ${setupErrorWords(failing.error, l10n)}');
      });

      test('hosts that are saved here and did not reach ZestSSH Cloud are said', () async {
        put('setup.json', changes);
        final offline = _FailingActions(owner.actions(o.id), syncFails: true);
        final result = await run(['apply', 'setup.json'],
            runner: SetupRunner(snapshot: (id) => owner.snapshot(id), actions: (_) => offline));
        expect(result.code, AdminExit.ok);
        expect(result.lines.sublist(result.lines.length - 2), ['2 changes made.', l10n.setupSyncLater]);
      });
    });

    group("a member's limits", () {
      test("the team's first change of a new kind is not made from a terminal: an owner makes it in the app, and "
          'after that a terminal goes on', () async {
        final ada = world.device(SetupWorld.ada);
        await world.join(owner, ada, o.id, o.members);
        put('setup.json', {
          'members': [
            {
              'email': SetupWorld.emailOf(SetupWorld.ada),
              'limits': {'Production': 'connect'},
            },
          ],
        });
        final plan = await planOf('setup.json');
        expect(plan.problems, isEmpty);
        expect(plan.writesNewKinds, isTrue);
        final before = world.server.recordOf(o.id).seq;
        for (final verb in ['plan', 'apply']) {
          final result = await run([verb, 'setup.json']);
          expect(result.code, AdminExit.inTheWay, reason: verb);
          expect(result.lines, [
            'Team: Northwind Ops',
            'File: setup.json',
            ...setupPlanText(plan, l10n).split('\n'),
            l10n.setupCliNewKindsInApp(kNewRecordKindsVersion),
          ]);
        }
        expect(world.server.recordOf(o.id).seq, before, reason: 'nothing was made');
        // An owner made one in the app: a terminal goes on.
        await owner.service.setVaultAccess(o.id, SetupWorld.ada, {o.staging: VaultPick.none});
        expect((await run(['plan', 'setup.json'])).code, AdminExit.changes);
        final applied = await run(['apply', 'setup.json']);
        expect(applied.code, AdminExit.ok);
        expect(applied.lines, isNot(contains(l10n.setupCliNewKindsInApp(kNewRecordKindsVersion))));
        expect(world.server.recordOf(o.id).members[SetupWorld.ada]!.limits,
            {o.production: levelSwitches(CrateLevel.connect)});
      });

      test('while ZestSSH Cloud does not take them yet, a limit stands in the way, and nothing is made', () async {
        final ada = world.device(SetupWorld.ada);
        await world.join(owner, ada, o.id, o.members);
        world.server.newRecordKinds = false;
        addTearDown(() => newRecordKindsOn.value = true);
        put('setup.json', {
          'members': [
            {
              'email': SetupWorld.emailOf(SetupWorld.ada),
              'limits': {'Production': 'none'},
            },
          ],
        });
        final before = world.server.recordOf(o.id).seq;
        final result = await run(['apply', 'setup.json']);
        expect(result.code, AdminExit.inTheWay);
        final step = l10n.setupStepLimitNone('Production', SetupWorld.emailOf(SetupWorld.ada));
        expect(result.lines, contains('  ! ${l10n.setupPair(step, l10n.vaultAccessNotYet(kNewRecordKindsVersion))}'));
        expect(world.server.recordOf(o.id).seq, before);
      });
    });

    group('the file', () {
      test('that cannot be read is said before anything is asked of the Orchard', () async {
        for (final verb in ['plan', 'apply']) {
          final result = await run([verb, 'nowhere.json']);
          expect(result.code, AdminExit.failed);
          expect(result.lines, ['nowhere.json could not be read.']);
        }
        expect(asked, 0);
      });

      test('that is no setup file is said with everything wrong with it', () async {
        files['notes.json'] = '{"name": "notes", "crates": "many"}';
        final problems = readSetupFile(files['notes.json']!).problems;
        expect(problems, isNotEmpty);
        final result = await run(['plan', 'notes.json']);
        expect(result.code, AdminExit.failed);
        expect(result.lines, [
          'File: notes.json',
          l10n.setupFileProblemsTitle,
          for (final p in problems) '  ! ${setupFileProblemWords(p, l10n)}',
        ]);
        expect(asked, 0);

        files['broken.json'] = '{"zestssh_setup": 1, "crates": [';
        expect((await run(['apply', 'broken.json'])).code, AdminExit.failed);
        expect(asked, 0);
      });
    });

    group('which Orchard', () {
      const two = [
        (id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', name: 'Contoso Lab'),
      ];
      List<AdminOrchard> both() => [(id: o.id, name: 'Northwind Ops'), ...two];

      test('the only one this device holds, when nothing names one', () async {
        put('setup.json', {});
        final result = await run(['plan', 'setup.json']);
        expect(result.code, AdminExit.ok);
        expect(result.lines.first, 'Team: Northwind Ops');
      });

      test('the one the file is for, when the device holds more', () async {
        put('setup.json', {'orchard': 'northwind ops'});
        final result = await run(['plan', 'setup.json'], orchards: both());
        expect(result.code, AdminExit.ok);
        expect(result.lines.first, 'Team: Northwind Ops');
      });

      test('the one named with --orchard, in small or capital letters', () async {
        put('setup.json', {});
        final result = await run(['plan', 'setup.json', '--orchard', ' NORTHWIND OPS '], orchards: both());
        expect(result.code, AdminExit.ok);
        expect(result.lines.first, 'Team: Northwind Ops');
      });

      test('--orchard is whom the command is for; a file that is for another one is in its own way', () async {
        put('setup.json', {'orchard': 'Contoso Lab'});
        final result = await run(['plan', 'setup.json', '--orchard', 'Northwind Ops'], orchards: both());
        expect(result.lines.first, 'Team: Northwind Ops');
        expect(result.code, AdminExit.inTheWay);
        expect((await planOf('setup.json')).problems.single.kind, SetupProblemKind.otherOrchard);
      });

      test('none named and more than one here: it says which there are', () async {
        put('setup.json', {});
        final result = await run(['plan', 'setup.json'], orchards: both());
        expect(result.code, AdminExit.failed);
        expect(result.lines,
            ['This device holds more than one team. Say which with --orchard: Northwind Ops, Contoso Lab']);
      });

      test('none here, none of that name, or two of that name', () async {
        put('setup.json', {});
        var result = await run(['plan', 'setup.json'], orchards: []);
        expect(result.code, AdminExit.failed);
        expect(result.lines, [l10n.setupCliNoOrchards]);

        result = await run(['export', 'out.json', '--orchard', 'Fabrikam'], orchards: both());
        expect(result.code, AdminExit.failed);
        expect(result.lines, ['No team on this device is called Fabrikam.']);
        expect(files.containsKey('out.json'), isFalse);

        put('named.json', {'orchard': 'Fabrikam'});
        result = await run(['plan', 'named.json']);
        expect(result.code, AdminExit.failed);
        expect(result.lines, ['No team on this device is called Fabrikam.']);

        result = await run(['plan', 'setup.json', '--orchard', 'Northwind Ops'],
            orchards: [...both(), (id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', name: 'northwind ops')]);
        expect(result.code, AdminExit.failed);
        expect(result.lines, ['More than one team on this device is called Northwind Ops.']);
      });

      test('one that cannot be read from this account is said', () async {
        put('setup.json', {});
        final result = await run(['plan', 'setup.json', '--orchard', 'Contoso Lab'], orchards: both());
        expect(result.code, AdminExit.failed);
        expect(result.lines, ['Team: Contoso Lab', l10n.setupNotOpen]);
      });

      test('Orchards that cannot be listed are said', () async {
        put('setup.json', {});
        final result = await runAdminCommand(
          typed(['plan', 'setup.json'])!,
          orchards: () async => throw const SetupNotOpen('unknown'),
          runner: runnerOf(owner),
          l10n: l10n,
          readFile: read,
          writeFile: write,
        );
        expect(result.code, AdminExit.failed);
        expect(result.lines, [l10n.setupNotOpen]);
      });
    });

    group('by the app once it is up', () {
      /// A clock that only moves when the command waits.
      late DateTime now;
      late List<Duration> waits;
      late List<String> out;

      setUp(() {
        now = DateTime.utc(2026, 10, 2, 9);
        waits = [];
        out = [];
      });

      Future<AdminHold?> nothing() async => null;

      Future<int> hosted(
        List<String> args, {
        required Future<AdminHold?> Function() held,
        SetupRunner Function()? runner,
        List<AdminOrchard>? orchards,
      }) =>
          runAdminHosted(
            args,
            words: () => l10n,
            held: held,
            orchards: () async {
              asked++;
              return orchards ?? [(id: o.id, name: 'Northwind Ops')];
            },
            runner: runner ?? () => runnerOf(owner),
            readFile: read,
            writeFile: write,
            out: out.add,
            program: 'zestssh',
            sleep: (d) async {
              waits.add(d);
              now = now.add(d);
            },
            clock: () => now,
          );

      test('what is no command is answered with how it is used, and the app is not asked whether it is ready',
          () async {
        var checks = 0;
        Future<AdminHold?> held() async {
          checks++;
          return null;
        }

        expect(await hosted(['destroy', 'setup.json'], held: held), AdminExit.failed);
        expect(out, ['Not understood: destroy', ...adminUsage(l10n, program: 'zestssh')]);
        out.clear();
        expect(await hosted(['--help'], held: held), AdminExit.ok);
        expect(out, adminUsage(l10n, program: 'zestssh'));
        expect(checks, 0);
        expect(asked, 0);
      });

      test('an app that is ready runs the command at once and says nothing of waiting', () async {
        put('setup.json', changes);
        expect(await hosted(['plan', 'setup.json'], held: nothing), AdminExit.changes);
        expect(waits, isEmpty);
        expect(out.first, 'Team: Northwind Ops');
        expect(out, isNot(contains(l10n.setupCliWaiting('120'))));
      });

      test('a locked app is waited for, said once, and the command runs when it is unlocked', () async {
        put('setup.json', {});
        var checks = 0;
        final code =
            await hosted(['plan', 'setup.json'], held: () async => ++checks > 3 ? null : AdminHold.locked);
        expect(code, AdminExit.ok);
        expect(waits, List.filled(3, const Duration(milliseconds: 500)));
        expect(out, [
          'Waiting for ZestSSH to be unlocked and signed in (--wait 120).',
          'Team: Northwind Ops',
          'File: setup.json',
          l10n.setupPlanNothing,
        ]);
      });

      test('an app still locked when the time is up: it says so and ends with 1, nothing asked of the Orchard',
          () async {
        put('setup.json', changes);
        var checks = 0;
        final code = await hosted(['apply', 'setup.json', '--wait', '2'], held: () async {
          checks++;
          return AdminHold.locked;
        });
        expect(code, AdminExit.failed);
        expect(out, [
          'Waiting for ZestSSH to be unlocked and signed in (--wait 2).',
          'ZestSSH was not unlocked within the time given.',
        ]);
        expect(waits, hasLength(4), reason: 'two seconds, half a second at a time');
        expect(checks, 5);
        expect(asked, 0);
        expect(await owner.hosts(o.id), isEmpty);
      });

      test('what held it at the end is what it says: locked, signed out, or ZestSSH Cloud not reached', () async {
        put('setup.json', {});
        for (final (hold, words) in [
          (AdminHold.locked, l10n.setupCliNotUnlocked),
          (AdminHold.signedOut, l10n.setupCliNotSignedIn),
          (AdminHold.unreachable, l10n.setupCliNoCloud),
        ]) {
          out.clear();
          expect(await hosted(['plan', 'setup.json', '--wait', '1'], held: () async => hold), AdminExit.failed);
          expect(out, [l10n.setupCliWaiting('1'), words], reason: '$hold');
          expect(adminHoldWords(hold, l10n), words);
        }
        expect({for (final h in AdminHold.values) adminHoldWords(h, l10n)}, hasLength(AdminHold.values.length));

        // Unlocked during the wait, and then nobody is signed in: the last
        // thing in the way is the one said.
        out.clear();
        var checks = 0;
        final code = await hosted(['plan', 'setup.json', '--wait', '2'],
            held: () async => ++checks < 3 ? AdminHold.locked : AdminHold.signedOut);
        expect(code, AdminExit.failed);
        expect(out.last, l10n.setupCliNotSignedIn);
        expect(asked, 0);
      });

      test('with no time to wait it asks once', () async {
        put('setup.json', {});
        var checks = 0;
        final code = await hosted(['plan', 'setup.json', '--wait', '0'], held: () async {
          checks++;
          return AdminHold.locked;
        });
        expect(code, AdminExit.failed);
        expect(out, [l10n.setupCliNotUnlocked]);
        expect(checks, 1);
        expect(waits, isEmpty);
      });

      test('a check that fails is "not reached yet": asked again, and said when it never comes', () async {
        put('setup.json', {});
        var checks = 0;
        var code = await hosted(['plan', 'setup.json'], held: () async {
          if (++checks < 3) throw StateError('no network');
          return null;
        });
        expect(code, AdminExit.ok);
        expect(checks, 3);

        out.clear();
        code = await hosted(['plan', 'setup.json', '--wait', '1'], held: () async => throw StateError('no network'));
        expect(code, AdminExit.failed);
        expect(out.last, l10n.setupCliNoCloud);
      });

      test('--out also keeps what was said, every line of it', () async {
        put('setup.json', changes);
        var checks = 0;
        final code = await hosted(['apply', 'setup.json', '--out', 'said.txt'],
            held: () async => ++checks > 1 ? null : AdminHold.locked);
        expect(code, AdminExit.ok);
        expect(out.first, l10n.setupCliWaiting('120'));
        expect(out.last, '2 changes made.');
        expect(files['said.txt'], '${out.join('\n')}\n');
      });

      test('--out that cannot be written is said, and a run that went well does not end with 0', () async {
        put('setup.json', {});
        var code = await hosted(['plan', 'setup.json', '--out', 'readonly/said.txt'], held: nothing);
        expect(code, AdminExit.failed);
        expect(out.last, 'readonly/said.txt could not be written.');
        expect(out[out.length - 2], isNot('readonly/said.txt could not be written.'));
        expect(out, contains(l10n.setupPlanNothing));

        // One that ended with another code keeps it.
        out.clear();
        put('more.json', changes);
        code = await hosted(['plan', 'more.json', '--out', 'readonly/said.txt'], held: nothing);
        expect(code, AdminExit.changes);
        expect(out.last, 'readonly/said.txt could not be written.');
      });

      test('something no command should meet ends as "could not run", with what it was', () async {
        put('setup.json', {});
        final code = await hosted(['plan', 'setup.json', '--out', 'said.txt'],
            held: nothing, runner: () => throw StateError('no runner'));
        expect(code, AdminExit.failed);
        expect(out, ['It could not run: Bad state: no runner']);
        expect(files['said.txt'], 'It could not run: Bad state: no runner\n');
      });
    });
  });

  group('waiting for the app', () {
    test('asks until nothing holds the command, at the pace given, and no longer than given', () async {
      var now = DateTime.utc(2026, 10, 2, 9);
      final waits = <Duration>[];
      var checks = 0;
      var told = 0;
      Future<void> sleep(Duration d) async {
        waits.add(d);
        now = now.add(d);
      }

      expect(
          await waitUntilReady(() async => ++checks >= 3 ? null : AdminHold.locked,
              within: const Duration(seconds: 10),
              every: const Duration(seconds: 1),
              sleep: sleep,
              clock: () => now,
              onWaiting: () => told++),
          isNull);
      expect(checks, 3);
      expect(waits, List.filled(2, const Duration(seconds: 1)));
      expect(told, 1);

      checks = 0;
      waits.clear();
      told = 0;
      expect(
          await waitUntilReady(() async {
            checks++;
            return AdminHold.signedOut;
          },
              within: const Duration(seconds: 3),
              every: const Duration(seconds: 1),
              sleep: sleep,
              clock: () => now,
              onWaiting: () => told++),
          AdminHold.signedOut);
      expect(checks, 4, reason: 'at the start and after each second');
      expect(waits, hasLength(3));
      expect(told, 1);
    });

    test('ready at the first ask: nobody is told of a wait', () async {
      var told = 0;
      expect(await waitUntilReady(() async => null, within: const Duration(seconds: 5), onWaiting: () => told++),
          isNull);
      expect(await waitUntilReady(() async => null, within: Duration.zero, onWaiting: () => told++), isNull);
      expect(told, 0);
    });

    test('no time to wait and something in the way: nobody is told of a wait either', () async {
      var told = 0;
      expect(
          await waitUntilReady(() async => AdminHold.locked, within: Duration.zero, onWaiting: () => told++),
          AdminHold.locked);
      expect(told, 0);
    });
  });
}

/// The real actions, with one of them failing: the step numbered [failAt]
/// (from 0, of the steps that change something), or the sync at the end.
class _FailingActions implements SetupActions {
  _FailingActions(this._real, {this.failAt, this.syncFails = false});

  final SetupActions _real;
  final int? failAt;
  final bool syncFails;
  final error = StateError('the disk is full');
  var _n = 0;

  void _step() {
    if (_n++ == failAt) throw error;
  }

  @override
  Future<String> addCrate(String name, {required bool ownersOnly}) {
    _step();
    return _real.addCrate(name, ownersOnly: ownersOnly);
  }

  @override
  Future<void> addHost(String crateId,
      {required String name,
      required String address,
      required int port,
      required String protocol,
      String? keyId,
      List<String> accountIds = const [],
      String? groupId,
      required Set<String> tags}) {
    _step();
    return _real.addHost(crateId,
        name: name,
        address: address,
        port: port,
        protocol: protocol,
        keyId: keyId,
        accountIds: accountIds,
        groupId: groupId,
        tags: tags);
  }

  @override
  Future<void> syncItems() async {
    if (syncFails) throw StateError('offline');
    return _real.syncItems();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
