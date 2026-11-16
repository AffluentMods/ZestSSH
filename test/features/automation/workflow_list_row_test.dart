import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:zestssh/features/automation/state/workflow_run_status.dart';
import 'package:zestssh/features/automation/widgets/workflow_list_pane.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/workflow_provider.dart';

/// A stand-in [WorkflowNotifier] holding a fixed list; the list pane only reads
/// its state, so the CRUD methods are stubbed via noSuchMethod.
class _FakeWorkflowNotifier extends StateNotifier<List<Workflow>>
    implements WorkflowNotifier {
  _FakeWorkflowNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Workflow _wf(String id, String name, {List<WorkflowStep> steps = const []}) =>
    Workflow(id: id, name: name, createdAt: DateTime(2026, 1, 1), steps: steps);

void main() {
  late AppLocalizations l10n;
  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  testWidgets('list rows show last-run status pills (failed + never run)',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final wfFailed = _wf('a', 'Alpha', steps: const [
      WorkflowStep(id: 'x', type: WorkflowStepType.execute, command: 'ls'),
    ]);
    final wfNever = _wf('b', 'Bravo');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workflowsProvider.overrideWith(
            (ref) => _FakeWorkflowNotifier([wfFailed, wfNever]),
          ),
          workflowLastRunProvider.overrideWith(
            (ref) => {
              'a': WorkflowRunSummary(
                success: false,
                failedStepNumber: 2,
                ranAt: now,
              ),
            },
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: WorkflowListPane(
              selectedId: null,
              onSelect: (_) {},
              onCreate: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Bravo'), findsOneWidget);

    // Alpha ran and failed at step 2; Bravo has never run.
    expect(find.textContaining('Failed at step 2'), findsOneWidget);
    expect(find.text(l10n.zestAutoOutcomeNeverRun), findsOneWidget);
  });

  // In the page's language (3.0): a row said "5m", "3d" or
  // "just now", and past a week 2026-09-28, in every language.
  testWidgets("a row says when its workflow last ran in a few letters of the page's language", (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final de = lookupAppLocalizations(const Locale('de'));
    final now = DateTime.now();
    final ran = now.subtract(const Duration(minutes: 5));
    final before = now.subtract(const Duration(days: 19));
    final wfRan = _wf('a', 'Alpha');
    final wfBefore = Workflow(id: 'b', name: 'Bravo', createdAt: DateTime(2026, 1, 1), steps: const [], lastRunAt: before);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workflowsProvider.overrideWith((ref) => _FakeWorkflowNotifier([wfRan, wfBefore])),
          workflowLastRunProvider.overrideWith((ref) => {'a': WorkflowRunSummary(success: true, ranAt: ran)}),
        ],
        child: MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: WorkflowListPane(selectedId: null, onSelect: (_) {}, onCreate: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // In the one compact style, "vor 5 Min.".
    expect(find.text(de.timeMinutesAgo(5)), findsOneWidget, reason: 'five minutes ago, in German');
    expect(find.text(timeAgoShort(de, before)), findsOneWidget);
    final day = before.year == now.year ? DateFormat.Md('de').format(before) : DateFormat.y('de').format(before);
    expect(timeAgoShort(de, before), day, reason: 'past a week the day as German writes it');
    expect(find.text('5m'), findsNothing);
    expect(find.text('5m ago'), findsNothing);
  });
}
