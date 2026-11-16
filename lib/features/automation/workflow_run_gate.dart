import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/spaces.dart' show OrchardSpace;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart' show activeSpaceProvider;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show runsCommands;
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_variable_dialog.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';

// What a run a person starts goes through before any of it runs: its Run, its
// Run on… and the list's Run now. A schedule, a link and another app have nobody
// to ask, and are what AutomationService.runSnippet refuses for itself.

/// Why a person cannot run a workflow now, or null where they can: a team's space
/// is on screen. A workflow runs on the hosts of the Tree
/// (automationServiceProvider) whatever is on screen, while its pickers, its
/// groups and its templates read the space on screen: All hosts in a team reached
/// every personal host, none of them listed. What runs by itself is not touched.
String? workflowRunRefusal(T Function<T>(ProviderListenable<T> provider) read, AppLocalizations l10n) =>
    read(activeSpaceProvider) is OrchardSpace ? l10n.wfRunTeamSpace : null;

/// [workflow] made ready for a run its person just started, or null when they
/// back out and nothing runs.
///
/// A snippet step with a variable that needs a value and has none in the step
/// ([snippetVariablesToAsk], the rule a run with nobody to ask refuses by) is
/// asked for it, with the dialog every snippet's run asks with; the value is for
/// this run alone. Then, where the dangerous-command check is on, it asks once
/// about every risky command the run will run (each step's command, each
/// system's alternative, each snippet's as [snippetCommandToRun] makes it), and
/// says on how many hosts. Then a snippet that says Confirm before running is
/// asked about, where that question did not cover it, as a snippet run from
/// anywhere else is (commandReadyToRun).
Future<Workflow?> workflowReadyToRun(BuildContext context, Workflow workflow) async {
  final l10n = AppLocalizations.of(context)!;
  // Read once: what asked may be gone by the time a question is answered.
  final container = ProviderScope.containerOf(context, listen: false);
  final navigator = Navigator.of(context, rootNavigator: true);
  final service = container.read(automationServiceProvider);

  final steps = <WorkflowStep>[];
  for (final step in workflow.steps) {
    final filled = step.disabled ? step : await _askForVariables(navigator, service, step, l10n);
    if (filled == null) return null;
    steps.add(filled);
  }

  // The commands asked about so far: each is asked about once.
  final asked = <String>{};
  if (container.read(dangerousCommandProtectionProvider)) {
    final risky = <String, String>{};
    final hosts = <String>{};
    for (final step in steps) {
      if (step.disabled) continue;
      final commands = await workflowStepCommands(service, step);
      final found = commands.where((c) => DangerousCommandService.checkFilled(c.runs).isNotEmpty).toList();
      if (found.isEmpty) continue;
      // On a host it reaches: a step with none runs nothing to ask about.
      final reached = await _hostsReached(service, step);
      if (reached.isEmpty) continue;
      risky.addAll({for (final c in found) c.runs: c.shown});
      hosts.addAll(reached);
    }
    if (risky.isNotEmpty) {
      final asking = navigator.context;
      if (!asking.mounted) return null;
      final answer = await showWorkflowDangerDialog(
        asking,
        commands: [for (final e in risky.entries) (runs: e.key, shown: e.value)],
        hosts: hosts.length,
      );
      if (answer.dontAskAgain) {
        await container.read(settingsUpdaterProvider).setDangerousCommandProtection(false);
      }
      if (!answer.proceed) return null;
      asked.addAll(risky.keys);
    }
  }

  // A snippet's own Confirm before running was never asked in a workflow, and
  // was everywhere else a person runs one (found in an
  // independent review). With nobody to ask, it still is not.
  for (final step in steps) {
    if (step.disabled || step.type != WorkflowStepType.snippet) continue;
    final name = step.snippetName;
    final snippet = name == null || name.isEmpty ? null : await service.snippetNamed(name);
    if (snippet == null || !snippet.confirmBeforeRun) continue;
    if (!asked.add(snippetCommandToRun(snippet.command, step.variables))) continue;
    if ((await _hostsReached(service, step)).isEmpty) continue;
    final shown = snippetCommandShown(snippet.command, step.variables);
    final asking = navigator.context;
    if (!asking.mounted) return null;
    final ok = await ZestConfirmDialog.show(
      asking,
      tone: ZestDialogTone.neutral,
      title: l10n.snippetRunConfirmTitle,
      body: l10n.snippetRunConfirmBody,
      bullets: [commandForQuestion(shown)],
      confirmLabel: l10n.snippetRunAction,
    );
    if (ok != true) return null;
  }
  return workflow.copyWith(steps: steps);
}

/// The hosts [step] names or takes in that a command can run on.
Future<List<String>> _hostsReached(AutomationService service, WorkflowStep step) async => [
      for (final h in await service.hostsOfStep(step))
        if (runsCommands(h.protocol)) h.id,
    ];

/// What [step] runs on a host, each of them: its command and its alternatives,
/// or its snippet's, the very text a run sends.
@visibleForTesting
Future<List<CommandAsked>> workflowStepCommands(AutomationService service, WorkflowStep step) async {
  switch (step.type) {
    case WorkflowStepType.execute:
      return [
        if (step.command?.trim().isNotEmpty ?? false) (runs: step.command!, shown: step.command!),
        for (final c in step.commandsByOs.values) (runs: c, shown: c),
      ];
    case WorkflowStepType.snippet:
      final name = step.snippetName;
      final snippet = name == null || name.isEmpty ? null : await service.snippetNamed(name);
      if (snippet == null) return const [];
      return [
        (
          runs: snippetCommandToRun(snippet.command, step.variables),
          shown: snippetCommandShown(snippet.command, step.variables),
        ),
      ];
    case WorkflowStepType.delay:
    case WorkflowStepType.notify:
      return const [];
  }
}

/// [step] with what it lacks asked for, or as it is where it lacks nothing. Null
/// when the person backs out. A snippet that is gone fails at its turn, and says
/// which it was.
Future<WorkflowStep?> _askForVariables(
  NavigatorState navigator,
  AutomationService service,
  WorkflowStep step,
  AppLocalizations l10n,
) async {
  final name = step.snippetName;
  if (step.type != WorkflowStepType.snippet || name == null || name.isEmpty) return step;
  final snippet = await service.snippetNamed(name);
  if (snippet == null) return step;
  final missing = snippetVariablesToAsk(snippet.command, step.variables);
  if (missing.isEmpty) return step;

  // A list of the host's own (`$[DOCKER]`) is read on the step's first host.
  final hosts = await _hostsReached(service, step);
  final on = hosts.firstOrNull;
  final asking = navigator.context;
  if (!asking.mounted) return null;
  final asked = await showVariableInputDialog(
    context: asking,
    variables: [for (final v in missing) v.name],
    snippetLabel: snippet.label,
    command: snippet.command,
    only: {for (final v in missing) v.key},
    given: {
      for (final e in step.variables.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value,
    },
    // One value for every host: asked once, it says so.
    note: hosts.length < 2
        ? null
        : [
            l10n.wfVariableGoesToAllHosts(hosts.length),
            if (missing.any((v) => v.isDynamic)) l10n.wfVariableListFromFirstHost,
          ].join(' '),
    executeCommand: on == null
        ? null
        : (command) async {
            final read = await service.executeCommand(connectionId: on, command: command);
            return read.success ? read.output : null;
          },
    doneLabel: l10n.zestSnippetsRunButton,
  );
  if (asked == null) return null;
  return step.copyWith(variables: {
    ...step.variables,
    for (final v in missing) v.key: ?asked[v.key],
  });
}
