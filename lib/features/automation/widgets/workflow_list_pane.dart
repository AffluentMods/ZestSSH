import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/workflow.dart';
import '../../../providers/workflow_provider.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/zest_button.dart';
import '../../../ui/widgets/zest_status.dart';
import '../state/workflow_run_status.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import '../workflow_templates.dart';

/// The left-hand workflow list of the 1.7 Automation master/detail. Each row
/// carries a last-run status pill (sourced from the session run summaries, with
/// a fallback to the persisted last-run time) so a failed run is visible
/// without opening the workflow.
class WorkflowListPane extends ConsumerStatefulWidget {
  const WorkflowListPane({
    super.key,
    required this.selectedId,
    required this.onSelect,
    required this.onCreate,
    this.onTemplate,
    this.templateInUse,
  });

  /// Currently-open workflow id (or the new-workflow sentinel), for highlight.
  final String? selectedId;
  final ValueChanged<String> onSelect;

  /// Rebind the detail pane to a fresh new workflow. Drives the secondary
  /// "New workflow" affordances in this pane (the header button + the empty
  /// state) - the solid-orange PRIMARY create stays in the detail pane so this
  /// pane keeps to at most one primary action (it has none).
  final VoidCallback onCreate;

  /// Open a template in the editor (the empty page's cards); none, no cards.
  final ValueChanged<WorkflowTemplate>? onTemplate;

  /// The template open in the editor beside the list, outlined.
  final WorkflowTemplate? templateInUse;

  @override
  ConsumerState<WorkflowListPane> createState() => _WorkflowListPaneState();
}

class _WorkflowListPaneState extends ConsumerState<WorkflowListPane> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final workflows = ref.watch(workflowsProvider);
    final lastRuns = ref.watch(workflowLastRunProvider);

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? workflows
        : workflows.where((w) => w.name.toLowerCase().contains(q)).toList();

    return Container(
      color: ZestTokens.surfaceBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // With no workflow yet the page is the templates, and there is
          // nothing to search.
          if (workflows.isNotEmpty) ...[
            _Header(
              query: _query,
              onQuery: (v) => setState(() => _query = v),
            ),
            Divider(height: 1, color: ZestTokens.border),
          ],
          Expanded(
            child: workflows.isEmpty && widget.onTemplate != null
                ? _templates(context)
                : filtered.isEmpty
                ? _emptyList(context)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final wf = filtered[index];
                      return _WorkflowRow(
                        workflow: wf,
                        summary: lastRuns[wf.id],
                        selected: widget.selectedId == wf.id,
                        onTap: () => widget.onSelect(wf.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// The empty page : no workflows
  /// yet, what workflows do, a card for each template, and an empty one.
  Widget _templates(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.zestAutoListEmptyTitle,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              l10n.autoEmptyBody,
              style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textTertiary),
            ),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, c) {
            final columns = c.maxWidth >= 560 ? 2 : 1;
            final width = (c.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final t in WorkflowTemplate.values)
                  SizedBox(
                    width: width,
                    child: _TemplateCard(
                      template: t,
                      inUse: widget.templateInUse == t,
                      onUse: () => widget.onTemplate!(t),
                    ),
                  ),
              ],
            );
          }),
          const SizedBox(height: 16),
          ZestButton(
            key: const ValueKey('automation-from-scratch'),
            label: l10n.autoTplScratch,
            icon: LucideIcons.plus,
            variant: ZestButtonVariant.ghost,
            onPressed: widget.onCreate,
          ),
        ],
      ),
    );
  }

  Widget _emptyList(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The detail pane on the right already shows a ready-to-fill new-workflow
    // form, but the list's tier-2 empty state still carries a SECONDARY create
    // affordance so the fill path is discoverable from this pane too (the solid
    // primary create stays on the right).
    // Scrolls where the pane is less tall than it (at a window's least
    // height it ran over its foot).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The empty state's look, as every page's (ZestEmptyState).
            Icon(
              LucideIcons.workflow,
              size: 48,
              color: ZestTokens.textSecondary.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.zestAutoListEmptyTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ZestTokens.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                l10n.zestAutoListEmptyBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: ZestTokens.textTertiary,
                ),
              ),
            ),
            // (No button here: New workflow is at the top of this list,
            // and a new workflow's form is open beside it.)
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.query,
    required this.onQuery,
  });

  final String query;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    // The search. (New workflow is the page head's.)
    //
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: _SearchField(query: query, onChanged: onQuery),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.query, required this.onChanged});

  final String query;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.query,
  );
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The one list-pane search field of the app: a single box with its
    // glyph inside, the text centred, the placeholder muted.
    return ZestListSearchField(
      controller: _controller,
      focusNode: _focus,
      hintText: MaterialLocalizations.of(context).searchFieldLabel,
      onChanged: widget.onChanged,
    );
  }
}

class _WorkflowRow extends StatefulWidget {
  const _WorkflowRow({
    required this.workflow,
    required this.summary,
    required this.selected,
    required this.onTap,
  });

  final Workflow workflow;
  final WorkflowRunSummary? summary;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_WorkflowRow> createState() => _WorkflowRowState();
}

class _WorkflowRowState extends State<_WorkflowRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final wf = widget.workflow;
    final selected = widget.selected;
    // The last-run state drives BOTH the left accent bar and the outcome text
    // colour, so a failed workflow reads as failed at a glance. Selection
    // changes the background/border but leaves the state bar its own colour -
    // a selected failed row still reads failed.
    final outcome = resolveWorkflowOutcome(
      l10n,
      widget.summary,
      fallbackLastRun: wf.lastRunAt,
    );
    final barColor = zestStatusColor(outcome.kind);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: selected
                  ? ZestTokens.brandSubtle
                  : (_hover ? ZestTokens.surfaceHover : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? ZestTokens.brandBorder : ZestTokens.border,
              ),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 3px last-run state accent bar, flush on the leading edge.
                  Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(8),
                        bottomLeft: Radius.circular(8),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Line 1: name + last-run outcome (right).
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  wf.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: ZestTokens.textPrimary,
                                  ),
                                ),
                              ),
                              if (!wf.enabled) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  LucideIcons.pause,
                                  size: 12,
                                  color: ZestTokens.textTertiary,
                                ),
                              ],
                              if (outcome.label.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  outcome.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: barColor,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          // Line 2: step count + plain-language schedule +
                          // relative time (right).
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _metaLine(l10n, wf),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ZestTokens.textTertiary,
                                  ),
                                ),
                              ),
                              if (outcome.relative != null) ...[
                                const SizedBox(width: 8),
                                Text(
                                  outcome.relative!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'JetBrainsMono',
                                    color: ZestTokens.textTertiary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "N steps".
  String _metaLine(AppLocalizations l10n, Workflow wf) => l10n.zestAutoRowStepCount(wf.steps.length);
}

/// A template of the empty page: its icon, title and what it does, and Use
/// template (or, where it is the one open beside the list, that it is).
class _TemplateCard extends StatelessWidget {
  const _TemplateCard({required this.template, required this.inUse, required this.onUse});

  final WorkflowTemplate template;
  final bool inUse;
  final VoidCallback onUse;

  IconData get _icon => switch (template) {
        WorkflowTemplate.updatePackages => LucideIcons.packageCheck,
        WorkflowTemplate.restartContainer => LucideIcons.box,
        WorkflowTemplate.checkDiskSpace => LucideIcons.hardDrive,
        WorkflowTemplate.backUpFolder => LucideIcons.folderSync,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: ValueKey('automation-template-${template.name}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: inUse ? ZestTokens.brandSubtle : ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: inUse ? ZestTokens.brandBorder : ZestTokens.border, width: inUse ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: ZestTokens.brandIconBg, borderRadius: BorderRadius.circular(8)),
            child: Icon(_icon, size: 16, color: ZestTokens.brandInk),
          ),
          const SizedBox(height: 12),
          Text(
            template.title(l10n),
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
          ),
          const SizedBox(height: 4),
          // Two lines tall whatever the system's text size, so the cards
          // beside one another keep one height: 38 at the size the app is
          // drawn at left two lines 38 of the 46 they need at 1.25 times.
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(38),
            child: Text(
              template.body(l10n),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary),
            ),
          ),
          const SizedBox(height: 12),
          if (inUse)
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  Icon(LucideIcons.arrowRight, size: 14, color: ZestTokens.brandInk),
                  const SizedBox(width: 6),
                  Text(l10n.autoTplEditingRight,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.brandInk)),
                ],
              ),
            )
          else
            ZestButton(
              label: l10n.autoTplUse,
              variant: ZestButtonVariant.secondary,
              onPressed: onUse,
            ),
        ],
      ),
    );
  }
}
