import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace, TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show defaultSavePlace, savePlaces, showMoveCopyDialog, transferOffer;
import 'package:zestssh/features/orchards/move/save_in_field.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/features/selection/item_selection_bar.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_detail_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_drafts.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_edit_controller.dart';
import 'package:zestssh/ui/widgets/edit_drafts.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart' show SelectBox;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/services/port_forward_messages.dart';
import 'package:zestssh/services/port_forward_service.dart' show PortForwardService, PortForwardType;
import 'package:zestssh/ui/screens/port_forward/network_bind_confirm.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_master_detail.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// Sentinel selection used while creating a brand-new rule (before it has an id).
const String _kNewSelection = '__new__';

/// The 1.7 desktop Port Forwarding screen - a [ZestMasterDetail] master/detail
/// (screenId `port_forwarding`). Saved rules sit in the list pane; the former
/// floating wizard card now lives inside a [ZestDetailScaffold] in the detail
/// pane. Selection, repository I/O and the dirty guard are owned here; the
/// [PortForwardEditController] owns the editor draft.
///
/// The class name is kept ([PortForwardListView]) so the desktop shell's
/// existing `const PortForwardListView()` reference stays valid.
class PortForwardListView extends ConsumerStatefulWidget {
  const PortForwardListView({super.key});

  @override
  ConsumerState<PortForwardListView> createState() =>
      _PortForwardListViewState();
}

class _PortForwardListViewState extends ConsumerState<PortForwardListView>
    with KeepsEditDrafts<PortForwardListView, PfKeptEdit> {
  late final PortForwardEditController _controller;

  /// null = nothing open; [_kNewSelection] = creating; else the rule id.
  String? _selectedId;

  /// Where a new rule is saved ("Save in", 3.4); null: where new items of the
  /// space on screen go.
  SavePlace? _saveIn;

  /// The key this form's draft is kept under: the rule's id, or the new rule's.
  String get _draftKey => _controller.original?.id ?? kPfNewRuleDraftKey;

  @override
  void initState() {
    super.initState();
    _controller = PortForwardEditController();
    // Unsaved edits kept as the page went (a terminal was shown in its
    // place): the same form opens again, with them, as unsaved. A change of
    // profile builds the drafts anew, empty: the form open here was the
    // profile before's, and goes too.
    final kept = takeEditDraft(portForwardDraftsProvider, onRenewed: () {
      _controller.bind(null);
      _saveIn = null;
      setState(() => _selectedId = _kNewSelection);
    });
    if (kept != null) {
      _controller.restore(kept.edit);
      _saveIn = kept.saveIn;
      _selectedId = kept.edit.original?.id ?? _kNewSelection;
    } else {
      // The detail pane always shows the editor, so start on a blank NEW rule -
      // the right side is ready to fill out by default (no empty state).
      _controller.bind(null);
      _selectedId = _kNewSelection;
    }
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Going with unsaved edits (the shell shows a terminal in this page's
    // place): they are kept, in memory, for when the page comes back.
    if (_controller.isDirty) {
      keepEditDraft(_draftKey, (edit: _controller.snapshot(), saveIn: _controller.isCreating ? _saveIn : null));
    }
    _controller.dispose();
    super.dispose();
  }

  bool get _hasSelection => _selectedId != null;

  // ── Selection / creation (all run the discard guard first) ─────────

  Future<void> _select(String id, {required bool narrow}) async {
    if (_selectedId == id) return;
    final proceed =
        await _controller.confirmDiscardIfDirty(context, onSave: _save);
    if (!proceed || !mounted) return;
    if (!_bind(id)) return;
    setState(() => _selectedId = id);
    if (narrow && mounted) await _pushDetailRoute();
  }

  Future<void> _createNew({required bool narrow}) async {
    final proceed =
        await _controller.confirmDiscardIfDirty(context, onSave: _save);
    if (!proceed || !mounted) return;
    _controller.bind(null);
    setState(() => _selectedId = _kNewSelection);
    if (narrow && mounted) await _pushDetailRoute();
  }

  /// Load a rule into the controller. Returns false if the id no longer exists.
  bool _bind(String id) {
    final rules =
        ref.read(filteredPortForwardRulesProvider).valueOrNull ?? const [];
    PortForwardRule? rule;
    for (final r in rules) {
      if (r.id == id) {
        rule = r;
        break;
      }
    }
    if (rule == null) return false;
    _controller.bind(rule, connectionId: rule.connectionId);
    return true;
  }

  Future<void> _close() async {
    final proceed =
        await _controller.confirmDiscardIfDirty(context, onSave: _save);
    if (!proceed || !mounted) return;
    forgetEditDraft(_draftKey);
    // Reset to a blank new rule rather than an empty pane.
    _controller.bind(null);
    setState(() => _selectedId = _kNewSelection);
  }

  // ── Persistence ────────────────────────────────────────────────────

  Future<bool> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final result = _controller.buildCompanion(l10n: l10n);
    if (result.error != null || result.companion == null) {
      if (mounted && result.error != null) {
        showTopSnackBar(context, result.error!, isError: true);
      }
      return false;
    }
    final companion = result.companion!;
    final existing = _controller.original;
    final draftKey = _draftKey;
    // A forward that other devices on the network can reach is kept only
    // once the person allows it (where it did not listen so before).
    PortForwardType typeOf(String t) => t == 'remote'
        ? PortForwardType.remote
        : t == 'dynamic'
            ? PortForwardType.dynamic
            : PortForwardType.local;
    final allowed = await confirmNetworkBind(
      context,
      listensOn: forwardListensOn(typeOf(companion.type.value), companion.bindAddress.value,
          gatewayPorts: companion.gatewayPorts.value),
      port: companion.bindPort.value,
      before: existing == null
          ? null
          : forwardListensOn(typeOf(existing.type), existing.bindAddress, gatewayPorts: existing.gatewayPorts),
    );
    if (!allowed || !mounted) return false;
    // A new one for another place than new items of this space go to ("Save
    // in", 3.4): saved there, with its host, and said where.
    final place = _saveIn ?? defaultSavePlace(ref);
    if (existing == null && place != defaultSavePlace(ref)) {
      final dao = ref.read(portForwardRulesDaoProvider);
      final id = await saveNewItemIn(context, ref, place: place, kind: TransferKinds.forward, write: () async {
        await dao.insertRule(companion);
        return companion.id.value;
      });
      if (id == null || !mounted) return id != null;
      final saved = savePlaces(ref, l10n, watch: false).where((p) => p.place == place).firstOrNull;
      showTopSnackBar(context, l10n.saveInSavedToast(Redactable.freeText(saved?.title ?? '').display), isSuccess: true);
      forgetEditDraft(draftKey);
      _saveIn = null;
      _controller.bind(null);
      setState(() => _selectedId = _kNewSelection);
      return true;
    }
    try {
      final dao = ref.read(portForwardRulesDaoProvider);
      if (existing != null) {
        // The editor now owns every column it writes (name/label, auto-start,
        // the reconnect/exit/gateway options, ssh flags), and the companion
        // preserves createdAt. A network pin is left untouched - the companion
        // never sets networkId, so `.write` leaves that column alone.
        await dao.updateRule(companion);
      } else {
        await dao.insertRule(companion);
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.portForwardNotSaved, isError: true, details: '$e');
      }
      return false;
    }
    // Saved: nothing of it is a draft any more.
    forgetEditDraft(draftKey);
    // Re-read the persisted row so the editor rebinds cleanly (title flips,
    // dirty clears) and future edits UPDATE in place.
    final saved = await _reloadRule(companion.id.value);
    if (!mounted) return true;
    if (saved != null) {
      _controller.markSaved(saved);
      setState(() => _selectedId = saved.id);
    }
    return true;
  }

  Future<PortForwardRule?> _reloadRule(String id) async {
    final rules = await ref.read(portForwardRulesDaoProvider).getAll();
    for (final r in rules) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> _delete() async {
    final rule = _controller.original;
    if (rule == null) return;
    final l10n = AppLocalizations.of(context)!;
    final name = _displayNameShown(rule, ref);
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.portForwardListDeleteConfirmTitle(name),
      body: l10n.portForwardListDeleteConfirmBody,
      confirmLabel: MaterialLocalizations.of(context).deleteButtonTooltip,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(portForwardRulesDaoProvider).deleteRule(rule.id);
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.portForwardNotDeleted, isError: true, details: '$e');
      }
      return;
    }
    forgetEditDraft(rule.id);
    if (!mounted) return;
    // Reset to a blank new rule so the deleted rule's now-stale draft can't
    // later prompt a spurious "save?".
    _controller.bind(null);
    setState(() => _selectedId = _kNewSelection);
  }

  Future<void> _onModeChanged(PfEditorMode mode) async {
    if (mode == _controller.mode) return;
    // A switch carries what was typed across (the kind, both ports), so it
    // asks nothing; only where Advanced holds what Simple cannot show (a host
    // other than localhost, flags of its own) does it say which, first.
    if (mode == PfEditorMode.simple) {
      final cannotShow = _controller.simpleCannotShow;
      if (cannotShow.isNotEmpty) {
        final l10n = AppLocalizations.of(context)!;
        final ok = await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.warning,
          title: l10n.pfToSimpleTitle,
          body: l10n.pfToSimpleBody,
          bullets: [
            for (final what in PfSimpleCannotShow.values)
              if (cannotShow.contains(what))
                switch (what) {
                  PfSimpleCannotShow.sourceHost => l10n.pfToSimpleSourceHost,
                  PfSimpleCannotShow.destinationHost => l10n.pfToSimpleDestinationHost,
                  PfSimpleCannotShow.flags => l10n.pfToSimpleFlags,
                },
          ],
          warning: l10n.pfToSimpleWarning,
          confirmLabel: l10n.pfToSimpleConfirm,
        );
        if (ok != true || !mounted) return;
      }
    }
    _controller.setMode(mode);
  }

  // ── Narrow single-column route ─────────────────────────────────────

  Future<void> _pushDetailRoute() {
    return ZestMasterDetail.pushDetail<void>(
      context,
      ListenableBuilder(
        listenable: _controller,
        builder: (routeContext, _) => PopScope<void>(
          canPop: !_controller.isDirty,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final proceed = await _controller.confirmDiscardIfDirty(
              routeContext,
              onSave: _save,
            );
            if (proceed && routeContext.mounted) {
              Navigator.of(routeContext).pop();
            }
          },
          child: PortForwardDetailPane(
            controller: _controller,
            hasSelection: true,
            onNew: () => _createNew(narrow: false),
            onSave: _save,
            onSaveAndStart: _saveAndStart,
            onClose: () async {
              final proceed = await _controller.confirmDiscardIfDirty(
                routeContext,
                onSave: _save,
              );
              if (proceed && routeContext.mounted) {
                Navigator.of(routeContext).pop();
              }
            },
            onDelete: () async {
              await _delete();
              if (_selectedId == null && routeContext.mounted) {
                Navigator.of(routeContext).pop();
              }
            },
            onModeChanged: _onModeChanged,
            saveIn: SaveInField(value: _saveIn, onChanged: (p) => setState(() => _saveIn = p)),
            onMoved: () {
              _moved();
              if (routeContext.mounted) Navigator.of(routeContext).pop();
            },
          ),
        ),
      ),
    );
  }

  /// A saved rule moved out of this place from its editor (4.0): nothing of
  /// it is open here any more; the pane goes back to a blank new rule.
  void _moved() {
    if (!mounted) return;
    forgetEditDraft(_draftKey);
    _controller.bind(null);
    setState(() => _selectedId = _kNewSelection);
  }

  /// Save, then start the rule (the editor's Save and start); a rule with
  /// nothing to save starts as it is.
  Future<void> _saveAndStart() async {
    if (_controller.isDirty || _controller.original == null) {
      if (!await _save()) return;
    }
    final rule = _controller.original;
    if (rule == null || !mounted) return;
    await startRuleFromPage(context, ref, rule);
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _reconcileSelection();

    // The page as the design draws it: the
    // rules with their own header (title, New rule, filter, state), and the
    // editor the full height beside them.
    return ColoredBox(
      color: ZestTokens.surfaceBase,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < ZestSizing.singleColumnBreakpoint;
          return ZestMasterDetail(
            screenId: 'port_forwarding_rules',
            initialRatio: 0.68,
            listPane: _PortForwardListPane(
              selectedId: _selectedId,
              onSelect: (id) => _select(id, narrow: narrow),
              onNew: () => _createNew(narrow: narrow),
              editorBeside: !narrow,
              // The selection's actions ask the editor about its changes
              // first (3.4).
              beforeChange: () => _controller.confirmDiscardIfDirty(context, onSave: _save),
            ),
            detailPane: PortForwardDetailPane(
              controller: _controller,
              hasSelection: _hasSelection,
              onNew: () => _createNew(narrow: narrow),
              onSave: _save,
              onSaveAndStart: _saveAndStart,
              onClose: _close,
              onDelete: _delete,
              onModeChanged: _onModeChanged,
              saveIn: SaveInField(value: _saveIn, onChanged: (p) => setState(() => _saveIn = p)),
              onMoved: _moved,
            ),
          );
        },
      ),
    );
  }

  /// Drop the selection if the currently-open, saved rule no longer exists.
  void _reconcileSelection() {
    final id = _selectedId;
    if (id == null || id == _kNewSelection) return;
    final rules = ref.watch(allPortForwardRulesProvider).valueOrNull;
    if (rules == null) return;
    if (!rules.any((r) => r.id == id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedId == id) {
          _controller.bind(null);
          setState(() => _selectedId = _kNewSelection);
        }
      });
    }
  }
}

/// Nickname or a generated fallback for a rule, in its display form (recording
/// mode): a nickname may embed a host, the fallback IS the remote address. It
/// is only ever painted - titles, dialogs, snackbars - so there is no raw
/// variant; rules are matched by id.
String _displayNameShown(PortForwardRule rule, WidgetRef ref) {
  if (rule.label != null && rule.label!.isNotEmpty) {
    return Redactable.freeText(rule.label!).displayIn(ref);
  }
  switch (rule.type) {
    case 'dynamic':
      return 'SOCKS5 :${rule.bindPort}';
    default:
      return Redactable.address('${rule.remoteHost}:${rule.remotePort}')
          .displayIn(ref);
  }
}

// ══════════════════════════════════════════════════════════════════
// List pane - the page's header (title, New rule, filter, state), the rules
// ══════════════════════════════════════════════════════════════════

/// Which rules the list shows: every one, the running, the stopped.
enum PfListFilter { all, running, stopped }

class _PortForwardListPane extends ConsumerStatefulWidget {
  const _PortForwardListPane({
    required this.selectedId,
    required this.onSelect,
    required this.onNew,
    required this.editorBeside,
    this.beforeChange,
  });

  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNew;

  /// Runs before the selection's bar changes rules (the editor beside the
  /// list asks about its changes).
  final Future<bool> Function()? beforeChange;

  /// Whether a new rule's form stands open beside this list.
  final bool editorBeside;

  @override
  ConsumerState<_PortForwardListPane> createState() =>
      _PortForwardListPaneState();
}

class _PortForwardListPaneState extends ConsumerState<_PortForwardListPane> {
  /// Rule ids whose last start attempt failed - drives the Error state word.
  final Set<String> _errored = {};

  PfListFilter _filter = PfListFilter.all;

  void _setErrored(String id, bool errored) {
    setState(() {
      if (errored) {
        _errored.add(id);
      } else {
        _errored.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final rulesAsync = ref.watch(filteredPortForwardRulesProvider);
    // The UNFILTERED list decides whether the whole pane is empty - a search
    // that matches nothing is tier-2, not tier-1.
    final allRules = ref.watch(allPortForwardRulesProvider);
    final every = allRules.valueOrNull ?? const <PortForwardRule>[];
    final activeIds = ref.watch(activeForwardIdsProvider);
    final running = every.where((r) => activeIds.contains(r.id)).length;
    final loadedEmpty = allRules.hasValue && every.isEmpty;
    // Port forwards selected (3.4), as the hosts are: a box on each, the
    // keys that select, the selection's bar at the list's foot.
    final selection = ref.watch(forwardSelectionProvider);
    final open = widget.selectedId == _kNewSelection ? null : widget.selectedId;
    void tap(String id) {
      if (!itemSelectionClick(ref, TransferKinds.forward, id, openId: open)) widget.onSelect(id);
    }

    final list = Container(
      color: ZestTokens.surfaceBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            onNew: widget.onNew,
            filter: _filter,
            onFilter: (f) => setState(() => _filter = f),
            all: every.length,
            running: running,
            showSelect: every.isNotEmpty,
          ),
          Expanded(
            child: ItemSelectionFocusArea(
            child: loadedEmpty
                // TIER 1: no rules at all. Beside the list a new rule's form
                // is already open: no second way to it in the middle.
                ? _EmptyState(onNew: widget.editorBeside ? null : widget.onNew)
                : rulesAsync.when(
                    // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
                    skipLoadingOnReload: true,
                    loading: () => Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.brand),
                      ),
                    ),
                    error: (e, _) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(l10n.portForwardListLoadFailed,
                            style: TextStyle(color: ZestTokens.statusCritical)),
                      ),
                    ),
                    data: (rules) {
                      final shown = [
                        for (final r in rules)
                          if (switch (_filter) {
                            PfListFilter.all => true,
                            PfListFilter.running => activeIds.contains(r.id),
                            PfListFilter.stopped => !activeIds.contains(r.id),
                          })
                            r,
                      ];
                      // The rules in the order shown: what Ctrl+A selects and
                      // a Shift-click's range runs along.
                      publishShownItems(ref, TransferKinds.forward, [for (final r in shown) r.id]);
                      if (rules.isEmpty) {
                        // TIER 2: rules exist but the search matched none.
                        return _FilterEmptyState(
                          onClear: () => ref.read(portForwardSearchQueryProvider.notifier).state = '',
                        );
                      }
                      if (shown.isEmpty) {
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                            child: ZestEmptyRow(message: l10n.pfPageNoneMatch),
                          ),
                        );
                      }
                      return _RuleList(
                        rules: shown,
                        activeIds: activeIds,
                        selectedId: widget.selectedId,
                        errored: _errored,
                        onSelect: tap,
                        onErroredChanged: _setErrored,
                        selecting: selection.active,
                        checked: selection.selected,
                      );
                    },
                  ),
            ),
          ),
        ],
      ),
    );
    return ItemSelectionKeys(
      kind: TransferKinds.forward,
      beforeChange: widget.beforeChange,
      child: Stack(
        children: [
          Positioned.fill(child: list),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ItemSelectionBar(
              kind: TransferKinds.forward,
              beforeChange: widget.beforeChange,
              onForwardErrored: _setErrored,
            ),
          ),
        ],
      ),
    );
  }
}

/// The page's header, as the design draws it: the
/// title, New rule, the filter field, and the rules by state with how many.
class _Header extends ConsumerStatefulWidget {
  const _Header({
    required this.onNew,
    required this.filter,
    required this.onFilter,
    required this.all,
    required this.running,
    this.showSelect = true,
  });

  /// Select is offered (there are rules to select, 3.4).
  final bool showSelect;

  final VoidCallback onNew;
  final PfListFilter filter;
  final ValueChanged<PfListFilter> onFilter;
  final int all;
  final int running;

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final filter = ZestModeToggle(
      key: const ValueKey('pf-filter-state'),
      selectedId: widget.filter.name,
      onChanged: (id) => widget.onFilter(PfListFilter.values.byName(id)),
      segments: [
        ZestModeSegment(id: PfListFilter.all.name, label: l10n.pfPageFilterAll(widget.all)),
        ZestModeSegment(id: PfListFilter.running.name, label: l10n.pfPageFilterRunning(widget.running)),
        ZestModeSegment(
            id: PfListFilter.stopped.name, label: l10n.pfPageFilterStopped(widget.all - widget.running)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
      child: LayoutBuilder(
        builder: (context, box) {
          final search = ZestListSearchField(
            controller: _controller,
            focusNode: _focus,
            hintText: l10n.pfPageFilterHint,
            onChanged: (v) => ref.read(portForwardSearchQueryProvider.notifier).state = v,
          );
          final title = GuideTitle(
            feature: 'port_forwards',
            title: Text(
              l10n.zestPfTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary, height: 1.2),
            ),
          );
          final newRule = ZestButton(
            key: const ValueKey('pf-new-rule'),
            label: l10n.zestPfNewLabel,
            icon: LucideIcons.plus,
            variant: ZestButtonVariant.primary,
            onPressed: widget.onNew,
          );
          // Narrow: the filter and the states go under the title.
          if (box.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(child: title),
                  const SizedBox(width: 12),
                  newRule,
                  if (widget.showSelect) ...[
                    const SizedBox(width: 10),
                    const ItemSelectToggle(kind: TransferKinds.forward),
                  ],
                ]),
                const SizedBox(height: 12),
                search,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: filter),
              ],
            );
          }
          return Row(
            children: [
              Flexible(child: title),
              const SizedBox(width: 18),
              newRule,
              if (widget.showSelect) ...[
                const SizedBox(width: 10),
                const ItemSelectToggle(kind: TransferKinds.forward),
              ],
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: search),
                ),
              ),
              const SizedBox(width: 12),
              filter,
            ],
          );
        },
      ),
    );
  }
}

class _RuleList extends StatelessWidget {
  const _RuleList({
    required this.rules,
    required this.activeIds,
    required this.selectedId,
    required this.errored,
    required this.onSelect,
    required this.onErroredChanged,
    this.selecting = false,
    this.checked = const {},
  });

  final List<PortForwardRule> rules;
  final Set<String> activeIds;
  final String? selectedId;
  final Set<String> errored;
  final ValueChanged<String> onSelect;
  final void Function(String id, bool errored) onErroredChanged;

  /// The rules are being selected (3.4): each has its box, the box over
  /// them heads the list; [checked] are the selected ones.
  final bool selecting;
  final Set<String> checked;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Room for the selection's bar under the last rule while selecting.
      padding: EdgeInsets.fromLTRB(24, 2, 24, selecting ? 140 : 24),
      children: [
        if (selecting)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 0, 12),
            child: Align(alignment: AlignmentDirectional.centerStart, child: ItemSelectionHead(kind: TransferKinds.forward)),
          ),
        for (final rule in rules)
          _RuleRow(
            key: ValueKey('pf-rule-${rule.id}'),
            rule: rule,
            isActive: activeIds.contains(rule.id),
            isSelected: selecting ? checked.contains(rule.id) : selectedId == rule.id,
            selecting: selecting,
            errored: errored.contains(rule.id),
            onSelect: () => onSelect(rule.id),
            onErroredChanged: (v) => onErroredChanged(rule.id, v),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Individual rule card
// ══════════════════════════════════════════════════════════════════

/// The host a rule goes through, from its connectionId: null when it is no
/// longer saved.
ConnectionWithDetails? _ruleHost(WidgetRef ref, PortForwardRule rule) {
  final list = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];
  for (final c in list) {
    if (c.connection.id == rule.connectionId) return c;
  }
  return null;
}

/// A host's name as it is painted (recording mode): its label, else its
/// address.
String _hostNameShown(WidgetRef ref, ConnectionWithDetails? c) {
  if (c == null) return '';
  return c.connection.label.isNotEmpty
      ? Redactable.host(c.connection.label).displayIn(ref)
      : Redactable.address(c.connection.host).displayIn(ref);
}

/// The scheme a forward's port is opened with in a browser: https for the
/// ports web interfaces serve TLS on (Proxmox's 8006 among them), else http.
String _webScheme(int port) => const {443, 8006, 8443, 9443, 10443}.contains(port) ? 'https' : 'http';

/// One rule as the mockup draws it: its kind (L, R, D, as ssh's own flags),
/// its name and the host it goes through, what goes where, its state with
/// a way to open a running local forward, and Start or Stop.
class _RuleRow extends ConsumerStatefulWidget {
  const _RuleRow({
    super.key,
    required this.rule,
    required this.isActive,
    required this.isSelected,
    required this.errored,
    required this.onSelect,
    required this.onErroredChanged,
    this.selecting = false,
  });

  final PortForwardRule rule;
  final bool isActive;

  /// Open beside the list, or (while [selecting]) selected.
  final bool isSelected;

  /// The rules are being selected: the card's box before its kind.
  final bool selecting;
  final bool errored;
  final VoidCallback onSelect;
  final ValueChanged<bool> onErroredChanged;

  @override
  ConsumerState<_RuleRow> createState() => _RuleRowState();
}

class _RuleRowState extends ConsumerState<_RuleRow> {
  bool _hover = false;

  PortForwardRule get rule => widget.rule;

  /// The listening side, as it will run (every address where other
  /// machines may reach it).
  String _listenShown() {
    final type = _pfType(rule.type);
    final bind = PortForwardService.bindAddressFor(type, rule.bindAddress, gatewayPorts: rule.gatewayPorts);
    final shown = PortForwardService.isNonLocalBind(bind) ? Redactable.address(bind).displayIn(ref) : 'localhost';
    return '$shown:${rule.bindPort}';
  }

  /// What goes where, in mono: `localhost:3000 → monitoring:3000`, the server's
  /// name where the service is on the server itself.
  String _mapping(String hostName) {
    String serviceAt() {
      final h = rule.remoteHost.trim();
      final loop = h.isEmpty || h == 'localhost' || h == '127.0.0.1' || h == '::1';
      return loop && hostName.isNotEmpty ? hostName : Redactable.address(h.isEmpty ? 'localhost' : h).displayIn(ref);
    }

    switch (rule.type) {
      case 'dynamic':
        return AppLocalizations.of(context)!.pfPageSocksOn(_listenShown());
      case 'remote':
        return '${hostName.isEmpty ? serviceAt() : hostName}:${rule.remotePort} → localhost:${rule.bindPort}';
      default:
        return '${_listenShown()} → ${serviceAt()}:${rule.remotePort}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final host = _ruleHost(ref, rule);
    final hostName = _hostNameShown(ref, host);
    final state = pfRuleStateFor(active: widget.isActive, errored: widget.errored);
    final (stateWord, stateColor) = switch (state) {
      PfRuleState.stopped => (l10n.zestPfStateStopped, ZestTokens.textTertiary),
      PfRuleState.running => (l10n.zestPfStateRunning, ZestTokens.statusHealthy),
      PfRuleState.error => (l10n.zestPfStateError, ZestTokens.statusCritical),
    };
    final letter = switch (rule.type) {
      'dynamic' => 'D',
      'remote' => 'R',
      _ => 'L',
    };
    final via = [
      if (hostName.isNotEmpty) l10n.pfPageVia(hostName),
      if (rule.autoStart) l10n.pfPageStartsOnConnect,
    ].join(' · ');
    final openable = widget.isActive && rule.type != 'dynamic' && rule.type != 'remote';
    final selected = widget.isSelected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // Reached with Tab, said as picked or not; its menu under Shift+F10, the
      // menu key and a screen reader's action too (4.0, the accessibility
      // pass: it was a bare tap and a right click).
      child: ZestPressable(
          onTap: widget.onSelect,
          onHover: (h) => setState(() => _hover = h),
          onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
          // The right click's menu under a long press too where the controls are
          // touch sized (a tablet, 4.0): a finger has no right button.
          onLongPress: touchSizedAt(context) ? () => _showContextMenu(context, globalCentreOf(context)) : null,
          onContextMenu: () => _showContextMenu(context, globalCentreOf(context)),
          semanticActions: {
            CustomSemanticsAction(label: l10n.zestCommonMoreActions): () => _showContextMenu(context, globalCentreOf(context)),
          },
          checked: widget.selecting ? selected : null,
          selected: !widget.selecting && selected,
          minSize: 0,
          borderRadius: 10,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minHeight: 78),
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            decoration: BoxDecoration(
              color: selected
                  ? ZestTokens.brandSubtle
                  : _hover
                      ? ZestTokens.surfaceRaisedAlt
                      : ZestTokens.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? ZestTokens.brandBorder : ZestTokens.border),
            ),
            child: Row(
              children: [
                if (widget.selecting) ...[
                  SelectBox(key: ValueKey('pf-rule-box-${rule.id}'), checked: selected, size: 16),
                  const SizedBox(width: 12),
                ],
                _TypeSquare(letter: letter),
                const SizedBox(width: 16),
                Expanded(
                  flex: 11,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayNameShown(rule, ref),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                      ),
                      if (via.isNotEmpty || rule.networkId != null) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (host != null) ...[
                              _ConnIcon(host: host, size: 15),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                via,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary),
                              ),
                            ),
                            if (rule.networkId != null) ...[
                              const SizedBox(width: 8),
                              _NetworkPinBadge(networkId: rule.networkId!),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 10,
                  child: Text(
                    _mapping(hostName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontFamily: 'JetBrainsMono', color: ZestTokens.textPrimary),
                  ),
                ),
                const SizedBox(width: 16),
                // The state, the link and the button in a column of their
                // own width, so the names and the mappings line up card to
                // card.
                SizedBox(
                  width: 340,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ZestStatusDot(kind: pfRuleStatusKind(state)),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          stateWord,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: stateColor),
                        ),
                      ),
                      if (openable) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          flex: 2,
                          child: _OpenLink(
                            label: l10n.pfPageOpen('localhost:${rule.bindPort}'),
                            tooltip: '${_webScheme(rule.remotePort)}://localhost:${rule.bindPort}',
                            onTap: () => launchUrl(
                              Uri.parse('${_webScheme(rule.remotePort)}://localhost:${rule.bindPort}'),
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 16),
                      widget.isActive
                          ? ZestButton(
                              key: ValueKey('pf-stop-${rule.id}'),
                              label: l10n.zestPfStop,
                              icon: LucideIcons.square,
                              variant: ZestButtonVariant.secondary,
                              onPressed: () {
                                ref.read(activeSessionsProvider.notifier).stopSavedForward(rule.id);
                                widget.onErroredChanged(false);
                              },
                            )
                          : ZestButton(
                              key: ValueKey('pf-start-${rule.id}'),
                              label: l10n.zestPfStart,
                              icon: LucideIcons.play,
                              variant: ZestButtonVariant.secondary,
                              onPressed: () => startRuleFromPage(context, ref, rule, onErrored: widget.onErroredChanged),
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ),
    );
  }

  // ── Context menu (right-click) ─────────────────────────────────

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final l10n = AppLocalizations.of(context)!;
    // Move to... and Copy to...: Personal, or a team's vault (3.4); a port
    // forward goes with its host.
    final offer = transferOffer(ref, TransferKinds.forward, [rule.id]);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx + 1, position.dy + 1),
      color: AppColors.v3Elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        _menuItem('edit', LucideIcons.pencil, l10n.edit),
        _menuItem('duplicate', LucideIcons.copy, l10n.commonDuplicate),
        if (offer.move) _menuItem('move_to', LucideIcons.folderInput, l10n.transferMoveTo),
        if (offer.copy) _menuItem('copy_to', LucideIcons.copyPlus, l10n.transferCopyTo),
        const PopupMenuDivider(height: 8),
        _menuItem(
            'run_on', LucideIcons.network, l10n.portForwardListMenuRunOnNetwork),
        _menuItem(
          rule.autoStart ? 'disable_auto' : 'enable_auto',
          rule.autoStart ? LucideIcons.pauseCircle : LucideIcons.playCircle,
          rule.autoStart
              ? l10n.portForwardListMenuDisableAutoStart
              : l10n.portForwardListMenuEnableAutoStart,
        ),
        const PopupMenuDivider(height: 8),
        _menuItem('delete', LucideIcons.trash2, l10n.delete,
            isDestructive: true),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'edit':
        widget.onSelect();
      case 'duplicate':
        await _duplicate(ref);
      case 'move_to' || 'copy_to':
        await showMoveCopyDialog(context, ref,
            kind: TransferKinds.forward, keys: [rule.id], mode: action == 'move_to' ? TransferMode.move : TransferMode.copy);
      case 'run_on':
        await _pickNetwork(context, ref);
      case 'enable_auto':
        await _setAutoStart(ref, true);
      case 'disable_auto':
        await _setAutoStart(ref, false);
      case 'delete':
        await _delete(context, ref);
    }
  }

  Future<void> _duplicate(WidgetRef ref) async {
    final dao = ref.read(portForwardRulesDaoProvider);
    await dao.insertRule(PortForwardRulesCompanion(
      id: Value(const Uuid().v4()),
      connectionId: Value(rule.connectionId),
      type: Value(rule.type),
      bindAddress: Value(rule.bindAddress),
      bindPort: Value(rule.bindPort),
      remoteHost: Value(rule.remoteHost),
      remotePort: Value(rule.remotePort),
      autoStart: Value(rule.autoStart),
      reconnect: Value(rule.reconnect),
      exitOnFailure: Value(rule.exitOnFailure),
      gatewayPorts: Value(rule.gatewayPorts),
      sshFlags: Value(rule.sshFlags),
      label: Value(rule.label != null ? '${rule.label!} (copy)' : null),
      networkId: Value(rule.networkId),
      createdAt: Value(DateTime.now()),
    ));
  }

  Future<void> _setAutoStart(WidgetRef ref, bool enabled) async {
    await ref.read(portForwardRulesDaoProvider).updateRule(
        PortForwardRulesCompanion(
            id: Value(rule.id), autoStart: Value(enabled)));
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n
          .portForwardListDeleteConfirmTitle(_displayNameShown(rule, ref)),
      body: l10n.portForwardListDeleteConfirmBody,
      confirmLabel: MaterialLocalizations.of(context).deleteButtonTooltip,
    );
    if (confirmed != true) return;
    try {
      await ref.read(portForwardRulesDaoProvider).deleteRule(rule.id);
    } catch (e) {
      if (context.mounted) showTopSnackBar(context, l10n.portForwardNotDeleted, isError: true, details: '$e');
    }
  }

  Future<void> _pickNetwork(BuildContext context, WidgetRef ref) async {
    final networks = ref.read(allNetworksProvider).valueOrNull ?? const [];
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    // One of a few choices, in the shell (the dialog rules of 3.4): a tap on
    // one chooses it; "All networks" is the empty id. A network's name is in
    // its display form (masked in recording mode).
    const allNetworks = '';
    final chosen = await showZestChoice<String>(
      context,
      title: l10n.portForwardListRunOnNetworkTitle,
      subtitle: l10n.portForwardListRunOnNetworkBody,
      icon: LucideIcons.wifi,
      selected: rule.networkId ?? allNetworks,
      choices: [
        ZestChoice(
          value: allNetworks,
          label: l10n.portForwardListAllNetworks,
          icon: LucideIcons.globe,
          key: const ValueKey('pf-network-all'),
        ),
        for (final n in networks)
          ZestChoice(
            value: n.id,
            label: Redactable.network(n.name).displayIn(ref),
            icon: n.icon,
            key: ValueKey('pf-network-${n.id}'),
          ),
      ],
    );
    final picked = chosen == null ? null : (id: chosen == allNetworks ? null : chosen, clear: chosen == allNetworks);
    if (picked == null) return;
    await ref.read(portForwardRulesDaoProvider).updateRule(
          PortForwardRulesCompanion(
            id: Value(rule.id),
            networkId: Value(picked.clear ? null : picked.id),
          ),
        );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label,
      {bool isDestructive = false}) {
    final color = isDestructive ? AppColors.v3Error : AppColors.v3TextPrimary;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 13, color: color)),
        ],
      ),
    );
  }
}

/// The kind of [type] as stored ('local', 'remote', 'dynamic').
PortForwardType _pfType(String type) => switch (type) {
      'remote' => PortForwardType.remote,
      'dynamic' => PortForwardType.dynamic,
      _ => PortForwardType.local,
    };

/// Starts [rule] from the page (its card's Start, or the editor's Save and
/// start): on the session open to its host, or, where none is, after asking
/// to connect; says why where it did not start. [onErrored] follows whether
/// its last start failed.
Future<void> startRuleFromPage(
  BuildContext context,
  WidgetRef ref,
  PortForwardRule rule, {
  ValueChanged<bool>? onErrored,
}) async {
  final result = await ref.read(activeSessionsProvider.notifier).startSavedForward(rule);
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  switch (result) {
    case StartForwardResult.started:
      onErrored?.call(false);
    case StartForwardResult.noSession:
      // No live session for this host. Offer to open one and then start the
      // forward, instead of dead-ending the user (lildevil's request). The
      // connect-then-start runs in the notifier because this row unmounts the
      // instant the session is created.
      final host = _hostNameShown(ref, _ruleHost(ref, rule));
      final target = host.isNotEmpty ? host : _displayNameShown(rule, ref);
      final confirmed = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.info,
        title: l10n.portForwardListConnectTitle(target),
        body: l10n.portForwardListConnectBody(target),
        confirmLabel: l10n.portForwardListConnectAndStart,
      );
      if (confirmed != true || !context.mounted) return;
      // Fire-and-forget: the notifier connects, waits, starts the forward,
      // and reports the outcome to the notification center on its own.
      ref.read(activeSessionsProvider.notifier).connectThenStartForward(rule);
      showTopSnackBar(context, l10n.portForwardListConnecting(target), isInfo: true);
    case StartForwardResult.error:
      onErrored?.call(true);
      // Why, from what starting it threw, with its details (3.0: before,
      // every failure was said to be the local port in use).
      final error = ref.read(activeSessionsProvider.notifier).lastForwardError(rule.id);
      showTopSnackBar(
        context,
        error == null ? l10n.pfFailedOther : forwardFailureSentence(l10n, error, rule),
        isError: true,
        // Raw: the notice builds the report (scrubbed) from it.
        details: error == null ? null : 'Kind: ${rule.type}, local port ${rule.bindPort}: $error',
      );
    case StartForwardResult.notAllowed:
      showTopSnackBar(context, l10n.orchardForwardNotAllowed, isWarning: true);
  }
}

/// The kind of a rule as ssh's own flag letter (L, R, D), in a small square.
class _TypeSquare extends StatelessWidget {
  const _TypeSquare({required this.letter});

  final String letter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Text(
        letter,
        // Its kind in words to a screen reader ("L" said nothing).
        semanticsLabel: switch (letter) {
          'D' => AppLocalizations.of(context)!.zestPfTypeDynamic,
          'R' => AppLocalizations.of(context)!.zestPfTypeRemote,
          _ => AppLocalizations.of(context)!.zestPfTypeLocal,
        },
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'JetBrainsMono',
          fontWeight: FontWeight.w700,
          color: ZestTokens.textSecondary,
        ),
      ),
    );
  }
}

/// A real link (it opens a page): accent text, underlined.
class _OpenLink extends StatelessWidget {
  const _OpenLink({required this.label, required this.tooltip, required this.onTap});

  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Said as a link, reached with Tab, a mouse's 32 high (it was its
    // line of 19).
    return Tooltip(
      message: tooltip,
      child: ZestPressable(
          onTap: onTap,
          link: true,
          borderRadius: 4,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: ZestTokens.brandInk,
              decoration: TextDecoration.underline,
              decorationColor: ZestTokens.brandInk,
            ),
          ),
      ),
    );
  }
}

/// A host's own icon, as its card draws it.
class _ConnIcon extends ConsumerWidget {
  const _ConnIcon({required this.host, this.size = 16});

  final ConnectionWithDetails host;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HostGlyph(host: host.connection, group: host.group, size: size);
  }
}

/// Badge shown when a rule is pinned to a specific Network.
class _NetworkPinBadge extends ConsumerWidget {
  const _NetworkPinBadge({required this.networkId});

  final String networkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final networks = ref.watch(allNetworksProvider).valueOrNull;
    Network? net;
    if (networks != null) {
      for (final n in networks) {
        if (n.id == networkId) {
          net = n;
          break;
        }
      }
    }
    // The profile name identifies the environment: display form.
    final label = net == null
        ? l10n.portForwardListPinnedBadge
        : Redactable.network(net.name).displayIn(ref);
    final icon = net?.icon ?? LucideIcons.network;
    final color = net?.effectiveColor ?? AppColors.v3TextSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Empty states
// ══════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onNew});

  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.arrowLeftRight,
      title: l10n.portForwardEmptyTitle,
      message: l10n.portForwardEmptyMessage,
      // The empty state's own button, as every page's.
      actionLabel: onNew == null ? null : l10n.zestPfNewLabel,
      onAction: onNew,
    );
  }
}

/// TIER 2 empty state: rules exist but the active search matched none. One
/// short italic line with an inline (non-orange) "Clear search" action. The
/// search field stays visible above, so this is a section-empty row, NOT a
/// full-pane tier-1 block.
class _FilterEmptyState extends StatelessWidget {
  const _FilterEmptyState({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: ZestEmptyRow(
          message: l10n.portForwardFilterEmptyTitle,
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
