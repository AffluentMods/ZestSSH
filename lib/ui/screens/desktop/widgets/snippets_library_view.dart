import 'dart:async';


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show showMoveCopyDialog, transferOffer;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/features/selection/item_selection_bar.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/snippets/run_snippet.dart' show currentSessionOf, defaultHostOf, runCommandOnPicked;
import 'package:zestssh/features/snippets/save_snippet.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippet_detail_editor.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippet_detail_view.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/edit_drafts.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart' show SelectBox;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_master_detail.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

// ══════════════════════════════════════════════════════════════════
// Snippet-specific semantic colors (design tokens with no palette entry)
// ══════════════════════════════════════════════════════════════════
//
// Shared by the card grid AND the detail editor (imported there). The warm
// palette owns every surface / border / text color; these three fg/bg pairs are
// the only snippet-specific accents the design introduces (variable amber-tan,
// confirm/required orange, never-run yellow) and have no token, so they live
// here as named consts rather than scattered inline hex.

/// Variable-token tint (e.g. `${DOCKER}`) + the badge background it sits on.
const Color kSnippetVarColor = Color(0xFFE0B48A);
const Color kSnippetVarBg = Color(0xFF221A13);

/// Confirm / required accent + its badge background.
const Color kSnippetConfirmColor = Color(0xFFF0A35E);
const Color kSnippetConfirmBg = Color(0xFF241A13);

/// Never-run accent + its chip background.
const Color kSnippetNeverRunColor = Color(0xFFD9A441);
const Color kSnippetNeverRunBg = Color(0xFF241F13);

/// Matches every variable placeholder form the parser understands -
/// `${VAR}`, `${VAR:-default}`, `$[VAR]` / `$[a,b]`, and the legacy `${[a,b]}` -
/// so a command preview can tint the whole token in [kSnippetVarColor].
final RegExp _kSnippetVarSpanRegex = RegExp(
  r'\$\[[^\]]+\]|\$\{\[[^\]]+\]\}|\$\{\w+(?::-[^}]*)?\}',
);

/// Render [command] as tinted spans: variable placeholders in
/// [kSnippetVarColor], everything else in [baseStyle]. The single source of
/// truth for command tinting, used by the card preview (a read-only
/// [Text.rich]) and by [SnippetCommandEditingController] (the editable command
/// field). Never returns an empty list, so it is safe for an empty command.
List<InlineSpan> buildSnippetCommandSpans(
  String command, {
  required TextStyle baseStyle,
}) {
  final spans = <InlineSpan>[];
  final varStyle = baseStyle.copyWith(color: kSnippetVarColor);
  var last = 0;
  for (final m in _kSnippetVarSpanRegex.allMatches(command)) {
    if (m.start > last) {
      spans.add(TextSpan(text: command.substring(last, m.start), style: baseStyle));
    }
    spans.add(TextSpan(text: m.group(0), style: varStyle));
    last = m.end;
  }
  if (last < command.length) {
    spans.add(TextSpan(text: command.substring(last), style: baseStyle));
  }
  if (spans.isEmpty) spans.add(TextSpan(text: command, style: baseStyle));
  return spans;
}

/// A [TextEditingController] that live-tints variable placeholders in the
/// editable command field. Overriding [buildTextSpan] is the least-invasive way
/// to colorize an editable field (no overlay, no ZestField changes); the field
/// stays fully editable and its `onChanged` fires normally.
class SnippetCommandEditingController extends TextEditingController {
  SnippetCommandEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    return TextSpan(
      style: style,
      children: buildSnippetCommandSpans(text, baseStyle: base),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Snippets Library View - 1.7 desktop master/detail
// ══════════════════════════════════════════════════════════════════

/// Display key for snippets with no category. Stable (English) across
/// locales so the persisted metadata keyed by this name stays consistent -
/// mirrors the pre-existing behavior of this view.
const _kUncategorized = 'Uncategorized';

/// Selection sentinel: the pane is on a blank NEW snippet (no id yet).
const _kNewSelection = '__new__';

/// The snippet editor's unsaved edits while the Snippets page is away
/// ([EditDrafts]), by the snippet's id (or the new snippet's key).
final snippetDraftsProvider = editDraftsProvider<SnippetKeptEdit>();

/// Summary filters for the snippet list, shown as a chip row above the list.
/// Orthogonal to the text search - both narrow the same list.
enum _SnippetFilter {
  /// Every snippet.
  all,

  /// Only snippets whose command contains `${...}` / `$[...]` placeholders.
  hasVariables,

  /// Only snippets flagged confirm-before-run ("Asks first").
  confirmRequired,
}

/// Full-height snippets library shown in the desktop shell's [IndexedStack]
/// when [NavSection.snippets] is active.
///
/// A [ZestMasterDetail] - the same list-left / editor-right master/detail shell
/// Networks and Port Forwarding use. The grouped snippet list fills the LEFT
/// pane; the [SnippetDetailEditor] is ALWAYS docked on the RIGHT, defaulting to
/// a blank NEW snippet (no empty state) so the editor is ready to fill on load.
/// Selecting a snippet fills the editor; the footer "Clear" resets it to a
/// blank new; a dirty guard prompts before switching away from unsaved edits.
///
/// Category sections carry a persisted color, a hide (eye) toggle, and a
/// rename/color editor; an Arrange slide-in reorders them. An ephemeral Sort
/// control re-orders the view without persisting.
class SnippetsLibraryView extends ConsumerStatefulWidget {
  const SnippetsLibraryView({super.key});

  @override
  ConsumerState<SnippetsLibraryView> createState() =>
      _SnippetsLibraryViewState();
}

class _SnippetsLibraryViewState extends ConsumerState<SnippetsLibraryView>
    with KeepsEditDrafts<SnippetsLibraryView, SnippetKeptEdit> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _searchQuery = '';

  /// Stable handle to the docked detail editor so we can ask it to confirm
  /// before the user switches away from a dirty draft.
  final _editorKey = GlobalKey<SnippetDetailEditorState>();

  /// Bumped on every open/reset so the reused editor State re-initialises even
  /// when the target snippet is unchanged (New after New, re-open after
  /// discard). See [SnippetDetailEditor.resetToken].
  int _editorToken = 0;

  /// Current selection: [_kNewSelection] = a blank new snippet; else a
  /// snippet id. The detail pane always shows the editor - never an empty pane.
  String _selectedId = _kNewSelection;

  /// Ephemeral "reveal hidden categories" toggle. The hidden FLAG persists;
  /// this local reveal does not.
  bool _showHidden = false;

  /// Active summary filter (ephemeral - resets on restart).
  _SnippetFilter _filter = _SnippetFilter.all;

  /// The folder its chip narrows the list to, or null for every folder.
  String? _folder;

  /// The list as cards (the earlier look) rather than rows.
  bool _grid = false;

  /// The selected snippet is open in the editor; otherwise its details show.
  bool _editing = false;

  /// Unsaved edits kept as the page went, which the editor opens with, and
  /// the editor's [_editorToken] they are for (a new open starts afresh).
  SnippetKeptEdit? _kept;
  int? _keptToken;

  @override
  void initState() {
    super.initState();
    // Unsaved edits kept as the page went (a terminal was shown in its
    // place): the same editor opens again, with them, as unsaved. A change
    // of profile builds the drafts anew, empty, and the form open here goes.
    final kept = takeEditDraft(snippetDraftsProvider, onRenewed: _resetToNew);
    if (kept != null) {
      _kept = kept;
      _keptToken = _editorToken;
      _selectedId = kept.snippetId ?? _kNewSelection;
      _editing = kept.snippetId != null;
    }
  }

  @override
  void deactivate() {
    // Going with unsaved edits (the shell shows a terminal in this page's
    // place): they are kept, in memory, for when the page comes back. Read
    // here, while the editor is still there.
    final kept = _editorKey.currentState?.keptEdit();
    if (kept != null) keepEditDraft(kept.snippetId ?? _kNewSelection, kept);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // Put back where it was (not gone after all): the editor still holds it.
    final kept = _editorKey.currentState?.keptEdit();
    if (kept != null) forgetEditDraft(kept.snippetId ?? _kNewSelection);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);
  }

  List<Snippet> _applyFilter(List<Snippet> snippets) {
    final q = _searchQuery.toLowerCase();
    return snippets.where((s) {
      // Summary filter first.
      switch (_filter) {
        case _SnippetFilter.all:
          break;
        case _SnippetFilter.hasVariables:
          if (!hasVariables(s.command)) return false;
        case _SnippetFilter.confirmRequired:
          if (!s.confirmBeforeRun) return false;
      }
      if (_folder != null && _folderOf(s) != _folder) return false;
      // Then the text search.
      if (q.isEmpty) return true;
      return s.label.toLowerCase().contains(q) ||
          s.command.toLowerCase().contains(q) ||
          (s.category?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  /// True when any narrowing is active (search text OR a non-"all" filter),
  /// so the empty-state can offer the right reset.
  bool get _isNarrowed =>
      _searchQuery.isNotEmpty || _filter != _SnippetFilter.all || _folder != null;

  static String _folderOf(Snippet s) =>
      (s.category != null && s.category!.isNotEmpty) ? s.category! : _kUncategorized;

  /// Resolve the currently-selected snippet from the live list, or null for a
  /// blank new (or a since-deleted selection).
  Snippet? _resolveSelected(List<Snippet>? snippets) {
    if (_selectedId == _kNewSelection || snippets == null) return null;
    for (final s in snippets) {
      if (s.id == _selectedId) return s;
    }
    return null;
  }

  /// If the open, saved snippet vanished from under us (deleted elsewhere),
  /// fall back to a blank new pane so its stale draft can't linger.
  void _reconcileSelection(List<Snippet>? snippets) {
    final id = _selectedId;
    if (id == _kNewSelection || snippets == null) return;
    if (!snippets.any((s) => s.id == id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedId == id) _resetToNew();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snippetsAsync = ref.watch(snippetsProvider);
    final metaMap = ref.watch(snippetCategoryMetaMapProvider);
    final sortMode = ref.watch(snippetSortModeProvider);

    _reconcileSelection(snippetsAsync.valueOrNull);
    final selected = _resolveSelected(snippetsAsync.valueOrNull);
    final all = snippetsAsync.valueOrNull ?? const <Snippet>[];

    // The page as the design draws it: the header
    // row, the chips and the list on the left; on the right a snippet's
    // details (read-only, Edit opens the editor), or the editor for a new one.
    return ColoredBox(
      color: ZestTokens.surfaceBase,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < ZestSizing.singleColumnBreakpoint;
          return ZestMasterDetail(
            screenId: 'snippets',
            // The list is the page, the details beside it: the
            // details keep about 680 wide, which the editor of a new snippet
            // needs, and the list takes the rest. Moved by hand, it stays.
            initialRatio: (1 - 680 / constraints.maxWidth).clamp(0.38, 0.72),
            listPane: _buildListPane(snippetsAsync, metaMap, sortMode, narrow, all),
            detailPane: selected != null && !_editing
                ? SnippetDetailView(
                    key: ValueKey('snippet-detail-${selected.id}'),
                    snippet: selected,
                    categoryColor: (selected.category?.isNotEmpty ?? false)
                        ? categoryAccent(selected.category!, metaMap[selected.category!])
                        : null,
                    onEdit: () => setState(() {
                      _editing = true;
                      _editorToken++;
                    }),
                    onClose: _resetToNew,
                  )
                : SnippetDetailEditor(
                    // Stable key: the same State is reused across snippets so
                    // its confirmLeave() guard can run before a switch.
                    // resetToken drives the per-open draft reset.
                    key: _editorKey,
                    resetToken: _editorToken,
                    snippet: selected,
                    kept: _keptToken == _editorToken ? _kept : null,
                    existingCategories: _getExistingCategories(),
                    onRequestNew: _resetToNew,
                    // Closing the editor of a snippet goes back to its details.
                    onClose: selected != null ? () => setState(() => _editing = false) : _resetToNew,
                  ),
          );
        },
      ),
    );
  }

  // ── List pane ────────────────────────────────────────────────────

  Widget _buildListPane(
    AsyncValue<List<Snippet>> snippetsAsync,
    Map<String, SnippetCategory> metaMap,
    SnippetSortMode sortMode,
    bool narrow,
    List<Snippet> all,
  ) {
    final l10n = AppLocalizations.of(context)!;
    // When the underlying list has loaded and is empty, the WHOLE pane becomes
    // the tier-1 empty state: hide the search field, filter chips and toolbar
    // so the pane's only control is that empty state's single (orange) CTA.
    final loadedEmpty =
        snippetsAsync.hasValue && (snippetsAsync.value?.isEmpty ?? false);
    // Snippets selected (3.4), as the hosts are: a box on each, the keys that
    // select, the selection's bar at the list's foot.
    final selection = ref.watch(snippetSelectionProvider);
    Future<bool> mayChange() async => await _editorKey.currentState?.confirmLeave() ?? true;
    return ItemSelectionKeys(
      kind: TransferKinds.snippet,
      beforeChange: mayChange,
      child: Stack(
        children: [
          Positioned.fill(child: Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // "/" shortcut focuses the search bar.
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.slash &&
            !_searchFocusNode.hasFocus) {
          _searchFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DecoratedBox(
        decoration: BoxDecoration(color: ZestTokens.surfaceBase),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search + New + filter chips + sort toolbar - the controls only
            // make sense when there's something to search or sort. Hidden
            // entirely once the list is empty, so tier-1 owns the whole pane.
            _PageHeaderRow(
              search: _SearchField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                hasContent: _searchQuery.isNotEmpty,
                onChanged: _onSearchChanged,
              ),
              onNew: () => _newSnippet(narrow: narrow),
              sortMode: sortMode,
              onSortChanged: (m) => ref.read(snippetSortModeProvider.notifier).state = m,
              onArrange: () => _showArrangePanel(context),
              grid: _grid,
              onGrid: (g) => setState(() => _grid = g),
              showSelect: !loadedEmpty,
            ),
            if (!loadedEmpty)
              _FolderChipsRow(
                total: all.length,
                folders: _buildSections(all, metaMap, sortMode),
                activeFolder: _folder,
                filter: _filter,
                onFolder: (f) => setState(() => _folder = f),
                onFilter: (f) => setState(() => _filter = f),
                // While selecting: the box over the snippets, how many are
                // selected and Clear selection, at the chips' end.
                trailing: selection.active ? const ItemSelectionHead(kind: TransferKinds.snippet) : null,
              ),
            Expanded(
              child: ItemSelectionFocusArea(
              child: snippetsAsync.when(
                // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
                skipLoadingOnReload: true,
                loading: () => Center(
                  child: CircularProgressIndicator(
                    color: AppColors.v3AccentPrimary,
                  ),
                ),
                error: (e, stack) => LoadErrorState(
                  message: l10n.snippetsLoadError,
                  where: 'Loading the snippet library',
                  error: e,
                  stack: stack,
                  onRetry: () => ref.invalidate(snippetsProvider),
                ),
                data: (snippets) {
                  if (snippets.isEmpty) {
                    publishShownItems(ref, TransferKinds.snippet, const []);
                    // Beside the list a new snippet's form is already open.
                    return _EmptyState(
                      onCreateFirst: narrow ? () => _newSnippet(narrow: narrow) : null,
                    );
                  }
                  final filtered = _applyFilter(snippets);
                  if (filtered.isEmpty && _isNarrowed) {
                    publishShownItems(ref, TransferKinds.snippet, const []);
                    // TIER 2: the list is non-empty but the active search /
                    // filter matched nothing. A short italic row with an inline
                    // "Clear search" - not a full-pane tier-1 block.
                    return _FilterEmptyState(
                      onClear: () {
                        _searchController.clear();
                        _onSearchChanged('');
                        setState(() {
                          _filter = _SnippetFilter.all;
                          _folder = null;
                        });
                      },
                    );
                  }

                  final sections = _buildSections(filtered, metaMap, sortMode);
                  // While narrowing, force-reveal hidden categories so a match
                  // is never swallowed by a collapsed group.
                  final revealHidden = _showHidden || _isNarrowed;
                  final totalHidden = sections.where((s) => s.hidden).length;
                  final visible = revealHidden
                      ? sections
                      : sections.where((s) => !s.hidden).toList();
                  // The snippets in the order shown: what Ctrl+A selects and
                  // a Shift-click's range runs along.
                  publishShownItems(ref, TransferKinds.snippet, [
                    for (final section in visible)
                      for (final s in section.snippets) s.id,
                  ]);

                  return _SnippetCategoryList(
                    grid: _grid,
                    sections: visible,
                    selectedId: _selectedId,
                    selecting: selection.active,
                    checked: selection.selected,
                    totalHidden: totalHidden,
                    showHidden: _showHidden,
                    searching: _isNarrowed,
                    onToggleShowHidden: () =>
                        setState(() => _showHidden = !_showHidden),
                    // A selection click where it is one (Ctrl or Cmd, Shift,
                    // any click while selecting), else the snippet opens.
                    onCardTap: (s) {
                      if (!itemSelectionClick(ref, TransferKinds.snippet, s.id,
                          openId: _selectedId == _kNewSelection ? null : _selectedId)) {
                        _selectSnippet(s, narrow: narrow);
                      }
                    },
                    onRun: _onSnippetRun,
                    onCopy: _onSnippetCopy,
                    onEdit: (s) =>
                        _selectSnippet(s, narrow: narrow, force: true),
                    onDuplicate: _onSnippetDuplicate,
                    onDelete: _onSnippetDelete,
                    onToggleCategoryHidden: _toggleCategoryHidden,
                    onEditCategory: _openCategoryEditor,
                    onDeleteCategory: _onDeleteCategory,
                  );
                },
              ),
              ),
            ),
          ],
        ),
      ),
          )),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ItemSelectionBar(kind: TransferKinds.snippet, beforeChange: mayChange),
          ),
        ],
      ),
    );
  }

  // ── Section building (order / hidden resolution) ─────────────────

  /// Group [filtered] by category and order the sections per [sortMode].
  /// In [SnippetSortMode.arranged], rowed categories order by their saved
  /// `sortOrder`; categories with no metadata row sort after, alphabetically.
  /// "Uncategorized" is always pinned last regardless of mode.
  List<_CatSection> _buildSections(
    List<Snippet> filtered,
    Map<String, SnippetCategory> metaMap,
    SnippetSortMode sortMode,
  ) {
    final groups = <String, List<Snippet>>{};
    for (final s in filtered) {
      final key = (s.category != null && s.category!.isNotEmpty)
          ? s.category!
          : _kUncategorized;
      (groups[key] ??= []).add(s);
    }

    // Within-section ordering.
    for (final items in groups.values) {
      if (sortMode == SnippetSortMode.recentlyUpdated) {
        items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      } else {
        items.sort((a, b) {
          final so = a.sortOrder.compareTo(b.sortOrder);
          return so != 0
              ? so
              : a.label.toLowerCase().compareTo(b.label.toLowerCase());
        });
      }
    }

    int cmpName(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    DateTime newest(String k) => groups[k]!
        .map((s) => s.updatedAt)
        .reduce((x, y) => x.isAfter(y) ? x : y);

    final names = groups.keys.toList()
      ..sort((a, b) {
        // Uncategorized always last.
        if (a == _kUncategorized && b != _kUncategorized) return 1;
        if (b == _kUncategorized && a != _kUncategorized) return -1;
        switch (sortMode) {
          case SnippetSortMode.nameAsc:
            return cmpName(a, b);
          case SnippetSortMode.nameDesc:
            return cmpName(b, a);
          case SnippetSortMode.recentlyUpdated:
            return newest(b).compareTo(newest(a));
          case SnippetSortMode.arranged:
            final ao = metaMap[a]?.sortOrder;
            final bo = metaMap[b]?.sortOrder;
            if (ao != null && bo != null) {
              final c = ao.compareTo(bo);
              return c != 0 ? c : cmpName(a, b);
            }
            if (ao != null) return -1; // rowed before unrowed
            if (bo != null) return 1;
            return cmpName(a, b);
        }
      });

    return [
      for (final n in names)
        _CatSection(
          name: n,
          snippets: groups[n]!,
          meta: metaMap[n],
          isUncategorized: n == _kUncategorized,
        ),
    ];
  }

  // ── Selection / creation (all run the dirty guard first) ─────────

  List<String> _getExistingCategories() {
    return ref.read(snippetCategoriesProvider);
  }

  /// Select [snippet] into the editor, first asking a dirty draft to confirm
  /// the switch. In the narrow single-column layout, push the editor as its
  /// own route instead of docking it.
  Future<void> _selectSnippet(
    Snippet snippet, {
    required bool narrow,
    bool force = false,
  }) async {
    // A left-click on the already-open card is a no-op; an explicit "Edit"
    // (force) always re-opens it into the editor so the menu action can never
    // feel dead.
    if (!force && !narrow && _selectedId == snippet.id) return;
    final proceed = await _editorKey.currentState?.confirmLeave() ?? true;
    if (!proceed || !mounted) return;
    if (narrow) {
      await _pushDetail(snippet);
      return;
    }
    setState(() {
      _selectedId = snippet.id;
      _editing = force;
      _editorToken++;
    });
  }

  /// Start a blank new snippet (dirty guard first). Narrow → push a route.
  Future<void> _newSnippet({required bool narrow}) async {
    final proceed = await _editorKey.currentState?.confirmLeave() ?? true;
    if (!proceed || !mounted) return;
    if (narrow) {
      await _pushDetail(null);
      return;
    }
    _resetToNew();
  }

  /// Reset the docked editor to a blank new snippet WITHOUT a guard (the caller
  /// already ran it, or nothing is dirty). Used as the editor's onRequestNew /
  /// onClose in the wide layout.
  void _resetToNew() {
    setState(() {
      _selectedId = _kNewSelection;
      _editing = false;
      _editorToken++;
    });
  }

  /// Present the editor full-screen in the narrow single-column layout.
  Future<void> _pushDetail(Snippet? initial) {
    return ZestMasterDetail.pushDetail<void>(
      context,
      _NarrowSnippetEditorHost(
        initialSnippet: initial,
        existingCategories: _getExistingCategories(),
      ),
    );
  }

  // ── Snippet actions ──────────────────────────────────────────────

  /// Keyboard/menu "Run on…": on the snippet's default host while it still
  /// exists (3.0 docs check: the field was saved and never used), else on a
  /// host picked through the grouped [ConnectionPickerDialog] (the same
  /// group-sorted design as the SFTP picker and the hosts slide-out). It runs
  /// as everywhere ([runCommandOnHost]): its variables asked, the
  /// dangerous-command check or its own "confirm before running", then
  /// entered in the host's live session, or in one opened to it. The
  /// picker's first choice, where this device has a shell of its own, is a
  /// new terminal on it ([runCommandInLocalTerminal]), run the same way.
  Future<void> _onSnippetRun(Snippet snippet) async {
    final l10n = AppLocalizations.of(context)!;
    final host = defaultHostOf(
        ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [], snippet.metadata);
    final result = host != null
        ? ConnectionPickerResult.connection(host)
        : await ConnectionPickerDialog.show(
            context,
            title: l10n.zestSnippetsRunOnTitle,
            needsTerminal: true,
            place: HostListPlace.runSnippet,
            includeLocalTerminal: true,
          );
    if (!mounted) return;
    await runCommandOnPicked(
      context,
      ref,
      result,
      command: snippet.command,
      label: snippet.label,
      confirmFirst: snippet.confirmBeforeRun,
      snippetId: snippet.id,
    );
  }

  /// Keyboard/menu "Copy" (Ctrl/Cmd+C) - puts the raw command on the clipboard.
  Future<void> _onSnippetCopy(Snippet snippet) async {
    await Clipboard.setData(ClipboardData(text: snippet.command));
    if (!mounted) return;
    showTopSnackBar(
      context,
      AppLocalizations.of(context)!.zestSnippetsCopied,
      duration: const Duration(seconds: 2),
    );
  }

  void _onSnippetDuplicate(Snippet snippet) {
    final l10n = AppLocalizations.of(context)!;
    final crud = ref.read(snippetCrudProvider);
    final label = l10n.snippetsLibraryDuplicateLabel(snippet.label);
    saveSnippetSaying(
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

  Future<void> _onSnippetDelete(Snippet snippet) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.snippetsLibraryDeleteConfirmTitle(snippet.label),
      body: l10n.snippetsLibraryDeleteConfirmBody,
      confirmLabel: l10n.snippetsLibraryDeleteConfirmAction,
    );
    if (confirmed == true) {
      ref.read(snippetCrudProvider).delete(snippet.id);
      // If the deleted snippet was open in the editor, reset to a blank new.
      if (_selectedId == snippet.id) _resetToNew();
    }
  }

  // ── Category actions ─────────────────────────────────────────────

  void _toggleCategoryHidden(_CatSection section) {
    final nowHidden = !(section.meta?.hidden ?? false);
    ref.read(snippetCategoryCrudProvider).setHidden(section.name, nowHidden);
  }

  Future<void> _openCategoryEditor(_CatSection section) async {
    await showSnippetCategoryEditor(
      context: context,
      name: section.name,
      meta: section.meta,
    );
  }

  /// Delete a custom group: its snippets revert to Uncategorized (commands
  /// kept) and the metadata row is dropped. Gated to non-built-in, non-synthetic
  /// groups by the header menu, but re-checked here as a guard.
  Future<void> _onDeleteCategory(_CatSection section) async {
    if (section.isUncategorized || section.isBuiltIn) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.zestSnippetsDeleteCategoryTitle(section.name),
      body: l10n.zestSnippetsDeleteCategoryBody(section.snippets.length),
      confirmLabel: l10n.zestSnippetsDeleteCategoryConfirm,
    );
    if (confirmed == true) {
      ref.read(snippetCategoryCrudProvider).deleteCategory(section.name);
    }
  }

  Future<void> _showArrangePanel(BuildContext context) async {
    await showSnippetArrangePanel(context);
  }
}

// ══════════════════════════════════════════════════════════════════
// Narrow single-column editor host
// ══════════════════════════════════════════════════════════════════

/// Hosts a [SnippetDetailEditor] as its own full-screen route in the narrow
/// (< 1000px) layout, where the master/detail shell shows only the list inline.
/// Owns a local selection + dirty flag so the route can guard back-navigation.
class _NarrowSnippetEditorHost extends StatefulWidget {
  const _NarrowSnippetEditorHost({
    required this.initialSnippet,
    required this.existingCategories,
  });

  final Snippet? initialSnippet;
  final List<String> existingCategories;

  @override
  State<_NarrowSnippetEditorHost> createState() =>
      _NarrowSnippetEditorHostState();
}

class _NarrowSnippetEditorHostState extends State<_NarrowSnippetEditorHost> {
  final _key = GlobalKey<SnippetDetailEditorState>();
  Snippet? _snippet;
  int _token = 0;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _snippet = widget.initialSnippet;
  }

  void _resetToNew() {
    setState(() {
      _snippet = null;
      _token++;
      _dirty = false;
    });
  }

  /// Leave the route (dirty guard first). Uses Navigator.pop directly so it
  /// forcibly closes even while PopScope's canPop is false.
  Future<void> _guardedPop() async {
    final proceed = await _key.currentState?.confirmLeave() ?? true;
    if (proceed && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _guardedPop();
      },
      child: SnippetDetailEditor(
        key: _key,
        resetToken: _token,
        snippet: _snippet,
        existingCategories: widget.existingCategories,
        onDirtyChanged: (d) => setState(() => _dirty = d),
        onRequestNew: _resetToNew,
        onClose: _guardedPop,
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// A resolved category section (name + its snippets + persisted metadata)
// ══════════════════════════════════════════════════════════════════

class _CatSection {
  final String name;
  final List<Snippet> snippets;
  final SnippetCategory? meta;
  final bool isUncategorized;

  const _CatSection({
    required this.name,
    required this.snippets,
    required this.meta,
    required this.isUncategorized,
  });

  bool get hidden => meta?.hidden ?? false;

  /// A "built-in" group holds at least one seeded default snippet (System,
  /// Docker, Network, …). These can be hidden/recolored but not deleted, since
  /// deleting can't remove the seeded commands and they'd just reappear.
  bool get isBuiltIn => snippets.any((s) => s.isDefault);
}

/// The accent color for a category header: the user's picked color when set,
/// otherwise the name-based default (docker=blue, network=green, …), so an
/// unpicked category still reads the way it always did.
Color categoryAccent(String name, SnippetCategory? meta) {
  // A custom colorValue (ARGB) wins over the palette index / name default.
  final value = meta?.colorValue;
  if (value != null) return Color(value);
  final idx = meta?.colorIndex;
  if (idx != null && idx >= 0) {
    return AppColors.labelPalette[idx % AppColors.labelPalette.length];
  }
  return _tagColor(name);
}

// ══════════════════════════════════════════════════════════════════
// Toolbar - ephemeral Sort control + Arrange slide-in launcher
// ══════════════════════════════════════════════════════════════════

class _Toolbar extends StatelessWidget {
  final SnippetSortMode sortMode;
  final ValueChanged<SnippetSortMode> onSortChanged;
  final VoidCallback onArrange;

  const _Toolbar({
    required this.sortMode,
    required this.onSortChanged,
    required this.onArrange,
  });

  static String _sortLabel(AppLocalizations l10n, SnippetSortMode mode) {
    return switch (mode) {
      // "Arranged (manual)" makes the relationship with the Arrange action
      // (which lives in this same menu) explicit.
      SnippetSortMode.arranged => l10n.snippetPageSortYourOrder,
      SnippetSortMode.nameAsc => l10n.snippetsSortNameAsc,
      SnippetSortMode.nameDesc => l10n.snippetsSortNameDesc,
      SnippetSortMode.recentlyUpdated => l10n.snippetsSortRecent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // ONE control: the sort dropdown. Its options are the sort modes plus,
    // below a divider, "Arrange categories…" - the action that manages the
    // manual order/color/visibility that "Arranged (manual)" then sorts by.
    // (Formerly a Sort chip and a separate Arrange chip at opposite ends of
    // the row, with a stuck "Sort" tooltip on the popup button.) No Align
    // around it: in the header's Wrap an Align took the whole line.
    return PopupMenuButton<Object>(
      // Empty tooltip: the popup button's own Tooltip could get stuck open
      // over the just-opened menu. The chip is self-describing anyway.
      tooltip: '',
      onSelected: (value) {
        if (value is SnippetSortMode) {
          onSortChanged(value);
        } else {
          onArrange();
        }
      },
      color: AppColors.v3Elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.v3BorderDefault, width: 0.5),
      ),
      itemBuilder: (context) => [
        for (final mode in SnippetSortMode.values)
          PopupMenuItem<Object>(
            value: mode,
            height: 36,
            child: Row(
              children: [
                Icon(
                  LucideIcons.check,
                  size: 14,
                  color: mode == sortMode
                      ? AppColors.v3AccentInk
                      : Colors.transparent,
                ),
                const SizedBox(width: 8),
                Text(
                  _sortLabel(l10n, mode),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: _kArrangeMenuValue,
          height: 36,
          child: Row(
            children: [
              Icon(
                LucideIcons.arrowUpDown,
                size: 14,
                color: AppColors.v3TextSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.zestSnippetsSortArrangeItem,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.v3TextPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
      child: _ToolbarChip(
        key: const ValueKey('snippets-sort'),
        icon: LucideIcons.arrowUpDown,
        label: _sortLabel(l10n, sortMode),
      ),
    );
  }
}

/// Sentinel [PopupMenuItem] value for the Arrange action inside the merged Sort
/// menu - distinguished from the [SnippetSortMode] values by type.
const String _kArrangeMenuValue = '__arrange__';

class _ToolbarChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ToolbarChip({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.v3TextSecondary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: AppColors.v3TextPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Icon(LucideIcons.chevronDown, size: 13, color: AppColors.v3TextTertiary),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Search / filter field
// ══════════════════════════════════════════════════════════════════

class _SearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasContent;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.hasContent,
    required this.onChanged,
  });

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  @override
  Widget build(BuildContext context) {
    // The one list-pane search field of the app.
    return ZestListSearchField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      hintText: AppLocalizations.of(context)!.snippetPageFilterHint,
      onChanged: widget.onChanged,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Grouped category list with snippet cards
// ══════════════════════════════════════════════════════════════════

class _SnippetCategoryList extends StatelessWidget {
  /// Cards (the earlier look) rather than rows.
  final bool grid;
  final List<_CatSection> sections;
  final String selectedId;

  /// The snippets are being selected (3.4): each has its box; [checked] are
  /// the selected ones.
  final bool selecting;
  final Set<String> checked;
  final int totalHidden;
  final bool showHidden;
  final bool searching;
  final VoidCallback onToggleShowHidden;
  final ValueChanged<Snippet> onCardTap;
  final ValueChanged<Snippet> onRun;
  final ValueChanged<Snippet> onCopy;
  final ValueChanged<Snippet> onEdit;
  final ValueChanged<Snippet> onDuplicate;
  final ValueChanged<Snippet> onDelete;
  final ValueChanged<_CatSection> onToggleCategoryHidden;
  final ValueChanged<_CatSection> onEditCategory;
  final ValueChanged<_CatSection> onDeleteCategory;

  const _SnippetCategoryList({
    required this.grid,
    required this.sections,
    required this.selectedId,
    this.selecting = false,
    this.checked = const {},
    required this.totalHidden,
    required this.showHidden,
    required this.searching,
    required this.onToggleShowHidden,
    required this.onCardTap,
    required this.onRun,
    required this.onCopy,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
    required this.onToggleCategoryHidden,
    required this.onEditCategory,
    required this.onDeleteCategory,
  });

  @override
  Widget build(BuildContext context) {
    // A CustomScrollView so each category header can PIN to the top while its
    // own cards scroll under it (SliverPersistentHeader with pinned:true). The
    // previous flat ListView scrolled the headers away with the content.
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        for (final section in sections) ...[
          SliverPersistentHeader(
            pinned: true,
            delegate: _StickyCategoryHeaderDelegate(
              section: section,
              onToggleHidden: () => onToggleCategoryHidden(section),
              onEdit: () => onEditCategory(section),
              onDelete: () => onDeleteCategory(section),
            ),
          ),
          if (!grid)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 16, 20),
              sliver: SliverList.builder(
                itemCount: section.snippets.length,
                itemBuilder: (context, i) {
                  final s = section.snippets[i];
                  return _SnippetRow(
                    key: ValueKey('snippet-row-widget-${s.id}'),
                    snippet: s,
                    selected: selecting ? checked.contains(s.id) : s.id == selectedId,
                    selecting: selecting,
                    onTap: () => onCardTap(s),
                    onCopy: () => onCopy(s),
                    onEdit: () => onEdit(s),
                    onDuplicate: () => onDuplicate(s),
                    onRunOn: () => onRun(s),
                    onDelete: () => onDelete(s),
                  );
                },
              ),
            ),
          if (grid)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            sliver: SliverToBoxAdapter(
              child: _SnippetCardGrid(
                snippets: section.snippets,
                selectedId: selectedId,
                selecting: selecting,
                checked: checked,
                onCardTap: onCardTap,
                onRun: onRun,
                onCopy: onCopy,
                onEdit: onEdit,
                onDuplicate: onDuplicate,
                onDelete: onDelete,
              ),
            ),
          ),
        ],
        // "Show hidden (N)" affordance - recoverability for collapsed
        // categories. Suppressed while narrowing (hidden are force-shown).
        if (totalHidden > 0 && !searching)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: _ShowHiddenToggle(
                count: totalHidden,
                showing: showHidden,
                onTap: onToggleShowHidden,
              ),
            ),
          ),
        // Room for the selection's bar under the last snippet.
        if (selecting) const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }
}

// ── Sticky (pinned) category header delegate ─────────────────────

/// Pins a category header to the top of the scroll view while its section's
/// cards scroll beneath it. Fixed extent + an opaque [ZestTokens.surfaceBase]
/// background so cards passing under are fully occluded. Hosts a
/// [_CategoryHeader], so hover icons + the right-click menu behave identically
/// whether pinned or not.
class _StickyCategoryHeaderDelegate extends SliverPersistentHeaderDelegate {
  final _CatSection section;
  final VoidCallback onToggleHidden;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _StickyCategoryHeaderDelegate({
    required this.section,
    required this.onToggleHidden,
    required this.onEdit,
    required this.onDelete,
  });

  static const double _extent = 46;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: ZestTokens.surfaceBase,
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 0),
      alignment: Alignment.topLeft,
      child: _CategoryHeader(
        section: section,
        onToggleHidden: onToggleHidden,
        onEdit: onEdit,
        onDelete: onDelete,
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyCategoryHeaderDelegate oldDelegate) {
    // Sections + callbacks are rebuilt each parent build, so rebuild the header
    // too - correctness (fresh hidden/color/count) over micro-optimisation.
    return true;
  }
}

// ── Category header (shared divider + eye/edit + right-click menu) ─────

/// A snippet-category divider. Its dot + label + count + hairline are the
/// shared [ZestSectionHeader.category] primitive; this widget wraps that with
/// the category-management interaction the primitive can't hold on its own -
/// hover-revealed edit/eye buttons, a hidden badge, and a right-click menu.
class _CategoryHeader extends StatefulWidget {
  final _CatSection section;
  final VoidCallback onToggleHidden;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CategoryHeader({
    required this.section,
    required this.onToggleHidden,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_CategoryHeader> createState() => _CategoryHeaderState();
}

class _CategoryHeaderState extends State<_CategoryHeader> {
  bool _hovering = false;

  /// Right-click menu for a group header: Edit (rename/color) and Delete only
  /// for custom groups; Hide/Show for every group. Mirrors the hover icons but
  /// adds Delete, which has no hover affordance.
  void _showHeaderMenu(Offset position) {
    final l10n = AppLocalizations.of(context)!;
    final section = widget.section;
    final hidden = section.hidden;
    final canEdit = !section.isUncategorized;
    final canDelete = !section.isUncategorized && !section.isBuiltIn;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      items: [
        if (canEdit)
          PopupMenuItem(
            value: 'edit',
            child: _ContextMenuItem(
              icon: LucideIcons.pencil,
              label: l10n.snippetsEditCategory,
            ),
          ),
        PopupMenuItem(
          value: 'hide',
          child: _ContextMenuItem(
            icon: hidden ? LucideIcons.eye : LucideIcons.eyeOff,
            label: hidden
                ? l10n.snippetsShowCategory
                : l10n.snippetsHideCategory,
          ),
        ),
        if (canDelete) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            child: _ContextMenuItem(
              icon: LucideIcons.trash2,
              label: l10n.zestSnippetsDeleteCategory,
              isDestructive: true,
            ),
          ),
        ],
      ],
    ).then((value) {
      if (value == null || !mounted) return;
      switch (value) {
        case 'edit':
          widget.onEdit();
        case 'hide':
          widget.onToggleHidden();
        case 'delete':
          widget.onDelete();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final section = widget.section;
    final color = categoryAccent(section.name, section.meta);
    final hidden = section.hidden;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (details) => _showHeaderMenu(details.globalPosition),
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context) ? (details) => _showHeaderMenu(details.globalPosition) : null,
        child: ZestSectionHeader.category(
          label: section.name,
          dot: color,
          count: section.snippets.length,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hidden) ...[
                _HiddenBadge(label: l10n.snippetsCategoryHidden),
                const SizedBox(width: 8),
              ],
              // Edit (rename + color) - not for the synthetic Uncategorized.
              if (!section.isUncategorized)
                _HeaderIconButton(
                  icon: LucideIcons.pencil,
                  tooltip: l10n.snippetsEditCategory,
                  visible: _hovering,
                  onTap: widget.onEdit,
                ),
              // Eye (hide/show) - always available, incl. Uncategorized.
              _HeaderIconButton(
                icon: hidden ? LucideIcons.eyeOff : LucideIcons.eye,
                tooltip: hidden
                    ? l10n.snippetsShowCategory
                    : l10n.snippetsHideCategory,
                visible: _hovering || hidden,
                onTap: widget.onToggleHidden,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Snippet-screen options overflow. Hosts "Press Enter after pasting a snippet"
/// (auto-execute), which moved here from Settings > Automation (spec 4): it is
/// snippet behaviour, filed under Automation before only because of the word.
class _SnippetOptionsButton extends ConsumerWidget {
  const _SnippetOptionsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final autoExec = ref.watch(autoExecuteSnippetsProvider);
    return PopupMenuButton<String>(
      icon: Icon(LucideIcons.settings2,
          size: 18, color: AppColors.v3TextSecondary),
      tooltip: l10n.snippetsAutoExecute,
      onSelected: (v) {
        if (v == 'autoexec') {
          ref.read(settingsUpdaterProvider).setAutoExecuteSnippets(!autoExec);
        }
      },
      itemBuilder: (ctx) => [
        CheckedPopupMenuItem<String>(
          value: 'autoexec',
          checked: autoExec,
          child: Text(l10n.snippetsAutoExecute),
        ),
      ],
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool visible;
  final VoidCallback onTap;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.visible,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: visible ? 1 : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(icon, size: 14, color: AppColors.v3TextSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _HiddenBadge extends StatelessWidget {
  final String label;
  const _HiddenBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.v3TextTertiary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppColors.v3TextTertiary,
        ),
      ),
    );
  }
}

class _ShowHiddenToggle extends StatelessWidget {
  final int count;
  final bool showing;
  final VoidCallback onTap;

  const _ShowHiddenToggle({
    required this.count,
    required this.showing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                showing ? LucideIcons.eyeOff : LucideIcons.eye,
                size: 14,
                color: AppColors.v3TextSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                showing
                    ? l10n.snippetsHideHidden
                    : l10n.snippetsShowHiddenCount(count),
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.v3TextSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Responsive card grid ─────────────────────────────────────────

class _SnippetCardGrid extends StatelessWidget {
  final List<Snippet> snippets;
  final String selectedId;
  final bool selecting;
  final Set<String> checked;
  final ValueChanged<Snippet> onCardTap;
  final ValueChanged<Snippet> onRun;
  final ValueChanged<Snippet> onCopy;
  final ValueChanged<Snippet> onEdit;
  final ValueChanged<Snippet> onDuplicate;
  final ValueChanged<Snippet> onDelete;

  const _SnippetCardGrid({
    required this.snippets,
    required this.selectedId,
    this.selecting = false,
    this.checked = const {},
    required this.onCardTap,
    required this.onRun,
    required this.onCopy,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Self-measure the (already-padded) content width so the grid works inside
    // a sliver adapter. Cards FLEX to fill: derive a column count from the
    // width, then divide the remaining space evenly with NO upper cap, so a row
    // always fills edge-to-edge (no dead gutter against the right edge).
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 300).floor().clamp(1, 6);
        final cardWidth =
            ((constraints.maxWidth - (columns - 1) * 10) / columns)
                .clamp(240.0, double.infinity);
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.start,
          children: snippets.map((snippet) {
            return SizedBox(
              width: cardWidth,
              child: _SnippetCard(
                snippet: snippet,
                selected: selecting ? checked.contains(snippet.id) : snippet.id == selectedId,
                selecting: selecting,
                onTap: () => onCardTap(snippet),
                onRun: () => onRun(snippet),
                onCopy: () => onCopy(snippet),
                onEdit: () => onEdit(snippet),
                onDuplicate: () => onDuplicate(snippet),
                onDelete: () => onDelete(snippet),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Snippet card - ~260-320x90 with hover overflow menu
// ══════════════════════════════════════════════════════════════════

// Card keyboard intents. Enter runs, Ctrl/Cmd+C copies, Ctrl/Cmd+E edits;
// arrow keys move focus between cards via Flutter's default directional
// focus traversal (no custom handling needed).
class _RunSnippetIntent extends Intent {
  const _RunSnippetIntent();
}

class _CopySnippetIntent extends Intent {
  const _CopySnippetIntent();
}

class _EditSnippetIntent extends Intent {
  const _EditSnippetIntent();
}

class _SnippetCard extends ConsumerStatefulWidget {
  final Snippet snippet;

  /// Open beside the list, or (while [selecting]) selected.
  final bool selected;

  /// The snippets are being selected: the card's box before its name.
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onRun;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  const _SnippetCard({
    required this.snippet,
    required this.selected,
    this.selecting = false,
    required this.onTap,
    required this.onRun,
    required this.onCopy,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  @override
  ConsumerState<_SnippetCard> createState() => _SnippetCardState();
}

class _SnippetCardState extends ConsumerState<_SnippetCard> {
  bool _hovering = false;
  bool _focused = false;

  /// True while the card's menu is open. The menu covers the card, so the
  /// mouse is no longer over it: without this the three dots would leave
  /// while their own menu is open.
  bool _menuOpen = false;

  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): _RunSnippetIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): _RunSnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, control: true):
        _CopySnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, meta: true): _CopySnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyE, control: true):
        _EditSnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyE, meta: true): _EditSnippetIntent(),
  };

  /// Number of `${...}` / `$[...]` placeholders in the command.
  int get _varCount => parseVariablesWithOptions(widget.snippet.command).length;

  bool get _confirm => widget.snippet.confirmBeforeRun;

  /// Count of saved workflows that reference this snippet by name (a snippet
  /// step matches by [WorkflowStep.snippetName]). Drives the "in N workflows"
  /// title chip - the same match the detail editor uses.
  int _workflowCount() {
    final label = widget.snippet.label;
    if (label.isEmpty) return 0;
    return ref
        .watch(workflowsProvider)
        .where((w) => w.steps.any((s) =>
            s.type == WorkflowStepType.snippet && s.snippetName == label))
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showActions = _hovering || _focused || _menuOpen;
    final selected = widget.selected;
    final varCount = _varCount;
    // Device-local usage (run count + last-run stamp) - rebuilds live after a
    // run is recorded. Always shown in the bottom row: "Run N times · Xago", or
    // "Never run" when the count is zero.
    final usage = ref.watch(snippetUsageProvider)[widget.snippet.id];
    final runCount = usage?.runCount ?? 0;
    final usageText = runCount > 0
        ? l10n.zestSnippetsCardRunUsage(
            runCount,
            _snippetRelativeRun(usage!.lastRunAt, l10n),
          )
        : l10n.zestSnippetsCardNeverRun;
    final workflowCount = _workflowCount();
    // Category chip (bottom row, left of the variable badge): the card carries
    // its own category so the flat search / sort / manual-arrange views - which
    // drop the section header - still show which group a snippet belongs to.
    // Hidden for uncategorized snippets (null/empty category).
    final category = widget.snippet.category;
    final showCategory = category != null && category.isNotEmpty;
    final categoryColor = category != null && category.isNotEmpty
        ? categoryAccent(
            category,
            ref.watch(snippetCategoryMetaMapProvider)[category],
          )
        : null;
    return FocusableActionDetector(
      shortcuts: _shortcuts,
      actions: {
        _RunSnippetIntent: CallbackAction<_RunSnippetIntent>(
          onInvoke: (_) {
            widget.onRun();
            return null;
          },
        ),
        _CopySnippetIntent: CallbackAction<_CopySnippetIntent>(
          onInvoke: (_) {
            widget.onCopy();
            return null;
          },
        ),
        _EditSnippetIntent: CallbackAction<_EditSnippetIntent>(
          onInvoke: (_) {
            widget.onEdit();
            return null;
          },
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (h) => setState(() => _hovering = h),
      onShowFocusHighlight: (f) => setState(() => _focused = f),
      child: GestureDetector(
        onTap: widget.onTap,
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context)
            ? (details) => _openMenu(RelativeRect.fromLTRB(details.globalPosition.dx, details.globalPosition.dy,
                details.globalPosition.dx + 1, details.globalPosition.dy + 1))
            : null,
        onSecondaryTapUp: (details) => _openMenu(
          RelativeRect.fromLTRB(
            details.globalPosition.dx,
            details.globalPosition.dy,
            details.globalPosition.dx + 1,
            details.globalPosition.dy + 1,
          ),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          // Uniform 3-row card: title(+markers) / mono command / bottom row
          // (variable + confirm pills, then the usage line). A fixed height so
          // the grid reads as an even matrix; the command bar flexes to fill
          // whatever the title and bottom rows leave.
          height: 116,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.06)
                : AppColors.v3Surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected || _focused
                  ? AppColors.v3AccentPrimary
                  : _hovering
                  ? AppColors.v3BorderStrong
                  : AppColors.v3BorderDefault,
              width: selected || _focused ? 1.5 : 1,
            ),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Row 1: title + workflow chip + confirm marker ──
                  Row(
                    children: [
                      if (widget.selecting) ...[
                        SelectBox(key: ValueKey('snippet-card-box-${widget.snippet.id}'), checked: selected, size: 16),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        // Recording mode: a label or command can embed a
                        // host or `user@host`, so both go through the
                        // free-text scan like every other piece of chrome.
                        child: RedactedText(
                          Redactable.freeText(widget.snippet.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.v3TextPrimary,
                            fontFamily: 'GeistSans',
                          ),
                        ),
                      ),
                      if (workflowCount > 0) ...[
                        const SizedBox(width: 6),
                        _WorkflowsChip(
                          label: l10n.zestSnippetsCardInWorkflows(workflowCount),
                        ),
                      ],
                      // The braces "has variables" glyph is dropped - the
                      // amber variable pill in the bottom row carries that
                      // signal now. Only the confirm shield stays up top.
                      if (_confirm)
                        _CardMarker(
                          icon: LucideIcons.shieldAlert,
                          color: kSnippetConfirmColor,
                          tooltip: l10n.zestSnippetsConfirmMarkerTooltip,
                        ),
                      // Reserve room for the hover overflow menu so markers
                      // never sit under it.
                      if (showActions) const SizedBox(width: 20),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // ── Row 2: mono command preview (variable-tinted) ──
                  Expanded(
                    // Full command on hover - the two-line preview truncates
                    // long commands, so the tooltip is the escape hatch.
                    child: Tooltip(
                      message: Redactable.freeText(widget.snippet.command)
                          .displayIn(ref),
                      waitDuration: const Duration(milliseconds: 500),
                      child: Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 2),
                        // A touch more vertical padding so glyph descenders on
                        // the second line aren't clipped by the bar's edge.
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.v3Background,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text.rich(
                          TextSpan(
                            children: buildSnippetCommandSpans(
                              Redactable.freeText(widget.snippet.command)
                                  .displayIn(ref),
                              baseStyle: TextStyle(
                                fontSize: 12,
                                height: 1.3,
                                fontFamily: 'JetBrainsMono',
                                color: AppColors.v3TextSecondary,
                              ),
                            ),
                          ),
                          // Two lines (wrapping) before truncating, so the
                          // "interesting" tail of a long command still shows;
                          // the full command is on the wrapping Tooltip.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  // ── Row 3: category chip, variable + confirm pills, usage ──
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        if (showCategory) ...[
                          Flexible(
                            child: _CategoryChip(
                              label: category,
                              color: categoryColor!,
                            ),
                          ),
                          const SizedBox(width: 7),
                        ],
                        if (varCount > 0) ...[
                          _SnippetTintPill(
                            label: l10n.zestSnippetsCardVariableCount(varCount),
                            fg: kSnippetVarColor,
                            bg: kSnippetVarBg,
                          ),
                          const SizedBox(width: 7),
                        ],
                        if (_confirm) ...[
                          _SnippetTintPill(
                            label: l10n.zestSnippetsCardConfirmsFirst,
                            fg: kSnippetConfirmColor,
                            bg: kSnippetConfirmBg,
                          ),
                          const SizedBox(width: 7),
                        ],
                        Expanded(
                          child: Text(
                            usageText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.v3TextTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (showActions)
                Positioned(
                  top: -4,
                  right: -4,
                  child: MenuDotsButton(
                    tooltip: l10n.zestCommonMoreActions,
                    onOpen: _openMenu,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The card's one menu, at [position]: from a right click and from the
  /// three dots. The card opens it and acts on what was picked, because the
  /// card is still here when the menu closes and the three dots may not be.
  Future<void> _openMenu(RelativeRect position) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _menuOpen = true);
    final value = await showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      // Its default host, while it still exists, is where Run goes, and the
      // item says so; without one, Run on… asks.
      items: _snippetCardMenuItems(
        l10n,
        transfer: transferOffer(ref, TransferKinds.snippet, [widget.snippet.id]),
        defaultHost: () {
          final host = defaultHostOf(
              ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [], widget.snippet.metadata);
          return host == null ? null : Redactable.host(host.connection.label).displayIn(ref);
        }(),
      ),
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    if (value == null) return;
    if (value == 'run-hosts') {
      unawaited(showRunOnHosts(context, snippet: widget.snippet));
      return;
    }
    if (value == 'move_to' || value == 'copy_to') {
      unawaited(showMoveCopyDialog(context, ref,
          kind: TransferKinds.snippet,
          keys: [widget.snippet.id],
          mode: value == 'move_to' ? TransferMode.move : TransferMode.copy));
      return;
    }
    _dispatchSnippetCardAction(
      value,
      onEdit: widget.onEdit,
      onCopy: widget.onCopy,
      onDuplicate: widget.onDuplicate,
      onRun: widget.onRun,
      onDelete: widget.onDelete,
    );
  }
}

// ── Shared snippet-card menu (right-click AND 3-dot use the exact same one) ──

/// The single menu shown by BOTH a snippet card's right-click context menu and
/// its 3-dot overflow button, opened by the card either way.
List<PopupMenuEntry<String>> _snippetCardMenuItems(AppLocalizations l10n,
        {String? defaultHost, ({bool move, bool copy}) transfer = (move: false, copy: false)}) => [
  PopupMenuItem(
    value: 'edit',
    child: _ContextMenuItem(
      icon: LucideIcons.pencil,
      label: l10n.zestSnippetsEdit,
    ),
  ),
  PopupMenuItem(
    value: 'copy',
    child: _ContextMenuItem(
      icon: LucideIcons.clipboard,
      label: l10n.zestSnippetsCopy,
    ),
  ),
  PopupMenuItem(
    value: 'duplicate',
    child: _ContextMenuItem(
      icon: LucideIcons.copy,
      label: l10n.zestSnippetsDuplicate,
    ),
  ),
  // Move to... and Copy to...: Personal, or a team's vault (3.4).
  if (transfer.move)
    PopupMenuItem(
      value: 'move_to',
      child: _ContextMenuItem(icon: LucideIcons.folderInput, label: l10n.transferMoveTo),
    ),
  if (transfer.copy)
    PopupMenuItem(
      value: 'copy_to',
      child: _ContextMenuItem(icon: LucideIcons.copyPlus, label: l10n.transferCopyTo),
    ),
  PopupMenuItem(
    value: 'run',
    child: _ContextMenuItem(
      icon: LucideIcons.play,
      label: defaultHost == null ? l10n.zestSnippetsRunOn : l10n.docCheckSnippetRunOnHost(defaultHost),
    ),
  ),
  // On many hosts at once, each with its result (3.0, Run on hosts).
  PopupMenuItem(
    value: 'run-hosts',
    child: _ContextMenuItem(
      icon: LucideIcons.listChecks,
      label: l10n.runOnHostsMenu,
    ),
  ),
  const PopupMenuDivider(),
  PopupMenuItem(
    value: 'delete',
    child: _ContextMenuItem(
      icon: LucideIcons.trash2,
      label: l10n.zestSnippetsDelete,
      isDestructive: true,
    ),
  ),
];

/// Route a shared-menu selection to the matching card callback.
void _dispatchSnippetCardAction(
  String value, {
  required VoidCallback onEdit,
  required VoidCallback onCopy,
  required VoidCallback onDuplicate,
  required VoidCallback onRun,
  required VoidCallback onDelete,
}) {
  switch (value) {
    case 'edit':
      onEdit();
    case 'copy':
      onCopy();
    case 'duplicate':
      onDuplicate();
    case 'run':
      onRun();
    case 'delete':
      onDelete();
  }
}

// ── Card marker glyph (row 1) + meta badge (row 3) ──────────────

/// [_snippetRelativeRun], for the snippet's details beside the list.
String snippetRelativeRun(DateTime dt, AppLocalizations l10n) => _snippetRelativeRun(dt, l10n);

/// When a snippet last ran, after a dot on its card ("Run 3 times · 5m ago")
/// and in "last run {when}" beside the list: the shared compact words begun
/// small as words that follow others, the seconds from ten, just now before
/// that, and past a week weeks then
/// months.
String _snippetRelativeRun(DateTime dt, AppLocalizations l10n) =>
    timeAgoInSentence(l10n, dt, seconds: true, keepCounting: true);

/// A small marker glyph shown in a snippet card's title row - the shield for
/// "confirm before run". Purely a signal; the labelled counterpart lives in the
/// bottom row as a [_SnippetTintPill].
class _CardMarker extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;

  const _CardMarker({
    required this.icon,
    required this.color,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Icon(icon, size: 13, color: color.withValues(alpha: 0.85)),
      ),
    );
  }
}

/// A compact text-only pill for a snippet card's bottom row - the amber
/// "N variables" and orange "Confirms first" markers. A solid [bg] with [fg]
/// text, no leading glyph.
class _SnippetTintPill extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;

  const _SnippetTintPill({
    required this.label,
    required this.fg,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }
}

/// Neutral "in N workflows" chip shown in a snippet card's title row when the
/// snippet is referenced by one or more automation workflows.
class _WorkflowsChip extends StatelessWidget {
  final String label;

  const _WorkflowsChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.v3Elevated,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: AppColors.v3TextSecondary,
        ),
      ),
    );
  }
}

/// Category chip shown in a snippet card's bottom row (left of the variable
/// badge). A category-accent dot + the group name on the neutral elevated
/// surface, so a card reads its own group even in the flat views that drop the
/// section header. Only rendered for snippets that HAVE a category.
class _CategoryChip extends StatelessWidget {
  final String label;
  final Color color;

  const _CategoryChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.v3Elevated,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          // Flexible + a soft cap so a long group name ellipsizes instead of
          // overflowing the crowded (category + variable + confirm) bottom row.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 84),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.v3TextSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tag chip (color-coded by category) ──────────────────────────

/// Per-category accent hue used ONLY for the small category dot (section
/// headers, tag chip). Deliberately keeps brand orange (`#FF7A1A`) OUT of the
/// vocabulary - the old `packages` orange competed with the brand accent /
/// primary buttons - so `packages` maps to indigo instead. Brand orange now
/// reads unambiguously as "primary action", never "category".
Color _tagColor(String tag) {
  final t = tag.toLowerCase().replaceAll('#', '');
  return switch (t) {
    'docker' => const Color(0xFF2496ED),
    'network' => const Color(0xFF10B981),
    'files' => const Color(0xFFA855F7),
    'packages' => const Color(0xFF6366F1), // was brand orange - de-clashed
    'security' => const Color(0xFFEF4444),
    'system' => const Color(0xFF14B8A6),
    'monitoring' => const Color(0xFFF59E0B),
    'git' => const Color(0xFFF05033),
    'kubernetes' => const Color(0xFF326CE5),
    'log' || 'logs' => const Color(0xFF8D8B83),
    _ => const Color(0xFF8B93A1),
  };
}

// ══════════════════════════════════════════════════════════════════
// Context menu item (reusable for popup menus)
// ══════════════════════════════════════════════════════════════════

class _ContextMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isDestructive;

  const _ContextMenuItem({
    required this.icon,
    required this.label,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? AppColors.v3Error : AppColors.v3TextPrimary;
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 13, color: color)),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Empty states
// ══════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  final VoidCallback? onCreateFirst;

  const _EmptyState({required this.onCreateFirst});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.code2,
      title: l10n.snippetsNone,
      message: l10n.snippetsEmptyMessage,
      actionLabel: onCreateFirst == null ? null : l10n.zestSnippetsNewLabel,
      onAction: onCreateFirst,
    );
  }
}

/// TIER 2 empty state: the library has snippets but the active search / filter
/// matched none. One short italic line with an inline (non-orange) "Clear
/// search" action. The search field and filter chips stay visible above, so
/// this is a section-empty row, NOT a full-pane tier-1 block.
class _FilterEmptyState extends StatelessWidget {
  final VoidCallback onClear;

  const _FilterEmptyState({required this.onClear});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: ZestEmptyRow(
          message: l10n.snippetsNoMatchingSnippets,
          action: ZestButton(
            label: l10n.emptyClearSearch,
            icon: LucideIcons.x,
            variant: ZestButtonVariant.ghost,
            size: ZestButtonSize.medium,
            onPressed: onClear,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Category editor dialog - rename + color (mirrors folder_edit_dialog)
// ══════════════════════════════════════════════════════════════════

/// Show the small category editor: rename (rewrites every snippet in the
/// category AND moves the metadata row atomically) + accent color picker.
Future<void> showSnippetCategoryEditor({
  required BuildContext context,
  required String name,
  required SnippetCategory? meta,
}) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    child: _CategoryEditorDialog(name: name, meta: meta),
  );
}

class _CategoryEditorDialog extends ConsumerStatefulWidget {
  final String name;
  final SnippetCategory? meta;

  const _CategoryEditorDialog({required this.name, required this.meta});

  @override
  ConsumerState<_CategoryEditorDialog> createState() =>
      _CategoryEditorDialogState();
}

class _CategoryEditorDialogState extends ConsumerState<_CategoryEditorDialog> {
  late final TextEditingController _nameController;
  int? _colorIndex;

  /// Custom accent (ARGB int). Non-null OVERRIDES [_colorIndex]. Null falls back
  /// to the index / name-default colour.
  int? _colorValue;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    _colorIndex = widget.meta?.colorIndex;
    _colorValue = widget.meta?.colorValue;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Concrete accent to preview/seed the picker: custom wins, else the picked
  /// index, else the brand accent as a neutral placeholder for "default".
  Color get _resolvedColor => _colorValue != null
      ? Color(_colorValue!)
      : (_colorIndex != null
          ? AppColors
              .labelPalette[_colorIndex! % AppColors.labelPalette.length]
          : AppColors.v3AccentPrimary);

  Future<void> _save() async {
    final crud = ref.read(snippetCategoryCrudProvider);
    final newName = _nameController.text.trim();
    // Rename first (moves any existing metadata row), then set color on the
    // resulting target name (upserts the row if the rename created none).
    if (newName.isNotEmpty && newName != widget.name) {
      await crud.renameCategory(widget.name, newName);
    }
    final target = newName.isNotEmpty ? newName : widget.name;
    await crud.setColor(target, _colorIndex, colorValue: _colorValue);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.folder,
      title: l10n.snippetsCategoryEditorTitle,
      maxWidth: 460,
      maxHeight: 420,
      secondaryAction: (
        label: l10n.cancel,
        onPressed: () => Navigator.of(context).pop(),
      ),
      primaryAction: (label: l10n.save, icon: null, onPressed: _save),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ZestTextField(
            controller: _nameController,
            label: l10n.snippetsCategoryNameLabel,
            onSubmit: _save,
          ),
          const SizedBox(height: 20),
          ZestSectionHeader(label: l10n.snippetsCategoryColorLabel),
          const SizedBox(height: 10),
          ZestColorPicker(
            presets: AppColors.labelPalette,
            // Allow ANY custom colour - persisted as colorValue (ARGB).
            allowCustom: true,
            selected: _resolvedColor,
            onChanged: (c) {
              setState(() {
                // A preset match persists as the index (clears any custom
                // value); anything else persists as a custom colour.
                final i = AppColors.labelPalette.indexOf(c);
                if (i >= 0) {
                  _colorIndex = i;
                  _colorValue = null;
                } else {
                  _colorValue = c.toARGB32();
                }
              });
            },
          ),
          const SizedBox(height: 10),
          // Reset to the name-derived default (clears index + custom).
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() {
                _colorIndex = null;
                _colorValue = null;
              }),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: (_colorIndex == null && _colorValue == null)
                      ? AppColors.v3Elevated
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: (_colorIndex == null && _colorValue == null)
                        ? AppColors.v3TextPrimary
                        : AppColors.v3BorderSubtle,
                    width: (_colorIndex == null && _colorValue == null)
                        ? 1.5
                        : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.eyeOff,
                        size: 15, color: AppColors.v3TextSecondary),
                    const SizedBox(width: 7),
                    Text(
                      l10n.folderColorDefault,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.v3TextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Arrange slide-in - drag to reorder + eye + color, all persisted
// ══════════════════════════════════════════════════════════════════

/// Slide a right-docked panel in that lists every category as a draggable
/// row. Dragging persists the order (`SnippetCategories.sortOrder`); each row
/// also carries the eye toggle + color swatch, so it doubles as the
/// manage-groups surface. Order + eye + color all persist and sync.
Future<void> showSnippetArrangePanel(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: l10n.snippetsLibraryDismiss,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, _, _) =>
        const Align(alignment: Alignment.centerRight, child: _ArrangePanel()),
    transitionBuilder: (context, animation, _, child) {
      final slide = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
          );
      return SlideTransition(position: slide, child: child);
    },
  );
}

class _ArrangePanel extends ConsumerWidget {
  const _ArrangePanel();

  /// The categories to arrange: the union of categories present on snippets
  /// and categories that already have a metadata row, ordered by the saved
  /// arrange order (rowed first by sortOrder, unrowed after alphabetically).
  /// Excludes the synthetic "Uncategorized" grouping.
  List<String> _resolveOrder(
    List<Snippet> snippets,
    Map<String, SnippetCategory> metaMap,
  ) {
    final names = <String>{};
    for (final s in snippets) {
      if (s.category != null && s.category!.isNotEmpty) names.add(s.category!);
    }
    names.addAll(metaMap.keys.where((k) => k != _kUncategorized));
    final list = names.toList()
      ..sort((a, b) {
        final ao = metaMap[a]?.sortOrder;
        final bo = metaMap[b]?.sortOrder;
        if (ao != null && bo != null) {
          final c = ao.compareTo(bo);
          return c != 0 ? c : a.toLowerCase().compareTo(b.toLowerCase());
        }
        if (ao != null) return -1;
        if (bo != null) return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return list;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final snippets =
        ref.watch(snippetsProvider).valueOrNull ?? const <Snippet>[];
    final metaMap = ref.watch(snippetCategoryMetaMapProvider);
    final order = _resolveOrder(snippets, metaMap);

    return Material(
      color: AppColors.v3Surface,
      child: SizedBox(
        width: 360,
        height: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: AppColors.v3BorderSubtle)),
          ),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.snippetsArrangeCategoriesTitle,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppColors.v3TextPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.snippetsArrangeCategoriesSubtitle,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: AppColors.v3TextTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: AppLocalizations.of(context)!.close,
                        icon: const Icon(LucideIcons.x, size: 18),
                        color: AppColors.v3TextSecondary,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: AppColors.v3BorderSubtle),
                Expanded(
                  child: order.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l10n.snippetsArrangeEmpty,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: AppColors.v3TextTertiary,
                              ),
                            ),
                          ),
                        )
                      : ReorderableListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          buildDefaultDragHandles: false,
                          itemCount: order.length,
                          itemBuilder: (context, index) {
                            final name = order[index];
                            return _ArrangeRow(
                              key: ValueKey(name),
                              index: index,
                              name: name,
                              meta: metaMap[name],
                            );
                          },
                          onReorderItem: (oldIndex, newIndex) {
                            final next = [...order];
                            final item = next.removeAt(oldIndex);
                            next.insert(newIndex, item);
                            ref
                                .read(snippetCategoryCrudProvider)
                                .updateOrder(next);
                          },
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

class _ArrangeRow extends ConsumerWidget {
  final int index;
  final String name;
  final SnippetCategory? meta;

  const _ArrangeRow({
    super.key,
    required this.index,
    required this.name,
    required this.meta,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final color = categoryAccent(name, meta);
    final hidden = meta?.hidden ?? false;
    final crud = ref.read(snippetCategoryCrudProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.v3Elevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.v3BorderSubtle, width: 0.5),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    LucideIcons.gripVertical,
                    size: 16,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ),
            ),
            // Color dot → tap opens color menu.
            _ArrangeColorDot(
              color: color,
              selected: meta?.colorIndex,
              onSelected: (i) => crud.setColor(name, i),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: hidden
                      ? AppColors.v3TextTertiary
                      : AppColors.v3TextPrimary,
                ),
              ),
            ),
            Tooltip(
              message: hidden
                  ? l10n.snippetsShowCategory
                  : l10n.snippetsHideCategory,
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => crud.setHidden(name, !hidden),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    hidden ? LucideIcons.eyeOff : LucideIcons.eye,
                    size: 15,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A color dot that opens a compact palette popup to recolor a category
/// straight from the arrange panel.
class _ArrangeColorDot extends StatelessWidget {
  final Color color;
  final int? selected;
  final ValueChanged<int?> onSelected;

  const _ArrangeColorDot({
    required this.color,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<int?>(
      tooltip: l10n.snippetsCategoryColorLabel,
      offset: const Offset(0, 24),
      color: AppColors.v3Elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppColors.v3BorderDefault, width: 0.5),
      ),
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem<int?>(
          value: null,
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: AppColors.v3Elevated,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.v3BorderStrong, width: 1),
                ),
                child: Icon(
                  LucideIcons.eyeOff,
                  size: 10,
                  color: AppColors.v3TextSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.folderColorDefault,
                style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary),
              ),
            ],
          ),
        ),
        for (var i = 0; i < AppColors.labelPalette.length; i++)
          PopupMenuItem<int?>(
            value: i,
            child: Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: AppColors.labelPalette[i],
                    shape: BoxShape.circle,
                    border: selected == i
                        ? Border.all(color: AppColors.v3TextPrimary, width: 2)
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.snippetsLibraryColorNumber(i + 1),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// The Snippets page as the design draws it: one
// header row, chips of folders and two filters, the list as rows grouped by
// folder (cards stay a view of their own), Run on a row's hover.
// ══════════════════════════════════════════════════════════════════

/// The page's one header row: its title, New snippet, the filter, the sort,
/// the list or cards toggle, and the page's options.
class _PageHeaderRow extends StatelessWidget {
  const _PageHeaderRow({
    required this.search,
    required this.onNew,
    required this.sortMode,
    required this.onSortChanged,
    required this.onArrange,
    required this.grid,
    required this.onGrid,
    this.showSelect = true,
  });

  /// Select is offered (there are snippets to select, 3.4).
  final bool showSelect;

  final Widget search;
  final VoidCallback onNew;
  final SnippetSortMode sortMode;
  final ValueChanged<SnippetSortMode> onSortChanged;
  final VoidCallback onArrange;
  final bool grid;
  final ValueChanged<bool> onGrid;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = GuideTitle(
      feature: 'snippets',
      title: Text(
        l10n.zestSnippetsTitle,
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
      ),
    );
    final newButton = ZestButton(
      key: const ValueKey('snippets-new'),
      label: l10n.zestSnippetsNewLabel,
      icon: LucideIcons.plus,
      variant: ZestButtonVariant.primary,
      onPressed: onNew,
    );
    // A Wrap, so that where the page is narrow (the list beside a snippet,
    // 370 wide at 1280 by 800) the setup guide and the sort go under one
    // another and do not run off the pane's edge; in the wide row it is one run.
    final controls = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Toolbar(sortMode: sortMode, onSortChanged: onSortChanged, onArrange: onArrange),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ViewToggle(grid: grid, onChanged: onGrid),
            const SizedBox(width: 4),
            const _SnippetOptionsButton(),
          ],
        ),
        const SetupGuideButton(SetupTopic.snippets),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 10),
      child: LayoutBuilder(builder: (context, constraints) {
        // Wide: the design's one row. Narrower: the buttons wrap, and the
        // filter takes its own line under them. (Select needs its room too.)
        if (constraints.maxWidth >= (showSelect ? 960 : 860)) {
          return Row(
            children: [
              title,
              const SizedBox(width: 16),
              newButton,
              if (showSelect) ...[
                const SizedBox(width: 10),
                const ItemSelectToggle(kind: TransferKinds.snippet),
              ],
              const SizedBox(width: 16),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: search),
                ),
              ),
              const SizedBox(width: 12),
              controls,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                title,
                newButton,
                if (showSelect) const ItemSelectToggle(kind: TransferKinds.snippet),
                controls,
              ],
            ),
            const SizedBox(height: 10),
            search,
          ],
        );
      }),
    );
  }
}

/// List or cards: two icon buttons in one hairline box.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.grid, required this.onChanged});

  final bool grid;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget button(bool isGrid, IconData icon, String tip) {
      final on = grid == isGrid;
      // A choice of two to a screen reader, the one shown picked; pressed
      // anywhere in a mouse's 32 square (a finger's 48) around its pill of
      // 30 by 28, reached with Tab (it was a 30 by 28 with a tooltip only).
      return Tooltip(
        message: tip,
        excludeFromSemantics: true,
        child: ZestPressable(
          key: ValueKey(isGrid ? 'snippets-view-grid' : 'snippets-view-list'),
          borderRadius: 6,
          onTap: () => onChanged(isGrid),
          semanticLabel: tip,
          excludeChildSemantics: true,
          selected: on,
          inGroup: true,
          child: Container(
            width: 30,
            height: 28,
            decoration: BoxDecoration(
              color: on ? ZestTokens.surfaceChip : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 15, color: on ? ZestTokens.textPrimary : ZestTokens.textTertiary),
          ),
        ),
      );
    }

    // The targets take the box's 2 of padding: the box is the size it was.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(false, LucideIcons.list, l10n.snippetPageViewList),
          button(true, LucideIcons.layoutGrid, l10n.snippetPageViewGrid),
        ],
      ),
    );
  }
}

/// The chip row: All, a chip per folder (its colour dot, its count) as many
/// as fit, "N more" for the rest, then Has variables and Asks first.
class _FolderChipsRow extends StatelessWidget {
  const _FolderChipsRow({
    required this.total,
    required this.folders,
    required this.activeFolder,
    required this.filter,
    required this.onFolder,
    required this.onFilter,
    this.trailing,
  });

  /// At the row's end, outside its scroll (the selection's head, 3.4).
  final Widget? trailing;

  final int total;
  final List<_CatSection> folders;
  final String? activeFolder;
  final _SnippetFilter filter;
  final ValueChanged<String?> onFolder;
  final ValueChanged<_SnippetFilter> onFilter;

  static double _textWidth(BuildContext context, String text, double size) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.copyWith(fontSize: size, fontWeight: FontWeight.w600)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final allActive = activeFolder == null && filter == _SnippetFilter.all;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 16, 10),
      child: LayoutBuilder(builder: (context, constraints) {
        double chipWidth(String label, {String? count, bool dot = false}) =>
            _textWidth(context, label, 12.5) +
            (count == null ? 0 : _textWidth(context, count, 11) + 7) +
            (dot ? 14 : 0) +
            24 +
            6;
        final fixed = chipWidth(l10n.snippetPageAll, count: '$total') +
            chipWidth(l10n.snippetPageHasVariables) +
            chipWidth(l10n.snippetPageAsksFirst) +
            21;
        var room = constraints.maxWidth - fixed;
        final shown = <_CatSection>[];
        for (var i = 0; i < folders.length; i++) {
          final rest = folders.length - i - 1;
          final w = chipWidth(folders[i].name, count: '${folders[i].snippets.length}', dot: true);
          final more = rest > 0 ? chipWidth(l10n.snippetPageMoreGroups(rest)) : 0;
          if (w + more > room) break;
          shown.add(folders[i]);
          room -= w;
        }
        final hidden = folders.skip(shown.length).toList();
        final hiddenActive = hidden.any((f) => f.name == activeFolder);
        final chips = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _PageChip(
                key: const ValueKey('snippets-chip-all'),
                label: l10n.snippetPageAll,
                count: '$total',
                active: allActive,
                onTap: () {
                  onFolder(null);
                  onFilter(_SnippetFilter.all);
                },
              ),
              for (final f in shown)
                _PageChip(
                  key: ValueKey('snippets-chip-folder-${f.name}'),
                  label: f.name,
                  count: '${f.snippets.length}',
                  dot: categoryAccent(f.name, f.meta),
                  active: activeFolder == f.name,
                  onTap: () => onFolder(activeFolder == f.name ? null : f.name),
                ),
              if (hidden.isNotEmpty)
                PopupMenuButton<String>(
                  key: const ValueKey('snippets-chip-more'),
                  tooltip: '',
                  color: AppColors.v3Surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  onSelected: onFolder,
                  itemBuilder: (_) => [
                    for (final f in hidden)
                      PopupMenuItem(
                        value: f.name,
                        height: 34,
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                  color: categoryAccent(f.name, f.meta), borderRadius: BorderRadius.circular(2)),
                            ),
                            const SizedBox(width: 8),
                            Text(f.name, style: TextStyle(fontSize: 12.5, color: ZestTokens.textPrimary)),
                            const SizedBox(width: 8),
                            Text('${f.snippets.length}',
                                style: TextStyle(fontSize: 11, color: ZestTokens.textTertiary, fontFamily: 'JetBrainsMono')),
                          ],
                        ),
                      ),
                  ],
                  child: _PageChip(
                    label: hiddenActive ? activeFolder! : l10n.snippetPageMoreGroups(hidden.length),
                    active: hiddenActive,
                  ),
                ),
              Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.only(left: 4, right: 10),
                color: ZestTokens.borderSubtle,
              ),
              _PageChip(
                key: const ValueKey('snippets-chip-vars'),
                label: l10n.snippetPageHasVariables,
                active: filter == _SnippetFilter.hasVariables,
                onTap: () => onFilter(
                    filter == _SnippetFilter.hasVariables ? _SnippetFilter.all : _SnippetFilter.hasVariables),
              ),
              _PageChip(
                key: const ValueKey('snippets-chip-asks'),
                label: l10n.snippetPageAsksFirst,
                active: filter == _SnippetFilter.confirmRequired,
                onTap: () => onFilter(
                    filter == _SnippetFilter.confirmRequired ? _SnippetFilter.all : _SnippetFilter.confirmRequired),
              ),
            ],
          ),
        );
        if (trailing == null) return chips;
        return Row(children: [Expanded(child: chips), const SizedBox(width: 12), trailing!]);
      }),
    );
  }
}

/// One chip of the row: its label, its count in mono, a folder's colour dot.
class _PageChip extends StatelessWidget {
  const _PageChip({super.key, required this.label, this.count, this.dot, required this.active, this.onTap});

  final String label;
  final String? count;
  final Color? dot;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      height: 30,
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: active ? ZestTokens.surfaceChip : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? ZestTokens.textTertiary.withValues(alpha: 0.5) : ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? ZestTokens.textPrimary : ZestTokens.textSecondary,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 7),
            Text(count!, style: TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary)),
          ],
        ],
      ),
    );
    if (onTap == null) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: chip),
    );
  }
}

/// A snippet as a row of the list: its name, its command in mono with its
/// variables as chips (a script of several lines shows its first line and
/// says so), "one variable" or "Asks first", when it last ran, and on hover
/// the Run split button (Run as the page runs it; the arrow: in the session
/// you're in, or on a host picked first). Enter runs, Ctrl or Cmd+C copies,
/// Ctrl or Cmd+E edits; a right click opens the card's menu.
class _SnippetRow extends ConsumerStatefulWidget {
  const _SnippetRow({
    super.key,
    required this.snippet,
    required this.selected,
    required this.onTap,
    required this.onCopy,
    required this.onEdit,
    required this.onDuplicate,
    required this.onRunOn,
    required this.onDelete,
    this.selecting = false,
  });

  final Snippet snippet;

  /// Open beside the list, or (while [selecting]) selected.
  final bool selected;

  /// The snippets are being selected: the row's box before its name.
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onRunOn;
  final VoidCallback onDelete;

  @override
  ConsumerState<_SnippetRow> createState() => _SnippetRowState();
}

class _SnippetRowState extends ConsumerState<_SnippetRow> {
  bool _hovering = false;
  bool _focused = false;
  bool _menuOpen = false;

  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): _RunSnippetIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): _RunSnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, control: true): _CopySnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, meta: true): _CopySnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyE, control: true): _EditSnippetIntent(),
    SingleActivator(LogicalKeyboardKey.keyE, meta: true): _EditSnippetIntent(),
  };

  void _run() => runSnippetFromPage(context, ref, widget.snippet);

  Future<void> _openMenu(RelativeRect position) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _menuOpen = true);
    final value = await showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      items: _snippetCardMenuItems(
        l10n,
        transfer: transferOffer(ref, TransferKinds.snippet, [widget.snippet.id]),
        defaultHost: () {
          final host = defaultHostOf(
              ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [], widget.snippet.metadata);
          return host == null ? null : Redactable.host(host.connection.label).displayIn(ref);
        }(),
      ),
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    if (value == null) return;
    if (value == 'run-hosts') {
      unawaited(showRunOnHosts(context, snippet: widget.snippet));
      return;
    }
    if (value == 'move_to' || value == 'copy_to') {
      unawaited(showMoveCopyDialog(context, ref,
          kind: TransferKinds.snippet,
          keys: [widget.snippet.id],
          mode: value == 'move_to' ? TransferMode.move : TransferMode.copy));
      return;
    }
    _dispatchSnippetCardAction(
      value,
      onEdit: widget.onEdit,
      onCopy: widget.onCopy,
      onDuplicate: widget.onDuplicate,
      onRun: widget.onRunOn,
      onDelete: widget.onDelete,
    );
  }

  Future<void> _openRunChoices(BuildContext anchor) async {
    final l10n = AppLocalizations.of(context)!;
    final box = anchor.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset(0, box.size.height + 4));
    final hasSession = currentSessionOf(ref.read) != null;
    setState(() => _menuOpen = true);
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      items: [
        PopupMenuItem(
          value: 'here',
          enabled: hasSession,
          child: _ContextMenuItem(icon: LucideIcons.terminal, label: l10n.snippetPageRunHere),
        ),
        PopupMenuItem(
          value: 'on',
          child: _ContextMenuItem(icon: LucideIcons.server, label: l10n.zestSnippetsRunOn),
        ),
      ],
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    switch (value) {
      case 'here':
        await runSnippetInCurrentSession(context, ref, widget.snippet);
      case 'on':
        await runSnippetOnPickedHost(context, ref, widget.snippet);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = widget.snippet;
    final selected = widget.selected;
    final showRun = _hovering || _focused || _menuOpen;
    final varCount = parseVariablesWithOptions(s.command).length;
    final lastRun = snippetLastRunText(l10n, ref.watch(snippetUsageProvider)[s.id]);
    final command = Redactable.freeText(s.command).displayIn(ref);
    final lines = command.trim().split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
    final mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestTokens.textSecondary);
    final meta = varCount > 0
        ? Text(l10n.snippetPageVariableCount(varCount),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary))
        : s.confirmBeforeRun
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.shield, size: 13, color: ZestTokens.textTertiary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(l10n.snippetPageAsksFirst,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
                ),
              ])
            : const SizedBox.shrink();

    return FocusableActionDetector(
      shortcuts: _shortcuts,
      actions: {
        _RunSnippetIntent: CallbackAction<_RunSnippetIntent>(onInvoke: (_) {
          _run();
          return null;
        }),
        _CopySnippetIntent: CallbackAction<_CopySnippetIntent>(onInvoke: (_) {
          widget.onCopy();
          return null;
        }),
        _EditSnippetIntent: CallbackAction<_EditSnippetIntent>(onInvoke: (_) {
          widget.onEdit();
          return null;
        }),
      },
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (h) => setState(() => _hovering = h),
      onShowFocusHighlight: (f) => setState(() => _focused = f),
      child: GestureDetector(
        onTap: widget.onTap,
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context)
            ? (d) => _openMenu(RelativeRect.fromLTRB(
                d.globalPosition.dx, d.globalPosition.dy, d.globalPosition.dx + 1, d.globalPosition.dy + 1))
            : null,
        onSecondaryTapUp: (d) => _openMenu(RelativeRect.fromLTRB(
            d.globalPosition.dx, d.globalPosition.dy, d.globalPosition.dx + 1, d.globalPosition.dy + 1)),
        child: AnimatedContainer(
          key: ValueKey('snippet-row-${s.id}'),
          duration: const Duration(milliseconds: 120),
          height: 44,
          margin: const EdgeInsets.only(bottom: 3),
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: BoxDecoration(
            color: selected
                ? ZestTokens.brand.withValues(alpha: 0.06)
                : (_hovering || _focused)
                    ? ZestTokens.surfaceRaisedAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? ZestTokens.brand.withValues(alpha: 0.55)
                  : _focused
                      ? ZestTokens.borderSubtle
                      : Colors.transparent,
            ),
          ),
          child: LayoutBuilder(builder: (context, constraints) {
            // Room for every column from 700 up; narrower, when it last ran
            // and the variables go first, then the name narrows.
            final w = constraints.maxWidth;
            final showMeta = w >= 560;
            final showLast = w >= 700;
            return Row(
            children: [
              if (widget.selecting) ...[
                SelectBox(key: ValueKey('snippet-row-box-${s.id}'), checked: selected, size: 16),
                const SizedBox(width: 10),
              ],
              SizedBox(
                width: (w * 0.3).clamp(110.0, 240.0),
                child: RedactedText(
                  Redactable.freeText(s.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Tooltip(
                  message: command,
                  waitDuration: const Duration(milliseconds: 600),
                  child: Text.rich(
                    TextSpan(
                      children: lines.length > 1
                          ? [
                              ...snippetCommandChipSpans(lines.first.trim(), mono),
                              TextSpan(text: '  ·  ${l10n.snippetPageScript}', style: mono),
                            ]
                          : snippetCommandChipSpans(lines.isEmpty ? '' : lines.first, mono),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              if (showMeta) SizedBox(width: 130, child: Align(alignment: Alignment.centerLeft, child: meta)),
              if (showLast)
                SizedBox(
                  width: 72,
                  child: Text(
                    lastRun ?? '',
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                  ),
                ),
              const SizedBox(width: 10),
              SizedBox(
                width: 84,
                child: showRun
                    ? _RunSplitButton(onRun: _run, onChoices: _openRunChoices)
                    : const SizedBox.shrink(),
              ),
            ],
          );
          }),
        ),
      ),
    );
  }
}

/// "▸ Run ▾": Run as the page runs it, and an arrow for where to run it.
class _RunSplitButton extends StatelessWidget {
  const _RunSplitButton({required this.onRun, required this.onChoices});

  final VoidCallback onRun;
  final void Function(BuildContext anchor) onChoices;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final style = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary);
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: InkWell(
              key: const ValueKey('snippet-row-run'),
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(7)),
              onTap: onRun,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.play, size: 11, color: ZestTokens.textPrimary),
                  const SizedBox(width: 5),
                  Flexible(child: Text(l10n.snippetPageRun, style: style, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
          Container(width: 1, height: 16, color: ZestTokens.borderSubtle),
          Builder(
            builder: (anchor) => Tooltip(
              message: l10n.snippetPageRunChoices,
              child: InkWell(
                key: const ValueKey('snippet-row-run-choices'),
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(7)),
                onTap: () => onChoices(anchor),
                child: SizedBox(
                  width: 24,
                  height: 28,
                  child: Icon(LucideIcons.chevronDown, size: 13, color: ZestTokens.textSecondary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
