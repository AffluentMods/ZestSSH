import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../database/daos/connections_dao.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../models/workflow.dart';
import '../../../providers/core_providers.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/copy_details_button.dart';
import '../../../ui/widgets/host_row.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../utils/error_report.dart';
import '../../hosts/host_list_layout.dart';
import '../state/workflow_edit_controller.dart';
import '../state/workflow_run_controller.dart';
import 'package:zestssh/utils/number_text.dart';

/// Where the run panel's height is kept, as a part of the pane it stands in.
const String kRunPanelFractionKey = 'workflow_run_panel_fraction';

/// The run-output panel over the bottom of the detail pane:
/// it opens at once at a fixed height, about half the view, its
/// results load and scroll inside, and its head with Cancel and Close stays
/// put (it grew as results came, and Cancel moved away from the mouse). Its
/// top edge drags to resize, and the height is remembered on this device.
class RunOutputPanel extends ConsumerStatefulWidget {
  const RunOutputPanel({super.key, required this.controller, required this.available});

  final WorkflowRunController controller;

  /// The height of what it stands in.
  final double available;

  @override
  ConsumerState<RunOutputPanel> createState() => _RunOutputPanelState();
}

class _RunOutputPanelState extends ConsumerState<RunOutputPanel> {
  static const double _least = 160;
  double _fraction = 0.5;

  @override
  void initState() {
    super.initState();
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      _fraction = prefs.getDouble(kRunPanelFractionKey) ?? _fraction;
    } catch (_) {
      // No store in this scope (a test of something else): the height it has.
    }
  }

  double get _most => widget.available * 0.92;

  void _persist() {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      // ignore: discarded_futures
      prefs.setDouble(kRunPanelFractionKey, _fraction);
    } catch (_) {
      // No store in this scope: it lasts as long as the page.
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = (_fraction * widget.available).clamp(_least < _most ? _least : _most, _most);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        key: const ValueKey('workflow-run-panel'),
        height: height,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(child: RunOutputDrawer(controller: widget.controller)),
            // The top edge, to drag.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                child: GestureDetector(
                  key: const ValueKey('workflow-run-panel-edge'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => setState(() {
                    final now = (_fraction * widget.available) - d.delta.dy;
                    _fraction = now.clamp(_least < _most ? _least : _most, _most) / widget.available;
                  }),
                  onVerticalDragEnd: (_) => _persist(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the panel shows: a head that stays, and each step's results, named by
/// host (every row said "Command" before), the failures
/// first, each opening to what it printed.
class RunOutputDrawer extends StatelessWidget {
  const RunOutputDrawer({super.key, required this.controller});

  final WorkflowRunController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Material(
          color: ZestTokens.surfaceRaised,
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: ZestTokens.borderStrong, width: 1),
              ),
            ),
            child: Column(
              children: [
                _header(context, l10n),
                Divider(height: 1, color: ZestTokens.border),
                Expanded(child: _body(context, l10n)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(
            controller.isRunning ? LucideIcons.loader : LucideIcons.terminal,
            size: 15,
            color: ZestTokens.textSecondary,
          ),
          const SizedBox(width: 8),
          Text(
            l10n.zestAutoRunOutput,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: ZestTokens.textPrimary,
            ),
          ),
          const SizedBox(width: 10),
          if (controller.totalSteps > 0)
            Text(
              _progressLabel(),
              key: const ValueKey('workflow-run-progress'),
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: ZestTokens.textTertiary,
              ),
            ),
          const Spacer(),
          if (controller.isRunning)
            TextButton.icon(
              key: const ValueKey('workflow-run-cancel'),
              onPressed: controller.cancel,
              icon: const Icon(LucideIcons.x, size: 13),
              label: Text(l10n.cancel, style: const TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: ZestTokens.textSecondary,
              ),
            ),
          if (!controller.isRunning && controller.results.isNotEmpty)
            IconButton(
              key: const ValueKey('workflow-run-copy'),
              tooltip: l10n.runOnHostsCopyAll,
              icon: const Icon(LucideIcons.copy, size: 15),
              color: ZestTokens.textSecondary,
              onPressed: () {
                final hosts = ProviderScope.containerOf(context, listen: false).read(hostsByIdProvider);
                Clipboard.setData(ClipboardData(text: _report(l10n, hosts)));
              },
            ),
          if (!controller.isRunning)
            TextButton(
              key: const ValueKey('workflow-run-clear'),
              onPressed: controller.clear,
              style: TextButton.styleFrom(foregroundColor: ZestTokens.textSecondary),
              child: Text(l10n.zestCommonClear, style: const TextStyle(fontSize: 12)),
            ),
          IconButton(
            key: const ValueKey('workflow-run-close'),
            icon: const Icon(LucideIcons.x, size: 16),
            color: ZestTokens.textSecondary,
            tooltip: l10n.close,
            onPressed: controller.close,
          ),
        ],
      ),
    );
  }

  /// Steps through of steps, where the steps' hosts' own progress shows beside
  /// each: results come per host, so their count says nothing of the steps.
  String _progressLabel() => '${controller.stepsDone} / ${controller.totalSteps}';

  /// The run as text: each result under its step's name and its host's, what
  /// it printed. Masked while a screen is recorded, as the panel shows them.
  String _report(AppLocalizations l10n, Map<String, ConnectionWithDetails> hosts) {
    final out = StringBuffer();
    final workflow = controller.workflow;
    for (final r in controller.results) {
      final at = r.stepIndex;
      final step = at == null || workflow == null || at >= workflow.steps.length ? null : workflow.steps[at];
      final host = hosts[r.connectionId]?.connection;
      final name = host == null
          ? ''
          : (host.label.isNotEmpty ? Redactable.host(host.label) : Redactable.address(host.host)).display;
      out.writeln('== ${step == null ? '' : stepTitleOf(l10n, step)} $name: ${_stateWords(l10n, r)}');
      if (r.error.trim().isNotEmpty) out.writeln(Redactable.freeText(r.error.trimRight()).display);
      if (r.output.trim().isNotEmpty) out.writeln(Redactable.freeText(r.output.trimRight()).display);
    }
    return out.toString();
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    if (controller.blockedMessage != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              LucideIcons.alertTriangle,
              size: 16,
              color: ZestTokens.statusWarning,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                controller.blockedMessage!,
                style: TextStyle(
                  fontSize: 13,
                  color: ZestTokens.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final workflow = controller.workflow;
    // Each host's last result of a step: a step that went back runs again, and
    // what it came to that time is what stands (Copy all results has them all).
    final results = settledStepResults(controller.results);
    final byStep = <int, List<WorkflowStepResult>>{};
    for (final r in results) {
      (byStep[r.stepIndex ?? 0] ??= []).add(r);
    }
    final indices = byStep.keys.toList()..sort();
    final activeStep = controller.isRunning ? controller.currentStep - 1 : -1;
    final several = (workflow?.steps.length ?? 1) > 1;

    return ListView(
      key: const ValueKey('workflow-run-results'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      children: [
        for (final i in indices) ...[
          if (several || byStep[i]!.length > 1)
            _StepHeading(
              number: i + 1,
              step: workflow != null && i < workflow.steps.length ? workflow.steps[i] : null,
              results: byStep[i]!,
            ),
          for (final r in _failuresFirst(byStep[i]!))
            _HostResultRow(
              key: ValueKey('workflow-run-row-${r.stepId}-${r.connectionId ?? 'none'}'),
              result: r,
              step: workflow != null && i < workflow.steps.length ? workflow.steps[i] : null,
              // One that failed alone says why without being opened.
              startsOpen: !r.success && !r.skipped && byStep[i]!.length == 1,
            ),
        ],
        if (controller.isRunning && activeStep >= 0)
          _RunningTile(
            stepNumber: activeStep + 1,
            done: controller.resultsOfStep(activeStep),
            hosts: controller.hostsOfStep(activeStep),
          ),
      ],
    );
  }
}

/// Failures first, then what went through, then what was skipped; each in the
/// order it came.
List<WorkflowStepResult> _failuresFirst(List<WorkflowStepResult> results) => [
      for (final r in results) if (!r.success && !r.skipped) r,
      for (final r in results) if (r.success) r,
      for (final r in results) if (r.skipped) r,
    ];

/// How a result ended, in a few words: "OK", "failed, exit 64", "skipped".
String _stateWords(AppLocalizations l10n, WorkflowStepResult r) {
  if (r.skipped) return l10n.wfRunStateSkipped;
  if (r.success) return l10n.wfRunStateOk;
  if (r.needsCredentials) return l10n.zestAutoOutcomeNeedsCreds;
  final exit = r.exitCode;
  return exit == null ? l10n.wfRunStateFailed : l10n.wfRunStateFailedExit(exit);
}

/// The heading of a step's results: its number, type and title; how many went
/// through where it ran on several hosts.
class _StepHeading extends StatelessWidget {
  const _StepHeading({required this.number, required this.step, required this.results});

  final int number;
  final WorkflowStep? step;
  final List<WorkflowStepResult> results;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = step;
    final notWell = results.where((r) => !r.success && !r.skipped).length;
    final well = results.where((r) => r.success).length;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ZestTokens.textTertiary.withValues(alpha: 0.14),
            ),
            child: Text(
              '$number',
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'JetBrainsMono',
                fontWeight: FontWeight.w700,
                color: ZestTokens.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (s != null) ...[
            Icon(stepTypeIcon(s.type), size: 13, color: ZestTokens.textTertiary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              s == null ? '' : stepTitleOf(l10n, s),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary),
            ),
          ),
          if (results.length > 1)
            Text(
              l10n.runOnHostsSummary(well, notWell),
              style: TextStyle(fontSize: 11, color: notWell > 0 ? ZestTokens.statusCritical : ZestTokens.textTertiary),
            ),
        ],
      ),
    );
  }
}

/// One result: the host's icon and "web-01: failed, exit 64" (masked while a
/// screen is recorded), how long it took, and opened, what it printed. A step
/// that runs on no host (a wait, a notice) is named by what it is.
class _HostResultRow extends ConsumerStatefulWidget {
  const _HostResultRow({super.key, required this.result, required this.step, required this.startsOpen});

  final WorkflowStepResult result;
  final WorkflowStep? step;
  final bool startsOpen;

  @override
  ConsumerState<_HostResultRow> createState() => _HostResultRowState();
}

class _HostResultRowState extends ConsumerState<_HostResultRow> {
  late bool _open = widget.startsOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final r = widget.result;
    final step = widget.step;
    final (icon, color) = r.skipped
        ? (LucideIcons.minusCircle, ZestTokens.textTertiary)
        : r.success
            ? (LucideIcons.checkCircle2, ZestTokens.statusHealthy)
            : r.needsCredentials
                ? (LucideIcons.alertTriangle, ZestTokens.statusWarning)
                : (LucideIcons.xCircle, ZestTokens.statusCritical);
    final details = r.connectionId == null ? null : ref.watch(hostsByIdProvider)[r.connectionId];
    final conn = details?.connection;
    final name = conn != null
        ? (conn.label.isNotEmpty ? Redactable.host(conn.label) : Redactable.address(conn.host)).displayIn(ref)
        : (step != null ? stepTitleOf(l10n, step) : stepTypeLabel(l10n, r.stepType));
    final hasDetails = r.error.trim().isNotEmpty || r.output.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('workflow-run-open-${r.stepId}-${r.connectionId ?? 'none'}'),
          borderRadius: BorderRadius.circular(6),
          onTap: hasDetails ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            child: Row(
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 8),
                if (conn != null) ...[
                  HostGlyph(host: conn, group: details?.group, size: 20),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    l10n.wfRunRowLine(name, _stateWords(l10n, r)),
                    key: ValueKey('workflow-run-line-${r.stepId}-${r.connectionId ?? 'none'}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: r.success ? FontWeight.w400 : FontWeight.w600,
                      color: r.success || r.skipped ? ZestTokens.textPrimary : color,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDuration(r.elapsed),
                  style: TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 14,
                  child: hasDetails
                      ? Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 14, color: ZestTokens.textTertiary)
                      : null,
                ),
              ],
            ),
          ),
        ),
        if (_open && hasDetails)
          Padding(
            key: ValueKey('workflow-run-details-${r.stepId}-${r.connectionId ?? 'none'}'),
            padding: const EdgeInsetsDirectional.fromSTEB(27, 0, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Masked while a screen is recorded: what a host said can name it.
                if (r.error.trim().isNotEmpty) _OutputBlock(text: Redactable.freeText(r.error).displayIn(ref), isError: true),
                if (r.error.trim().isNotEmpty && r.output.trim().isNotEmpty) const SizedBox(height: 6),
                if (r.output.trim().isNotEmpty) _OutputBlock(text: Redactable.freeText(r.output).displayIn(ref), isError: false),
                if (!r.success && !r.skipped)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: CopyDetailsButton(
                      detail: ErrorReport.build(what: r.error, where: 'Workflow run: a host', error: r.error),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RunningTile extends StatelessWidget {
  const _RunningTile({required this.stepNumber, required this.done, required this.hosts});

  final int stepNumber;
  final int done;
  final int hosts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      key: const ValueKey('workflow-run-running'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ZestTokens.brand,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            l10n.workflowRunningStep(stepNumber),
            style: TextStyle(
              fontSize: 12.5,
              color: ZestTokens.textSecondary,
            ),
          ),
          if (hosts > 1) ...[
            const SizedBox(width: 10),
            Text(
              l10n.runOnHostsProgress(done, hosts),
              style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

class _OutputBlock extends StatelessWidget {
  const _OutputBlock({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 160),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.border),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text.trimRight(),
          style: TextStyle(
            fontSize: 11.5,
            height: 1.4,
            fontFamily: 'JetBrainsMono',
            color: isError ? ZestTokens.statusCritical : ZestTokens.textPrimary,
          ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  if (d.inSeconds < 60) {
    return '${formatDecimal(d.inMilliseconds / 1000)}s';
  }
  return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
}
