import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/automation_link_question.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/workflow_service.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What a run was handed; nothing runs.
class _Engine implements WorkflowService {
  final runs = <Workflow>[];

  @override
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    runs.add(workflow);
    return WorkflowResult(
      workflowId: workflow.id,
      workflowName: workflow.name,
      success: true,
      stepResults: const [],
      totalElapsed: Duration.zero,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A link or a schedule that fires with a team's space open: automation runs on
/// the Tree's hosts, and it read the team's workflows and ran them on personal
/// hosts (found in a review). It reads the Tree's always, whichever space
/// is on screen, and a workflow saved in a team's space never runs that way.
void main() {
  const apiKey = 'zk_made-up-key-for-this-test-only';
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  late AppDatabase tree;
  late AppDatabase team;
  late ProviderContainer container;
  late _Engine engine;

  Workflow workflow(String id, String name) => Workflow(
        id: id,
        name: name,
        createdAt: DateTime(2026),
        steps: const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, connectionId: 'c1', command: 'uptime')],
      );

  void teamOnScreen() => container.read(activeSpaceProvider.notifier).state = const OrchardSpace('team');

  Future<void> fire(Map<String, dynamic> request) => container.read(automationProvider.notifier).handleAutomation(request);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'automation_api_keys': AutomationApiKey.encodeList([
        AutomationApiKey.fromSecret(id: 'k-1', label: 'phone', secret: apiKey, createdAt: DateTime(2026)),
      ]),
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    team = AppDatabase.forTesting(NativeDatabase.memory());
    engine = _Engine();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      databaseProvider.overrideWith((ref) => ref.watch(activeSpaceProvider) is OrchardSpace ? team : ref.watch(treeDatabaseProvider)),
      workflowServiceProvider.overrideWithValue(engine),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(automationProvider.notifier).setEnabled(true);
    await container.read(workflowsProvider.notifier).addWorkflow(workflow('w-tree', 'Nightly'));
    teamOnScreen();
    await container.read(workflowsProvider.notifier).addWorkflow(workflow('w-team', 'Nightly'));
    await container.read(workflowsProvider.notifier).addWorkflow(workflow('w-team-only', 'Team job'));
    container.read(activeSpaceProvider.notifier).state = const TreeSpace();
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
    await team.close();
  });

  test('a link with a team open runs the Tree\'s workflow of that name, not the team\'s', () async {
    teamOnScreen();
    await fire({'action': 'workflow', 'workflow_name': 'Nightly', 'key': apiKey});
    expect(engine.runs.single.id, 'w-tree');
    final inTree = await tree.workflowsDao.getById('w-tree');
    final inTeam = await team.workflowsDao.getById('w-team');
    expect(inTree!.lastRunAt, isNotNull, reason: 'its last run, where it is kept');
    expect(inTeam!.lastRunAt, isNull);
  });

  test('a schedule with a team open runs the Tree\'s workflow by its id, as the scheduler hands it over', () async {
    teamOnScreen();
    await fire({'action': 'workflow', 'workflow_id': 'w-tree', 'api_key_id': 'k-1'});
    expect(engine.runs.single.id, 'w-tree');
  });

  test('a workflow saved in a team\'s space never runs that way, by its name or by its id', () async {
    teamOnScreen();
    await fire({'action': 'workflow', 'workflow_name': 'Team job', 'key': apiKey});
    await fire({'action': 'workflow', 'workflow_id': 'w-team-only', 'key': apiKey});
    expect(engine.runs, isEmpty);
    expect(container.read(automationProvider).errorMessage, contains('Workflow not found'));
  });

  test('with the Tree on screen it is as it was', () async {
    await fire({'action': 'workflow', 'workflow_name': 'nightly', 'key': apiKey});
    expect(engine.runs.single.id, 'w-tree');
  });

  test('runWorkflow with nobody there, with a team open: the Tree\'s, and no other', () async {
    teamOnScreen();
    final notifier = container.read(workflowsProvider.notifier);
    expect(notifier.state.map((w) => w.id), containsAll(['w-team', 'w-team-only']), reason: 'the list on screen is the team\'s');
    expect((await notifier.runWorkflow('w-tree', unattended: true)).success, isTrue);
    expect(engine.runs.single.id, 'w-tree');
    final notThere = await notifier.runWorkflow('w-team-only', unattended: true);
    expect(notThere.success, isFalse);
    expect(engine.runs, hasLength(1));
  });

  test('what a schedule and a link are made from: the Tree\'s, with a team open', () async {
    teamOnScreen();
    final offered = await container.read(automationWorkflowsProvider.future);
    expect(offered.map((w) => w.id), ['w-tree']);
  });

  testWidgets('a link\'s question names the Tree\'s workflow, by its name where the link gave its id', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, _) => const Scaffold(body: _AskALink())),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
    teamOnScreen();
    await tester.pump();
    await tester.tap(find.text('ask'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.textContaining(en.automationLinkWorkflow('Nightly')), findsOneWidget);
    expect(find.textContaining('w-tree'), findsNothing);
    await tester.tap(find.text(en.cancel));
    await tester.pump(const Duration(seconds: 1));
  });
}

class _AskALink extends ConsumerWidget {
  const _AskALink();

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
        onPressed: () => askAutomationLink(context, ref, action: 'workflow', target: 'w-tree'),
        child: const Text('ask'),
      );
}
