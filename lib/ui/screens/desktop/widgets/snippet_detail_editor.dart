
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace, TransferKinds;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show defaultSavePlace, savePlaces;
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/features/orchards/move/save_in_field.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/snippets/run_snippet.dart' show defaultHostOf, runCommandOnPicked;
import 'package:zestssh/features/snippets/save_snippet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart'
    show
        SnippetCommandEditingController,
        categoryAccent,
        kSnippetConfirmBg,
        kSnippetConfirmColor,
        kSnippetVarColor;
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/utils/kept_from_sync.dart';
import 'package:zestssh/providers/core_providers.dart' show snippetsDaoProvider;

/// Shared width of the left label cell for the snippet editor's fields. Sized so
/// the longest label in the pane ("Default host") fits on one line without
/// clipping, while Label + Category still share one row. Every field in the pane
/// uses this so their inputs align on one vertical rule.
const double _kSnippetLabelWidth = 120;

/// The snippet editor's unsaved edits, as [SnippetDetailEditorState.keptEdit]
/// takes them while the page is away (a terminal shown in its place), held in
/// memory only. A snippet holds nothing secret.
@immutable
class SnippetKeptEdit {
  const SnippetKeptEdit({
    required this.snippetId,
    required this.label,
    required this.category,
    required this.command,
    required this.description,
    required this.confirmBeforeRun,
    required this.defaultConnectionId,
    required this.variableDescriptions,
    required this.saveIn,
  });

  /// The snippet being edited; null for a new one.
  final String? snippetId;
  final String label;
  final String category;
  final String command;
  final String description;
  final bool confirmBeforeRun;
  final String? defaultConnectionId;
  final Map<String, String> variableDescriptions;

  /// Where a new snippet was to be saved.
  final SavePlace? saveIn;
}

// ══════════════════════════════════════════════════════════════════
// Snippet detail editor - 1.7 desktop detail pane
// ══════════════════════════════════════════════════════════════════
//
// The right-hand pane of the snippets [ZestMasterDetail]. The pane is ALWAYS
// the editor (a blank NEW snippet by default, no empty state) and gets its
// chrome - sticky Clear + Save Configuration footer, dirty dot, close X - from
// the shared [ZestDetailScaffold], matching Networks / Port Forwarding.
//
// Enriches the old SnippetEditor form with the 1.7 spec: a DETECTED-VARIABLES
// TABLE (Name / Default / Description / Required) plus a snippet Description,
// all built from the Zest foundation (ZestField / ZestSectionHeader). Owns its
// own persistence (create / updateFull) and a dirty guard modelled on the
// Networks controller pattern.
//
// Data model:
//   * A variable's DEFAULT lives in the command itself (`${VAR:-default}`) - the
//     Default cell rewrites the command live, so the command text is always the
//     single source of truth for defaults.
//   * A snippet description + per-variable descriptions live in the nullable
//     `Snippets.metadata` JSON column (schema v23), encoded via
//     [encodeSnippetMetadata].

class SnippetDetailEditor extends ConsumerStatefulWidget {
  const SnippetDetailEditor({
    super.key,
    required this.snippet,
    required this.existingCategories,
    required this.resetToken,
    required this.onRequestNew,
    required this.onClose,
    this.onDirtyChanged,
    this.kept,
  });

  /// Unsaved edits kept while the page was away: the editor opens with them,
  /// shown unsaved.
  final SnippetKeptEdit? kept;

  /// The snippet being edited, or null when creating a new one.
  final Snippet? snippet;

  /// Bumped by the shell on every open request. A change re-initialises the
  /// draft even when [snippet] is unchanged (e.g. +New after +New, or re-opening
  /// the same snippet after a discard), since the shell reuses this State via a
  /// stable GlobalKey rather than a per-snippet ValueKey.
  final int resetToken;

  /// Category names for the category field's suggestions.
  final List<String> existingCategories;

  /// Reset the pane to a blank NEW snippet. Fired by the footer "Clear" (after
  /// the dirty guard clears) and automatically after a brand-new snippet is
  /// saved, so the editor is always ready for the next entry.
  final VoidCallback onRequestNew;

  /// Close the pane - the header "X". In the wide master/detail this resets to
  /// a blank new snippet; in the narrow single-column route it pops back to the
  /// list. The dirty guard runs before either.
  final VoidCallback onClose;

  /// Reports the dirty state up to the shell so it can guard nav-away.
  final ValueChanged<bool>? onDirtyChanged;

  @override
  ConsumerState<SnippetDetailEditor> createState() =>
      SnippetDetailEditorState();
}

class SnippetDetailEditorState extends ConsumerState<SnippetDetailEditor> {
  late TextEditingController _labelCtrl;
  late TextEditingController _categoryCtrl;
  late TextEditingController _commandCtrl;
  late TextEditingController _descCtrl;
  late bool _confirmBeforeRun;

  /// Optional saved-connection id this snippet runs on by default. Persisted in
  /// the snippet's `metadata` JSON (see [SnippetMetadata.defaultConnectionId])
  /// - NOT a schema column, so no migration is needed.
  String? _defaultConnectionId;

  /// Per-variable Prompt cell controllers, keyed by var key.
  final Map<String, TextEditingController> _varDescCtrls = {};

  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _initFrom(widget.snippet);
    final kept = widget.kept;
    if (kept != null) _restore(kept);
  }

  /// Puts back what [keptEdit] took, shown unsaved.
  void _restore(SnippetKeptEdit kept) {
    _labelCtrl.text = kept.label;
    _categoryCtrl.text = kept.category;
    _commandCtrl.text = kept.command;
    _descCtrl.text = kept.description;
    _confirmBeforeRun = kept.confirmBeforeRun;
    _defaultConnectionId = kept.defaultConnectionId;
    _saveIn = kept.saveIn;
    _syncVariableControllers();
    for (final entry in kept.variableDescriptions.entries) {
      _varDescCtrls[entry.key]?.text = entry.value;
    }
    _dirty = true;
  }

  /// The unsaved edits, to be kept while the page is away; null when there
  /// are none.
  SnippetKeptEdit? keptEdit() => !_dirty
      ? null
      : SnippetKeptEdit(
          snippetId: widget.snippet?.id ?? widget.kept?.snippetId,
          label: _labelCtrl.text,
          category: _categoryCtrl.text,
          command: _commandCtrl.text,
          description: _descCtrl.text,
          confirmBeforeRun: _confirmBeforeRun,
          defaultConnectionId: _defaultConnectionId,
          variableDescriptions: {for (final c in _varDescCtrls.entries) c.key: c.value.text},
          saveIn: widget.snippet == null && widget.kept?.snippetId == null ? _saveIn : null,
        );

  void _initFrom(Snippet? snippet) {
    _labelCtrl = TextEditingController(text: snippet?.label ?? '');
    _categoryCtrl = TextEditingController(text: snippet?.category ?? '');
    // A self-tinting controller so `${VAR}` placeholders colorize live as the
    // command is edited.
    _commandCtrl = SnippetCommandEditingController(text: snippet?.command ?? '');
    _confirmBeforeRun = snippet?.confirmBeforeRun ?? false;

    final meta = parseSnippetMetadata(snippet?.metadata);
    _descCtrl = TextEditingController(text: meta.description ?? '');
    _defaultConnectionId = meta.defaultConnectionId;

    // Seed per-variable cell controllers from the current command + metadata.
    _syncVariableControllers(seedFromMetadata: meta);
    _dirty = false;
  }

  @override
  void didUpdateWidget(SnippetDetailEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The shell reuses this State across snippets (stable GlobalKey) and only
    // swaps [snippet] after confirmLeave() has cleared any pending edits, so a
    // changed resetToken means "load the requested snippet fresh".
    if (widget.resetToken != oldWidget.resetToken) {
      _disposeControllers();
      _initFrom(widget.snippet);
    }
  }

  void _disposeControllers() {
    _labelCtrl.dispose();
    _categoryCtrl.dispose();
    _commandCtrl.dispose();
    _descCtrl.dispose();
    for (final c in _varDescCtrls.values) {
      c.dispose();
    }
    _varDescCtrls.clear();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  // ── Dirty tracking ───────────────────────────────────────────────

  void _markDirty() {
    if (_dirty) return;
    // Rebuild on the first edit so the scaffold sees isDirty and ENABLES Save.
    // The Description, Category, and per-variable Description cells route here
    // WITHOUT their own setState, so this is what turns Save on for a
    // description-only (or category-only) change - previously it stayed disabled
    // until a field that happened to call setState (label/command) was touched.
    setState(() => _dirty = true);
    widget.onDirtyChanged?.call(true);
  }

  /// The shared leave-guard the split shell calls before switching snippets,
  /// creating a new one, or closing. Returns true to PROCEED. Mirrors the
  /// Networks `confirmDiscardIfDirty` contract.
  Future<bool> confirmLeave() async {
    if (!_dirty) return true;
    final choice = await showZestDiscardDialog(context);
    switch (choice) {
      case DiscardChoice.cancel:
        return false;
      case DiscardChoice.discard:
        return true;
      case DiscardChoice.save:
        return _save();
    }
  }

  // ── Variable controller sync ─────────────────────────────────────

  List<ParsedVariable> get _vars =>
      parseVariablesWithOptions(_commandCtrl.text);

  /// Ensure a Prompt controller exists for every current variable, seeding
  /// freshly-created ones from the persisted metadata. Variable DEFAULTS are no
  /// longer edited here - the Default column is read-only and the command string
  /// (`${VAR:-default}`) is the single source of truth - so there is nothing to
  /// reseed on a command edit.
  void _syncVariableControllers({SnippetMetadata? seedFromMetadata}) {
    final vars = _vars;
    final descSeed = seedFromMetadata?.variableDescriptions ?? const {};
    for (final v in vars) {
      _varDescCtrls.putIfAbsent(
        v.key,
        () => TextEditingController(text: descSeed[v.key] ?? ''),
      );
    }
  }

  /// The command was edited - refresh the detected-variable rows (add Prompt
  /// controllers for any new variable) and rebuild.
  void _onCommandChanged(String _) {
    _syncVariableControllers();
    _markDirty();
    setState(() {});
  }

  // ── Default host ─────────────────────────────────────────────────

  /// Open the grouped [ConnectionPickerDialog] to choose the host this snippet
  /// runs on by default. The picked id is stored in metadata on save.
  Future<void> _pickDefaultHost() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await ConnectionPickerDialog.show(
      context,
      title: l10n.zestSnippetsDefaultHostPickTitle,
      needsTerminal: true,
    );
    final picked = result.connection;
    if (picked == null || !mounted) return;
    if (picked.connection.id == _defaultConnectionId) return; // picked again
    setState(() => _defaultConnectionId = picked.connection.id);
    _markDirty();
  }

  void _clearDefaultHost() {
    setState(() => _defaultConnectionId = null);
    _markDirty();
  }

  // ── Save ─────────────────────────────────────────────────────────

  bool get _valid =>
      _labelCtrl.text.trim().isNotEmpty && _commandCtrl.text.trim().isNotEmpty;

  /// A save is being stored: a second press of Save meanwhile does nothing
  /// (it would make the new snippet twice).
  bool _saving = false;

  /// Where a new snippet is saved ("Save in", 3.4); null: where new items of
  /// the space on screen go.
  SavePlace? _saveIn;

  /// Persist, and say so ([saveSnippetSaying]): "Snippet added" or "Snippet
  /// saved" with its name once it is stored. Returns true then; false if
  /// validation blocks it (a label and command are required) or the write
  /// failed, which is said, and the draft stays as it is.
  Future<bool> _save() async {
    if (!_valid || _saving) return false;

    final vars = _vars;
    // The command IS the source of truth for variable defaults (`${VAR:-x}`), so
    // it persists verbatim - no default-cell baking.
    final command = _commandCtrl.text.trim();

    // Build metadata (snippet description + per-variable descriptions). Only
    // keep descriptions for variables that still exist in the command.
    final varDescs = <String, String>{};
    for (final v in vars) {
      final d = _varDescCtrls[v.key]?.text.trim() ?? '';
      if (d.isNotEmpty) varDescs[v.key] = d;
    }
    final metadata = encodeSnippetMetadata(
      SnippetMetadata(
        description: _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
        variableDescriptions: varDescs,
        defaultConnectionId: _defaultConnectionId,
      ),
    );

    final category = _categoryCtrl.text.trim();
    final label = _labelCtrl.text.trim();
    final crud = ref.read(snippetCrudProvider);
    final editing = widget.snippet;
    final place = _saveIn ?? defaultSavePlace(ref);
    _saving = true;
    final bool saved;
    try {
      saved = editing == null && place != defaultSavePlace(ref)
          ? await _saveElsewhere(place, () => crud.create(
                label: label,
                command: command,
                category: category.isEmpty ? null : category,
                confirmBeforeRun: _confirmBeforeRun,
                metadata: metadata,
              ))
          : await saveSnippetSaying(
        context,
        name: label,
        added: editing == null,
        write: () async {
          if (editing == null) {
            await crud.create(
                label: label,
                command: command,
                category: category.isEmpty ? null : category,
                confirmBeforeRun: _confirmBeforeRun,
                metadata: metadata,
              );
            return;
          }
          // A field the person did not touch keeps what a sync wrote while
          // the editor was open (found in a code audit).
          final now = await ref.read(snippetsDaoProvider).getById(editing.id);
          final keep = keptSince<Snippet>(editing, now, (s) => s.updatedAt);
          return crud.updateFull(
                id: editing.id,
                label: keep(label, (s) => s.label),
                command: keep(command, (s) => s.command),
                category: keep(category.isEmpty ? null : category, (s) => s.category),
                confirmBeforeRun: keep(_confirmBeforeRun, (s) => s.confirmBeforeRun),
                metadata: metadata,
              );
        },
      );
    } finally {
      _saving = false;
    }
    if (!saved) return false;
    if (!mounted) return true;
    _dirty = false;
    widget.onDirtyChanged?.call(false);
    return true;
  }

  /// A new snippet saved at [place], in another space or vault than new items
  /// of the one on screen go to ("Save in", 3.4), and said where.
  Future<bool> _saveElsewhere(SavePlace place, Future<String> Function() write) async {
    final id = await saveNewItemIn(context, ref, place: place, kind: TransferKinds.snippet, write: write);
    if (id == null || !mounted) return id != null;
    final l10n = AppLocalizations.of(context)!;
    final saved = savePlaces(ref, l10n, watch: false).where((p) => p.place == place).firstOrNull;
    showTopSnackBar(context, l10n.saveInSavedToast(Redactable.freeText(saved?.title ?? '').display), isSuccess: true);
    _saveIn = null;
    return true;
  }

  Future<void> _onSavePressed() async {
    final wasNew = widget.snippet == null;
    if (await _save() && mounted) {
      // A brand-new snippet: hand back a blank new pane so the next entry is
      // ready (and the just-created one shows in the list). An edit: stay put
      // with the dirty flag now cleared.
      if (wasNew) {
        widget.onRequestNew();
      } else {
        setState(() {});
      }
    }
  }

  /// Header "X" - leave the pane (dirty guard first). The host decides where
  /// that goes (reset-to-new when docked, pop when a narrow route).
  Future<void> _onClosePressed() async {
    if (await confirmLeave()) widget.onClose();
  }

  // ── Run ──────────────────────────────────────────────────────────

  /// Header "Run": the CURRENT command (the draft, saved or not), on the
  /// snippet's default host while it still exists, else on a host picked
  /// through the grouped picker. It runs as everywhere ([runCommandOnHost]):
  /// its variables asked, the dangerous-command check or its "confirm before
  /// running", then entered in the host's live session, or in one opened to
  /// it. (It sent the raw command, ${VAR} and all, with no check, and the
  /// default host was saved and never used; 3.0 docs check.) A run of a saved
  /// snippet is counted (a brand-new one has no id to key).
  Future<void> _run() async {
    final l10n = AppLocalizations.of(context)!;
    final command = _commandCtrl.text.trim();
    if (command.isEmpty) return;
    final host = defaultHostOf(
      ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [],
      encodeSnippetMetadata(SnippetMetadata(defaultConnectionId: _defaultConnectionId)),
    );
    // With no default host, the picker; its first choice, where this device
    // has a shell of its own, a new terminal on it.
    final result = host != null
        ? ConnectionPickerResult.connection(host)
        : await ConnectionPickerDialog.show(
            context,
            place: HostListPlace.runSnippet,
            title: l10n.zestSnippetsRunOnTitle,
            needsTerminal: true,
            includeLocalTerminal: true,
          );
    if (!mounted) return;
    await runCommandOnPicked(
      context,
      ref,
      result,
      command: command,
      label: _title(l10n),
      confirmFirst: _confirmBeforeRun,
      snippetId: widget.snippet?.id,
    );
  }

  // ── Build ────────────────────────────────────────────────────────

  /// The pane title: the label being typed, else the bound snippet's label,
  /// else the "New snippet" placeholder.
  String _title(AppLocalizations l10n) {
    final typed = _labelCtrl.text.trim();
    if (typed.isNotEmpty) return typed;
    final editing = widget.snippet;
    if (editing != null && editing.label.isNotEmpty) return editing.label;
    return l10n.zestSnippetsNewLabel;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final vars = _vars;
    _syncVariableControllers();

    // Workflows that reference the BOUND snippet by name (a workflow snippet
    // step matches by [WorkflowStep.snippetName]). Editing a referenced snippet
    // changes what those workflows run, so surface a non-blocking warning.
    final referencingWorkflows = _referencingWorkflows();

    final command = _commandCtrl.text.trim();

    // Header trim: a braces glyph tinted by the snippet's category accent, the
    // category name as a chip badge, and a single-line command preview under the
    // title (mono, like the other detail panes' identity subtitles).
    final categoryName = _categoryCtrl.text.trim();
    final categoryMeta = categoryName.isEmpty
        ? null
        : ref.watch(snippetCategoryMetaMapProvider)[categoryName];
    final categoryColor =
        categoryName.isEmpty ? null : categoryAccent(categoryName, categoryMeta);
    final commandPreview = command.isEmpty
        ? null
        : Redactable.freeText(command.split('\n').first).displayIn(ref);

    return ZestDetailScaffold(
      title: _title(l10n),
      icon: LucideIcons.braces,
      iconColor: categoryColor,
      badge: categoryName.isEmpty
          ? null
          : ZestDetailBadge(
              label: categoryName,
              color: ZestTokens.textSecondary,
              background: ZestTokens.surfaceChip,
            ),
      subtitle: commandPreview,
      subtitleMono: true,
      isDirty: _dirty,
      onSave: _onSavePressed,
      onClose: _onClosePressed,
      headerAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A saved snippet's Move or copy (4.0): its places, then Move here
          // or Copy here; moved, it is not here any more and the editor
          // closes.
          if (widget.snippet case final saved?)
            MoveCopyMenuButton(
              kind: TransferKinds.snippet,
              itemKey: saved.id,
              iconSize: 18,
              color: ZestTokens.textSecondary,
              hasUnsavedChanges: () => _dirty,
              onMoved: () {
                if (mounted) widget.onClose();
              },
            ),
          _RunHeaderButton(
            enabled: command.isNotEmpty,
            onTap: _run,
            label: l10n.zestSnippetsRunButton,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Where a new snippet is saved (3.4).
            if (widget.snippet == null)
              SaveInField(
                value: _saveIn,
                onChanged: (p) => setState(() => _saveIn = p),
                padding: const EdgeInsets.only(bottom: 16),
              ),
            if (referencingWorkflows > 0) ...[
              _WorkflowUsageBanner(count: referencingWorkflows),
              const SizedBox(height: 16),
            ],
            // Label + Category share one row (Label the wider of the two).
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 14,
                  child: ZestField(
                    label: l10n.snippetsLabel,
                    controller: _labelCtrl,
                    placeholder: l10n.snippetsLabelHint,
                    labelWidth: _snippetLabelWidth(context, l10n),
                    onChanged: (_) {
                      _markDirty();
                      setState(() {});
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 10,
                  child: _CategoryField(
                    controller: _categoryCtrl,
                    labelWidth: _snippetLabelWidth(context, l10n),
                    onChanged: _markDirty,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ZestField(
              label: l10n.zestSnippetsFieldCommand,
              controller: _commandCtrl,
              isMono: true,
              maxLines: 6,
              labelWidth: _snippetLabelWidth(context, l10n),
              placeholder: r'docker restart ${NAME:-web}',
              onChanged: _onCommandChanged,
            ),
            const SizedBox(height: 14),
            ZestField(
              label: l10n.zestSnippetsFieldAbout,
              controller: _descCtrl,
              maxLines: 3,
              labelWidth: _snippetLabelWidth(context, l10n),
              placeholder: r'What does this snippet do?',
              onChanged: (_) => _markDirty(),
            ),
            const SizedBox(height: 22),
            _variablesSection(l10n, vars),
            const SizedBox(height: 22),
            // Run options + Usage, two columns beside each other.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _runOptionsSection(l10n)),
                const SizedBox(width: 18),
                Expanded(child: _usageSection(l10n)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Count of saved workflows that reference the BOUND snippet by name via a
  /// `snippet`-type step. Zero for a brand-new (unsaved) snippet.
  int _referencingWorkflows() {
    final editing = widget.snippet;
    if (editing == null || editing.label.isEmpty) return 0;
    final workflows = ref.watch(workflowsProvider);
    return workflows
        .where((w) => w.steps.any((s) =>
            s.type == WorkflowStepType.snippet &&
            s.snippetName == editing.label))
        .length;
  }

  Widget _variablesSection(AppLocalizations l10n, List<ParsedVariable> vars) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(
          label: l10n.zestSnippetsVariablesLabel,
          count: vars.isEmpty ? null : vars.length,
          infoTooltip: r'${NAME}  ${NAME:-default}  $[a,b]  $[DOCKER]',
          trailing: Text(
            l10n.zestSnippetsVariablesDetected,
            style: TextStyle(
              fontSize: 12,
              color: ZestTokens.textTertiary,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (vars.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              r'No variables. Add ${NAME} or ${NAME:-default} to the command '
              'to prompt for values at run time.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: ZestTokens.textTertiary,
              ),
            ),
          )
        else
          _VariablesTable(
            l10n: l10n,
            vars: vars,
            varDescCtrls: _varDescCtrls,
            onDescriptionChanged: _markDirty,
          ),
      ],
    );
  }

  /// Left column of the bottom section: the confirm-before-running toggle and
  /// the default host, grouped under a "Run options" header.
  Widget _runOptionsSection(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ZestSectionHeader(label: l10n.zestSnippetsRunOptions),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.zestSnippetsConfirmBeforeRunning,
                  style: TextStyle(
                    fontSize: 13,
                    color: ZestTokens.textSecondary,
                  ),
                ),
              ),
              ZestSwitch(value: _confirmBeforeRun, semanticLabel: l10n.zestSnippetsConfirmBeforeRunning, onChanged: (v) {
                  setState(() => _confirmBeforeRun = v);
                  _markDirty();
                }),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _DefaultHostField(
          connectionId: _defaultConnectionId,
          labelWidth: _snippetLabelWidth(context, l10n),
          onPick: _pickDefaultHost,
          onClear: _clearDefaultHost,
        ),
      ],
    );
  }

  /// Right column of the bottom section: run count, last run, and how many
  /// workflows reference this snippet.
  Widget _usageSection(AppLocalizations l10n) {
    final id = widget.snippet?.id;
    final usage = id == null ? null : ref.watch(snippetUsageProvider)[id];
    final runCount = usage?.runCount ?? 0;
    final runValue = runCount > 0
        ? l10n.zestSnippetsUsageRunValue(runCount)
        : l10n.zestSnippetsUsageNever;
    final lastRunValue = usage != null
        ? _snippetRelativeRun(usage.lastRunAt, l10n)
        : l10n.zestSnippetsUsageNever;
    final workflowValue =
        l10n.zestSnippetsUsageWorkflows(_referencingWorkflows());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ZestSectionHeader(label: l10n.zestSnippetsUsageTitle),
        // The Inspector's read-only rows, as every name and value of the
        // app (they were in a box of their own).
        _UsageRow(label: l10n.zestSnippetsUsageRunLabel, value: runValue),
        _UsageRow(
          label: l10n.zestSnippetsUsageLastRunLabel,
          value: lastRunValue,
        ),
        _UsageRow(
          label: l10n.zestSnippetsUsageUsedByLabel,
          value: workflowValue,
          last: true,
        ),
      ],
    );
  }
}

/// When a snippet last ran, a value of its own in the Usage panel, in the
/// shared compact words as the cards say it: the seconds from ten, just now
/// before that, and past a week weeks then
/// months.
String _snippetRelativeRun(DateTime dt, AppLocalizations l10n) =>
    timeAgoWords(l10n, dt, seconds: true, keepCounting: true);

/// One label/value line inside the Usage panel.
class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.label, required this.value, this.last = false});

  final String label;
  final String value;

  /// The last row: no hairline under it.
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: ZestTokens.textTertiary,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              color: ZestTokens.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Run" pill in the detail-pane header (left of the close X). Dispatches
/// the current command to a picked host; dimmed and inert when there is no
/// command to run.
class _RunHeaderButton extends StatelessWidget {
  const _RunHeaderButton({
    required this.enabled,
    required this.onTap,
    required this.label,
  });

  final bool enabled;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: MouseRegion(
        cursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceRaised,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: ZestTokens.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.play,
                  size: 14,
                  color: ZestTokens.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: ZestTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Detected-variables table
// ══════════════════════════════════════════════════════════════════

class _VariablesTable extends StatelessWidget {
  const _VariablesTable({
    required this.l10n,
    required this.vars,
    required this.varDescCtrls,
    required this.onDescriptionChanged,
  });

  final AppLocalizations l10n;
  final List<ParsedVariable> vars;
  final Map<String, TextEditingController> varDescCtrls;
  final VoidCallback onDescriptionChanged;

  // Shared column geometry so the header labels line up over the row cells.
  static const double _nameWidth = 96;
  static const double _defaultWidth = 96;
  static const double _requiredWidth = 64;
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    // A header row of column labels above individually-bordered variable cards
    // (replacing the old single bordered box with dividers).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _headerRow(),
        for (var i = 0; i < vars.length; i++) ...[
          if (i > 0) const SizedBox(height: 5),
          _VariableRow(
            l10n: l10n,
            variable: vars[i],
            descCtrl: varDescCtrls[vars[i].key],
            onDescriptionChanged: onDescriptionChanged,
            nameWidth: _nameWidth,
            defaultWidth: _defaultWidth,
            requiredWidth: _requiredWidth,
            gap: _gap,
          ),
        ],
      ],
    );
  }

  Widget _headerRow() {
    // Sentence-case column labels (not uppercase) matching the design.
    Text label(String text) => Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: ZestTokens.textTertiary,
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
      child: Row(
        children: [
          SizedBox(width: _nameWidth, child: label(l10n.zestSnippetsVarName)),
          const SizedBox(width: _gap),
          SizedBox(
            width: _defaultWidth,
            child: label(l10n.zestSnippetsVarDefault),
          ),
          const SizedBox(width: _gap),
          Expanded(child: label(l10n.zestSnippetsVarPromptHeader)),
          const SizedBox(width: _gap),
          SizedBox(
            width: _requiredWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: label(l10n.zestSnippetsVarRequired),
            ),
          ),
        ],
      ),
    );
  }
}

/// One detected variable, rendered as its own bordered card: mono Name (var
/// tint), read-only Default (`none` when absent), editable Prompt, and a
/// computed Required badge.
class _VariableRow extends StatelessWidget {
  const _VariableRow({
    required this.l10n,
    required this.variable,
    required this.descCtrl,
    required this.onDescriptionChanged,
    required this.nameWidth,
    required this.defaultWidth,
    required this.requiredWidth,
    required this.gap,
  });

  final AppLocalizations l10n;
  final ParsedVariable variable;
  final TextEditingController? descCtrl;
  final VoidCallback onDescriptionChanged;
  final double nameWidth;
  final double defaultWidth;
  final double requiredWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Name (mono, variable tint) ──
          SizedBox(
            width: nameWidth,
            child: Tooltip(
              message: variable.matchPattern,
              child: Text(
                _displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'JetBrainsMono',
                  color: kSnippetVarColor,
                ),
              ),
            ),
          ),
          SizedBox(width: gap),
          // ── Default (read-only; `none` when absent) ──
          SizedBox(width: defaultWidth, child: _defaultCell()),
          SizedBox(width: gap),
          // ── Prompt (editable; italic hint when empty) ──
          Expanded(
            child: _PromptField(
              controller: descCtrl,
              hint: l10n.zestSnippetsVarPromptHint,
              onChanged: onDescriptionChanged,
            ),
          ),
          SizedBox(width: gap),
          // ── Required (computed: default == null) ──
          SizedBox(
            width: requiredWidth,
            child: Align(
              alignment: Alignment.center,
              child: variable.isRequired
                  ? _YesBadge(label: l10n.zestSnippetsVarRequiredYes)
                  : Text(
                      l10n.zestSnippetsVarRequiredNo,
                      style: TextStyle(
                        fontSize: 11,
                        color: ZestTokens.textTertiary,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String get _displayName {
    switch (variable.type) {
      case VariableType.freeText:
        return variable.name;
      case VariableType.inlineList:
        return 'list';
      case VariableType.dynamicList:
        return variable.dynamicSource ?? variable.name;
    }
  }

  /// The variable's baked-in default, read-only. `none` (dim mono) when there is
  /// no default - including every list variable (which has no `:-default`), so a
  /// list var no longer mis-prints its own name here.
  Widget _defaultCell() {
    final d = variable.defaultValue;
    final hasValue = d != null && d.isNotEmpty;
    return Text(
      hasValue ? d : l10n.zestSnippetsVarDefaultNone,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontFamily: 'JetBrainsMono',
        color: hasValue ? ZestTokens.textPrimary : ZestTokens.textPlaceholder,
      ),
    );
  }
}

/// The inline, borderless Prompt editor for a variable row. Renders its empty
/// state as an italic dim "Add a prompt" hint (matching the design) - a look the
/// bordered [ZestField] can't give, so this is a bare [TextField].
class _PromptField extends StatelessWidget {
  const _PromptField({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController? controller;
  final String hint;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: (_) => onChanged(),
      maxLines: 1,
      cursorColor: ZestTokens.brand,
      cursorWidth: 1.5,
      style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
      decoration: InputDecoration(
        isCollapsed: true,
        filled: false,
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: ZestTokens.textPlaceholder,
        ),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
      ),
    );
  }
}

/// The "Yes" badge for the Required column - confirm-orange on its tinted
/// background. A plain muted "No" is rendered inline for optional variables.
class _YesBadge extends StatelessWidget {
  const _YesBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kSnippetConfirmBg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, color: kSnippetConfirmColor),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Workflow-usage warning banner
// ══════════════════════════════════════════════════════════════════

/// Non-blocking amber banner shown when the snippet being edited is referenced
/// by one or more automation workflows. Editing the snippet changes what those
/// workflows run, so this makes the blast radius visible without preventing the
/// edit.
class _WorkflowUsageBanner extends StatelessWidget {
  const _WorkflowUsageBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ZestTokens.statusWarning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ZestTokens.statusWarning.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            LucideIcons.workflow,
            size: 16,
            color: ZestTokens.statusWarning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.zestSnippetsWorkflowUsageWarning(count),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: ZestTokens.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Default-host field - pick which saved host this snippet runs on
// ══════════════════════════════════════════════════════════════════

/// The optional "Default host" row: a tappable box that opens the grouped
/// [ConnectionPickerDialog]. Shows the picked host's label (resolved live from
/// [connectionsWithDetailsProvider]) or a muted placeholder, plus a trailing
/// clear (x) once set. The chosen id persists in the snippet's metadata JSON
/// (see [SnippetMetadata.defaultConnectionId]) - no schema column.
class _DefaultHostField extends ConsumerWidget {
  const _DefaultHostField({
    required this.connectionId,
    required this.labelWidth,
    required this.onPick,
    required this.onClear,
  });

  final String? connectionId;
  final double labelWidth;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connections =
        ref.watch(connectionsWithDetailsProvider).valueOrNull ??
            const <ConnectionWithDetails>[];

    // Resolve the stored id → label. A host deleted since it was chosen
    // resolves to null → show a muted "unknown host" hint instead of a
    // dangling id.
    String? resolvedLabel;
    ConnectionWithDetails? resolved;
    if (connectionId != null) {
      for (final c in connections) {
        if (c.connection.id == connectionId) {
          resolved = c;
          resolvedLabel = c.connection.label;
          break;
        }
      }
    }
    final hasValue = connectionId != null;
    final display = resolvedLabel ??
        (hasValue ? l10n.zestSnippetsDefaultHostUnknown : null);

    return ZestField.custom(
      label: l10n.zestSnippetsDefaultHostLabel,
      labelWidth: labelWidth,
      child: InkWell(
        onTap: onPick,
        child: Row(
          children: [
            if (resolved != null) ...[
              HostGlyph(host: resolved.connection, group: resolved.group, size: 18),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                display ?? l10n.zestSnippetsDefaultHostAskEachTime,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  // "Ask each time" is a choice, not a hint: the muted
                  // grey that reads at 4.5:1 (the placeholder's was 3.5:1).
                  color: display == null
                      ? ZestTokens.textTertiary
                      : ZestTokens.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (hasValue)
              Tooltip(message: AppLocalizations.of(context)!.zestCommonClear, child: GestureDetector(
                onTap: onClear,
                behavior: HitTestBehavior.opaque,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Icon(
                      LucideIcons.x,
                      size: 15,
                      color: ZestTokens.textTertiary,
                    ),
                  ),
                ),
              ))
            else
              Icon(
                LucideIcons.chevronDown,
                size: 16,
                color: ZestTokens.textTertiary,
              ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Category field - a filtering dropdown of existing snippet groups
// ══════════════════════════════════════════════════════════════════

/// The Category row: a text input that, when focused, drops a filtering list of
/// the existing snippet groups. Empty + focused shows ALL groups; typing filters
/// by substring on every keystroke. Each row carries the group's accent color so
/// look-alike names are easy to tell apart (colors come from the
/// [SnippetCategories] metadata, resolved via [categoryAccent]).
///
/// The field stays free-text - a brand-new category name the user types is kept
/// verbatim; the dropdown is a convenience, not a hard picker.
class _CategoryField extends ConsumerStatefulWidget {
  const _CategoryField({
    required this.controller,
    required this.labelWidth,
    required this.onChanged,
  });

  final TextEditingController controller;
  final double labelWidth;

  /// Fired on every edit (typing or a pick) so the editor marks itself dirty.
  final VoidCallback onChanged;

  @override
  ConsumerState<_CategoryField> createState() => _CategoryFieldState();
}

class _CategoryFieldState extends ConsumerState<_CategoryField> {
  final _focusNode = FocusNode();
  final _link = LayerLink();
  OverlayEntry? _overlay;
  bool _focused = false;

  // Snapshot of the group data, refreshed from providers on every build so the
  // overlay builder (which runs later) reads current values.
  List<String> _allCategories = const [];
  Map<String, SnippetCategory> _metaMap = const {};

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _closeOverlay();
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final has = _focusNode.hasFocus;
    if (has != _focused && mounted) setState(() => _focused = has);
    if (has) {
      _openOverlay();
    } else {
      // Defer the close a frame so a pointer-up on a dropdown row still lands
      // (the row uses canRequestFocus:false, so a pick keeps focus until we
      // unfocus in _select - but an outside tap blurs first).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) _closeOverlay();
      });
    }
  }

  List<String> _filtered() {
    final q = widget.controller.text.trim().toLowerCase();
    if (q.isEmpty) return _allCategories;
    return _allCategories.where((c) => c.toLowerCase().contains(q)).toList();
  }

  void _openOverlay() {
    if (_overlay != null) return;
    final overlayState = Overlay.of(context);
    _overlay = OverlayEntry(
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 4),
            // TextFieldTapRegion shares the group EditableText uses for its
            // tap-outside detection, so a tap on the dropdown (which lives in
            // the root Overlay, OUTSIDE the field's subtree) does NOT blur the
            // field mid-click - the pick lands, then _select unfocuses to close.
            child: TextFieldTapRegion(
              child: SizedBox(
                width: _link.leaderSize?.width,
                child: _CategoryOptions(
                  options: _filtered(),
                  metaMap: _metaMap,
                  emptyHint: l10n.zestSnippetsCategoryPickerHint,
                  onSelected: _select,
                ),
              ),
            ),
          ),
        );
      },
    );
    overlayState.insert(_overlay!);
  }

  void _closeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _select(String name) {
    widget.controller.text = name;
    widget.controller.selection = TextSelection.collapsed(offset: name.length);
    widget.onChanged();
    _focusNode.unfocus(); // schedules the overlay close via _handleFocusChange
  }

  void _onFieldChanged(String _) {
    widget.onChanged();
    if (_focusNode.hasFocus && _overlay == null) _openOverlay();
    _overlay?.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    _allCategories = ref.watch(snippetCategoriesProvider);
    _metaMap = ref.watch(snippetCategoryMetaMapProvider);
    // Reflect provider changes (a category added/recolored elsewhere) in an
    // already-open dropdown.
    _overlay?.markNeedsBuild();

    // No manual tap-outside handling: the inner TextField (EditableText)
    // unfocuses on any tap outside its region on desktop, which fires the focus
    // listener that closes the dropdown. A tap ON the dropdown is exempted by
    // its TextFieldTapRegion.
    return ZestField.custom(
      label: l10n.zestSnippetsFieldCategory,
      labelWidth: widget.labelWidth,
      child: CompositedTransformTarget(
        link: _link,
        child: _CategoryInputBox(
          controller: widget.controller,
          focusNode: _focusNode,
          focused: _focused,
          placeholder: l10n.snippetsCategoryHint,
          onChanged: _onFieldChanged,
        ),
      ),
    );
  }
}

/// The category text input, styled to match [ZestField]'s input box (so it sits
/// flush with the Label/Command/Description fields) with a trailing chevron that
/// signals the filtering dropdown.
class _CategoryInputBox extends StatelessWidget {
  const _CategoryInputBox({
    required this.controller,
    required this.focusNode,
    required this.focused,
    required this.placeholder,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool focused;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: 13,
      color: ZestTokens.textPrimary,
      height: 1.3,
    );
    final hintStyle = textStyle.copyWith(color: ZestTokens.textPlaceholder);
    // The border, radius, sunken fill and horizontal padding are supplied by the
    // enclosing [ZestField.custom]; this box only lays out the input + chevron.
    return Container(
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: textStyle,
              cursorColor: ZestTokens.brand,
              cursorWidth: 1.5,
              onChanged: onChanged,
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                hintText: placeholder,
                hintStyle: hintStyle,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            focused ? LucideIcons.chevronUp : LucideIcons.chevronDown,
            size: 16,
            color: ZestTokens.textTertiary,
          ),
        ],
      ),
    );
  }
}

/// The dropdown surface: a scrollable list of group rows, each a color swatch +
/// name. Falls back to a single muted [emptyHint] row when nothing matches so
/// the panel never collapses to an empty box while the field is focused.
class _CategoryOptions extends StatelessWidget {
  const _CategoryOptions({
    required this.options,
    required this.metaMap,
    required this.emptyHint,
    required this.onSelected,
  });

  final List<String> options;
  final Map<String, SnippetCategory> metaMap;
  final String emptyHint;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 236),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: options.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Text(
                    emptyHint,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: ZestTokens.textTertiary,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, i) {
                    final name = options[i];
                    final color = categoryAccent(name, metaMap[name]);
                    return InkWell(
                      // Don't steal focus from the text field on tap, so the
                      // overlay stays open through the pick (we unfocus after).
                      canRequestFocus: false,
                      onTap: () => onSelected(name),
                      hoverColor: ZestTokens.surfaceSunken,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: ZestTokens.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// The names' column of the form, as wide as the longest of its names at the
/// text size the app is drawn at, and at least the _kSnippetLabelWidth it had (a longer
/// name was cut, in Russian or Spanish).
double _snippetLabelWidth(BuildContext context, AppLocalizations l10n) =>
    zestFieldLabelWidth(context, [l10n.snippetsLabel, l10n.zestSnippetsFieldCommand, l10n.zestSnippetsFieldAbout, l10n.zestSnippetsDefaultHostLabel, l10n.zestSnippetsFieldCategory], min: _kSnippetLabelWidth);
