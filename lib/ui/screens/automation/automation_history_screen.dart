import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart' show AutomationHistoryData;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/utils/number_text.dart';

/// Screen displaying the log of past automation runs.
///
/// Each entry is tappable and expands to show full stdout/stderr,
/// exit code, and elapsed time. A clear-all button in the app bar
/// wipes the log after confirmation. Includes search and filter
/// functionality for narrowing down results.
class AutomationHistoryScreen extends ConsumerStatefulWidget {
  const AutomationHistoryScreen({super.key});

  @override
  ConsumerState<AutomationHistoryScreen> createState() =>
      _AutomationHistoryScreenState();
}

class _AutomationHistoryScreenState
    extends ConsumerState<AutomationHistoryScreen> {
  String _searchQuery = '';
  String? _actionFilter; // null = all, or 'execute'/'snippet'/'batch'/'connect'
  String? _statusFilter; // null = all, 'success', or 'failed'

  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<AutomationHistoryData> _applyFilters(List<AutomationHistoryData> log) {
    return log.where((entry) {
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        if (!entry.connectionId.toLowerCase().contains(q) &&
            !entry.command.toLowerCase().contains(q) &&
            !entry.stdout.toLowerCase().contains(q) &&
            !(entry.snippetName?.toLowerCase().contains(q) ?? false)) {
          return false;
        }
      }
      if (_actionFilter != null && entry.action != _actionFilter) return false;
      if (_statusFilter == 'success' && !entry.success) return false;
      if (_statusFilter == 'failed' && entry.success) return false;
      return true;
    }).toList();
  }

  bool get _hasActiveFilters =>
      _searchQuery.isNotEmpty ||
      _actionFilter != null ||
      _statusFilter != null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final asyncEntries = ref.watch(automationLogProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.automationHistoryTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          // Only show clear button when we have data
          asyncEntries.maybeWhen(
            data: (entries) => entries.isNotEmpty
                ? IconButton(
                    icon: const Icon(LucideIcons.trash2, size: 22),
                    tooltip: l10n.commonClearAll,
                    onPressed: () => _confirmClearAll(context),
                  )
                : null,
            orElse: () => null,
          ) ?? const SizedBox.shrink(),
        ],
      ),
      body: asyncEntries.when(
        // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
        skipLoadingOnReload: true,
        loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.brandOrange),
        ),
        error: (error, stack) => LoadErrorState(
          message: l10n.automationRunsNotLoaded,
          where: 'Loading the automation history',
          error: error,
          stack: stack,
          onRetry: () => ref.invalidate(automationLogProvider),
        ),
        data: (entries) {
          if (entries.isEmpty) return const _EmptyState();

          final filtered = _applyFilters(entries);

          return Column(
            children: [
              // ── Search bar ─────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: l10n.automationHistorySearchHint,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                    prefixIcon: Icon(
                      LucideIcons.search,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            tooltip: AppLocalizations.of(context)!.emptyClearSearch,
                            icon: Icon(
                              LucideIcons.x,
                              size: 18,
                              color: AppColors.textSecondary,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppColors.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: AppColors.divider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: AppColors.divider),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: AppColors.brandOrange,
                      ),
                    ),
                  ),
                  onChanged: (value) =>
                      setState(() => _searchQuery = value.trim()),
                ),
              ),

              // ── Filter chips ───────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      // Action type filters
                      _buildActionChip(l10n.automationHistoryFilterAll, null),
                      _buildActionChip(l10n.automationHistoryActionExecute, 'execute'),
                      _buildActionChip(l10n.automationHistoryActionSnippet, 'snippet'),
                      _buildActionChip(l10n.automationHistoryActionBatch, 'batch'),
                      _buildActionChip(l10n.commonConnect, 'connect'),
                      // Every kind the log holds has its filter: a session
                      // opened by automation, and a workflow (they had none).
                      _buildActionChip(l10n.automationHistoryActionOpen, 'open'),
                      _buildActionChip(l10n.automationHistoryActionWorkflow, 'workflow'),
                      // Divider
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        child: Container(
                          width: 1,
                          color: AppColors.divider,
                        ),
                      ),
                      // Status filters
                      _buildStatusChip(l10n.automationHistoryFilterAll, null),
                      _buildStatusChip(l10n.automationHistoryStatusSuccess, 'success'),
                      _buildStatusChip(l10n.automationHistoryStatusFailed, 'failed'),
                    ],
                  ),
                ),
              ),

              // ── Result count ───────────────────────────────
              if (_hasActiveFilters)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.automationHistoryResultCount(
                        filtered.length,
                        entries.length,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),

              // ── Filtered list ──────────────────────────────
              Expanded(
                child: filtered.isEmpty
                    ? ZestEmptyState(
                        icon: LucideIcons.searchX,
                        title: l10n.emptyNoMatchingEntries,
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) =>
                            _LogEntryCard(entry: filtered[index]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildActionChip(String label, String? value) {
    final selected = _actionFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? AppColors.background : AppColors.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        selected: selected,
        onSelected: (_) => setState(() => _actionFilter = value),
        selectedColor: AppColors.brandOrange,
        backgroundColor: AppColors.surface,
        side: BorderSide(
          color: selected ? AppColors.brandOrange : AppColors.divider,
        ),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
    );
  }

  Widget _buildStatusChip(String label, String? value) {
    final selected = _statusFilter == value;
    final chipColor = value == 'success'
        ? AppColors.success
        : value == 'failed'
            ? AppColors.error
            : AppColors.brandOrange;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? AppColors.background : AppColors.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        selected: selected,
        onSelected: (_) => setState(() => _statusFilter = value),
        selectedColor: chipColor,
        backgroundColor: AppColors.surface,
        side: BorderSide(
          color: selected ? chipColor : AppColors.divider,
        ),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
    );
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    // The app's own question (it was a plain dialog built here).
    final sure = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.automationHistoryClearDialogTitle,
      body: l10n.automationHistoryClearDialogMessage,
      confirmLabel: l10n.automationHistoryClearAllButton,
    );
    if (sure == true) ref.read(automationProvider.notifier).clearLog();
  }
}

// ══════════════════════════════════════════════════════════════════
// Empty State
// ══════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // History is a byproduct of running automations - nothing for the user to
    // create here, so it carries no call to action.
    return ZestEmptyState(
      icon: LucideIcons.history,
      title: l10n.automationHistoryEmptyTitle,
      message: l10n.automationHistoryEmptyMessage,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Log Entry Card (expandable)
// ══════════════════════════════════════════════════════════════════

class _LogEntryCard extends StatefulWidget {
  final AutomationHistoryData entry;

  const _LogEntryCard({required this.entry});

  @override
  State<_LogEntryCard> createState() => _LogEntryCardState();
}

class _LogEntryCardState extends State<_LogEntryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Collapsed summary row ────────────────────────
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    // Status icon
                    _StatusIcon(success: entry.success),
                    const SizedBox(width: 10),

                    // Main content column
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Action label + connection name
                          Row(
                            children: [
                              _ActionChip(action: entry.action),
                              const SizedBox(width: 8),
                              Expanded(
                                // The column holds the target as the caller
                                // named it (a saved label or an id): the
                                // free-text rule masks a registered name and
                                // leaves an opaque id alone (recording mode).
                                child: RedactedText(
                                  Redactable.freeText(entry.connectionId),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.onSurface,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),

                          // Command text (monospace, single line)
                          Text(
                            entry.command,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'JetBrainsMono',
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),

                          // Timestamp + elapsed, the elapsed time on the
                          // next line where the row cannot hold both (a
                          // date ran over the row at a large text size).
                          Wrap(
                            spacing: 12,
                            runSpacing: 2,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    LucideIcons.clock,
                                    size: 12,
                                    color: AppColors.onSurfaceDim.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      timeAgoWords(AppLocalizations.of(context)!, entry.timestamp),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.onSurfaceDim,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    LucideIcons.timer,
                                    size: 12,
                                    color: AppColors.onSurfaceDim.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      _formatElapsed(entry.elapsedMs),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.onSurfaceDim,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Expand chevron
                    AnimatedRotation(
                      turns: _expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        LucideIcons.chevronRight,
                        size: 20,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Expanded detail view ─────────────────────────
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: _ExpandedDetail(entry: entry),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Status Icon
// ══════════════════════════════════════════════════════════════════

class _StatusIcon extends StatelessWidget {
  final bool success;

  const _StatusIcon({required this.success});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: (success ? AppColors.success : AppColors.error).withValues(alpha: 0.15),
      ),
      child: Icon(
        success ? LucideIcons.check : LucideIcons.x,
        size: 18,
        color: success ? AppColors.success : AppColors.error,
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Action Chip
// ══════════════════════════════════════════════════════════════════

class _ActionChip extends StatelessWidget {
  final String action;

  const _ActionChip({required this.action});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _actionColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _actionLabel(l10n),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _actionColor,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  String _actionLabel(AppLocalizations l10n) {
    switch (action) {
      case 'execute':
        return l10n.automationHistoryActionExecuteBadge;
      case 'snippet':
        return l10n.automationHistoryActionSnippetBadge;
      case 'batch':
        return l10n.automationHistoryActionBatchBadge;
      case 'connect':
        return l10n.automationHistoryActionConnectBadge;
      // In the person's language too (they showed as OPEN and WORKFLOW).
      case 'open':
        return l10n.automationHistoryActionOpenBadge;
      case 'workflow':
        return l10n.automationHistoryActionWorkflowBadge;
      default:
        return action.toUpperCase();
    }
  }

  Color get _actionColor {
    switch (action) {
      case 'execute':
        return AppColors.brandOrange;
      case 'snippet':
        return AppColors.categoryServices;
      case 'batch':
        return AppColors.cloudSync;
      case 'connect':
        return AppColors.success;
      default:
        return AppColors.textSecondary;
    }
  }
}

// ══════════════════════════════════════════════════════════════════
// Expanded Detail View
// ══════════════════════════════════════════════════════════════════

class _ExpandedDetail extends StatelessWidget {
  final AutomationHistoryData entry;

  const _ExpandedDetail({required this.entry});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 12),

          // ── Command ──────────────────────────────────────
          _DetailLabel(label: l10n.automationHistoryLabelCommand),
          const SizedBox(height: 4),
          _MonoBlock(text: entry.command),
          const SizedBox(height: 12),

          // ── Exit code + elapsed ───────────────────────────
          Row(
            children: [
              _DetailPill(
                label: l10n.automationHistoryLabelExitCode,
                value: entry.exitCode?.toString() ?? '--',
                color: entry.success ? AppColors.success : AppColors.error,
              ),
              const SizedBox(width: 12),
              _DetailPill(
                label: l10n.automationHistoryLabelElapsed,
                value: _formatElapsed(entry.elapsedMs),
                color: AppColors.brandOrange,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Stdout ────────────────────────────────────────
          if (entry.stdout.isNotEmpty) ...[
            Row(
              children: [
                _DetailLabel(label: l10n.automationHistoryLabelOutput),
                const Spacer(),
                _CopyButton(text: entry.stdout),
              ],
            ),
            const SizedBox(height: 4),
            _MonoBlock(text: entry.stdout),
            const SizedBox(height: 12),
          ],

          // ── Stderr ────────────────────────────────────────
          if (entry.stderr.isNotEmpty) ...[
            _DetailLabel(label: l10n.automationHistoryLabelStderr, isError: true),
            const SizedBox(height: 4),
            _MonoBlock(text: entry.stderr, isError: true),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Detail Sub-widgets
// ══════════════════════════════════════════════════════════════════

class _DetailLabel extends StatelessWidget {
  final String label;
  final bool isError;

  const _DetailLabel({required this.label, this.isError = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: isError ? AppColors.error : AppColors.onSurfaceDim,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _DetailPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _DetailPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11,
              color: color.withValues(alpha: 0.7),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'JetBrainsMono',
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonoBlock extends StatelessWidget {
  final String text;
  final bool isError;

  const _MonoBlock({required this.text, this.isError = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError
            ? AppColors.error.withValues(alpha: 0.08)
            : AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError
              ? AppColors.error.withValues(alpha: 0.2)
              : AppColors.divider,
        ),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'JetBrainsMono',
          height: 1.5,
          color: isError ? AppColors.error : AppColors.onSurface,
        ),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  final String text;

  const _CopyButton({required this.text});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        if (!mounted) return;
        setState(() => _copied = true);
        Future.delayed(
          const Duration(seconds: 2),
          () {
            if (mounted) setState(() => _copied = false);
          },
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? LucideIcons.check : LucideIcons.copy,
              size: 14,
              color: _copied ? AppColors.success : AppColors.accentInk,
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? l10n.automationHistoryCopied : l10n.copy,
              style: TextStyle(
                fontSize: 11,
                color: _copied ? AppColors.success : AppColors.accentInk,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Time Formatting Helpers
// ══════════════════════════════════════════════════════════════════

/// Formats elapsed milliseconds as a compact duration string.
String _formatElapsed(int ms) {
  if (ms < 1000) return '${ms}ms';
  if (ms < 10000) return '${formatDecimal(ms / 1000)}s';
  if (ms < 60000) return '${formatDecimal(ms / 1000, digits: 0)}s';

  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  return '${minutes}m ${seconds}s';
}
