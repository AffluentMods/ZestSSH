// The Automation page as designed: the
// templates of the empty page, built of what the engine runs, from the
// person's own groups and hosts; a snippet a template needs added once the
// person says so; and When it runs (here only, or from outside with an API
// key), which is the workflow's on/off that runs from outside are held to.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/workflow_templates.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/automation_view.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final made = DateTime(2026, 1, 1);

  group('the templates', () {
    late List<Connection> hosts;
    late List<ConnectionGroup> groups;

    setUpAll(() async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      for (final (id, name, order) in [('g-empty', 'Empty', 0), ('g-nodes', 'Nodes', 1)]) {
        await db.into(db.connectionGroups)
            .insert(ConnectionGroupsCompanion.insert(id: id, name: name, sortOrder: Value(order), createdAt: made));
      }
      for (final (id, g) in [('web-01', null), ('node-01', 'g-nodes'), ('node-02', 'g-nodes')]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id, label: id, host: '$id.example.internal', groupId: Value(g), createdAt: made, updatedAt: made));
      }
      groups = await db.select(db.connectionGroups).get();
      hosts = [
        for (final id in ['web-01', 'node-01', 'node-02']) (await db.connectionsDao.getById(id))!,
      ];
      await db.close();
    });

    test('Update packages: one step on the first group that has hosts, stopping at the first failure', () {
      final wf = buildTemplateWorkflow(WorkflowTemplate.updatePackages, en, groups: groups, connections: hosts);
      expect(wf.name, en.autoTplUpdateTitle);
      expect([for (final s in wf.steps) (s.type, s.targetGroupId, s.connectionId, s.onFailure)], [
        (WorkflowStepType.snippet, 'g-nodes', null, StepFailureAction.abort),
        (WorkflowStepType.notify, null, null, StepFailureAction.abort),
      ]);
      expect(wf.steps.first.snippetName, en.autoTplSnippetUpdate);
      // No number: its group's hosts are counted when it runs, not now.
      expect(wf.steps.last.command, en.autoTplUpdatesFinished);
      expect(wf.steps.last.command, isNot(contains(RegExp(r'\d'))));
      expect(wf.notifyOnFailure, isTrue);
    });

    test("a template's hosts are those that can run a command: a group of SFTP-only hosts is no group to update", () {
      final filesOnly = [
        for (final h in hosts) h.groupId == 'g-nodes' || h.id == 'web-01' ? h.copyWith(protocol: 'sftp') : h,
      ];
      final none = buildTemplateWorkflow(WorkflowTemplate.updatePackages, en, groups: groups, connections: filesOnly);
      expect(none.steps.first.targetGroupId, isNull);
      expect(none.steps.first.connectionId, isNull);

      final first = [hosts.first.copyWith(protocol: 'sftp'), ...hosts.skip(1)];
      final restart = buildTemplateWorkflow(WorkflowTemplate.restartContainer, en, groups: groups, connections: first);
      expect(restart.steps.single.connectionId, 'node-01', reason: 'not web-01, which is SFTP only here');

      final mosh = [for (final h in hosts) h.copyWith(protocol: 'mosh')];
      final update = buildTemplateWorkflow(WorkflowTemplate.updatePackages, en, groups: groups, connections: mosh);
      expect(update.steps.first.targetGroupId, 'g-nodes', reason: 'tasks reach Mosh hosts over SSH');
    });

    test('Check disk space: one step on every host, each checked whatever another found, with its own command for '
        'BSD and macOS', () {
      final wf = buildTemplateWorkflow(WorkflowTemplate.checkDiskSpace, en, groups: groups, connections: hosts);
      final s = wf.steps.single;
      expect((s.type, s.command, s.onFailure, s.targetAll),
          (WorkflowStepType.execute, kDiskOver85Command, StepFailureAction.continueNext, true));
      expect(s.commandsByOs, {'bsd': kDiskOver85BsdCommand, 'macos': kDiskOver85BsdCommand});
      expect(kDiskOver85BsdCommand, isNot(contains('-x')), reason: "BSD's df has no -x");
      expect(WorkflowTemplate.checkDiskSpace.snippet(en), isNull);
    });

    test("a container and a folder are the person's to fill in", () {
      final restart = buildTemplateWorkflow(WorkflowTemplate.restartContainer, en, groups: groups, connections: hosts);
      expect(restart.steps.single.variables, {'CONTAINER': ''});
      expect(WorkflowTemplate.restartContainer.snippet(en)!.command, contains(r'${CONTAINER}'));
      final backup = buildTemplateWorkflow(WorkflowTemplate.backUpFolder, en, groups: groups, connections: hosts);
      expect(backup.steps.single.variables.keys, {'FOLDER', 'DESTINATION'});
    });

    test('with no hosts at all, a step with none to choose', () {
      final wf = buildTemplateWorkflow(WorkflowTemplate.updatePackages, en, groups: const [], connections: const []);
      expect(wf.steps.first.connectionId, isNull);
    });
  });

  late AppDatabase templatesDb;
  setUp(() async {
    templatesDb = AppDatabase.forTesting(NativeDatabase.memory());
    final db = templatesDb;
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-nodes', name: 'Nodes', createdAt: made));
    for (final id in ['node-01', 'node-02', 'web-01']) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id,
            host: '$id.example.internal',
            groupId: Value(id.startsWith('node') ? 'g-nodes' : null),
            createdAt: made,
            updatedAt: made,
          ));
    }
  });
  tearDown(() => templatesDb.close().timeout(const Duration(seconds: 5), onTimeout: () => debugPrint('CLOSE TIMEOUT')));

  testWidgets('a template opens beside the list once its snippet is added, and saves as a workflow', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A computer's: what is said goes to the notification center.
    debugTopSnackBarOnPhone = false;
    addTearDown(() => debugTopSnackBarOnPhone = null);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'automation_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    // (Made, and closed, outside the test's fake clock.)
    final db = templatesDb;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      redactionFleetRegistrar.overrideWith((ref) {}),
      isProProvider.overrideWith((ref) => _Pro()),
    ]);
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: AutomationView()),
      ),
    ));
    await settle();
    expect(find.text(en.zestAutoListEmptyTitle), findsOneWidget);
    for (final t in WorkflowTemplate.values) {
      expect(find.text(t.title(en)), findsOneWidget);
    }
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('automation-template-updatePackages')), matching: find.text(en.autoTplUse)));
    await settle();
    // The snippet it runs is asked about first, with what it runs.
    expect(find.text(en.autoTplAddSnippetTitle(en.autoTplSnippetUpdate)), findsOneWidget);
    await tester.tap(find.text(en.autoTplAddSnippetAction));
    await settle();
    final snippets = (await tester.runAsync(db.snippetsDao.getAll))!;
    expect([for (final s in snippets) s.label], [en.autoTplSnippetUpdate]);
    // Added, it is said, with its name.
    expect([for (final n in container.read(notificationCenterProvider).history) n.title],
        [en.snippetAddedToast(en.autoTplSnippetUpdate)]);
    expect(find.text(en.autoTplEditingRight), findsOneWidget);
    expect(find.textContaining(en.autoFromTemplate), findsOneWidget);
    // Here only: a workflow that nothing outside starts.
    await tester.tap(find.text(en.autoRunManually));
    await settle();
    expect(find.text(en.autoRunManuallyHelp), findsOneWidget);
    await tester.tap(find.text(en.autoSaveWorkflow));
    await settle();
    final saved = container.read(workflowsProvider).single;
    expect(saved.name, en.autoTplUpdateTitle);
    expect(saved.steps, hasLength(2));
    expect(saved.enabled, isFalse, reason: 'When it runs: manually');
    // Saved, the page lists it, and no template is shown.
    expect(find.text(en.zestAutoListEmptyTitle), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    container.dispose();
    // What the database still had to do in the test's clock, done.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
