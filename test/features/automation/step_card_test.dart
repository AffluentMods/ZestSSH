import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart' show Snippet;
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/widgets/step_card.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/snippet_providers.dart';

/// Counts route pushes so a test can assert step editing NEVER opens a modal
/// route (the 1.7 requirement: cards expand in place).
class _RecordingObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

Widget _host(
  WorkflowEditController c,
  _RecordingObserver obs, {
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: [obs],
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: c,
            builder: (_, _) => StepCard(
              draft: c.steps.first,
              controller: c,
              stepNumber: 1,
              index: 0,
              connections: const [],
            ),
          ),
        ),
      ),
    ),
  );
}

Workflow _wf(List<WorkflowStep> steps) => Workflow(
      id: 'w1',
      name: 'W',
      createdAt: DateTime(2026, 1, 1),
      steps: steps,
    );

void main() {
  late AppLocalizations l10n;
  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  testWidgets('tapping a step card expands it inline - no modal, no route push',
      (tester) async {
    final c = WorkflowEditController()
      ..bind(_wf(const [
        WorkflowStep(
          id: 's1',
          type: WorkflowStepType.execute,
          command: 'ls -la',
        ),
      ]));
    addTearDown(c.dispose);
    final obs = _RecordingObserver();

    await tester.pumpWidget(_host(c, obs));
    final baseline = obs.pushes;

    // Collapsed: the Advanced expander is not shown yet.
    expect(find.text(l10n.zestAutoStepAdvanced), findsNothing);

    // Tap the collapsed card header to expand it. The whole header is one
    // opaque GestureDetector, so tapping the type icon - whose tooltip is the
    // step-type label (zestAutoStepTypeCommand) - toggles it open in place.
    await tester.tap(find.byTooltip(l10n.zestAutoStepTypeCommand));
    await tester.pumpAndSettle();

    // Expanded IN PLACE: the Advanced expander is now present…
    expect(find.text(l10n.zestAutoStepAdvanced), findsOneWidget);
    // …and nothing was pushed onto the navigator (no modal / route push).
    expect(obs.pushes, baseline);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('a message step with no name has its message whole as its title, not cut beside a copy in mono',
      (tester) async {
    const message = 'Updates finished on 2 hosts in the web group';
    final c = WorkflowEditController()
      ..bind(_wf(const [WorkflowStep(id: 's1', type: WorkflowStepType.notify, command: message)]));
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(c, _RecordingObserver()));
    // It was cut ("Updates finished on 2 h…") beside the whole of it in mono
    // (found in a design review).
    expect(find.text(message), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('step-title-s1'))).data, message);
  });

  // Found while comparing the five platforms' versions: retries, a
  // working folder and run-if-previous were offered, and no run read them.
  testWidgets("a step's advanced options are those a run honours: its time and what follows a failure", (tester) async {
    final c = WorkflowEditController()
      ..bind(_wf(const [
        WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'uptime'),
      ]));
    addTearDown(c.dispose);
    await tester.pumpWidget(_host(c, _RecordingObserver()));
    await tester.tap(find.byTooltip(l10n.zestAutoStepTypeCommand));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.zestAutoStepAdvanced));
    await tester.pumpAndSettle();
    expect(find.text(l10n.zestAutoStepTimeout), findsOneWidget);
    expect(find.text(l10n.zestAutoStepContinueOnError), findsOneWidget);
    for (final unread in ['Retries', 'Working directory', 'Run only if previous step succeeded']) {
      expect(find.text(unread), findsNothing, reason: unread);
    }
  });

  testWidgets('a snippet step renders its detected variables inline',
      (tester) async {
    final c = WorkflowEditController()
      ..bind(_wf(const [
        WorkflowStep(
          id: 's1',
          type: WorkflowStepType.snippet,
          snippetName: 'Greet',
        ),
      ]));
    addTearDown(c.dispose);
    c.toggleExpanded('s1');

    final snippet = Snippet(
      id: 'x',
      label: 'Greet',
      command: r'echo ${NAME}',
      confirmBeforeRun: false,
      isDefault: false,
      sortOrder: 0,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final obs = _RecordingObserver();

    await tester.pumpWidget(_host(
      c,
      obs,
      overrides: [
        snippetsProvider.overrideWith((ref) => Stream.value([snippet])),
      ],
    ));
    await tester.pumpAndSettle();

    // The picked snippet + its detected ${NAME} variable both render in-card.
    expect(find.text('Greet'), findsWidgets);
    expect(find.text('NAME'), findsOneWidget);
  });
}
