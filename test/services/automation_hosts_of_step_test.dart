import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/workflow_run_gate.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/snippet_providers.dart' show commandWithDefaults, snippetRunsUnattended;
import 'package:zestssh/providers/terminal_providers.dart' show noCommandReason, reachedByAllHosts, runsCommands;
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/workflow_service.dart';

/// The hosts a workflow's step runs on, and what a task does with a host that
/// cannot run a command, read from a real database (the fakes of the other tests
/// stand in for all of this). Group and All left out Mosh and Eternal Terminal
/// hosts, which tasks reach over SSH; a step that named an SFTP-only host signed
/// in to it and sent the command; and a snippet's `rm -rf ${DIR}/*` with DIR
/// blank reached a shell.
/// The real runSnippet, with what it hands a shell kept and nothing signed in to.
class _Sends extends AutomationService {
  _Sends(AppDatabase db) : super(db, const FlutterSecureStorage());
  final sent = <String>[];

  @override
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async {
    sent.add(command);
    return const AutomationResult(success: true, output: '', error: '', elapsed: Duration.zero);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  late AppDatabase db;
  late AutomationService service;
  late List<String> signedIn;

  Future<void> host(String id, String protocol, {String? group, int order = 0}) async {
    final at = DateTime(2026);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: '$id.example.invalid',
          port: const Value(22),
          protocol: Value(protocol),
          groupId: Value(group),
          sortOrder: Value(order),
          createdAt: at,
          updatedAt: at,
        ));
  }

  Future<void> snippet(String label, String command) async {
    final at = DateTime(2026);
    await db.into(db.snippets).insert(SnippetsCompanion.insert(id: label, label: label, command: command, createdAt: at, updatedAt: at));
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g', name: 'G', createdAt: DateTime(2026)));
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'other', name: 'O', createdAt: DateTime(2026)));
    await host('ssh1', 'ssh', group: 'g', order: 1);
    await host('sftp1', 'sftp', group: 'g', order: 2);
    await host('mosh1', 'mosh', group: 'g', order: 3);
    await host('et1', 'et', order: 4);
    await host('telnet1', 'telnet', group: 'g', order: 5);
    await host('serial1', 'serial', order: 6);
    await host('local1', 'localShell', order: 7);
    await host('ssh2', 'ssh', group: 'other', order: 8);
    signedIn = [];
    service = AutomationService(db, const FlutterSecureStorage(), signIn: (c, {required unattended, onLog}) async {
      signedIn.add('${c.id}:${c.protocol}');
      throw Exception('stop here: the test has no host');
    });
  });

  tearDown(() async {
    service.dispose();
    await db.close();
  });

  const step = WorkflowStep(id: 's', type: WorkflowStepType.execute, command: 'df');

  List<String> ids(List<Connection> hosts) => [for (final c in hosts) c.id];

  group('what can run a command', () {
    test('what a task reaches over SSH can; the rest cannot, and each says why', () {
      expect(['ssh', 'mosh', 'et', 'serial'].every(runsCommands), isTrue);
      expect(['sftp', 'telnet', 'localShell', 'demo'].any(runsCommands), isFalse);
    });

    test('All hosts and a group take in all of those but a serial host, which a step has to name', () {
      expect(['ssh', 'mosh', 'et'].every(reachedByAllHosts), isTrue);
      expect(['serial', 'sftp', 'telnet', 'localShell', 'demo'].any(reachedByAllHosts), isFalse);
    });

    test('why', () async {
      final all = await db.connectionsDao.getAll();
      Connection of(String id) => all.firstWhere((c) => c.id == id);
      expect(noCommandReason(of('ssh1'), en), isNull);
      expect(noCommandReason(of('mosh1'), en), isNull);
      expect(noCommandReason(of('sftp1'), en), en.hostSftpOnlyNoTerminal);
      expect(noCommandReason(of('telnet1'), en), en.hostNoCommandsNotSsh);
    });
  });

  group('hostsOfStep', () {
    test('all hosts: every one that can run a command, Mosh and Eternal Terminal ones too', () async {
      final hosts = await service.hostsOfStep(step.copyWith(targetAll: true));
      expect(ids(hosts).toSet(), {'ssh1', 'mosh1', 'et1', 'ssh2'});
    });

    test('a group: its own that can run a command', () async {
      final hosts = await service.hostsOfStep(step.copyWith(targetGroupId: 'g'));
      expect(ids(hosts).toSet(), {'ssh1', 'mosh1'});
    });

    test('a serial host is run on where a step names it, and not by All hosts or its group', () async {
      await host('serial2', 'serial', group: 'g', order: 9);
      expect(ids(await service.hostsOfStep(step.copyWith(targetAll: true))), isNot(contains('serial2')));
      expect(ids(await service.hostsOfStep(step.copyWith(targetGroupId: 'g'))), isNot(contains('serial2')));
      expect(ids(await service.hostsOfStep(step.copyWith(targetIds: ['serial2']))), ['serial2']);
      expect(ids(await service.hostsOfStep(step.copyWith(connectionId: 'serial2'))), ['serial2']);
    });

    test('hosts by name: in the order named, without one deleted; one that cannot run a command stays, to say why',
        () async {
      final hosts = await service.hostsOfStep(step.copyWith(targetIds: ['ssh2', 'gone', 'sftp1', 'ssh1']));
      expect(ids(hosts), ['ssh2', 'sftp1', 'ssh1']);
    });

    test('one host: that one, or none where it was deleted or none was chosen', () async {
      expect(ids(await service.hostsOfStep(step.copyWith(connectionId: 'ssh1'))), ['ssh1']);
      expect(await service.hostsOfStep(step.copyWith(connectionId: 'gone')), isEmpty);
      expect(await service.hostsOfStep(step), isEmpty);
    });

    test('Run on… of one host: the step runs there, and nowhere else', () async {
      final hosts = await service.hostsOfStep(step.copyWith(targetAll: true).onHosts(['ssh2']));
      expect(ids(hosts), ['ssh2']);
    });
  });

  group('a command to a host', () {
    test('SFTP only: fails with why, and nothing signs in', () async {
      final result = await service.executeCommand(connectionId: 'sftp1', command: 'rm x');
      expect(result.success, isFalse);
      expect(result.error, en.hostSftpOnlyNoTerminal);
      expect(signedIn, isEmpty);
    });

    test('Telnet, this device: the same', () async {
      for (final id in ['telnet1', 'local1']) {
        final result = await service.executeCommand(connectionId: id, command: 'rm x');
        expect(result.error, en.hostNoCommandsNotSsh, reason: id);
      }
      expect(signedIn, isEmpty);
    });

    test('SSH, Mosh and Eternal Terminal: signed in to over SSH', () async {
      for (final id in ['ssh1', 'mosh1', 'et1']) {
        await service.executeCommand(connectionId: id, command: 'uptime');
      }
      expect(signedIn, ['ssh1:ssh', 'mosh1:ssh', 'et1:ssh']);
    });

    // A serial host is reached over SSH at its console server, and a task was
    // signed in there as it always was: refusing it took away what worked.
    test('a serial host: over SSH, at its console server, as a task always was', () async {
      final result = await service.executeCommand(connectionId: 'serial1', command: 'uptime');
      expect(signedIn, ['serial1:ssh']);
      expect(result.error, isNot(en.hostNoCommandsNotSsh));
    });

    test("a saved step that names an SFTP-only host does not run there, and says why on the host's row", () async {
      final result = await WorkflowService(service, notice: (_, _, _) {}).executeWorkflow(Workflow(
        id: 'w',
        name: 'W',
        createdAt: DateTime(2026),
        steps: [step.copyWith(targetIds: ['sftp1', 'et1'], onFailure: StepFailureAction.continueNext)],
      ));
      expect(signedIn, ['et1:ssh']);
      final row = result.stepResults.firstWhere((r) => r.connectionId == 'sftp1');
      expect((row.success, row.error), (false, en.hostSftpOnlyNoTerminal));
    });
  });

  group("a snippet's variables", () {
    const dir = r'rm -rf ${DIR}/*';

    Future<AutomationResult> run(String name, {Map<String, String>? variables, bool unattended = true}) =>
        service.runSnippet(connectionId: 'ssh1', snippetName: name, variables: variables, unattended: unattended);

    test('with nobody to ask: no value, or a blank one, fails naming it, and nothing signs in', () async {
      await snippet('wipe', dir);
      for (final values in <Map<String, String>?>[null, const {}, const {'DIR': ''}, const {'DIR': '  '}]) {
        final result = await run('wipe', variables: values);
        expect(result.success, isFalse, reason: '$values');
        expect(result.variablesMissing, isTrue);
        expect(result.error, en.automationSnippetNeedsValue('wipe', 'DIR'));
      }
      expect(signedIn, isEmpty);
    });

    test("automation's own {{name}}: a blank value is the same empty word; with none it stays as written", () async {
      await snippet('wipe', 'rm -rf {{DIR}}/*');
      await snippet('template', "docker inspect -f '{{json}}' web");
      final blank = await run('wipe', variables: const {'DIR': ' '});
      expect(blank.error, en.automationSnippetNeedsValue('wipe', 'DIR'));
      expect(signedIn, isEmpty);
      await run('template');
      await run('wipe', variables: const {'DIR': '/tmp/x'});
      expect(signedIn, hasLength(2));
    });

    test('a list with no value fails too', () async {
      await snippet('restart', r'docker restart $[DOCKER]');
      final result = await run('restart');
      expect(result.variablesMissing, isTrue);
      expect(signedIn, isEmpty);
    });

    test('every one of them is named', () async {
      await snippet('copy', r'rm -rf ${FROM}/${TO}/* ${OPTS:--v}');
      final result = await run('copy');
      expect(result.error, en.automationSnippetNeedsValue('copy', 'FROM, TO'));
      expect(signedIn, isEmpty);
    });

    test("a plain variable never given is the shell's, as it always was, unless the command is dangerous with it empty", () async {
      await snippet('sizes', r'du -sh ${HOME}/backups');
      await snippet('loop', r'for f in a b; do echo ${f}; done');
      expect((await run('sizes')).variablesMissing, isFalse);
      expect((await run('loop', variables: const {})).variablesMissing, isFalse);
      expect(signedIn, hasLength(2), reason: 'both went on to sign in');
    });

    test('a field left blank stops it whatever the command is', () async {
      await snippet('sizes', r'du -sh ${HOME}/backups');
      final result = await run('sizes', variables: const {'HOME': ''});
      expect(result.error, en.automationSnippetNeedsValue('sizes', 'HOME'));
      expect(signedIn, isEmpty);
    });

    test('a secret with no value stops it: only the app can fill one', () async {
      await snippet('login', r'curl -u me:${TOKEN:secret} https://example.com/health');
      final result = await run('login');
      expect(result.variablesMissing, isTrue);
      expect(signedIn, isEmpty);
    });

    test('with a value, or a default, it goes on', () async {
      await snippet('wipe', dir);
      await snippet('list', r'ls ${DIR:-/srv}');
      await run('wipe', variables: const {'DIR': '/tmp/x'});
      await run('list');
      await run('list', variables: const {'DIR': ''});
      expect(signedIn, hasLength(3));
    });

    test('a blank value of one with a default takes its default, never an empty argument', () {
      expect(snippetCommandToRun(r'rm -rf ${DIR:-/tmp/x}/*', const {'DIR': ''}), "rm -rf '/tmp/x'/*");
      expect(snippetCommandToRun(r'rm -rf ${DIR:-/tmp/x}/*', const {'DIR': 'a b'}), "rm -rf 'a b'/*");
    });

    group('one text: what a question checks is what a run sends', () {
      const defaultFirst = r'mkdir -p ${DIR:-/tmp/a}; rm -rf ${DIR}/*';
      const asItRuns = "mkdir -p '/tmp/a'; rm -rf '/tmp/a'/*";
      // What it is given, and what it sends: null where it refuses, naming these.
      const rows = <(String, Map<String, String>?, String?, List<String>)>[
        (defaultFirst, null, asItRuns, []),
        (defaultFirst, {'DIR': ''}, asItRuns, []),
        (defaultFirst, {'DIR': '  '}, asItRuns, []),
        (defaultFirst, {'OTHER': 'x'}, asItRuns, []),
        (defaultFirst, {'DIR': '/srv/b'}, "mkdir -p '/srv/b'; rm -rf '/srv/b'/*", []),
        // The first one bare: no default as the app reads it, and dangerous empty.
        (r'rm -rf ${DIR}/*; mkdir ${DIR:-/tmp/a}', null, null, ['DIR']),
        (r'rm -rf ${DIR:-}/*', null, null, ['DIR']),
        (r'rm -rf ${DIR:-}/*', {'DIR': ''}, null, ['DIR']),
        (r'rm -rf ${DIR:- }/*', null, null, ['DIR']),
        (r'rm -rf ${DIR:-}/*', {'DIR': '/tmp/a'}, "rm -rf '/tmp/a'/*", []),
        (r'echo ${NOTE:-}', null, "echo ''", []),
        (r'rm -rf ${DIR:-/}', null, "rm -rf '/'", []),
        (r'rm -rf ${DIR:-/tmp/a}/*', null, "rm -rf '/tmp/a'/*", []),
        (r'rm -rf ${DIR}/*', {'DIR': '/tmp/a'}, "rm -rf '/tmp/a'/*", []),
        (r'rm -rf ${DIR}/*', null, null, ['DIR']),
        (r'rm -rf ${DIR}/*', {'DIR': ''}, null, ['DIR']),
        (r'rm -rf /*', null, r'rm -rf /*', []),
        (r'tar czf ${HOME}/backup.tgz /etc', null, r'tar czf ${HOME}/backup.tgz /etc', []),
        (r'tar czf ${HOME}/backup.tgz /etc', {'HOME': ''}, null, ['HOME']),
        (r'tar czf ${HOME}/backup.tgz /etc', {'HOME': '/srv'}, "tar czf '/srv'/backup.tgz /etc", []),
        (r'echo ${A:-x} "${A}" ' "'" r'${A}' "'", null, "echo 'x' \"x\" 'x'", []),
        ('echo {{X}} \${Y:-z}', {'X': 'a b'}, "echo 'a b' 'z'", []),
        (r'echo ${[a,b]}', {'[a,b]': 'b'}, "echo 'b'", []),
        (r'echo $[a,b]', null, null, ['a, b']),
        (r'curl -u me:${PW:secret} x', null, null, ['PW']),
        (r'grep "${P}" log', {'P': r'$(touch x)'}, r'grep "\$(touch x)" log', []),
      ];

      for (final (i, (template, given, sends, names)) in rows.indexed) {
        test('$template, given $given', () async {
          final rec = _Sends(db);
          addTearDown(rec.dispose);
          await snippet('s$i', template);
          final run = await rec.runSnippet(connectionId: 'ssh1', snippetName: 's$i', variables: given);
          final checked = await workflowStepCommands(
            rec,
            WorkflowStep(id: 's', type: WorkflowStepType.snippet, snippetName: 's$i', connectionId: 'ssh1', variables: given ?? const {}),
          );
          expect([for (final v in snippetVariablesToAsk(template, given)) v.name], names, reason: 'a person is asked for the same');
          if (sends == null) {
            expect(run.variablesMissing, isTrue);
            expect(rec.sent, isEmpty);
            expect(run.error, en.automationSnippetNeedsValue('s$i', names.join(', ')));
          } else {
            expect(rec.sent, [sends]);
            expect(checked.single.runs, sends, reason: 'the very text');
          }
        });
      }

      test('a link says what it will run in the same words', () {
        expect(snippetCommandToRun(defaultFirst, const {}), asItRuns);
      });
    });

    test("a snippet's Confirm before running stops nothing with nobody to ask", () async {
      final at = DateTime(2026);
      await db.into(db.snippets).insert(SnippetsCompanion.insert(
          id: 'c', label: 'careful', command: 'uptime', confirmBeforeRun: const Value(true), createdAt: at, updatedAt: at));
      await run('careful');
      expect(signedIn, ['ssh1:ssh']);
    });

    group('run on connect, with nobody to ask', () {
      test('every occurrence takes the default: the shell would leave the bare one empty', () {
        expect(commandWithDefaults(r'mkdir -p ${DIR:-/tmp/a}; rm -rf ${DIR}/*'), "mkdir -p '/tmp/a'; rm -rf '/tmp/a'/*");
      });

      test('a blank default where the command is dangerous with it empty does not run by itself', () {
        expect(snippetRunsUnattended(r'rm -rf ${DIR:-}/*', confirmBeforeRun: false), isFalse);
        expect(snippetRunsUnattended(r'echo ${NOTE:-}', confirmBeforeRun: false), isTrue);
      });
    });

    test('a workflow with nobody there: the step fails, naming it, nothing runs, and the workflow stops there', () async {
      await snippet('wipe', dir);
      final result = await WorkflowService(service, notice: (_, _, _) {}).executeWorkflow(
        Workflow(
          id: 'w',
          name: 'W',
          createdAt: DateTime(2026),
          steps: const [
            WorkflowStep(
              id: 's1',
              type: WorkflowStepType.snippet,
              snippetName: 'wipe',
              targetIds: ['ssh1', 'mosh1'],
              variables: {'DIR': ''},
              onFailure: StepFailureAction.continueNext,
            ),
            WorkflowStep(id: 's2', type: WorkflowStepType.execute, command: 'uptime', connectionId: 'ssh1'),
          ],
        ),
        unattended: true,
      );
      expect(signedIn, isEmpty);
      expect(result.success, isFalse);
      final first = result.stepResults.firstWhere((r) => r.stepId == 's1' && !r.skipped);
      expect(first.error, en.automationSnippetNeedsValue('wipe', 'DIR'));
      expect(result.stepResults.where((r) => r.stepId == 's2').single.skipped, isTrue);
    });

    test('the snippet a task runs is found whatever its case, and one gone says so', () async {
      await snippet('Wipe', 'ls');
      expect((await service.snippetNamed('wipe'))?.label, 'Wipe');
      expect(await service.snippetNamed('nope'), isNull);
      final gone = await run('nope');
      expect(gone.snippetMissing, isTrue);
    });
  });
}
