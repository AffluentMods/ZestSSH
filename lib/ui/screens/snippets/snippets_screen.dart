import 'dart:async';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show defaultSavePlace, savePlaces, showMoveCopyDialog, transferOffer;
import 'package:zestssh/features/orchards/move/save_in_field.dart' show saveNewItemIn;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/features/selection/item_selection_bar.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart' show SelectBox;
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart' show kCsvMaxBytes;
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/features/snippets/save_snippet.dart';
import 'package:zestssh/features/snippets/snippet_category_color.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_variable_dialog.dart';
// Reuse the shared category editor (rename + accent colour) so the mobile
// folder menu and the desktop right-click menu open the identical editor.
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart'
    show showSnippetCategoryEditor;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_bottom_nav.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/utils/capped_file.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/utils/kept_from_sync.dart';
import 'package:zestssh/providers/core_providers.dart' show snippetsDaoProvider;

/// Snippet management screen - the Snippets tab.
///
/// Groups snippets by category with collapsible sections,
/// search bar, FAB to create, long-press context menu.
class SnippetsScreen extends ConsumerStatefulWidget {
  /// If provided, tapping a snippet sends it to this callback
  /// instead of just copying it, its variables filled in. The callback runs
  /// the risky-command check (the session's own); the list asks the
  /// snippet's "confirm before running" only where that check will not ask.
  /// With it, the command as a question shows it: its masked values
  /// (`${VAR:secret}`) out of sight.
  final void Function(String command, String shown, List<String> secrets)? onExecute;

  /// Optional callback to execute a command on the active SSH session
  /// and return its stdout. Used for dynamic list variables like $[DOCKER].
  final CommandExecutor? executeCommand;

  /// When false, the inline "Setup guide" button is dropped from the search
  /// row so it stops crowding the search box. The host route (which owns an
  /// AppBar) sets this and puts the guide in the AppBar's top-right instead.
  final bool showSetupGuide;

  /// When false, New snippet and the import and export menu are left to the
  /// app bar above (the phone's Snippets tab puts them there, as every list
  /// page adds: [SnippetsScreenState.newSnippet], [SnippetsMenuButton]);
  /// the row holds the search alone.
  final bool actionsInRow;

  const SnippetsScreen({
    super.key,
    this.onExecute,
    this.executeCommand,
    this.showSetupGuide = true,
    this.actionsInRow = true,
  });

  @override
  ConsumerState<SnippetsScreen> createState() => SnippetsScreenState();
}

/// The import and export menu of a [SnippetsScreen] whose [state] is
/// reached by a key, for an app bar over it (horizontal dots, as every
/// overflow menu).
class SnippetsMenuButton extends ConsumerWidget {
  const SnippetsMenuButton({super.key, required this.state});

  final GlobalKey<SnippetsScreenState> state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _menu(context, ref, () => state.currentState);
}

/// A phone's Snippets page (More, Snippets): New snippet and the import and
/// export menu at the bar's end, as every list page adds and as a tablet's
/// Snippets tab has them, and the search alone in the row under the bar
/// (they sat beside the search).
class SnippetsPhoneScreen extends ConsumerStatefulWidget {
  const SnippetsPhoneScreen({super.key});

  @override
  ConsumerState<SnippetsPhoneScreen> createState() => _SnippetsPhoneScreenState();
}

class _SnippetsPhoneScreenState extends ConsumerState<SnippetsPhoneScreen> {
  final _snippets = GlobalKey<SnippetsScreenState>();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Snippets selected (3.4), the hosts' way: the bar says how many, the
    // tab bar is the selection's actions, back ends it.
    final selecting = ref.watch(snippetSelectionProvider).active;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) ref.read(snippetSelectionProvider.notifier).exit();
      },
      child: Scaffold(
      bottomNavigationBar: selecting
          ? PhoneItemSelectionBar(
              kind: TransferKinds.snippet,
              onItemActions: (id) => _snippets.currentState?.showSnippetActions(id),
            )
          : null,
      appBar: selecting ? const PhoneItemSelectionAppBar(kind: TransferKinds.snippet) : AppBar(
        title: Text(l10n.routerErrSnippets),
        actions: [
          const SetupGuideButton(SetupTopic.snippets),
          IconButton(
            key: const ValueKey('snippets-new'),
            icon: const Icon(LucideIcons.plus),
            tooltip: l10n.snippetsNewSnippet,
            onPressed: () => _snippets.currentState?.newSnippet(),
          ),
          SnippetsMenuButton(state: _snippets),
          const SizedBox(width: 4),
        ],
      ),
      // In the one centred column a phone page takes on a tablet, as Hosts
      // and Networks have, and a tablet's Snippets tab.
      body: PhonePageColumn(
        child: SnippetsScreen(key: _snippets, showSetupGuide: false, actionsInRow: false),
      ),
      ),
    );
  }
}

Widget _menu(BuildContext context, WidgetRef ref, SnippetsScreenState? Function() state) {
  final l10n = AppLocalizations.of(context)!;
  return PopupMenuButton<String>(
    key: const ValueKey('snippets-menu'),
    icon: const Icon(LucideIcons.moreHorizontal, size: 20),
    tooltip: l10n.zestCommonMoreActions,
    onSelected: (action) {
      switch (action) {
        case 'export':
          state()?._exportSnippets();
        case 'import':
          state()?._importSnippets();
      }
    },
    itemBuilder: (context) => [
      // An Orchard's snippets leave in an export only an owner makes.
      if (mayExportScreenSpace(ref))
        PopupMenuItem(
          value: 'export',
          child: ListTile(
            leading: const Icon(LucideIcons.upload, size: 20),
            title: Text(l10n.snippetsExportSnippets),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      PopupMenuItem(
        value: 'import',
        child: ListTile(
          leading: const Icon(LucideIcons.download, size: 20),
          title: Text(l10n.snippetsImportSnippets),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ],
  );
}

class SnippetsScreenState extends ConsumerState<SnippetsScreen> {
  /// Opens the editor for a new snippet (the app bar's "+").
  Future<void> newSnippet() => _showEditDialog(context);

  /// The snippet [id]'s own sheet (what a long press on it offered before
  /// it started selecting): the selection's More with one snippet (3.4).
  void showSnippetActions(String id) {
    final snippet = (ref.read(snippetsProvider).valueOrNull ?? const <Snippet>[]).where((s) => s.id == id).firstOrNull;
    if (snippet != null) _showContextMenu(context, snippet);
  }

  final _searchController = TextEditingController();
  final _collapsedCategories = <String>{};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snippetsAsync = ref.watch(snippetsProvider);
    // Persisted per-category metadata (accent colour / hidden). Drives the
    // folder header colour so a recolour from the long-press menu shows here.
    final categoryMeta = ref.watch(snippetCategoryMetaMapProvider);

    // Use SafeArea top padding when embedded in a tab (no AppBar above us)
    final topPad = MediaQuery.of(context).padding.top;

    return Material(
      color: Colors.transparent,
      child: Column(
        children: [
          // The search (the phone lists' field), then New snippet and the
          // import and export menu where no app bar holds them.
          Padding(
            padding: EdgeInsets.fromLTRB(16, topPad + 12, widget.actionsInRow ? 8 : 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: PhoneSearchField(
                    controller: _searchController,
                    hintText: l10n.snippetsSearchHint,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                if (widget.actionsInRow) ...[
                  IconButton(
                    key: const ValueKey('snippets-new'),
                    icon: const Icon(LucideIcons.plus, size: 20),
                    tooltip: l10n.snippetsNewSnippet,
                    onPressed: () => _showEditDialog(context),
                  ),
                  if (widget.showSetupGuide)
                    const SetupGuideButton(SetupTopic.snippets),
                  _menu(context, ref, () => this),
                ],
              ],
            ),
          ),

        Expanded(
          child: snippetsAsync.when(
            data: (snippets) {
              final filtered = _filterSnippets(snippets);
              if (filtered.isEmpty && snippets.isEmpty) {
                return _buildEmptyState(context);
              }
              if (filtered.isEmpty) {
                return ZestEmptyState(
                  icon: LucideIcons.searchX,
                  title: l10n.snippetsNoMatchingSnippets,
                );
              }
              return _buildGroupedList(context, filtered, categoryMeta);
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: Text(l10n.snippetsLoadError,
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
          ),
        ),
        ],
      ),
    );
  }

  List<Snippet> _filterSnippets(List<Snippet> snippets) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return snippets;
    return snippets
        .where((s) =>
            s.label.toLowerCase().contains(query) ||
            s.command.toLowerCase().contains(query) ||
            (s.category?.toLowerCase().contains(query) ?? false))
        .toList();
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.code2,
      title: l10n.snippetsNone,
      message: l10n.snippetsNoneDesc,
      // Two fill paths: create a snippet, or seed the built-in defaults.
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: () => _showEditDialog(context),
            icon: const Icon(LucideIcons.plus, size: 16),
            label: Text(l10n.snippetsNewSnippet),
          ),
          // Beside the one primary, the theme's neutral secondary (it was
          // outlined in the accent).
          OutlinedButton.icon(
            key: const ValueKey('snippets-load-defaults'),
            onPressed: _seedDefaults,
            icon: const Icon(LucideIcons.sparkles, size: 16),
            label: Text(l10n.snippetsLoadDefaults),
          ),
        ],
      ),
    );
  }

  /// Whether this list selects (3.4): not inside a session, where a tap runs
  /// a snippet and the list is a picker.
  bool get _selectable => widget.onExecute == null;

  Widget _buildGroupedList(BuildContext context, List<Snippet> snippets,
      Map<String, SnippetCategory> categoryMeta) {
    // Group by category
    final grouped = <String, List<Snippet>>{};
    for (final snippet in snippets) {
      final cat = snippet.category ?? AppLocalizations.of(context)!.snippetsUncategorized;
      grouped.putIfAbsent(cat, () => []).add(snippet);
    }

    final categories = grouped.keys.toList()..sort();
    // The snippets shown, in order (a folded category's are not): what
    // Select all shown selects (3.4).
    if (_selectable) {
      publishShownItems(ref, TransferKinds.snippet, [
        for (final c in categories)
          if (!_collapsedCategories.contains(c))
            for (final s in grouped[c]!) s.id,
      ]);
    }
    final lead = _selectable ? 1 : 0;

    return ListView.builder(
      // Clear the bottom nav + FAB so the last snippet stays visible.
      padding: EdgeInsets.only(
          bottom: ZestBottomNav.contentBottomPadding(context)),
      itemCount: categories.length + lead,
      itemBuilder: (context, at) {
        // Selected snippets the search hides: said, with Show.
        if (at < lead) {
          return PhoneSelectionHiddenLine(
            kind: TransferKinds.snippet,
            onShow: () => setState(_searchController.clear),
          );
        }
        final index = at - lead;
        final category = categories[index];
        final items = grouped[category]!;
        final isCollapsed = _collapsedCategories.contains(category);
        // The bucket's real (raw) category string - null/empty for the
        // synthetic "Uncategorized" group, which has no folder to
        // rename / recolour / delete.
        final rawCategory = items.first.category;
        final isUncategorized = rawCategory == null || rawCategory.isEmpty;
        final meta = isUncategorized ? null : categoryMeta[rawCategory];
        final categoryColor = _resolveCategoryColor(category, meta);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Category header
            Semantics(
              label: AppLocalizations.of(context)!.snippetsCategoryLabel(category, items.length),
              button: true,
              hint: isCollapsed ? AppLocalizations.of(context)!.snippetsTapToExpand : AppLocalizations.of(context)!.snippetsTapToCollapse,
              child: InkWell(
              onTap: () {
                setState(() {
                  if (isCollapsed) {
                    _collapsedCategories.remove(category);
                  } else {
                    _collapsedCategories.add(category);
                  }
                });
              },
              // Long-press a real category folder to rename / recolour /
              // delete it - mirrors the host-group long-press menu and the
              // desktop snippet-category right-click menu. The synthetic
              // Uncategorized bucket has no folder actions.
              onLongPress: isUncategorized
                  ? null
                  : () => _showCategoryContextMenu(
                      context, rawCategory, meta, items),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: ZestSectionHeader.category(
                    label: category,
                    dot: categoryColor,
                    count: items.length,
                    trailing: AnimatedRotation(
                      turns: isCollapsed ? -0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(LucideIcons.chevronDown, size: 16, color: AppColors.v3TextTertiary),
                    ),
                  ),
                ),
              ),
            ),
            ),

            // Snippet tiles
            if (!isCollapsed)
              for (final snippet in items)
                _buildSnippetTile(context, snippet, categoryColor),
          ],
        );
      },
    );
  }

  Widget _buildSnippetTile(
      BuildContext context, Snippet snippet, Color categoryColor) {
    final l10n = AppLocalizations.of(context)!;
    final varCount = parseVariablesWithOptions(snippet.command).length;
    final confirm = snippet.confirmBeforeRun;
    final category = snippet.category;
    final hasCategory = category != null && category.isNotEmpty;
    final hasMeta = hasCategory || varCount > 0 || confirm;
    // Snippets being selected (3.4): a long press starts it with this one,
    // then a tap puts one in or takes it out.
    final selection = _selectable ? ref.watch(snippetSelectionProvider) : null;
    final selecting = selection?.active ?? false;
    final selected = selection?.isSelected(snippet.id) ?? false;
    void toggle() {
      haptic(ref, Haptic.selection);
      ref.read(snippetSelectionProvider.notifier).toggle(snippet.id);
    }

    return Semantics(
      label: l10n.snippetsItemLabel(snippet.label, snippet.command),
      button: true,
      selected: selecting && selected,
      hint: selecting ? null : l10n.snippetsTapToExecuteHint,
      child: Card(
        key: ValueKey('phone-snippet-${snippet.id}'),
        color: selecting && selected ? Color.alphaBlend(phoneSelectedTint(), Theme.of(context).cardTheme.color ?? AppColors.surface) : null,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          splashColor: categoryColor.withValues(alpha: 0.08),
          highlightColor: categoryColor.withValues(alpha: 0.04),
          onTap: selecting ? toggle : () => _executeSnippet(context, snippet),
          onLongPress: selecting
              ? toggle
              : _selectable
                  ? () {
                      haptic(ref, Haptic.medium);
                      ref.read(snippetSelectionProvider.notifier).enter(snippet.id);
                    }
                  : () => _showContextMenu(context, snippet),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (selecting) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectBox(key: ValueKey('phone-snippet-box-${snippet.id}'), checked: selected, size: 20),
                  ),
                  const SizedBox(width: 12),
                ],
                // Category color indicator
                ExcludeSemantics(
                  child: Container(
                    width: 3,
                    height: 44,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: categoryColor,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [
                        BoxShadow(
                          color: categoryColor.withValues(alpha: 0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // 3-row body: title(+markers) / mono command / meta chips
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Row 1: title + marker glyphs
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              snippet.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (varCount > 0)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(LucideIcons.braces,
                                  size: 13,
                                  color: AppColors.accentInk
                                      .withValues(alpha: 0.8)),
                            ),
                          if (confirm)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(LucideIcons.shieldAlert,
                                  size: 13,
                                  color:
                                      AppColors.warning.withValues(alpha: 0.85)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Row 2: mono command preview (2 lines)
                      Text(
                        snippet.command,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11,
                          height: 1.3,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      // Row 3 on a phone and a tablet: its category, its
                      // variables and whether it asks first, as one line of
                      // plain text (they were chips; 3.0 quick wins: chips
                      // are for filters and what needs someone).
                      if (hasMeta && isTouchLayout) ...[
                        const SizedBox(height: 6),
                        Row(
                          key: ValueKey('snippet-meta-${snippet.id}'),
                          children: [
                            if (hasCategory) ...[
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(color: categoryColor, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 5),
                            ],
                            Flexible(
                              child: Text(
                                [
                                  if (hasCategory) category.toLowerCase(),
                                  if (varCount > 0) l10n.zestSnippetsVarsBadge(varCount),
                                  if (confirm) l10n.zestSnippetsConfirmBadge,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ]
                      // Row 3: meta chips
                      else if (hasMeta) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            if (hasCategory)
                              _MobileMetaChip(
                                label: category.toLowerCase(),
                                dotColor: categoryColor,
                              ),
                            if (varCount > 0)
                              _MobileMetaChip(
                                icon: LucideIcons.braces,
                                label: l10n.zestSnippetsVarsBadge(varCount),
                              ),
                            if (confirm)
                              _MobileMetaChip(
                                icon: LucideIcons.shieldAlert,
                                label: l10n.zestSnippetsConfirmBadge,
                                tone: AppColors.warning,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                // Quick action: run
                if (widget.onExecute != null)
                  Semantics(
                    label: l10n.snippetsExecuteLabel(snippet.label),
                    button: true,
                    child: IconButton(
                      icon:
                          Icon(LucideIcons.play, color: AppColors.success),
                      onPressed: () => _executeSnippet(context, snippet),
                      tooltip: l10n.snippetsExecuteTooltip,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Runs [snippet] through [SnippetsScreen.onExecute] (the list inside a
  /// session on a phone). Its variables are filled in as everywhere a snippet
  /// runs: those without a default are asked for, defaults are used silently.
  /// Then it is asked about once (3.0 docs check, 22 October 2026: it could be
  /// asked about twice, its own "confirm before running" here and then the
  /// session's risky-command check). The session that runs it ([onExecute]'s
  /// caller) checks for a risky command; where that check will ask, it is the
  /// one question, and the snippet's own question is asked only where it will
  /// not, as [commandReadyToRun] does.
  Future<void> _executeSnippet(BuildContext context, Snippet snippet) async {
    final l10n = AppLocalizations.of(context)!;
    final protectionOn = ref.read(dangerousCommandProtectionProvider);
    String resolvedCommand = snippet.command;
    String shownCommand = snippet.command;
    List<String> secrets = const [];

    if (variablesToPrompt(snippet.command).isNotEmpty) {
      final parsedVars = parseVariablesWithOptions(snippet.command);
      final values = await showVariableInputDialog(
        context: context,
        variables: parsedVars.map((v) => v.name).toList(),
        snippetLabel: snippet.label,
        command: snippet.command,
        executeCommand: widget.executeCommand,
      );
      if (values == null) return; // User cancelled
      resolvedCommand = resolveVariables(snippet.command, values);
      shownCommand = resolveVariablesShown(snippet.command, values);
      secrets = maskedValuesIn(snippet.command, values);
    } else {
      resolvedCommand = commandWithDefaults(snippet.command);
      shownCommand = resolvedCommand;
    }

    if (!context.mounted) return;
    final riskyCheckAsks = widget.onExecute != null &&
        protectionOn &&
        DangerousCommandService.checkFilled(resolvedCommand).isNotEmpty;
    if (snippet.confirmBeforeRun && !riskyCheckAsks) {
      final confirmed = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.neutral,
        title: l10n.snippetRunConfirmTitle,
        body: l10n.snippetRunConfirmBody,
        bullets: [commandForQuestion(shownCommand)],
        confirmLabel: l10n.snippetRunAction,
      );
      if (confirmed != true) return;
    }

    if (widget.onExecute != null) {
      widget.onExecute!(resolvedCommand, shownCommand, secrets);
    } else {
      // Copy to clipboard as fallback
      await Clipboard.setData(ClipboardData(text: resolvedCommand));
      if (context.mounted) {
        showTopSnackBar(
          context,
          l10n.snippetsCommandCopiedToClipboard,
        );
      }
    }
  }

  void _showContextMenu(BuildContext context, Snippet snippet) {
    final l10n = AppLocalizations.of(context)!;
    haptic(ref, Haptic.medium);
    // Move to... and Copy to...: Personal, or a team's vault (3.4).
    final offer = transferOffer(ref, TransferKinds.snippet, [snippet.id]);
    final page = this.context;
    void transfer(TransferMode mode) =>
        unawaited(showMoveCopyDialog(page, ref, kind: TransferKinds.snippet, keys: [snippet.id], mode: mode));
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: Text(l10n.edit),
              onTap: () {
                Navigator.pop(context);
                _showEditDialog(context, snippet: snippet);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.copy),
              title: Text(l10n.snippetsCopyCommand),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: snippet.command));
                showTopSnackBar(context, l10n.snippetsCommandCopied);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.copy),
              title: Text(l10n.snippetsDuplicate),
              onTap: () {
                Navigator.pop(context);
                _duplicateSnippet(snippet);
              },
            ),
            if (offer.move)
              ListTile(
                key: const ValueKey('snippet-sheet-move-to'),
                leading: const Icon(LucideIcons.folderInput),
                title: Text(l10n.transferMoveTo),
                onTap: () {
                  Navigator.pop(context);
                  transfer(TransferMode.move);
                },
              ),
            if (offer.copy)
              ListTile(
                key: const ValueKey('snippet-sheet-copy-to'),
                leading: const Icon(LucideIcons.copyPlus),
                title: Text(l10n.transferCopyTo),
                onTap: () {
                  Navigator.pop(context);
                  transfer(TransferMode.copy);
                },
              ),
            ListTile(
              leading: Icon(LucideIcons.trash2, color: AppColors.error),
              title:
                  Text(l10n.delete, style: TextStyle(color: AppColors.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(context, snippet);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Folder accent: a user-picked colour (custom ARGB, else palette index)
  /// wins; otherwise the name-derived default the mobile list has always used.
  Color _resolveCategoryColor(String category, SnippetCategory? meta) {
    final value = meta?.colorValue;
    if (value != null) return Color(value);
    final idx = meta?.colorIndex;
    if (idx != null && idx >= 0) {
      return AppColors.v3GroupColors[idx % AppColors.v3GroupColors.length];
    }
    return _categoryColor(category);
  }

  /// Long-press menu for a snippet category (folder): Edit (rename + recolour)
  /// and, for user-created folders, Delete. Mirrors the host-group long-press
  /// menu; built-in folders (containing seeded default snippets) can be
  /// recoloured/renamed but not deleted, matching the desktop rule.
  void _showCategoryContextMenu(
    BuildContext context,
    String category,
    SnippetCategory? meta,
    List<Snippet> items,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final isBuiltIn = items.any((s) => s.isDefault);
    haptic(ref, Haptic.medium);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.textCursorInput),
              title: Text(l10n.snippetsEditCategory),
              onTap: () {
                Navigator.pop(context);
                showSnippetCategoryEditor(
                  context: context,
                  name: category,
                  meta: meta,
                );
              },
            ),
            if (!isBuiltIn)
              ListTile(
                leading:
                    Icon(LucideIcons.trash2, color: AppColors.error),
                title: Text(
                  l10n.zestSnippetsDeleteCategory,
                  style: TextStyle(color: AppColors.error),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDeleteCategory(context, category, items.length);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteCategory(
      BuildContext context, String category, int count) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.zestSnippetsDeleteCategoryTitle(category),
      body: l10n.zestSnippetsDeleteCategoryBody(count),
      confirmLabel: l10n.zestSnippetsDeleteCategoryConfirm,
    );

    if (confirmed == true) {
      await ref.read(snippetCategoryCrudProvider).deleteCategory(category);
    }
  }

  Future<void> _showEditDialog(BuildContext context,
      {Snippet? snippet}) async {
    // Gather existing categories for the autocomplete dropdown
    final allSnippets = ref.read(snippetsProvider).valueOrNull ?? [];
    final existingCategories = allSnippets
        .map((s) => s.category)
        .where((c) => c != null && c.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList()
      ..sort();

    final result = await showSnippetEditDialog(
      context: context,
      snippet: snippet,
      existingCategories: existingCategories,
    );
    if (result == null || !mounted) return;

    final crud = ref.read(snippetCrudProvider);
    // A new one for another place than new items of this space go to ("Save
    // in", 3.4): saved there, and said where.
    final place = result.saveIn;
    if (snippet == null && place != null && place != defaultSavePlace(ref)) {
      final id = await saveNewItemIn(this.context, ref, place: place, kind: TransferKinds.snippet, write: () => crud.create(
            label: result.label,
            command: result.command,
            category: result.category,
            confirmBeforeRun: result.confirmBeforeRun,
            metadata: result.metadata,
          ));
      if (id == null || !mounted) return;
      final l10n = AppLocalizations.of(this.context)!;
      final saved = savePlaces(ref, l10n, watch: false).where((p) => p.place == place).firstOrNull;
      showTopSnackBar(this.context, l10n.saveInSavedToast(Redactable.freeText(saved?.title ?? '').display), isSuccess: true);
      return;
    }
    // Stored, then said with its name ("Snippet saved" / "Snippet added").
    await saveSnippetSaying(
      this.context,
      name: result.label,
      added: snippet == null,
      write: () async => snippet != null
          // updateFull writes every field, so clearing the category (result
          // .category == null) persists as uncategorized. The partial update()
          // treats a null category as "unchanged" and could never clear it.
          // A field the person did not touch keeps what a sync wrote while
          // the editor was open.
          ? await _updateKeepingSync(snippet, result)
          : await crud.create(
              label: result.label,
              command: result.command,
              category: result.category,
              confirmBeforeRun: result.confirmBeforeRun,
              metadata: result.metadata,
            ),
    );
  }

  /// [result] written over [snippet] as the editor read it, keeping what a
  /// sync changed meanwhile in the fields the person did not touch.
  Future<void> _updateKeepingSync(Snippet snippet, SnippetEditResult result) async {
    final now = await ref.read(snippetsDaoProvider).getById(snippet.id);
    final keep = keptSince<Snippet>(snippet, now, (s) => s.updatedAt);
    await ref.read(snippetCrudProvider).updateFull(
              id: snippet.id,
              label: keep(result.label, (s) => s.label),
              command: keep(result.command, (s) => s.command),
              category: keep(result.category, (s) => s.category),
              confirmBeforeRun: keep(result.confirmBeforeRun, (s) => s.confirmBeforeRun),
              // The editor now owns the metadata blob (variable descriptions +
              // default host) and PRESERVES the snippet description it didn't
              // edit, so a mobile save can't wipe what the desktop detail
              // editor wrote.
              metadata: result.metadata,
            );
  }

  Future<void> _duplicateSnippet(Snippet snippet) async {
    final crud = ref.read(snippetCrudProvider);
    final label = AppLocalizations.of(context)!.snippetsDuplicateSuffix(snippet.label);
    await saveSnippetSaying(
      context,
      name: label,
      added: true,
      write: () => crud.create(
        label: label,
        command: snippet.command,
        category: snippet.category,
        confirmBeforeRun: snippet.confirmBeforeRun,
        // Its description, the notes on its variables and its default host
        // come along (the copy had none of them).
        metadata: snippet.metadata,
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Snippet snippet) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.snippetsDeleteTitle,
      body: l10n.snippetsDeleteMsg(snippet.label),
      confirmLabel: l10n.delete,
    );

    if (confirmed == true) {
      await ref.read(snippetCrudProvider).delete(snippet.id);
    }
  }

  Future<void> _seedDefaults() async {
    final crud = ref.read(snippetCrudProvider);
    await crud.seedDefaults();
  }

  Future<void> _exportSnippets() async {
    final l10n = AppLocalizations.of(context)!;
    if (!mayExportScreenSpace(ref)) return;
    final snippets = ref.read(snippetsProvider).valueOrNull ?? [];
    if (snippets.isEmpty) {
      if (mounted) {
        showTopSnackBar(context, l10n.snippetsNoSnippetsToExport);
      }
      return;
    }

    final exportData = {
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'snippets': snippets.map((s) => {
        'label': s.label,
        'command': s.command,
        'category': s.category,
        'confirmBeforeRun': s.confirmBeforeRun,
        'sortOrder': s.sortOrder,
      }).toList(),
    };

    try {
      final json = const JsonEncoder.withIndent('  ').convert(exportData);
      // Written into a folder of its own, and deleted with it once the sheet
      // has closed (it was written straight into the folder of temporary
      // files and left there, every command in it).
      await ConnectionShareService.shareFiles(
        {'zestssh_snippets.json': utf8.encode(json)},
        subject: l10n.snippetsShareSubject,
        // Said before the share sheet, so it is seen even when the share is
        // cancelled.
        written: () {
          if (!mounted) return;
          showTopSnackBar(context, l10n.snippetsExportedChooseTarget(snippets.length),
              isSuccess: true, duration: const Duration(seconds: 4));
        },
      );
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.snippetsExportFailed, isError: true, details: '$e');
      }
    }
  }

  Future<void> _importSnippets() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.isEmpty) return;

      final path = result.files.first.path;
      if (path == null) {
        if (mounted) {
          showTopSnackBar(context, l10n.snippetsCouldNotReadFile);
        }
        return;
      }

      // A file chosen can be anything, of any size: read as far as a host file
      // may be, as every other import does, and off the screen's thread.
      final bytes = await readFileCapped(path, kCsvMaxBytes);
      if (bytes == null) {
        if (mounted) showTopSnackBar(context, l10n.csvImpTooLarge(kCsvMaxBytes ~/ (1024 * 1024)), isError: true);
        return;
      }
      final data = await importJsonAway(bytes) as Map<String, dynamic>;

      if (data['snippets'] is! List) {
        if (mounted) {
          showTopSnackBar(context, l10n.snippetsInvalidFileFormat);
        }
        return;
      }

      final snippetsList = data['snippets'] as List;
      const maxImportCount = 500;
      const maxCommandLength = 10000;
      if (snippetsList.length > maxImportCount) {
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.snippetsImportLimited(maxImportCount),
            isWarning: true,
          );
        }
      }
      final crud = ref.read(snippetCrudProvider);
      var imported = 0;

      for (final item in snippetsList.take(maxImportCount)) {
        final map = item as Map<String, dynamic>;
        final label = map['label'] as String? ?? '';
        final command = map['command'] as String? ?? '';
        if (label.isEmpty || command.isEmpty) continue;
        if (command.length > maxCommandLength) continue;

        await crud.create(
          label: label,
          command: command,
          category: map['category'] as String?,
          confirmBeforeRun: map['confirmBeforeRun'] as bool? ?? false,
        );
        imported++;
      }

      if (mounted) {
        showTopSnackBar(
          context,
          l10n.snippetsImportedCount(imported),
        );
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.snippetsImportFailed,
          isError: true, details: '$e'
        );
      }
    }
  }

  Color _categoryColor(String category) => snippetCategoryColor(category);
}

/// A compact meta chip for the mobile snippet card's third row: either a
/// category chip (coloured leading dot) or a labelled badge with a leading
/// glyph (e.g. "3 vars", "Confirm"). Neutral by default; pass a [tone] to tint.
class _MobileMetaChip extends StatelessWidget {
  final IconData? icon;
  final Color? dotColor;
  final String label;
  final Color? tone;

  const _MobileMetaChip({
    this.icon,
    this.dotColor,
    required this.label,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tone ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(
        color: tone == null
            ? AppColors.surfaceLight
            : tone!.withValues(alpha: 0.14),
        // The app's chip corners (no pills).
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: tone == null ? AppColors.divider : tone!.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ] else if (icon != null) ...[
            Icon(icon, size: 11, color: accent),
            const SizedBox(width: 4),
          ],
          Text(label, style: TextStyle(fontSize: 11, color: accent)),
        ],
      ),
    );
  }
}
