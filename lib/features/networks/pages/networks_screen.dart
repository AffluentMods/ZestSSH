import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/network_providers.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/edit_drafts.dart';
import '../../../ui/widgets/top_snackbar.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../../../ui/widgets/zest_master_detail.dart';
import '../models/network.dart';
import '../state/network_controller.dart';
import '../widgets/network_detail_pane.dart';
import '../widgets/network_list_pane.dart';

/// Sentinel selection id used while creating a brand-new network (before it
/// has a real id).
const String _kNewSelection = '__new__';

/// The Networks editor's unsaved edits while its page is away ([EditDrafts]):
/// the editor itself, kept as it was, by the network's id (or the new
/// network's key). A network holds nothing secret. A kept editor that is let
/// go is disposed.
final networkDraftsProvider = editDraftsProvider<NetworkEditController>(onForget: (c) => c.dispose());

/// The 1.7 desktop Networks screen - the REFERENCE master/detail refactor.
///
/// A [ZestMasterDetail] shell: the [NetworkListPane] on the left, the
/// [NetworkDetailPane] on the right. All editor state, the dirty guard and the
/// Simple/Advanced invariants live in one [NetworkEditController]; the screen
/// owns selection + the repository I/O the controller deliberately avoids.
class NetworksScreen extends ConsumerStatefulWidget {
  const NetworksScreen({super.key});

  @override
  ConsumerState<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends ConsumerState<NetworksScreen>
    with KeepsEditDrafts<NetworksScreen, NetworkEditController> {
  late final NetworkEditController _controller;

  /// null = nothing open; [_kNewSelection] = creating; else the network id.
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    // Unsaved edits kept as the page went (a terminal was shown in its
    // place): the same editor comes back, with them, as unsaved. A change of
    // profile builds the drafts anew, empty, and the form open here goes.
    final kept = takeEditDraft(networkDraftsProvider, onRenewed: () {
      _controller.bind(null, overrideRows: const [], mode: EditorMode.simple);
      setState(() => _selectedId = _kNewSelection);
    });
    _controller = kept ?? NetworkEditController();
    if (kept != null) {
      _selectedId = kept.original?.id ?? _kNewSelection;
    } else {
      // The detail pane always shows the editor, so start on a blank NEW
      // network - the right side is ready to fill out by default (no empty
      // state).
      _controller.bind(null, overrideRows: const [], mode: EditorMode.simple);
      _selectedId = _kNewSelection;
    }
    // Rebuild the screen (list ordinals + detail chrome) when editor state
    // changes - chiefly the Simple/Advanced mode and the dirty flag.
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Going with unsaved edits (the shell shows a terminal in this page's
    // place): the editor is kept, in memory, for when the page comes back.
    final kept = _controller.isDirty && keepEditDraft(_controller.original?.id ?? _kNewSelection, _controller);
    if (!kept) _controller.dispose();
    super.dispose();
  }

  bool get _hasSelection => _selectedId != null;

  // ── Selection / creation (all run the discard guard first) ─────────

  Future<void> _select(String id, {required bool narrow}) async {
    if (_selectedId == id) return;
    final proceed =
        await _controller.confirmDiscardIfDirty(context, onSave: _save);
    if (!proceed || !mounted) return;
    if (!await _bind(id)) return;
    setState(() => _selectedId = id);
    if (narrow && mounted) await _pushDetailRoute();
  }

  Future<void> _createNew({required bool narrow}) async {
    final proceed =
        await _controller.confirmDiscardIfDirty(context, onSave: _save);
    if (!proceed || !mounted) return;
    _controller.bind(null, overrideRows: const [], mode: EditorMode.simple);
    setState(() => _selectedId = _kNewSelection);
    if (narrow && mounted) await _pushDetailRoute();
  }

  /// Load a network (+ its overrides + remembered mode) into the controller.
  Future<bool> _bind(String id) async {
    final networks = ref.read(allNetworksProvider).valueOrNull ?? const [];
    Network? net;
    for (final n in networks) {
      if (n.id == id) {
        net = n;
        break;
      }
    }
    if (net == null) return false;
    final overrides = await ref
        .read(hostNetworkOverridesRepositoryProvider)
        .listForNetwork(id);
    final mode = await NetworkEditModePrefs.load(id);
    if (!mounted) return false;
    _controller.bind(net, overrideRows: overrides, mode: mode);
    return true;
  }

  Future<void> _close() async {
    final proceed =
        await _controller.confirmDiscardIfDirty(context, onSave: _save);
    if (!proceed || !mounted) return;
    // Reset to a blank new network rather than an empty pane.
    _controller.bind(null, overrideRows: const [], mode: EditorMode.simple);
    setState(() => _selectedId = _kNewSelection);
  }

  // ── Persistence ────────────────────────────────────────────────────

  Future<bool> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final nameErr = _controller.validateName(l10n);
    final triggersErr = _controller.validateTriggers(l10n);
    if (nameErr != null || triggersErr != null) {
      _controller.setErrors(name: nameErr, triggers: triggersErr);
      return false;
    }

    final repo = ref.read(networkRepositoryProvider);
    final id = _controller.original?.id ?? const Uuid().v4();
    final network = _controller.buildNetwork(id);
    try {
      if (_controller.isCreating) {
        await repo.create(network);
      } else {
        await repo.update(network);
      }
      await _persistOverrides(network.id);
      await NetworkEditModePrefs.save(network.id, _controller.mode);
    } catch (e) {
      // In the app's language, with what was thrown to copy (it was English
      // with the raw error glued on).
      if (mounted) {
        showTopSnackBar(context, l10n.networkNotSaved, isError: true, details: '$e');
      }
      return false;
    }
    _controller.markSaved(network);
    if (mounted) setState(() => _selectedId = network.id);
    return true;
  }

  /// Apply the override drafts: delete removed rows, upsert non-empty drafts,
  /// and drop any draft that has become a no-op.
  Future<void> _persistOverrides(String networkId) async {
    final repo = ref.read(hostNetworkOverridesRepositoryProvider);
    for (final removedId in _controller.removedOverrideIds) {
      await repo.delete(removedId);
    }
    for (final draft in _controller.overrides) {
      if (draft.isEmptyDraft) {
        if (draft.existingId != null) {
          await repo.delete(draft.existingId!);
          draft.existingId = null;
        }
      } else {
        final saved = await repo.upsert(draft.toModel(networkId));
        draft.existingId = saved.id;
      }
    }
  }

  Future<void> _delete() async {
    final net = _controller.original;
    if (net == null || net.isFallback) return;
    final l10n = AppLocalizations.of(context)!;
    final count = ref
            .read(overrideCountsByNetworkProvider)
            .valueOrNull?[net.id] ??
        0;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      // Built outside build: the display form is a snapshot (recording mode).
      title: l10n.networksDeleteTitle(Redactable.network(net.name).display),
      body: count > 0
          ? l10n.networksDeleteWarningCount(count)
          : l10n.networksDeleteBody,
      confirmLabel: l10n.networksDelete,
      cancelLabel: l10n.networkEditorCancel,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(networkRepositoryProvider).delete(net.id);
    } catch (e) {
      if (mounted) showTopSnackBar(context, l10n.networkNotDeleted, isError: true, details: '$e');
      return;
    }
    if (!mounted) return;
    // Reset to a blank new network so the deleted network's now-stale draft
    // can't later prompt a spurious "save?" and re-insert orphan override rows.
    _controller.bind(null, overrideRows: const [], mode: EditorMode.simple);
    setState(() => _selectedId = _kNewSelection);
  }

  void _onModeChanged(EditorMode mode) {
    _controller.setMode(mode);
    final id = _controller.original?.id;
    // A saved network persists its preference immediately; a brand-new one
    // records it at save time (under its freshly-minted id).
    if (id != null) unawaited(NetworkEditModePrefs.save(id, mode));
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
          child: NetworkDetailPane(
            controller: _controller,
            hasSelection: true,
            // narrow:false → rebuild the already-mounted route in place
            // instead of pushing a second, duplicate detail route.
            onNew: () => _createNew(narrow: false),
            onSave: _save,
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
              // _delete nulls _selectedId on success; pop the route directly
              // (bypassing PopScope) so it can't linger on the deleted network.
              if (_selectedId == null && routeContext.mounted) {
                Navigator.of(routeContext).pop();
              }
            },
            onModeChanged: _onModeChanged,
          ),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────

  /// A new network for where this device is (ACTIVE NOW's button): its
  /// Wi-Fi's name as the rule where it is known, else its subnet.
  Future<void> _makeFor(CurrentNetworkSuggestion here, {required bool narrow}) async {
    await _createNew(narrow: false);
    if (!mounted || _selectedId != _kNewSelection) return;
    _controller.startFor(here);
    if (narrow && mounted) await _pushDetailRoute();
  }

  @override
  Widget build(BuildContext context) {
    // If the open network vanished from under us (deleted elsewhere), close.
    _reconcileSelection();

    // The page: the
    // networks with their own header (title, New network, filter), and the
    // editor the full height beside them.
    return ColoredBox(
      color: ZestTokens.surfaceBase,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < ZestSizing.singleColumnBreakpoint;
          return ZestMasterDetail(
            screenId: 'networks_rules',
            initialRatio: 0.68,
            listPane: NetworkListPane(
              selectedId: _selectedId,
              onSelect: (id) => _select(id, narrow: narrow),
              onNew: () => _createNew(narrow: narrow),
              draft: _controller,
              onMakeFor: (here) => _makeFor(here, narrow: narrow),
            ),
            detailPane: NetworkDetailPane(
              controller: _controller,
              hasSelection: _hasSelection,
              onNew: () => _createNew(narrow: narrow),
              onSave: _save,
              onClose: _close,
              onDelete: _delete,
              onModeChanged: _onModeChanged,
            ),
          );
        },
      ),
    );
  }

  /// Drop the selection if the currently-open, saved network no longer exists.
  void _reconcileSelection() {
    final id = _selectedId;
    if (id == null || id == _kNewSelection) return;
    final networks = ref.watch(allNetworksProvider).valueOrNull;
    if (networks == null) return;
    if (!networks.any((n) => n.id == id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedId == id) {
          _controller.bind(null, overrideRows: const [], mode: EditorMode.simple);
          setState(() => _selectedId = _kNewSelection);
        }
      });
    }
  }
}
