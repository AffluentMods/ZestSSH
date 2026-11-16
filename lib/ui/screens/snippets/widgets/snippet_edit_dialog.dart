import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace, TransferKinds;
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/features/orchards/move/save_in_field.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/theme/zest_tokens.dart';

/// Result returned from the snippet edit dialog.
class SnippetEditResult {
  final String label;
  final String command;
  final String? category;
  final bool confirmBeforeRun;

  /// Encoded `Snippets.metadata` JSON (snippet + per-variable descriptions and
  /// the optional default-host id), or null when the snippet has none. The
  /// editor owns this so a mobile save persists the variables table + default
  /// host without a separate write path.
  final String? metadata;

  /// Where a new snippet is saved ("Save in", 3.4); null: where new items of
  /// the space on screen go.
  final SavePlace? saveIn;

  const SnippetEditResult({
    required this.label,
    required this.command,
    this.category,
    this.confirmBeforeRun = false,
    this.metadata,
    this.saveIn,
  });
}

/// Whether we are running on a desktop platform ([isTouchLayout] is its
/// opposite in the app, and a test can draw the phone's with it).
bool get _isDesktop => !isTouchLayout;

/// Shows the snippet editor.
///
/// On mobile: opens a full-screen modal route for maximum editing space.
/// On desktop: opens a wide dialog with generous room for the command editor.
///
/// If [initialCommand] is provided (e.g. from terminal text selection),
/// the command field is pre-filled with it.
Future<SnippetEditResult?> showSnippetEditDialog({
  required BuildContext context,
  Snippet? snippet,
  List<String> existingCategories = const [],
  String? initialCommand,
}) async {
  if (_isDesktop) {
    return showDialog<SnippetEditResult>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 700),
          child: SnippetEditor(
            snippet: snippet,
            existingCategories: existingCategories,
            initialCommand: initialCommand,
          ),
        ),
      ),
    );
  }

  // Mobile: full-screen modal for maximum space
  return Navigator.of(context).push<SnippetEditResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => Scaffold(
        backgroundColor: AppColors.surface,
        appBar: AppBar(
          title: Text(snippet != null
              ? AppLocalizations.of(context)!.snippetsEditTitle
              : AppLocalizations.of(context)!.snippetsNewTitle),
          leading: IconButton(
            tooltip: AppLocalizations.of(context)!.close,
            icon: const Icon(LucideIcons.x),
            onPressed: () => Navigator.pop(context),
          ),
          // A saved snippet's Move or copy (4.0): its places, then Move here
          // or Copy here; moved, it is not here any more and the page closes
          // with nothing to save.
          actions: [
            if (snippet != null)
              MoveCopyMenuButton(
                kind: TransferKinds.snippet,
                itemKey: snippet.id,
                onMoved: () {
                  if (context.mounted) Navigator.pop(context);
                },
              ),
          ],
        ),
        // Its Cancel and Save are pinned at the bottom: kept above the phone's
        // navigation bar, which covered them on Android (3.3). The AppBar keeps
        // clear of the status bar by itself.
        body: SafeArea(
          top: false,
          child: SnippetEditor(
            snippet: snippet,
            existingCategories: existingCategories,
            initialCommand: initialCommand,
          ),
        ),
      ),
    ),
  );
}

/// The core snippet editor form. Used three ways:
///  * desktop dialog (showSnippetEditDialog) - returns via Navigator.pop
///  * mobile full-screen route - returns via Navigator.pop
///  * desktop inline split (SnippetsLibraryView) - reports through [onSubmit]/
///    [onCancel] and pops nothing (there is no route to pop).
class SnippetEditor extends ConsumerStatefulWidget {
  final Snippet? snippet;
  final List<String> existingCategories;
  final String? initialCommand;

  /// Inline mode: when [onSubmit] is non-null the editor reports its result
  /// through these callbacks instead of Navigator.pop, and skips the PopScope
  /// route guard (there is no enclosing route to intercept).
  final void Function(SnippetEditResult result)? onSubmit;
  final VoidCallback? onCancel;

  const SnippetEditor({
    super.key,
    this.snippet,
    this.existingCategories = const [],
    this.initialCommand,
    this.onSubmit,
    this.onCancel,
  });

  bool get _inline => onSubmit != null;

  @override
  ConsumerState<SnippetEditor> createState() => _SnippetEditorState();
}

class _SnippetEditorState extends ConsumerState<SnippetEditor> {
  late final TextEditingController _labelController;
  late final TextEditingController _commandController;
  late final TextEditingController _categoryController;
  late bool _confirmBeforeRun;
  final _formKey = GlobalKey<FormState>();
  final _commandFocus = FocusNode();
  bool _allowPop = false;

  /// Metadata parsed from the bound snippet: seeds per-variable descriptions +
  /// the default host, and preserves the snippet DESCRIPTION (mobile has no
  /// description editor, so re-emitting it prevents a mobile save from wiping
  /// what the desktop detail editor wrote).
  late final SnippetMetadata _initialMeta;

  /// Optional default-host connection id (persisted in metadata JSON - no
  /// schema column).
  String? _defaultConnectionId;

  /// Per free-text-variable Default cell controllers, keyed by variable key.
  /// Editing one rewrites the command (`${VAR}` ↔ `${VAR:-value}`), matching the
  /// desktop detail editor, so the command stays the single source of truth.
  final Map<String, TextEditingController> _varDefaultCtrls = {};

  /// Per-variable Description controllers, persisted into metadata on save.
  final Map<String, TextEditingController> _varDescCtrls = {};

  /// Where a new snippet is saved ("Save in", 3.4).
  SavePlace? _saveIn;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.snippet?.label);
    _commandController = TextEditingController(
      text: widget.snippet?.command ?? widget.initialCommand,
    );
    // A new snippet starts in the category Settings gives new snippets (it
    // started in none whatever Settings said); one there has its own.
    _categoryController = TextEditingController(
        text: widget.snippet == null ? ref.read(defaultSnippetCategoryProvider) : widget.snippet!.category);
    _confirmBeforeRun = widget.snippet?.confirmBeforeRun ?? false;
    _initialMeta = parseSnippetMetadata(widget.snippet?.metadata);
    _defaultConnectionId = _initialMeta.defaultConnectionId;
    _syncVarControllers();
    _commandFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _labelController.dispose();
    _commandController.dispose();
    _categoryController.dispose();
    _commandFocus.dispose();
    for (final c in _varDefaultCtrls.values) {
      c.dispose();
    }
    for (final c in _varDescCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Variable table sync (mirrors the desktop detail editor) ──────

  List<ParsedVariable> get _vars =>
      parseVariablesWithOptions(_commandController.text);

  /// Ensure a Default + Description controller exists for every current
  /// variable, seeding new ones from the command's parsed default and (once)
  /// the persisted metadata descriptions.
  void _syncVarControllers() {
    final descSeed = _initialMeta.variableDescriptions;
    for (final v in _vars) {
      if (v.isFreeText) {
        _varDefaultCtrls.putIfAbsent(
          v.key,
          () => TextEditingController(text: v.defaultValue ?? ''),
        );
      }
      _varDescCtrls.putIfAbsent(
        v.key,
        () => TextEditingController(text: descSeed[v.key] ?? ''),
      );
    }
  }

  /// The command changed - reseed each Default cell to the command's parsed
  /// default so a `:-default` typed straight into the command stays in sync.
  void _onCommandChanged(String _) {
    _syncVarControllers();
    for (final v in _vars) {
      if (!v.isFreeText) continue;
      final ctrl = _varDefaultCtrls[v.key];
      if (ctrl == null) continue;
      final parsed = v.defaultValue ?? '';
      if (ctrl.text != parsed) ctrl.text = parsed;
    }
    setState(() {});
  }

  /// A Default cell was edited - rewrite the command so it carries the new
  /// default. Done programmatically, so it never re-triggers [_onCommandChanged].
  void _onVarDefaultChanged(String name, String value) {
    _commandController.text =
        setVariableDefault(_commandController.text, name, value);
    setState(() {});
  }

  /// Build the metadata blob to persist: preserved snippet description +
  /// per-variable descriptions (for variables still present) + default host.
  String? _buildMetadata() {
    final varDescs = <String, String>{};
    for (final v in _vars) {
      final d = _varDescCtrls[v.key]?.text.trim() ?? '';
      if (d.isNotEmpty) varDescs[v.key] = d;
    }
    return encodeSnippetMetadata(
      SnippetMetadata(
        description: _initialMeta.description,
        variableDescriptions: varDescs,
        defaultConnectionId: _defaultConnectionId,
      ),
    );
  }

  /// Pick the default host via the grouped connection picker.
  Future<void> _pickDefaultHost() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await ConnectionPickerDialog.show(
      context,
      title: l10n.zestSnippetsDefaultHostPickTitle,
      needsTerminal: true,
    );
    final picked = result.connection;
    if (picked == null || !mounted) return;
    setState(() => _defaultConnectionId = picked.connection.id);
  }

  /// Insert text at the current cursor position in the command editor.
  void _insertAtCursor(String text) {
    final controller = _commandController;
    final selection = controller.selection;
    final currentText = controller.text;

    if (selection.isValid) {
      final newText = currentText.replaceRange(
          selection.start, selection.end, text);
      controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
            offset: selection.start + text.length),
      );
    } else {
      // Cursor at end
      controller.text = currentText + text;
      controller.selection = TextSelection.collapsed(
          offset: controller.text.length);
    }
    // Keep focus on the command field
    _commandFocus.requestFocus();
    // A freshly-inserted `${VAR}` needs its variables-table row.
    _syncVarControllers();
    setState(() {});
  }

  List<String> get _allCategories {
    // Combine existing categories from the database with well-known defaults
    final known = <String>{
      'System',
      'Services',
      'Docker',
      'Network',
      'Files',
      'Security',
      'Packages',
      'Git',
      'Database',
      'Logs',
    };
    known.addAll(widget.existingCategories);
    final sorted = known.toList()..sort();
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = widget.snippet != null;
    final detectedVars = parseVariablesWithOptions(_commandController.text);

    final form = Form(
      key: _formKey,
      child: Column(
        children: [
          // ── Header (desktop dialog only) ──────────────────
          if (_isDesktop)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Row(
                children: [
                  Icon(LucideIcons.code, color: AppColors.accentInk),
                  const SizedBox(width: 10),
                  Text(
                    isEditing ? l10n.snippetsEditTitle : l10n.snippetsNewTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  // A saved snippet's Move or copy (4.0); moved, it is not
                  // here any more and the editor closes with nothing to save.
                  if (widget.snippet case final saved?)
                    MoveCopyMenuButton(
                      kind: TransferKinds.snippet,
                      itemKey: saved.id,
                      onMoved: _closeAfterMove,
                    ),
                  IconButton(
                    tooltip: AppLocalizations.of(context)!.close,
                    icon: const Icon(LucideIcons.x),
                    onPressed: () => _handleClose(),
                  ),
                ],
              ),
            ),

          // ── Scrollable content ────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Where a new snippet is saved (3.4).
                if (!isEditing)
                  SaveInField(
                    value: _saveIn,
                    onChanged: (p) => setState(() => _saveIn = p),
                    padding: const EdgeInsets.only(bottom: 16),
                  ),
                // ── Display Name ─────────────────────────────
                TextFormField(
                  controller: _labelController,
                  decoration: InputDecoration(
                    labelText: l10n.snippetEditDisplayName,
                    hintText: l10n.snippetEditDisplayNameHint,
                    prefixIcon: const Icon(LucideIcons.tag, size: 20),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  autofocus: !isEditing,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? l10n.snippetEditNameRequired : null,
                ),
                const SizedBox(height: 20),

                // ── Category (autocomplete) ──────────────────
                Text(
                  l10n.snippetsCategory,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                _CategoryAutocomplete(
                  controller: _categoryController,
                  categories: _allCategories,
                ),
                const SizedBox(height: 20),

                // ── Command ──────────────────────────────────
                Row(
                  children: [
                    Text(
                      l10n.snippetsCommand,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(message: AppLocalizations.of(context)!.helpTitle, child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _showVariableHelp(context),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          LucideIcons.helpCircle,
                          size: 16,
                          color: AppColors.accentInk.withValues(alpha: 0.7),
                        ),
                      ),
                    )),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r'${VAR}  $[a,b]  $[DOCKER]',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.divider,
                      width: 1,
                    ),
                  ),
                  child: TextFormField(
                    controller: _commandController,
                    focusNode: _commandFocus,
                    decoration: InputDecoration(
                      hintText: _isDesktop
                          ? 'docker restart \$[DOCKER]\n# \$[a,b,c] for lists, \${VAR} for text'
                          : r'docker restart $[DOCKER]',
                      hintStyle: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 13,
                        color: ZestTokens.textPlaceholder,
                      ),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.all(14),
                    ),
                    maxLines: _isDesktop ? 12 : 8,
                    minLines: _isDesktop ? 8 : 5,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13,
                      color: Color(0xFFD4D4D4),
                      height: 1.5,
                    ),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? l10n.snippetEditCommandRequired
                        : null,
                    onChanged: _onCommandChanged,
                  ),
                ),


                // ── Variables table ─────────────────────────
                if (detectedVars.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _MobileVariablesTable(
                    variables: detectedVars,
                    defaultCtrls: _varDefaultCtrls,
                    descCtrls: _varDescCtrls,
                    onDefaultChanged: _onVarDefaultChanged,
                  ),
                ],

                const SizedBox(height: 20),

                // ── Default host ────────────────────────────
                _MobileDefaultHostField(
                  connectionId: _defaultConnectionId,
                  onPick: _pickDefaultHost,
                  onClear: () =>
                      setState(() => _defaultConnectionId = null),
                ),

                const SizedBox(height: 20),

                // ── Options ─────────────────────────────────
                // A Material, not a coloured box, so the switch row draws its
                // hover and press on it (Flutter 3.44 asks for that).
                Material(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(10),
                  child: SwitchListTile(
                    title: Text(l10n.snippetEditConfirmBeforeRun),
                    subtitle: Text(
                      l10n.snippetEditConfirmBeforeRunDesc,
                      style: const TextStyle(fontSize: 12),
                    ),
                    secondary: Icon(
                      LucideIcons.alertTriangle,
                      color: _confirmBeforeRun
                          ? AppColors.warning
                          : AppColors.textSecondary,
                      size: 20,
                    ),
                    value: _confirmBeforeRun,
                    onChanged: (v) => setState(() => _confirmBeforeRun = v),
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Bottom action buttons ─────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.divider),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Row 1: Template quick-insert buttons
                if (_commandFocus.hasFocus || _isDesktop)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        _ShortcutButton(
                          label: r'${VAR}',
                          isTemplate: true,
                          onTap: () => _insertAtCursor(r'${VAR}'),
                          compact: true,
                        ),
                        const SizedBox(width: 4),
                        _ShortcutButton(
                          label: r'$[a,b]',
                          isTemplate: true,
                          onTap: () => _insertAtCursor(r'$[]'),
                          compact: true,
                        ),
                        const SizedBox(width: 4),
                        _ShortcutButton(
                          label: r'$[DOCKER]',
                          isTemplate: true,
                          onTap: () => _insertAtCursor(r'$[DOCKER]'),
                          compact: true,
                        ),
                        if (_isDesktop) ...[
                          const Spacer(),
                          Text(
                            l10n.snippetEditChars(_commandController.text.length, 4096),
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                              fontFamily: 'JetBrainsMono',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                // Row 2: Cancel + Save/Create
                Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => _handleClose(),
                      child: Text(l10n.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _save,
                      icon: Icon(
                        isEditing ? LucideIcons.check : LucideIcons.plus,
                        size: 18,
                      ),
                      label: Text(isEditing ? l10n.save : l10n.create),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandOrange,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // Route modes (dialog / full-screen) guard the back gesture with PopScope
    // to confirm discard; inline mode has no route to pop, so return the bare
    // form (its Cancel / close button routes through onCancel instead).
    if (widget._inline) return form;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onPopInvoked();
        if (shouldPop && context.mounted) {
          setState(() => _allowPop = true);
          Navigator.pop(context);
        }
      },
      child: form,
    );
  }

  /// The kinds of variable a snippet takes: a notice in the app's dialog
  /// (3.4), a phone's sheet, with Got it in its footer (a sheet of its own
  /// before, each kind in a colour of its own).
  void _showVariableHelp(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.info,
          icon: LucideIcons.helpCircle,
          title: l10n.snippetEditVarsTitle,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _helpItem(
                r'${VAR}',
                l10n.snippetEditVarText,
                l10n.snippetEditVarTextDesc,
                r'ssh ${USER}@${HOST}',
              ),
              const SizedBox(height: 14),
              _helpItem(
                r'$[a,b,c]',
                l10n.snippetEditVarList,
                l10n.snippetEditVarListDesc,
                r'systemctl $[start,stop,restart] nginx',
              ),
              const SizedBox(height: 14),
              _helpItem(
                r'$[DOCKER]',
                l10n.snippetEditVarDynamic,
                l10n.snippetEditVarDynamicDesc,
                r'docker logs $[DOCKER]',
              ),
              const SizedBox(height: 16),
              Text(
                l10n.snippetEditPasteNote,
                style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary),
              ),
            ],
          ),
          primaryKey: const ValueKey('snippet-vars-help-done'),
          primaryAction: (label: l10n.desktopGotIt, icon: null, onPressed: () => Navigator.of(ctx).pop()),
        ),
      ),
    );
  }

  /// One kind of variable: its syntax and name, what it does, an example.
  /// In the text's colours, every kind alike (each had a colour of its own).
  Widget _helpItem(
    String syntax,
    String title,
    String description,
    String example,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.v3TextPrimary.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                syntax,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.v3TextPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Text(
            example,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: AppColors.v3TextSecondary,
            ),
          ),
        ),
      ],
    );
  }

  /// Show discard confirmation if the command field has text, then pop.
  Future<void> _handleClose() async {
    if (_commandController.text.isNotEmpty) {
      final discard = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.destructive,
        title: AppLocalizations.of(context)!.snippetEditDiscardTitle,
        body: AppLocalizations.of(context)!.snippetEditDiscardBody,
        confirmLabel: AppLocalizations.of(context)!.zestCommonDiscard,
        cancelLabel: AppLocalizations.of(context)!.snippetEditKeepEditing,
      );
      if (discard != true) return;
    }
    if (!mounted) return;
    // Inline (split) mode dismisses via the callback; routes pop.
    if (widget.onCancel != null) {
      widget.onCancel!();
      return;
    }
    setState(() => _allowPop = true);
    Navigator.pop(context);
  }

  /// After the snippet moved out of this place: closes, saving nothing.
  void _closeAfterMove() {
    if (!mounted) return;
    if (widget.onCancel != null) {
      widget.onCancel!();
      return;
    }
    setState(() => _allowPop = true);
    Navigator.pop(context);
  }

  /// Called by PopScope to intercept system back / mobile AppBar close.
  Future<bool> _onPopInvoked() async {
    if (_commandController.text.isEmpty) return true;
    final discard = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: AppLocalizations.of(context)!.snippetEditDiscardTitle,
      body: AppLocalizations.of(context)!.snippetEditDiscardBody,
      confirmLabel: AppLocalizations.of(context)!.zestCommonDiscard,
      cancelLabel: AppLocalizations.of(context)!.snippetEditKeepEditing,
    );
    return discard == true;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    // Bake each free-text default from its cell into the command so the stored
    // command matches the variables table even if a cell and the command drift.
    var command = _commandController.text.trim();
    for (final v in _vars) {
      if (!v.isFreeText) continue;
      command = setVariableDefault(
        command,
        v.key,
        _varDefaultCtrls[v.key]?.text ?? '',
      );
    }
    final category = _categoryController.text.trim();
    final result = SnippetEditResult(
      label: _labelController.text.trim(),
      command: command,
      category: category.isEmpty ? null : category,
      confirmBeforeRun: _confirmBeforeRun,
      metadata: _buildMetadata(),
      saveIn: _saveIn,
    );
    // Inline (split) mode reports back through the callback; the dialog and
    // full-screen routes return via Navigator.pop.
    if (widget.onSubmit != null) {
      widget.onSubmit!(result);
      return;
    }
    setState(() => _allowPop = true);
    Navigator.pop(context, result);
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Shortcut Button for command editor
// ═══════════════════════════════════════════════════════════════════

class _ShortcutButton extends StatelessWidget {
  final String label;
  final bool isTemplate;
  final bool compact;
  final VoidCallback onTap;

  const _ShortcutButton({
    required this.label,
    this.isTemplate = false,
    this.compact = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final double height = compact ? 30 : 36;
    final double fontSize = compact ? 10 : (isTemplate ? 11 : 16);

    return Material(
      color: isTemplate
          ? AppColors.brandOrange.withValues(alpha: 0.12)
          : AppColors.surfaceContainer,
      borderRadius: BorderRadius.circular(compact ? 6 : 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(
            minWidth: isTemplate ? 0 : 38,
            minHeight: height,
          ),
          alignment: Alignment.center,
          padding: isTemplate
              ? EdgeInsets.symmetric(horizontal: compact ? 6 : 6)
              : null,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: AppColors.accentInk,
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Category Autocomplete Widget
// ═══════════════════════════════════════════════════════════════════

class _CategoryAutocomplete extends StatelessWidget {
  final TextEditingController controller;
  final List<String> categories;

  const _CategoryAutocomplete({
    required this.controller,
    required this.categories,
  });

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.trim().toLowerCase();
        if (query.isEmpty) return categories;
        return categories
            .where((c) => c.toLowerCase().contains(query))
            .toList();
      },
      fieldViewBuilder:
          (context, textController, focusNode, onFieldSubmitted) {
        return TextFormField(
          controller: textController,
          focusNode: focusNode,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.snippetEditCategorySearch,
            prefixIcon: const Icon(LucideIcons.folder, size: 20),
            suffixIcon: textController.text.isNotEmpty
                ? IconButton(
                    tooltip: AppLocalizations.of(context)!.emptyClearSearch,
                    icon: const Icon(LucideIcons.x, size: 16),
                    onPressed: () {
                      textController.clear();
                      controller.clear();
                    },
                  )
                : null,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          textCapitalization: TextCapitalization.words,
          onFieldSubmitted: (_) => onFieldSubmitted(),
          // Sync the external controller with the internal one via onChanged
          // instead of addListener to avoid accumulating listeners on rebuild.
          onChanged: (value) {
            if (controller.text != value) {
              controller.text = value;
            }
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final query = controller.text.trim();
        final exactMatch =
            options.any((o) => o.toLowerCase() == query.toLowerCase());

        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            color: AppColors.surfaceContainer,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 300),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  // Show "Create new" option when typed text doesn't match
                  if (query.isNotEmpty && !exactMatch)
                    ListTile(
                      leading: Icon(LucideIcons.plusCircle,
                          color: AppColors.accentInk, size: 20),
                      title: Text(
                        AppLocalizations.of(context)!.snippetEditCreateCategory(query),
                        style: TextStyle(
                          color: AppColors.accentInk,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      dense: true,
                      onTap: () => onSelected(query),
                    ),
                  ...options.map((option) => ListTile(
                        leading: Icon(
                          LucideIcons.folder,
                          size: 18,
                          color: _categoryColor(option),
                        ),
                        title:
                            Text(option, style: const TextStyle(fontSize: 14)),
                        dense: true,
                        onTap: () => onSelected(option),
                      )),
                ],
              ),
            ),
          ),
        );
      },
      onSelected: (selection) {
        controller.text = selection;
      },
    );
  }

  Color _categoryColor(String category) {
    switch (category.toLowerCase()) {
      case 'system':
        return AppColors.categorySystem;
      case 'services':
        return const Color(0xFF8B5CF6);
      case 'docker':
        return const Color(0xFF0EA5E9);
      case 'network':
        return const Color(0xFF10B981);
      case 'files':
        return const Color(0xFFF59E0B);
      case 'security':
        return const Color(0xFFEF4444);
      case 'packages':
        return const Color(0xFF6366F1);
      case 'git':
        return const Color(0xFFF97316);
      case 'database':
        return const Color(0xFF14B8A6);
      case 'logs':
        return const Color(0xFF64748B);
      default:
        return AppColors.brandOrange;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Mobile variables table
// ═══════════════════════════════════════════════════════════════════

/// The mobile counterpart of the desktop detected-variables table: a stacked
/// list of per-variable cards (name · Default · Prompt · Required) instead of a
/// wide 4-column grid, purpose-built for the narrow phone form. Editing a
/// free-text variable's Default rewrites the command; Prompt persists into the
/// snippet metadata.
class _MobileVariablesTable extends StatelessWidget {
  final List<ParsedVariable> variables;
  final Map<String, TextEditingController> defaultCtrls;
  final Map<String, TextEditingController> descCtrls;
  final void Function(String name, String value) onDefaultChanged;

  const _MobileVariablesTable({
    required this.variables,
    required this.defaultCtrls,
    required this.descCtrls,
    required this.onDefaultChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              LucideIcons.braces,
              size: 14,
              color: AppColors.accentInk.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 6),
            Text(
              l10n.zestSnippetsVariablesLabel,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '(${variables.length})',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < variables.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _MobileVariableRow(
            variable: variables[i],
            defaultCtrl: defaultCtrls[variables[i].key],
            descCtrl: descCtrls[variables[i].key],
            onDefaultChanged: onDefaultChanged,
          ),
        ],
      ],
    );
  }
}

class _MobileVariableRow extends StatelessWidget {
  final ParsedVariable variable;
  final TextEditingController? defaultCtrl;
  final TextEditingController? descCtrl;
  final void Function(String name, String value) onDefaultChanged;

  const _MobileVariableRow({
    required this.variable,
    required this.defaultCtrl,
    required this.descCtrl,
    required this.onDefaultChanged,
  });

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
              ),
              if (variable.isRequired)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    l10n.zestSnippetsVarRequired,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.warning,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (variable.isFreeText)
            TextField(
              controller: defaultCtrl,
              onChanged: (v) => onDefaultChanged(variable.name, v),
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
              ),
              decoration: InputDecoration(
                labelText: l10n.zestSnippetsVarDefault,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                variable.isInlineList
                    ? variable.options.join(', ')
                    : (variable.dynamicSource ?? variable.name),
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: descCtrl,
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              labelText: l10n.zestSnippetsVarDescription,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Mobile default-host field
// ═══════════════════════════════════════════════════════════════════

/// The optional "Default host" row for the mobile editor. Opens the grouped
/// [ConnectionPickerDialog] and shows the picked host's label (resolved from
/// [connectionsWithDetailsProvider]). The id persists in metadata (no schema
/// column).
class _MobileDefaultHostField extends ConsumerWidget {
  final String? connectionId;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _MobileDefaultHostField({
    required this.connectionId,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connections =
        ref.watch(connectionsWithDetailsProvider).valueOrNull ??
            const <ConnectionWithDetails>[];
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.zestSnippetsFieldTarget,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPick,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                if (resolved != null)
                  HostGlyph(host: resolved.connection, group: resolved.group, size: 22)
                else
                  Icon(
                    LucideIcons.target,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    display ?? l10n.zestSnippetsDefaultHostNone,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: display == null
                          ? AppColors.textSecondary
                          : AppColors.onSurface,
                    ),
                  ),
                ),
                if (hasValue)
                  Tooltip(message: AppLocalizations.of(context)!.zestCommonClear, child: GestureDetector(
                    onTap: onClear,
                    behavior: HitTestBehavior.opaque,
                    child: Icon(
                      LucideIcons.x,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ))
                else
                  Icon(
                    LucideIcons.chevronDown,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
