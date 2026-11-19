import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/triggers/alert_presets.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/triggers/widgets/trigger_edit_dialog.dart' show kTriggerHighlightPresets;
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/edit_drafts.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/zest_master_detail.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/ui/widgets/zest_page_header.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/utils/error_report.dart';

// ══════════════════════════════════════════════════════════════════
// Alerts: a computer's page of terminal triggers (3.0). A trigger can
// notify, play a sound and highlight what it
// matched, and nothing else, so the page calls them alerts (its data, routes
// and providers keep the trigger names).
//
// The head: the title, New alert, a filter and All / On / Off. A row per
// alert: a bell in its colour, the name and where it watches, the pattern,
// what it does, an on/off switch. Beside it the editor: Simple (a preset or
// your own text, no regular expression to write) or Regex, a live test line,
// what happens when it matches, and where it watches.
// ══════════════════════════════════════════════════════════════════

/// Which alerts the list shows.
enum _Show { all, on, off }

/// The alert editor's unsaved edits while the Alerts page is away
/// ([EditDrafts]), by the alert's id (or the new alert's key).
final alertDraftsProvider = editDraftsProvider<AlertKeptEdit>();

/// The key a new alert's form is kept under.
const String _kNewAlertDraftKey = '__new__';

class TriggersView extends ConsumerStatefulWidget {
  const TriggersView({super.key});

  @override
  ConsumerState<TriggersView> createState() => _TriggersViewState();
}

class _TriggersViewState extends ConsumerState<TriggersView> with KeepsEditDrafts<TriggersView, AlertKeptEdit> {
  String? _selectedId;

  /// Unsaved edits kept as the page went, which the editor opens with, and
  /// the editor's [_token] they are for (a new open starts afresh).
  AlertKeptEdit? _kept;
  int? _keptToken;

  /// The page is going (its editor's edits are kept as it goes, and only
  /// then: a pane that goes for another alert, New or Cancel lets them go).
  bool _leaving = false;

  /// The alert just created, until the list has it: the list hears of a save
  /// a moment after it is done, and until then it is no deleted selection.
  String? _justCreated;
  int _token = 0; // bumped to force the editor pane to reset
  String _query = '';
  _Show _show = _Show.all;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Unsaved edits kept as the page went (a terminal was shown in its
    // place): the same editor opens again, with them, as unsaved. A change
    // of profile builds the drafts anew, empty, and the form open here goes.
    final kept = takeEditDraft(alertDraftsProvider, onRenewed: _close);
    if (kept != null) {
      _kept = kept;
      _keptToken = _token;
      _selectedId = kept.triggerId;
      // Until the list is read, the alert is no deleted selection.
      if (ref.read(triggersProvider).valueOrNull == null) _justCreated = kept.triggerId;
    }
  }

  @override
  void deactivate() {
    _leaving = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _leaving = false;
  }

  /// The editor beside the list went with unsaved edits: kept, in memory,
  /// where the page is going (the shell shows a terminal in its place).
  void _editorGone(AlertKeptEdit edit) {
    if (_leaving) keepEditDraft(edit.triggerId ?? _kNewAlertDraftKey, edit);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _new(bool narrow) {
    if (narrow) {
      _pushEditor(null);
      return;
    }
    setState(() {
      _selectedId = null;
      _token++;
    });
  }

  void _select(TerminalTrigger t, bool narrow) {
    if (narrow) {
      _pushEditor(t);
      return;
    }
    _selectId(t.id);
  }

  /// Narrow single-column layout: the editor as a full-screen route (as
  /// Snippets does), since no pane stands beside the list.
  Future<void> _pushEditor(TerminalTrigger? trigger) {
    final conns = ref.read(triggerScopeConnectionsProvider).valueOrNull ?? const <Connection>[];
    final nav = Navigator.of(context);
    return ZestMasterDetail.pushDetail<void>(
      context,
      _AlertEditorPane(
        trigger: trigger,
        connections: conns,
        onSaved: (_) => nav.pop(),
        onDeleted: () => nav.pop(),
        onClose: () => nav.pop(),
      ),
    );
  }

  void _selectId(String id) => setState(() {
        _selectedId = id;
        _token++;
      });

  /// A save from the pane beside the list: the pane stays as it is, with what
  /// was saved in it. (This reset it, from the list's row of before the save,
  /// which the list had not yet heard of: the colour just saved went back and
  /// the dot went out, as if nothing had been saved: no save, no error,
  /// and a changed colour did nothing.)
  void _saved(String id) => setState(() {
        if (_selectedId != id) _justCreated = id;
        _selectedId = id;
      });

  void _close() => setState(() {
        _selectedId = null;
        _token++;
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final all = ref.watch(triggersProvider).valueOrNull ?? const [];
    final conns = ref.watch(triggerScopeConnectionsProvider).valueOrNull ?? const <Connection>[];

    TerminalTrigger? selected;
    for (final t in all) {
      if (t.id == _selectedId) selected = t;
    }
    if (selected != null && selected.id == _justCreated) _justCreated = null;
    // A deleted selection falls back to the New pane.
    if (_selectedId != null && selected == null && _selectedId != _justCreated) {
      _selectedId = null;
      _token++;
    }

    return ColoredBox(
      color: ZestTokens.surfaceBase,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < ZestSizing.singleColumnBreakpoint;
          return ZestMasterDetail(
            screenId: 'triggers',
            // The list is the page; the editor stands beside it.
            initialRatio: 0.64,
            listPane: _listPane(l10n, all, conns, narrow),
            detailPane: _AlertEditorPane(
              key: ValueKey('alert-pane-$_token'),
              trigger: selected,
              connections: conns,
              onSaved: _saved,
              onDeleted: _close,
              onClose: _close,
              kept: _keptToken == _token ? _kept : null,
              onGone: _editorGone,
            ),
          );
        },
      ),
    );
  }

  Widget _listPane(AppLocalizations l10n, List<TerminalTrigger> all, List<Connection> conns, bool narrow) {
    final q = _query.trim().toLowerCase();
    final on = all.where((t) => t.enabled).length;
    final shown = [
      for (final t in all)
        if ((q.isEmpty || t.name.toLowerCase().contains(q) || t.pattern.toLowerCase().contains(q)) &&
            switch (_show) {
              _Show.all => true,
              _Show.on => t.enabled,
              _Show.off => !t.enabled,
            })
          t,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestPageBand(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
            // One line where the pane is wide; the filter and All / On / Off
            // under the title where it is not.
            child: LayoutBuilder(builder: (context, c) {
              final title = GuideTitle(
                feature: 'alerts',
                title: Text(
                  l10n.trgTitle,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    color: ZestTokens.textPrimary,
                    height: 1.2,
                  ),
                ),
              );
              final newAlert = ZestButton(
                key: const ValueKey('alerts-new'),
                label: l10n.trgNewTrigger,
                icon: LucideIcons.plus,
                variant: ZestButtonVariant.primary,
                onPressed: () => _new(narrow),
              );
              final search = ZestListSearchField(
                controller: _search,
                hintText: l10n.trgFilterHint,
                onChanged: (v) => setState(() => _query = v),
              );
              final filter = ZestModeToggle(
                key: const ValueKey('alerts-filter'),
                segments: [
                  ZestModeSegment(id: 'all', label: l10n.alertsFilterAll(all.length)),
                  ZestModeSegment(id: 'on', label: l10n.alertsFilterOn(on)),
                  ZestModeSegment(id: 'off', label: l10n.alertsFilterOff(all.length - on)),
                ],
                selectedId: _show.name,
                onChanged: (id) => setState(() => _show = _Show.values.byName(id)),
              );
              if (c.maxWidth >= 820) {
                return Row(
                  children: [
                    title,
                    const SizedBox(width: 16),
                    newAlert,
                    const SizedBox(width: 12),
                    Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: search)),
                    const Spacer(),
                    const SizedBox(width: 12),
                    filter,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [Expanded(child: title), newAlert]),
                  const SizedBox(height: 10),
                  Row(children: [Expanded(child: search), const SizedBox(width: 12), filter]),
                ],
              );
            }),
          ),
        ),
        Expanded(
          child: all.isEmpty
              ? ZestEmptyState(
                  icon: LucideIcons.bellRing,
                  title: l10n.trgEmptyTitle,
                  message: l10n.trgEmptyMessage,
                  // Beside the list a new alert's form is already open.
                  actionLabel: narrow ? l10n.trgNewTrigger : null,
                  onAction: () => _new(narrow),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                  children: [
                    // True of every alert: the engine matches each line with
                    // its escape codes (colours) taken out (stripAnsi).
                    Text(
                      l10n.alertsWatchLine,
                      style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
                    ),
                    const SizedBox(height: 14),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: ZestEmptyState(icon: LucideIcons.searchX, title: l10n.cmdhNoMatches),
                      )
                    else
                      for (final t in shown)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _AlertRow(
                            trigger: t,
                            connections: conns,
                            selected: t.id == _selectedId,
                            onTap: () => _select(t, narrow),
                            onToggle: (v) => ref.read(triggerCrudProvider).setEnabled(t.id, v),
                            onDelete: () => _deleteFromRow(t),
                          ),
                        ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _deleteFromRow(TerminalTrigger t) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.trgDeleteTitle,
      body: l10n.trgDeleteConfirm(t.name),
      confirmLabel: l10n.delete,
    );
    if (ok != true) return;
    await ref.read(triggerCrudProvider).delete(t.id);
    if (mounted && _selectedId == t.id) _close();
  }
}

/// Where an alert watches, in words: all hosts, or its host.
String _scopeLabel(AppLocalizations l10n, WidgetRef ref, String? connectionId, List<Connection> connections) {
  if (connectionId == null) return l10n.trgAllHosts;
  for (final c in connections) {
    if (c.id == connectionId) return Redactable.host(c.label).displayIn(ref);
  }
  return l10n.trgUnknownHost;
}

/// The colour an alert is shown in: its highlight's, or none.
Color? _alertColor(TerminalTrigger t) =>
    t.highlight ? Color(t.highlightColor ?? kTriggerHighlightPresets.first) : null;

// ── A row of the list ───────────────────────────────────────────────────

class _AlertRow extends ConsumerStatefulWidget {
  const _AlertRow({
    required this.trigger,
    required this.connections,
    required this.selected,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  final TerminalTrigger trigger;
  final List<Connection> connections;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  ConsumerState<_AlertRow> createState() => _AlertRowState();
}

class _AlertRowState extends ConsumerState<_AlertRow> {
  bool _hovering = false;
  bool _focused = false;

  /// True while the row's menu is open: the three dots stay where it came
  /// from.
  bool _menuOpen = false;

  TerminalTrigger get t => widget.trigger;

  void _showContextMenu(BuildContext context, Offset position) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    _openMenu(RelativeRect.fromRect(Rect.fromLTWH(position.dx, position.dy, 1, 1), Offset.zero & overlay.size));
  }

  /// The row's one menu, from a right click and from the three dots.
  Future<void> _openMenu(RelativeRect position) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _menuOpen = true);
    final value = await showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: ZestTokens.surfaceElevated,
      items: [
        PopupMenuItem(value: 'edit', child: Text(l10n.edit)),
        PopupMenuItem(value: 'toggle', child: Text(t.enabled ? l10n.commonDisable : l10n.commonEnable)),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Text(l10n.delete, style: TextStyle(color: ZestTokens.statusCritical)),
        ),
      ],
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    switch (value) {
      case 'edit':
        widget.onTap();
      case 'toggle':
        widget.onToggle(!t.enabled);
      case 'delete':
        widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final off = !t.enabled;
    final colour = _alertColor(t);
    final selected = widget.selected;
    final showDots = _hovering || _focused || _menuOpen;

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (h) => setState(() => _hovering = h),
      onShowFocusHighlight: (f) => setState(() => _focused = f),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context) ? (d) => _showContextMenu(context, d.globalPosition) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            color: selected ? ZestTokens.brandSubtle : ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected || _focused
                  ? ZestTokens.brandBorder
                  : _hovering
                      ? ZestTokens.borderStrong
                      : ZestTokens.border,
            ),
          ),
          child: LayoutBuilder(builder: (context, c) {
            final bell = Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colour == null ? ZestTokens.surfaceChip : colour.withValues(alpha: off ? 0.08 : 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                LucideIcons.bell,
                size: 16,
                color: colour == null || off ? ZestTokens.textSecondary : colour,
              ),
            );
            final names = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // A name can hold a host ("web-01 down"): through the
                // recording-mode scan, as the pattern is.
                RedactedText(
                  Redactable.freeText(t.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: off ? ZestTokens.textSecondary : ZestTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _scopeLabel(l10n, ref, t.connectionId, widget.connections),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                      ),
                    ),
                    Flexible(child: _TriggerStatsLabel(triggerId: t.id)),
                  ],
                ),
              ],
            );
            final pattern = Tooltip(
              message: Redactable.freeText(t.pattern).displayIn(ref),
              waitDuration: const Duration(milliseconds: 500),
              child: RedactedText(
                Redactable.freeText(t.pattern),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'JetBrainsMono',
                  color: off ? ZestTokens.textTertiary : ZestTokens.textSecondary,
                ),
              ),
            );
            // What it does.
            final chips = [
              if (t.notify) _Chip(label: l10n.alertsChipNotify),
              if (t.notify && t.playSound) ...[const SizedBox(width: 6), _Chip(label: l10n.alertsChipSound)],
              if (t.highlight) ...[
                const SizedBox(width: 6),
                _Chip(label: l10n.alertsChipHighlight, dot: colour),
              ],
            ];
            final controls = [
              SizedBox(
                width: 28,
                child: showDots ? MenuDotsButton(tooltip: l10n.zestCommonMoreActions, onOpen: _openMenu) : null,
              ),
              const SizedBox(width: 4),
              // Said by the alert's name (it was an unnamed switch).
              ZestSwitch(value: t.enabled, semanticLabel: t.name, onChanged: widget.onToggle),
            ];
            // A pattern this app will not run, written here or by a teammate.
            final refused = triggerPatternRefused(t.pattern, caseSensitive: t.caseSensitive);
            // One line where the list is wide; the pattern and the chips
            // under the name where it is not.
            if (c.maxWidth >= 640) {
              final row = Row(
                children: [
                  bell,
                  const SizedBox(width: 14),
                  SizedBox(width: 180, child: names),
                  const SizedBox(width: 16),
                  Expanded(child: pattern),
                  const SizedBox(width: 12),
                  ...chips,
                  const SizedBox(width: 14),
                  ...controls,
                ],
              );
              if (!refused) return row;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [row, const SizedBox(height: 8), _RefusedLine(triggerId: t.id)],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [bell, const SizedBox(width: 14), Expanded(child: names), ...controls]),
                const SizedBox(height: 10),
                pattern,
                if (refused) ...[const SizedBox(height: 8), _RefusedLine(triggerId: t.id)],
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 0, runSpacing: 6, children: chips),
                ],
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// A small chip of what an alert does, with the highlight's colour as a dot.
/// What a row says of a pattern this app will not run.
class _RefusedLine extends StatelessWidget {
  const _RefusedLine({required this.triggerId});

  final String triggerId;

  @override
  Widget build(BuildContext context) => Text(
        AppLocalizations.of(context)!.trgPatternRefused,
        key: ValueKey('alert-refused-$triggerId'),
        style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.statusWarning),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.dot});

  final String label;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 5),
          ],
          Text(label, style: TextStyle(fontSize: 11.5, color: ZestTokens.textSecondary)),
        ],
      ),
    );
  }
}

/// " · 12× · 5m ago": how often an alert matched in this run of the app, fed
/// by the runtime's counters. Nothing until it has matched.
class _TriggerStatsLabel extends ConsumerWidget {
  const _TriggerStatsLabel({required this.triggerId});

  final String triggerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final runtime = ref.read(triggerRuntimeProvider);
    return ValueListenableBuilder<int>(
      valueListenable: runtime.statsRevision,
      builder: (context, _, _) {
        final s = runtime.statsFor(triggerId);
        if (s == null || s.count == 0) return const SizedBox.shrink();
        return Text(
          ' · ${l10n.trgMatchStat(s.count, _rel(l10n, s.last))}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
        );
      },
    );
  }

  /// When the last match was, after a dot: within a day the shared compact
  /// words ("Just now", "5m ago", "3h ago"), then the day and the month.
  static String _rel(AppLocalizations l10n, DateTime t) {
    if (DateTime.now().difference(t).inHours < 24) return timeAgoWords(l10n, t);
    return DateFormat.Md(l10n.localeName).format(t);
  }
}

// ── The editor ────────────────────────────────────────────────────────────

/// The least width of the editor's name column (wider where a name's words
/// need it: [_AlertEditorPaneState._labelWidth]).
const double _kLabelWidth = 120;

/// The alert editor's unsaved edits, kept while its page is away (a terminal
/// shown in its place), in memory only. An alert holds nothing secret.
@immutable
class AlertKeptEdit {
  const AlertKeptEdit({
    required this.triggerId,
    required this.name,
    required this.pattern,
    required this.ownText,
    required this.test,
    required this.simple,
    required this.preset,
    required this.caseSensitive,
    required this.notify,
    required this.playSound,
    required this.highlight,
    required this.highlightColor,
    required this.connectionId,
    required this.initial,
  });

  /// The alert being edited (or the one this form made); null for a new one.
  final String? triggerId;
  final String name;
  final String pattern;
  final String ownText;
  final String test;
  final bool simple;
  final AlertPreset preset;
  final bool caseSensitive;
  final bool notify;
  final bool playSound;
  final bool highlight;
  final int? highlightColor;
  final String? connectionId;

  /// The alert as it was opened or last saved, which the dot compares with.
  final AlertForm initial;
}

/// Everything the editor holds, for whether a new alert's form was touched.
typedef _AlertFields = ({
  String name,
  String pattern,
  String ownText,
  String test,
  bool simple,
  AlertPreset preset,
  bool caseSensitive,
  bool notify,
  bool playSound,
  bool highlight,
  int? highlightColor,
  String? connectionId,
});

/// A snapshot of the form, for the dirty check.
typedef AlertForm = ({
  String name,
  String pattern,
  bool caseSensitive,
  bool notify,
  bool playSound,
  bool highlight,
  int? highlightColor,
  String? connectionId,
});

/// The name a preset gives a new alert, in the person's language.
String _presetLabel(AppLocalizations l10n, AlertPreset p) => switch (p) {
      AlertPreset.errors => l10n.alertsPresetErrors,
      AlertPreset.warnings => l10n.alertsPresetWarnings,
      AlertPreset.buildFinished => l10n.alertsPresetBuildFinished,
      AlertPreset.passwordPrompt => l10n.alertsPresetPasswordPrompt,
      AlertPreset.ownText => l10n.alertsPresetOwnText,
    };

class _AlertEditorPane extends ConsumerStatefulWidget {
  const _AlertEditorPane({
    super.key,
    required this.trigger,
    required this.connections,
    required this.onSaved,
    required this.onDeleted,
    required this.onClose,
    this.kept,
    this.onGone,
  });

  /// Unsaved edits kept while the page was away: the editor opens with them,
  /// shown unsaved.
  final AlertKeptEdit? kept;

  /// The editor goes with unsaved edits (they are kept where the page is
  /// going).
  final ValueChanged<AlertKeptEdit>? onGone;

  final TerminalTrigger? trigger;
  final List<Connection> connections;
  final ValueChanged<String> onSaved;
  final VoidCallback onDeleted;
  final VoidCallback onClose;

  @override
  ConsumerState<_AlertEditorPane> createState() => _AlertEditorPaneState();
}

class _AlertEditorPaneState extends ConsumerState<_AlertEditorPane> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late final TextEditingController _ownText;
  late final TextEditingController _test;

  /// Simple (a preset, or the person's own text) or Regex.
  late bool _simple;
  late AlertPreset _preset;
  late bool _caseSensitive;
  late bool _notify;
  late bool _playSound;
  late bool _highlight;
  late int? _highlightColor;
  late String? _connectionId;

  /// What was last saved (or opened): what the dot compares the form with.
  late AlertForm _initial;

  /// The alert this pane has created, from then on what it saves to.
  String? _createdId;

  /// True while a save is running, so that it is not started twice.
  bool _saving = false;

  /// What stopped the last save, with its report, until the next try.
  ({String message, String report})? _saveFailure;

  bool get _isNew => widget.trigger == null && _createdId == null;

  @override
  void initState() {
    super.initState();
    final t = widget.trigger;
    final pattern = t?.pattern ?? AlertPreset.errors.pattern;
    final preset = AlertPreset.of(pattern);
    _simple = preset != null;
    _preset = preset ?? AlertPreset.errors;
    _name = TextEditingController(text: t?.name ?? '');
    _pattern = TextEditingController(text: pattern);
    _ownText = TextEditingController(text: AlertPreset.ownTextOf(pattern) ?? '');
    _test = TextEditingController(text: _preset.examples.isEmpty ? '' : _preset.examples.first);
    _caseSensitive = t?.caseSensitive ?? false;
    _notify = t?.notify ?? true;
    _playSound = t?.playSound ?? false;
    _highlight = t?.highlight ?? false;
    _highlightColor = t?.highlightColor ?? kTriggerHighlightPresets.first;
    _connectionId = t?.connectionId;
    _initial = _form;
    final kept = widget.kept;
    if (kept != null) {
      _name.text = kept.name;
      _pattern.text = kept.pattern;
      _ownText.text = kept.ownText;
      _test.text = kept.test;
      _simple = kept.simple;
      _preset = kept.preset;
      _caseSensitive = kept.caseSensitive;
      _notify = kept.notify;
      _playSound = kept.playSound;
      _highlight = kept.highlight;
      _highlightColor = kept.highlightColor;
      _connectionId = kept.connectionId;
      _initial = kept.initial;
      if (t == null) _createdId = kept.triggerId;
    }
  }

  bool _seeded = false;

  /// A new alert's form as it opens, untouched (null for an alert that is
  /// saved): a form that is not, goes with its edits kept.
  _AlertFields? _untouched;

  _AlertFields get _fields => (
        name: _name.text,
        pattern: _pattern.text,
        ownText: _ownText.text,
        test: _test.text,
        simple: _simple,
        preset: _preset,
        caseSensitive: _caseSensitive,
        notify: _notify,
        playSound: _playSound,
        highlight: _highlight,
        highlightColor: _highlightColor,
        connectionId: _connectionId,
      );

  /// Whether the form holds what the person changed and did not save.
  bool get _hasEdits => _isNew ? _fields != _untouched : _form != _initial;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    // A new alert is named after the preset it starts from (in the person's
    // language, which initState cannot read yet).
    final l10n = AppLocalizations.of(context)!;
    if (_isNew && _name.text.isEmpty && widget.kept == null) _name.text = _presetLabel(l10n, _preset);
    if (_isNew) {
      const preset = AlertPreset.errors;
      _untouched = (
        name: _presetLabel(l10n, preset),
        pattern: preset.pattern,
        ownText: '',
        test: preset.examples.isEmpty ? '' : preset.examples.first,
        simple: true,
        preset: preset,
        caseSensitive: false,
        notify: true,
        playSound: false,
        highlight: false,
        highlightColor: kTriggerHighlightPresets.first,
        connectionId: null,
      );
    }
    for (final c in [_name, _pattern, _ownText, _test]) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    final gone = widget.onGone;
    if (gone != null && _hasEdits) {
      gone(AlertKeptEdit(
        triggerId: widget.trigger?.id ?? _createdId,
        name: _name.text,
        pattern: _pattern.text,
        ownText: _ownText.text,
        test: _test.text,
        simple: _simple,
        preset: _preset,
        caseSensitive: _caseSensitive,
        notify: _notify,
        playSound: _playSound,
        highlight: _highlight,
        highlightColor: _highlightColor,
        connectionId: _connectionId,
        initial: _initial,
      ));
    }
    for (final c in [_name, _pattern, _ownText, _test]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The pattern that is saved: the preset's, the own text's, or the one
  /// typed in Regex mode.
  String get _effectivePattern {
    if (!_simple) return _pattern.text.trim();
    if (_preset == AlertPreset.ownText) {
      return _ownText.text.trim().isEmpty ? '' : AlertPreset.ownTextPattern(_ownText.text);
    }
    return _preset.pattern;
  }

  AlertForm get _form => (
        name: _name.text.trim(),
        pattern: _effectivePattern,
        caseSensitive: _caseSensitive,
        notify: _notify,
        playSound: _notify && _playSound,
        highlight: _highlight,
        highlightColor: _highlight ? _highlightColor : null,
        connectionId: _connectionId,
      );

  bool get _dirty => _isNew || _form != _initial;

  String? get _patternError {
    if (triggerPatternRefused(_effectivePattern, caseSensitive: _caseSensitive)) {
      return AppLocalizations.of(context)!.trgPatternRefused;
    }
    return _simple ? null : triggerPatternError(_pattern.text.trim());
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty && _effectivePattern.isNotEmpty && _patternError == null && (_notify || _highlight);

  void _pickPreset(AlertPreset p) {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      // The name follows the preset while it is the preset's own.
      if (_name.text.trim().isEmpty || _name.text == _presetLabel(l10n, _preset)) {
        _name.text = p == AlertPreset.ownText ? '' : _presetLabel(l10n, p);
      }
      // So does the test line, while it is one of the preset's examples.
      if (_test.text.isEmpty || _preset.examples.contains(_test.text)) {
        _test.text = p.examples.isEmpty ? '' : p.examples.first;
      }
      _preset = p;
      _caseSensitive = false;
    });
  }

  /// Simple to Regex keeps the pattern; Regex to Simple finds the preset it
  /// is, or starts from the person's own text.
  void _setMode(bool simple) {
    setState(() {
      if (!simple && _simple) {
        _pattern.text = _effectivePattern;
      } else if (simple && !_simple) {
        final p = AlertPreset.of(_pattern.text.trim());
        _preset = p ?? AlertPreset.ownText;
        if (p == AlertPreset.ownText) _ownText.text = AlertPreset.ownTextOf(_pattern.text.trim()) ?? '';
      }
      _simple = simple;
    });
  }

  /// Saves the form, and says so: a toast and the dot gone, or what went
  /// wrong above the footer, with its code and Copy details, and the form as
  /// it was typed (a save that failed said nothing at all).
  Future<void> _save() async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context)!;
    final crud = ref.read(triggerCrudProvider);
    final f = _form;
    setState(() {
      _saving = true;
      _saveFailure = null;
    });
    try {
      final String id;
      final existing = widget.trigger?.id ?? _createdId;
      if (existing == null) {
        id = await crud.create(
          name: f.name,
          pattern: f.pattern,
          caseSensitive: f.caseSensitive,
          notify: f.notify,
          highlight: f.highlight,
          highlightColor: f.highlightColor,
          playSound: f.playSound,
          connectionId: f.connectionId,
        );
      } else {
        id = existing;
        await crud.update(
          id: existing,
          name: f.name,
          pattern: f.pattern,
          caseSensitive: f.caseSensitive,
          notify: f.notify,
          highlight: f.highlight,
          highlightColor: f.highlightColor,
          playSound: f.playSound,
          connectionId: f.connectionId,
          enabled: widget.trigger?.enabled ?? true,
        );
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _createdId = id;
        _initial = f;
      });
      showTopSnackBar(context, l10n.alertsSaved(Redactable.freeText(f.name).displayIn(ref)), isSuccess: true);
      widget.onSaved(id);
    } catch (e, stack) {
      if (!mounted) return;
      final message = l10n.alertsSaveFailed(ErrorCodes.localSaveFailed.code);
      setState(() {
        _saving = false;
        _saveFailure = (
          message: message,
          report: ErrorReport.build(what: message, where: 'Saving an alert', error: e, stack: stack),
        );
      });
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final id = widget.trigger?.id ?? _createdId;
    if (id == null) return;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.trgDeleteTitle,
      body: l10n.trgDeleteConfirm(widget.trigger?.name ?? _initial.name),
      confirmLabel: l10n.delete,
    );
    if (ok == true) {
      await ref.read(triggerCrudProvider).delete(id);
      widget.onDeleted();
    }
  }

  String _title(AppLocalizations l10n) {
    final name = widget.trigger?.name ?? (_createdId != null ? _initial.name : '');
    if (name.isNotEmpty) return Redactable.freeText(name).displayIn(ref);
    return l10n.trgNewTrigger;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDetailScaffold(
      title: _title(l10n),
      icon: LucideIcons.bell,
      modeToggle: ZestModeToggle(
        key: const ValueKey('alert-mode'),
        segments: [
          ZestModeSegment(id: 'simple', label: l10n.alertsModeSimple),
          ZestModeSegment(id: 'regex', label: l10n.alertsModeRegex),
        ],
        selectedId: _simple ? 'simple' : 'regex',
        onChanged: (id) => _setMode(id == 'simple'),
      ),
      isDirty: _dirty,
      onSave: _canSave ? _save : null,
      saveLabel: l10n.alertsSaveAlert,
      onClose: widget.onClose,
      footerLeading: _isNew
          ? null
          : ZestButton(
              label: l10n.delete,
              variant: ZestButtonVariant.danger,
              size: ZestButtonSize.large,
              onPressed: _delete,
            ),
      notice: _saveFailure == null
          ? null
          : _SaveFailedNotice(message: _saveFailure!.message, report: _saveFailure!.report),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_simple) ..._simpleForm(l10n) else ..._regexForm(l10n),
            const SizedBox(height: 18),
            _label(l10n.alertsTryIt),
            const SizedBox(height: 8),
            _testField(l10n),
            const SizedBox(height: 8),
            _testResult(l10n),
            const SizedBox(height: 24),
            ZestSectionHeader(label: l10n.alertsSectionWhenMatches),
            const SizedBox(height: 8),
            _toggleRow(l10n.trgNotifyMe, _notify, (v) => setState(() => _notify = v), key: 'alert-notify'),
            _toggleRow(l10n.trgPlaySound, _notify && _playSound, _notify ? (v) => setState(() => _playSound = v) : null,
                key: 'alert-sound'),
            const SizedBox(height: 6),
            _highlightBox(l10n),
            const SizedBox(height: 10),
            // The engine's one limit: the same line of the same alert is told
            // once in ten seconds (TriggerCoalescer). Said, not offered.
            ZestField.custom(
              label: l10n.alertsThrottleLabel,
              labelWidth: _labelWidth(l10n),
              child: Text(l10n.alertsThrottleValue,
                  style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
            ),
            if (!_notify && !_highlight) ...[
              const SizedBox(height: 8),
              Text(l10n.trgPickAction, style: TextStyle(fontSize: 12, color: ZestTokens.statusWarning)),
            ],
            const SizedBox(height: 24),
            ZestSectionHeader(label: l10n.alertsSectionWhere),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: _labelWidth(l10n),
                  child: Text(l10n.alertsWatch, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary)),
                ),
                Expanded(
                  child: ZestSelect<String>(
                key: const ValueKey('alert-watch'),
                value: _connectionId ?? '',
                items: [
                  ZestSelectItem('', l10n.trgAllHosts),
                  for (final c in widget.connections)
                    ZestSelectItem(c.id, Redactable.host(c.label).displayIn(ref), leading: HostGlyph(host: c, size: 16)),
                ],
                    onChanged: (v) => setState(() => _connectionId = v.isEmpty ? null : v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _simpleForm(AppLocalizations l10n) {
    final examples = _preset == AlertPreset.ownText
        ? [if (_ownText.text.trim().isNotEmpty) _ownText.text.trim()]
        : _preset.examples;
    return [
      _label(l10n.alertsWhenOutputShows),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in AlertPreset.values)
            _PresetChip(
              key: ValueKey('alert-preset-${p.name}'),
              label: _presetLabel(l10n, p),
              selected: p == _preset,
              onTap: () => _pickPreset(p),
            ),
        ],
      ),
      if (_preset == AlertPreset.ownText) ...[
        const SizedBox(height: 12),
        ZestField(
          key: const ValueKey('alert-own-text'),
          label: l10n.alertsOwnTextLabel,
          controller: _ownText,
          placeholder: l10n.alertsOwnTextHint,
          isMono: true,
          errorText: _patternError,
          labelWidth: _labelWidth(l10n),
        ),
      ],
      const SizedBox(height: 12),
      ZestField(
          key: const ValueKey('alert-name'),
          label: l10n.trgName,
          controller: _name,
          placeholder: l10n.trgNameHint,
          labelWidth: _labelWidth(l10n),
        ),
      const SizedBox(height: 12),
      _box(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(l10n.alertsMatchesLinesLike,
                      style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
                ),
                ZestButton(
                  key: const ValueKey('alert-edit-as-regex'),
                  label: l10n.alertsEditAsRegex,
                  variant: ZestButtonVariant.ghost,
                  onPressed: () => _setMode(false),
                ),
              ],
            ),
            if (examples.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                examples.join('  ·  '),
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.5, color: ZestTokens.textPrimary),
              ),
            ],
            const SizedBox(height: 6),
            _toggleRow(l10n.alertsAnyCase, !_caseSensitive, (v) => setState(() => _caseSensitive = !v),
                key: 'alert-any-case', small: true),
          ],
        ),
      ),
    ];
  }

  List<Widget> _regexForm(AppLocalizations l10n) => [
        ZestField(
          key: const ValueKey('alert-name'),
          label: l10n.trgName,
          controller: _name,
          placeholder: l10n.trgNameHint,
          labelWidth: _labelWidth(l10n),
        ),
        const SizedBox(height: 12),
        ZestField(
          key: const ValueKey('alert-pattern'),
          label: l10n.trgPattern,
          controller: _pattern,
          isMono: true,
          placeholder: r'\b(error|failed)\b',
          helperText: l10n.trgPatternHelp,
          errorText: _patternError,
          labelWidth: _labelWidth(l10n),
        ),
        const SizedBox(height: 6),
        // The same words and the same way round as the simple form's switch
        // (a design audit found two opposite switches for one
        // thing).
        _toggleRow(l10n.alertsAnyCase, !_caseSensitive, (v) => setState(() => _caseSensitive = !v),
            key: 'alert-any-case'),
      ];

  /// The name column, as wide as the longest of the editor's names needs in
  /// this language and text size (at least [_kLabelWidth]).
  double _labelWidth(AppLocalizations l10n) => zestFieldLabelWidth(
        context,
        [l10n.alertsThrottleLabel, l10n.alertsWatch, l10n.alertsOwnTextLabel, l10n.trgName, l10n.trgPattern],
        min: _kLabelWidth,
      );

  Widget _label(String text) => Text(
        text,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
      );

  Widget _testField(AppLocalizations l10n) => Container(
        decoration: BoxDecoration(
          color: ZestTokens.surfaceSunken,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          key: const ValueKey('alert-test-line'),
          controller: _test,
          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, color: ZestTokens.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            hintText: l10n.trgTestLineHint,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            filled: false,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      );

  /// The test line again, what matched marked in the highlight's colour, and
  /// whether it matches.
  Widget _testResult(AppLocalizations l10n) {
    final line = _test.text;
    final re = triggerRegExp(_effectivePattern, caseSensitive: _caseSensitive);
    if (line.isEmpty || re == null) {
      return _box(Text(
        _patternError != null ? l10n.trgTestFix : l10n.trgTestPrompt,
        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: ZestTokens.textTertiary),
      ));
    }
    final mark = _highlight ? Color(_highlightColor ?? kTriggerHighlightPresets.first) : ZestTokens.brand;
    final matches = re
        .allMatches(triggerPatternCheck(_effectivePattern, caseSensitive: _caseSensitive).bound(line))
        .where((m) => m.end > m.start)
        .toList();
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in matches) {
      if (m.start > at) spans.add(TextSpan(text: line.substring(at, m.start)));
      spans.add(TextSpan(
        text: line.substring(m.start, m.end),
        style: TextStyle(backgroundColor: mark.withValues(alpha: 0.85), color: Colors.black),
      ));
      at = m.end;
    }
    if (at < line.length) spans.add(TextSpan(text: line.substring(at)));
    final hit = matches.isNotEmpty;
    return _box(
      Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: spans),
              key: const ValueKey('alert-test-result'),
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, color: ZestTokens.textPrimary),
            ),
          ),
          const SizedBox(width: 10),
          if (hit) ...[
            Icon(LucideIcons.check, size: 14, color: ZestTokens.statusHealthy),
            const SizedBox(width: 4),
          ],
          Text(
            hit ? l10n.alertsTestMatches : l10n.alertsTestNoMatch,
            style: TextStyle(fontSize: 12.5, color: hit ? ZestTokens.statusHealthy : ZestTokens.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _highlightBox(AppLocalizations l10n) => _box(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _toggleRow(l10n.trgHighlight, _highlight, (v) => setState(() => _highlight = v), key: 'alert-highlight'),
            if (_highlight) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  for (final argb in kTriggerHighlightPresets)
                    Semantics(
                      button: true,
                      selected: _highlightColor == argb,
                      child: GestureDetector(
                        key: ValueKey('alert-colour-${argb.toRadixString(16)}'),
                        onTap: () => setState(() => _highlightColor = argb),
                        child: Container(
                          width: 24,
                          height: 24,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _highlightColor == argb ? ZestTokens.textPrimary : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: Color(argb), shape: BoxShape.circle),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      );

  /// A row with its name at the left and its switch at the right.
  Widget _toggleRow(String title, bool value, ValueChanged<bool>? onChanged, {required String key, bool small = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: small ? 2 : 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: small ? 12.5 : 13.5,
                fontWeight: small ? FontWeight.w400 : FontWeight.w500,
                color: onChanged == null
                    ? ZestTokens.textTertiary
                    : small
                        ? ZestTokens.textSecondary
                        : ZestTokens.textPrimary,
              ),
            ),
          ),
          ZestSwitch(key: ValueKey(key), value: value, semanticLabel: title, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _box(Widget child) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: child,
      );
}

/// What stopped a save, above the footer, so that it is on screen wherever
/// the form is scrolled to: what happened and what to do, with its code in
/// the words, and the report behind Copy details.
class _SaveFailedNotice extends StatelessWidget {
  const _SaveFailedNotice({required this.message, required this.report});

  final String message;
  final String report;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('alert-save-failed'),
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: ZestTokens.statusCritical.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.statusCritical.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(LucideIcons.alertCircle, size: 15, color: ZestTokens.statusCritical),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textPrimary)),
                CopyDetailsButton(detail: report, color: ZestTokens.statusCritical),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A choice of Simple mode, outlined in the accent when it is the one.
class _PresetChip extends StatelessWidget {
  const _PresetChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? ZestTokens.brandSubtle : ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? ZestTokens.brandBorder : ZestTokens.border),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? ZestTokens.brandInk : ZestTokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
