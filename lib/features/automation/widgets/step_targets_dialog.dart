import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../core/theme/group_color.dart';
import '../../../database/database.dart' show ConnectionGroup;
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/connection_providers.dart';
import '../../../providers/terminal_providers.dart' show noCommandReason, reachedByAllHosts;
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../../../ui/widgets/zest_mode_toggle.dart';
import '../../broadcast/host_checklist.dart';
import '../../hosts/data/folder_icon_catalog.dart';
import '../../hosts/host_list_layout.dart';

/// What a workflow's step runs on: hosts by name, a group, or all hosts (the
/// one step with many targets, "Check disk space
/// everywhere" having been 21 copies of a step).
class StepTargets {
  const StepTargets({this.hosts = const [], this.groupId, this.all = false});

  final List<String> hosts;
  final String? groupId;
  final bool all;
}

/// What a step with many targets runs on, in a few words: all hosts, a group's
/// name (masked while a screen is recorded), or how many hosts. Null for a step
/// that has none.
String? manyTargetsWords(
  AppLocalizations l10n,
  WidgetRef ref, {
  required bool all,
  String? groupId,
  List<String> hosts = const [],
}) {
  if (all) return l10n.wfTargetAll;
  if (groupId != null) {
    final groups = ref.watch(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[];
    final group = groups.where((g) => g.id == groupId).firstOrNull;
    return group == null ? l10n.wfTargetKindGroup : l10n.wfTargetGroupNamed(Redactable.group(group.name).displayIn(ref));
  }
  return hosts.isEmpty ? null : l10n.wfTargetHosts(hosts.length);
}

/// Asks what a step runs on, starting from what it runs on now. Null when the
/// person backs out.
Future<StepTargets?> showStepTargets(BuildContext context, {required StepTargets current}) => showZestModal<StepTargets>(
      context: context,
      size: ZestModalSize.large,
      child: _StepTargetsDialog(current: current),
    );

enum _TargetKind { hosts, group, all }

class _StepTargetsDialog extends ConsumerStatefulWidget {
  const _StepTargetsDialog({required this.current});

  final StepTargets current;

  @override
  ConsumerState<_StepTargetsDialog> createState() => _StepTargetsDialogState();
}

class _StepTargetsDialogState extends ConsumerState<_StepTargetsDialog> {
  late _TargetKind _kind = widget.current.all
      ? _TargetKind.all
      : widget.current.groupId != null
          ? _TargetKind.group
          : _TargetKind.hosts;
  late Set<String> _hosts = {...widget.current.hosts};
  late String? _groupId = widget.current.groupId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = ref.watch(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[];
    // Those it can run on, of those ticked: a host saved on it that cannot run
    // a command any more, or is gone, is not handed back.
    final byId = ref.watch(hostsByIdProvider);
    final hosts = [
      for (final id in _hosts)
        if (byId[id] case final h? when noCommandReason(h.connection, l10n) == null) id,
    ];
    final ready = switch (_kind) {
      _TargetKind.hosts => hosts.isNotEmpty,
      _TargetKind.group => _groupId != null,
      _TargetKind.all => true,
    };
    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.target,
      title: l10n.wfTargetTitle,
      subtitle: l10n.wfTargetHelp,
      bodyScrolls: false,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ZestModeToggle(
              key: const ValueKey('step-targets-kind'),
              segments: [
                ZestModeSegment(id: _TargetKind.hosts.name, label: l10n.wfTargetKindHosts),
                ZestModeSegment(id: _TargetKind.group.name, label: l10n.wfTargetKindGroup),
                ZestModeSegment(id: _TargetKind.all.name, label: l10n.wfTargetAll),
              ],
              selectedId: _kind.name,
              onChanged: (id) => setState(() => _kind = _TargetKind.values.byName(id)),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: switch (_kind) {
              _TargetKind.hosts => HostChecklist(
                  picked: _hosts,
                  onChanged: (picked) => setState(() => _hosts = picked),
                  keyPrefix: 'step-targets',
                  place: HostListPlace.workflowTarget,
                  quickPicks: true,
                  unavailable: noCommandReason,
                ),
              _TargetKind.group => groups.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        l10n.wfTargetNoGroups,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary),
                      ),
                    )
                  : _GroupChoices(
                      groups: groups,
                      selectedId: _groupId,
                      onChanged: (id) => setState(() => _groupId = id),
                    ),
              _TargetKind.all => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l10n.wfTargetAllHelp,
                    key: const ValueKey('step-targets-all-help'),
                    style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary),
                  ),
                ),
            },
          ),
        ],
      ),
      primaryAction: (
        label: l10n.done,
        icon: LucideIcons.check,
        onPressed: ready
            ? () => Navigator.of(context).pop(switch (_kind) {
                  _TargetKind.hosts => StepTargets(hosts: hosts),
                  _TargetKind.group => StepTargets(groupId: _groupId),
                  _TargetKind.all => const StepTargets(all: true),
                })
            : null,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// The groups, one to choose, each with how many hosts it has now.
class _GroupChoices extends ConsumerWidget {
  const _GroupChoices({required this.groups, required this.selectedId, required this.onChanged});

  final List<ConnectionGroup> groups;
  final String? selectedId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.wfTargetGroupHelp,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary),
            ),
          ),
          for (final g in groups)
            InkWell(
              key: ValueKey('step-targets-group-${g.id}'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => onChanged(g.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: selectedId == g.id ? ZestTokens.brandSubtle : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      folderIconFor(g.iconCodePoint),
                      size: 15,
                      color: resolveGroupColor(colorValue: g.colorValue, colorIndex: g.colorIndex, name: g.name),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        Redactable.group(g.name).displayIn(ref),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                      ),
                    ),
                    Text(
                      // What it will run on: its hosts that can run a command.
                      l10n.wfTargetHosts(
                          hosts.where((h) => h.connection.groupId == g.id && reachedByAllHosts(h.connection.protocol)).length),
                      style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 16,
                      child: selectedId == g.id ? Icon(LucideIcons.check, size: 15, color: ZestTokens.brandInk) : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Run on…": the hosts a workflow runs on this once, picked as its run starts
/// (like a snippet's, with Active first and the
/// chips of what the Server monitor found). They take the place of what its
/// steps are set to run on. Null when the person backs out.
Future<List<String>?> showWorkflowRunOn(BuildContext context, {required String workflowName}) =>
    showZestModal<List<String>>(
      context: context,
      size: ZestModalSize.large,
      child: _WorkflowRunOnDialog(workflowName: workflowName),
    );

class _WorkflowRunOnDialog extends ConsumerStatefulWidget {
  const _WorkflowRunOnDialog({required this.workflowName});

  final String workflowName;

  @override
  ConsumerState<_WorkflowRunOnDialog> createState() => _WorkflowRunOnDialogState();
}

class _WorkflowRunOnDialogState extends ConsumerState<_WorkflowRunOnDialog> {
  var _picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.play,
      title: widget.workflowName.isEmpty ? l10n.zestSnippetsRunOn : l10n.wfRunOnTitle(widget.workflowName),
      subtitle: l10n.wfRunOnHelp,
      bodyScrolls: false,
      body: HostChecklist(
        picked: _picked,
        onChanged: (picked) => setState(() => _picked = picked),
        keyPrefix: 'workflow-run',
        place: HostListPlace.workflowRun,
        quickPicks: true,
        unavailable: noCommandReason,
      ),
      primaryAction: (
        label: l10n.runOnHostsRun(_picked.length),
        icon: LucideIcons.play,
        onPressed: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked.toList()),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
