import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/network_providers.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_button.dart';
import '../../../ui/widgets/zest_detail_scaffold.dart';
import '../../../ui/widgets/zest_mode_toggle.dart';
import '../state/network_controller.dart';
import 'network_advanced_form.dart';
import 'network_simple_form.dart';

/// The right-hand detail pane of the 1.7 Networks master/detail. Composes the
/// [ZestDetailScaffold] (sticky footer, dirty dot, close X) + the
/// Simple/Advanced [ZestModeToggle] + the active form. Rebuilds from the
/// [NetworkEditController] so the title, dirty state, mode and forms stay live.
///
/// An empty detail (nothing selected) is the shared [ZestEmptyState] with a
/// large "+ New network" primary action - never a blank pane.
class NetworkDetailPane extends ConsumerWidget {
  const NetworkDetailPane({
    super.key,
    required this.controller,
    required this.hasSelection,
    required this.onNew,
    required this.onSave,
    required this.onClose,
    required this.onDelete,
    required this.onModeChanged,
  });

  final NetworkEditController controller;

  /// Whether a network is currently bound for editing.
  final bool hasSelection;

  /// Start a brand-new network (runs the dirty guard first).
  final VoidCallback onNew;

  /// Persist. Returns true on success. Fired by the footer Save and by the
  /// discard dialog's Save.
  final Future<bool> Function() onSave;

  /// Close the editor - the X and the footer Cancel (runs the dirty guard).
  final VoidCallback onClose;

  /// Delete the bound network (existing, non-fallback only).
  final VoidCallback onDelete;

  /// Switch Simple/Advanced (persists the per-network preference).
  final ValueChanged<EditorMode> onModeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The detail pane is ALWAYS the editor now - a blank/creating controller
    // renders a ready-to-fill "new" form, so there is no empty state. Clearing
    // (footer) or deleting simply rebinds a blank new one.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _editor(context, ref),
    );
  }

  Widget _editor(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // The header names the network (typed or saved) and quotes its subnets and
    // SSIDs in the match expression: both painted in their display form
    // (recording mode).
    final typed = controller.nameController.text.trim();
    final rawTitle = typed.isNotEmpty
        ? typed
        : (controller.isCreating ? null : controller.original!.name);
    final title = rawTitle == null
        ? l10n.zestNetworkNewLabel
        : Redactable.network(rawTitle).displayIn(ref);

    final showDelete = !controller.isCreating && !controller.isFallback;

    // Header identity: the network's OWN icon in a neutral tile, a
    // match-position / state badge, and the derived match expression as a mono
    // subtitle - hidden until there is something to match on, since an empty
    // expression is noise (§3.7).
    final hasMatch = controller.triggers.isNotEmpty || controller.isFallback;
    final matchExpr = Redactable.freeText(
      derivedMatchExpression(
        controller.triggers,
        isFallback: controller.isFallback,
        displaySsid: (s) => Redactable.network(s).displayIn(ref),
      ),
    ).displayIn(ref);

    return ZestDetailScaffold(
      title: title,
      icon: controller.icon,
      // A neutral tile, as every editor's header (the network's colour is
      // its colour row's choice; it made the header a blue one).
      iconColor: ZestTokens.textSecondary,
      iconBackground: ZestTokens.surfaceChip,
      badge: _headerBadge(l10n),
      subtitle: hasMatch ? matchExpr : null,
      subtitleMono: true,
      modeToggle: _modeToggle(context),
      isDirty: controller.isDirty,
      onSave: () => onSave(),
      // "Save network" and Cancel, as the design
      // has them; Cancel closes the editor (with the dirty guard first).
      saveLabel: l10n.netEdSave,
      onCancel: onClose,
      onClose: onClose,
      footerLeading: showDelete
          ? ZestButton(
              label: l10n.networkEditorDelete,
              icon: LucideIcons.trash2,
              variant: ZestButtonVariant.danger,
              size: ZestButtonSize.large,
              onPressed: onDelete,
            )
          : null,
      body: controller.mode == EditorMode.simple
          ? NetworkSimpleForm(controller: controller)
          : NetworkAdvancedForm(controller: controller),
    );
  }

  /// The small header badge right of the title: a match-position pill for a
  /// saved, ordered network, or the "always (fallback)" state for the Default
  /// network. A brand-new (unsaved) network has no position yet → no badge.
  Widget? _headerBadge(AppLocalizations l10n) {
    if (controller.isCreating) return null;
    if (controller.isFallback) {
      return ZestDetailBadge(
        label: l10n.networksTriggerSummaryAlways,
        color: ZestTokens.textSecondary,
        background: ZestTokens.surfaceChipStrong,
      );
    }
    return _MatchPositionBadge(networkId: controller.original!.id);
  }

  Widget _modeToggle(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final blockedReason = controller.simpleBlockedReason(l10n);
    return ZestModeToggle(
      selectedId: controller.mode.name,
      onChanged: (id) => onModeChanged(
        id == EditorMode.advanced.name
            ? EditorMode.advanced
            : EditorMode.simple,
      ),
      segments: [
        ZestModeSegment(
          id: EditorMode.simple.name,
          label: l10n.zestModeSimple,
          enabled: blockedReason == null,
          disabledReason: blockedReason,
        ),
        ZestModeSegment(
          id: EditorMode.advanced.name,
          label: l10n.zestModeAdvanced,
        ),
      ],
    );
  }
}

/// The header match-position badge ("2 of 4") for a saved, non-fallback
/// network. Reads the live network order so it tracks reorders, mirroring the
/// position maths in the Advanced form's match-order row.
class _MatchPositionBadge extends ConsumerWidget {
  const _MatchPositionBadge({required this.networkId});

  final String networkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final networks = ref.watch(allNetworksProvider).valueOrNull ?? const [];
    final nonFallback =
        networks.where((n) => !n.isFallback).toList(growable: false);
    final idx = nonFallback.indexWhere((n) => n.id == networkId);
    if (idx < 0) return const SizedBox.shrink();
    return ZestDetailBadge(
      label: l10n.zestNetworkMatchPositionBadge(idx + 1, nonFallback.length),
      color: ZestTokens.textSecondary,
      background: ZestTokens.surfaceChipStrong,
    );
  }
}
