/// The workflows a computer's Automation page offers to start from (3.0):
/// each a workflow filled in from the
/// person's own hosts and groups, built of what the engine runs (a snippet or
/// a command on one host, a wait, a notice), and opened in the editor unsaved.
///
/// A template that runs on a group or on every host is one step with many
/// targets (3.3; it was a copy of the step for each host, 21 of them for "Check
/// disk space everywhere"). Set to stop at a
/// failure, it goes one host at a time and stops at the first that fails.
library;

import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart' show Connection, ConnectionGroup, Snippet;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/terminal_providers.dart' show reachedByAllHosts;

/// A template of the empty Automation page.
enum WorkflowTemplate { updatePackages, restartContainer, checkDiskSpace, backUpFolder }

/// A snippet a template runs: what it is named and what it runs. It is added
/// to the person's snippets (once they say so) where none of that name is.
typedef TemplateSnippet = ({String label, String command});

/// The command that fails (and prints the filesystems) where any is more than
/// 85% full: the Check disk space template's.
const String kDiskOver85Command =
    r"df -P -x tmpfs -x devtmpfs | awk 'NR > 1 && $5 + 0 > 85 { print; full = 1 } END { exit full }'";

/// The same on BSD and macOS, whose df has no -x (because
/// on an OPNsense it failed with "df: invalid option -- x"): what is no disk is
/// left out by its name, as devfs is always full.
const String kDiskOver85BsdCommand =
    r"df -P | awk 'NR > 1 && $1 !~ /^(devfs|fdescfs|procfs|linprocfs|tmpfs|map)/ && $5 + 0 > 85 { print; full = 1 } END { exit full }'";

extension WorkflowTemplateWords on WorkflowTemplate {
  String title(AppLocalizations l10n) => switch (this) {
        WorkflowTemplate.updatePackages => l10n.autoTplUpdateTitle,
        WorkflowTemplate.restartContainer => l10n.autoTplRestartTitle,
        WorkflowTemplate.checkDiskSpace => l10n.autoTplDiskTitle,
        WorkflowTemplate.backUpFolder => l10n.autoTplBackupTitle,
      };

  String body(AppLocalizations l10n) => switch (this) {
        WorkflowTemplate.updatePackages => l10n.autoTplUpdateBody,
        WorkflowTemplate.restartContainer => l10n.autoTplRestartBody,
        WorkflowTemplate.checkDiskSpace => l10n.autoTplDiskBody,
        WorkflowTemplate.backUpFolder => l10n.autoTplBackupBody,
      };

  /// The snippet it runs, or null where its steps run a command of their own.
  TemplateSnippet? snippet(AppLocalizations l10n) => switch (this) {
        WorkflowTemplate.updatePackages => (
            label: l10n.autoTplSnippetUpdate,
            command: 'sudo apt-get update && sudo apt-get -y upgrade',
          ),
        WorkflowTemplate.restartContainer => (
            label: l10n.autoTplSnippetRestart,
            command: r'docker restart ${CONTAINER}',
          ),
        WorkflowTemplate.checkDiskSpace => null,
        WorkflowTemplate.backUpFolder => (
            label: l10n.autoTplSnippetBackup,
            command: r'rsync -az ${FOLDER}/ ${DESTINATION}',
          ),
      };
}

/// The hosts of the person's first group that has any (by the groups'
/// order), or, where no group has a host, the first host; and that group.
({ConnectionGroup? group, List<Connection> hosts}) templateGroup(
  List<ConnectionGroup> groups,
  List<Connection> connections,
) {
  final ordered = [...groups]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  // Those it can run on: a group of SFTP-only hosts is no group to update.
  final usable = [for (final c in connections) if (reachedByAllHosts(c.protocol)) c];
  for (final g in ordered) {
    final hosts = [for (final c in usable) if (c.groupId == g.id) c];
    if (hosts.isNotEmpty) return (group: g, hosts: hosts);
  }
  return (group: null, hosts: usable.take(1).toList());
}

/// [template] as a workflow, from the person's [groups] and [connections],
/// running the snippet named [snippetLabel] (the template's own, or one of
/// that name the person has). Not saved: the editor opens it.
Workflow buildTemplateWorkflow(
  WorkflowTemplate template,
  AppLocalizations l10n, {
  required List<ConnectionGroup> groups,
  required List<Connection> connections,
  String? snippetLabel,
}) {
  const uuid = Uuid();
  String id() => uuid.v4();
  final snippet = snippetLabel ?? template.snippet(l10n)?.label;
  final steps = <WorkflowStep>[];
  // The one host of a template that runs on one: one that can run a command.
  final firstHost = [for (final c in connections) if (reachedByAllHosts(c.protocol)) c.id].firstOrNull;
  switch (template) {
    case WorkflowTemplate.updatePackages:
      final target = templateGroup(groups, connections);
      final hosts = target.hosts;
      steps.add(WorkflowStep(
        id: id(),
        type: WorkflowStepType.snippet,
        snippetName: snippet,
        targetGroupId: target.group?.id,
        connectionId: target.group == null && hosts.isNotEmpty ? hosts.first.id : null,
      ));
      steps.add(WorkflowStep(
        id: id(),
        type: WorkflowStepType.notify,
        // No number: its group's hosts are counted when it runs, not now.
        command: l10n.autoTplUpdatesFinished,
      ));
    case WorkflowTemplate.restartContainer:
      steps.add(WorkflowStep(
        id: id(),
        type: WorkflowStepType.snippet,
        snippetName: snippet,
        connectionId: firstHost,
        variables: const {'CONTAINER': ''},
      ));
    case WorkflowTemplate.checkDiskSpace:
      steps.add(WorkflowStep(
        id: id(),
        type: WorkflowStepType.execute,
        command: kDiskOver85Command,
        commandsByOs: {
          WorkflowOsFamily.bsd.name: kDiskOver85BsdCommand,
          WorkflowOsFamily.macos.name: kDiskOver85BsdCommand,
        },
        targetAll: true,
        // Every host is checked: a full one does not stop the others.
        onFailure: StepFailureAction.continueNext,
      ));
    case WorkflowTemplate.backUpFolder:
      steps.add(WorkflowStep(
        id: id(),
        type: WorkflowStepType.snippet,
        snippetName: snippet,
        connectionId: firstHost,
        variables: const {'FOLDER': '', 'DESTINATION': ''},
      ));
  }
  return Workflow(
    id: id(),
    name: template.title(l10n),
    steps: steps,
    createdAt: DateTime.now(),
    // A notice when it fails, as every template is something to hear of.
    notifyOnFailure: true,
    notifyOnSuccess: false,
  );
}

/// The person's snippet named [label] (upper and lower case alike), or null.
Snippet? snippetNamed(List<Snippet> snippets, String label) {
  final lower = label.toLowerCase();
  for (final s in snippets) {
    if (s.label.toLowerCase() == lower) return s;
  }
  return null;
}
