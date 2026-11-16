import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/hosts/widgets/hosts_band.dart' show BandMenuRow;
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds;
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/features/selection/list_selection.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart';
import 'package:zestssh/ui/widgets/zest_bottom_nav.dart';

// The keys', snippets' and port forwards' select (3.4) on a computer and a
// phone, drawn with the hosts' pieces (selection_bar.dart) and doing what
// item_selection.dart says a selection does.

/// Select on a list's line (Selecting while it selects): starts and ends
/// selecting the list of [kind]. Its button's key is `<kind>s-select`.
class ItemSelectToggle extends ConsumerWidget {
  const ItemSelectToggle({super.key, required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selecting = ref.watch(itemSelectionProvider(kind)).active;
    return SelectToggleButton(
      buttonKey: ValueKey('${kind}s-select'),
      selecting: selecting,
      tooltip: switch (kind) {
        TransferKinds.key => l10n.selectKeysTip,
        TransferKinds.snippet => l10n.selectSnippetsTip,
        _ => l10n.selectForwardsTip,
      },
      onTap: () {
        final select = ref.read(itemSelectionProvider(kind).notifier);
        selecting ? select.exit() : select.enter();
        // The keys that select reach the list from here on.
        context.findAncestorStateOfType<_ItemSelectionKeysState>()?._takeKeyboard();
      },
    );
  }
}

/// At the head of a list of [kind] while it selects: the box that selects
/// every item shown, or none, how many are selected, and Clear selection.
/// Its parts' keys start with `<kind>-selection`.
class ItemSelectionHead extends ConsumerWidget {
  const ItemSelectionHead({super.key, required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final shown = ref.watch(shownItemIdsProvider(kind));
    final notifier = ref.read(itemSelectionProvider(kind).notifier);
    return SelectionHead(
      keyPrefix: '$kind-selection',
      shown: shown,
      selected: ref.watch(itemSelectionProvider(kind)).selected,
      tooltip: l10n.selectShownTip,
      onSelectShown: () => notifier.addAll(shown),
      onUnselectShown: () => notifier.removeAll(shown),
      onClear: notifier.clearSelection,
    );
  }
}

/// A click on the item [id] of the list of [kind], taken as a selection click
/// where it is one (Ctrl or Cmd adds it, Shift selects a range, a plain click
/// while selecting puts it in or out). [openId] is the item open beside the
/// list, where selecting starts from it. False for a plain click outside
/// selecting, which the list handles as it always did.
bool itemSelectionClick(WidgetRef ref, String kind, String id, {String? openId}) => selectionClick(
      ref.read(itemSelectionProvider(kind).notifier),
      ref.read(itemSelectionProvider(kind)),
      id,
      ref.read(shownItemIdsProvider(kind)),
      openId: openId,
    );

/// The keys of a list of [kind] that selects, as the Hosts page has them:
/// Ctrl+A (Cmd+A on a Mac) selects every item shown, Delete (Backspace on a
/// Mac too) deletes the selected ones once asked, Esc stops selecting. Not
/// Ctrl+A or Delete while the keyboard is in a text field, where they edit
/// the text (Esc is heard there too, after the field's own).
/// The list's own part ([ItemSelectionFocusArea]) takes the keyboard when
/// pressed, so the keys reach it. [beforeChange] runs before a delete (an
/// editor beside the list asks about its changes).
class ItemSelectionKeys extends ConsumerStatefulWidget {
  const ItemSelectionKeys({super.key, required this.kind, required this.child, this.beforeChange});

  final String kind;
  final Widget child;
  final Future<bool> Function()? beforeChange;

  @override
  ConsumerState<ItemSelectionKeys> createState() => _ItemSelectionKeysState();
}

class _ItemSelectionKeysState extends ConsumerState<ItemSelectionKeys> {
  final _focus = FocusNode(debugLabel: 'ItemSelectionKeys');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _takeKeyboard() {
    if (!_focus.hasPrimaryFocus) _focus.requestFocus();
  }

  static bool _typing() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final kind = widget.kind;
    // Esc stops selecting from anywhere on the page, the search field too
    // (where its own Esc comes first), as on the Hosts page.
    if (event.logicalKey == LogicalKeyboardKey.escape && ref.read(itemSelectionProvider(kind)).active) {
      ref.read(itemSelectionProvider(kind).notifier).exit();
      return KeyEventResult.handled;
    }
    if (_typing()) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyA &&
        selectionToggleKeyHeld() &&
        !keys.isShiftPressed &&
        !keys.isAltPressed) {
      final shown = ref.read(shownItemIdsProvider(kind));
      if (shown.isEmpty) return KeyEventResult.ignored;
      ref.read(itemSelectionProvider(kind).notifier).selectAll(shown);
      return KeyEventResult.handled;
    }
    final select = ref.read(itemSelectionProvider(kind));
    final deleteKey = event.logicalKey == LogicalKeyboardKey.delete ||
        (defaultTargetPlatform == TargetPlatform.macOS && event.logicalKey == LogicalKeyboardKey.backspace);
    if (deleteKey && select.active && select.hasSelection) {
      unawaited(_delete());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _delete() async {
    final ids = selectedItemsInOrder(ref, widget.kind);
    if (ids.isEmpty || !mayDeleteAnyOf(ref, widget.kind, ids)) return;
    if (widget.beforeChange != null && (!await widget.beforeChange!() || !mounted)) return;
    await deleteSelection(context, ref, widget.kind, ids);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // Never takes the keyboard by itself (it must not take it from a
      // search field); a press on the list gives it on purpose.
      focusNode: _focus,
      descendantsAreFocusable: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}

/// The part of a list that a press there gives the keyboard to its
/// [ItemSelectionKeys] (the rows, not the search field over them).
class ItemSelectionFocusArea extends StatelessWidget {
  const ItemSelectionFocusArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => context.findAncestorStateOfType<_ItemSelectionKeysState>()?._takeKeyboard(),
      child: child,
    );
  }
}

/// The selection bar of a computer's list of [kind], at the foot of the
/// list while it selects (as the hosts' bar
/// does): the count (a click offers every item shown, or none), what the
/// selection can do, Delete in red, and the close; the keys that select over
/// it. [beforeChange] runs before an action (an editor beside the list asks
/// about its changes); [onForwardErrored] follows a port forward's start.
class ItemSelectionBar extends ConsumerStatefulWidget {
  const ItemSelectionBar({super.key, required this.kind, this.beforeChange, this.onForwardErrored});

  final String kind;
  final Future<bool> Function()? beforeChange;
  final void Function(String id, bool errored)? onForwardErrored;

  @override
  ConsumerState<ItemSelectionBar> createState() => _ItemSelectionBarState();
}

class _ItemSelectionBarState extends ConsumerState<ItemSelectionBar> {
  bool _busy = false;

  Future<void> _run(ItemSelectionAction action) async {
    if (_busy) return;
    if (widget.beforeChange != null && (!await widget.beforeChange!() || !mounted)) return;
    setState(() => _busy = true);
    try {
      await action.run(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showCountMenu(BuildContext anchor) async {
    final l10n = AppLocalizations.of(context)!;
    final box = anchor.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final shown = ref.read(shownItemIdsProvider(widget.kind));
    final pick = await showMenu<String>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: selectionMenuAt(box, overlay),
      items: [
        PopupMenuItem(
          key: const ValueKey('bulk-select-all'),
          value: 'all',
          height: 38,
          child: BandMenuRow(icon: LucideIcons.checkSquare, label: l10n.selectAllShownCount(shown.length)),
        ),
        PopupMenuItem(
          key: const ValueKey('bulk-select-none'),
          value: 'none',
          height: 38,
          child: BandMenuRow(icon: LucideIcons.square, label: l10n.hostsSelSelectNone),
        ),
      ],
    );
    if (!mounted) return;
    final notifier = ref.read(itemSelectionProvider(widget.kind).notifier);
    if (pick == 'all') notifier.selectAll(shown);
    if (pick == 'none') notifier.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final state = ref.watch(itemSelectionProvider(kind));
    if (!state.active) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final ids = selectedItemsInOrder(ref, kind, watch: true);
    final shown = ref.watch(shownItemIdsProvider(kind));
    final on = ids.isNotEmpty && !_busy;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final toggleKey = selectionToggleKeyName();
    final actions = itemSelectionActions(ref, l10n, kind, ids, onForwardErrored: widget.onForwardErrored);
    final delete = actions.where((a) => a.destructive).single;
    return SelectionBarFrame(
      key: ValueKey('$kind-selection-bar'),
      barKey: ValueKey('$kind-bulk-actions'),
      hints: SelectionHints(key: ValueKey('$kind-bulk-hint'), toggleKey: toggleKey),
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, end: 10),
          child: SelectionCountLabel(
            label: l10n.hostBulkActionSelectedCount(ids.length),
            tooltip: '${l10n.selectAllShownCount(shown.length)} ($toggleKey+A)',
            onTap: _showCountMenu,
          ),
        ),
        for (final a in actions)
          if (!a.destructive)
            SelectionBarItem(
              key: ValueKey('bulk-${a.id}'),
              icon: a.icon,
              label: a.label,
              enabled: on && a.enabled,
              onTap: () => unawaited(_run(a)),
            ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const SelectionBarDivider(),
          SelectionBarItem(
            key: const ValueKey('bulk-delete'),
            icon: delete.icon,
            label: delete.label,
            enabled: on && delete.enabled,
            destructive: true,
            showIcon: false,
            shortcut: mac ? '⌫' : 'Del',
            onTap: () => unawaited(_run(delete)),
          ),
        ]),
        SelectionBarItem(
          key: const ValueKey('bulk-done'),
          icon: LucideIcons.x,
          label: l10n.done,
          iconOnly: true,
          enabled: !_busy,
          shortcut: 'Esc',
          onTap: () => ref.read(itemSelectionProvider(kind).notifier).exit(),
        ),
      ],
    );
  }
}

/// The top bar while a phone's list of [kind] selects: the close, how many
/// are selected, and Select all shown.
class PhoneItemSelectionAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const PhoneItemSelectionAppBar({super.key, required this.kind});

  final String kind;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.watch(shownItemIdsProvider(kind));
    final notifier = ref.read(itemSelectionProvider(kind).notifier);
    return PhoneSelectionAppBar(
      count: selectedItemsInOrder(ref, kind, watch: true).length,
      onClose: notifier.exit,
      onSelectAll: shown.isEmpty ? null : () => notifier.addAll(shown),
    );
  }
}

/// The tab bar while a phone's list of [kind] selects (the hosts' way: the
/// tabs become the selection's actions): what it can do, Delete, and, with
/// one item selected and [onItemActions] given, More, that item's own sheet
/// (what a long press offered before it started selecting).
class PhoneItemSelectionBar extends ConsumerWidget {
  const PhoneItemSelectionBar({super.key, required this.kind, this.onItemActions});

  final String kind;
  final void Function(String id)? onItemActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final ids = selectedItemsInOrder(ref, kind, watch: true);
    final actions = itemSelectionActions(ref, l10n, kind, ids);
    final more = onItemActions != null && ids.length == 1;
    return ZestBottomNav(
      key: const ValueKey('phone-selection-actions'),
      selectedIndex: 0,
      onDestinationSelected: (i) {
        if (ids.isEmpty) return;
        if (i < actions.length) {
          // One with nothing to do says why, or does nothing (Start where
          // all of them run).
          unawaited(actions[i].run(context));
          return;
        }
        // The one item's own sheet: selecting is over.
        ref.read(itemSelectionProvider(kind).notifier).exit();
        onItemActions!(ids.single);
      },
      items: [
        for (final a in actions)
          ZestNavItem(icon: a.icon, selectedIcon: a.icon, label: a.shortLabel ?? a.label),
        if (more)
          ZestNavItem(
            icon: LucideIcons.moreHorizontal,
            selectedIcon: LucideIcons.moreHorizontal,
            label: kind == TransferKinds.key ? l10n.selectKeyActions : l10n.selectSnippetActions,
          ),
      ],
    );
  }
}

/// A phone's list's line for selected items its search hides, with Show
/// ([onShow] empties the search).
class PhoneSelectionHiddenLine extends ConsumerWidget {
  const PhoneSelectionHiddenLine({super.key, required this.kind, required this.onShow});

  final String kind;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(itemSelectionProvider(kind));
    if (!state.active) return const SizedBox.shrink();
    final shown = ref.watch(shownItemIdsProvider(kind)).toSet();
    final hidden = selectedItemsInOrder(ref, kind, watch: true).where((id) => !shown.contains(id)).length;
    if (hidden == 0) return const SizedBox.shrink();
    return SelectionHiddenRow(
      key: const ValueKey('phone-selection-hidden'),
      text: AppLocalizations.of(context)!.selectHiddenBySearch(hidden),
      onShow: onShow,
    );
  }
}

/// The colour a selected row of a phone's list is tinted with.
Color phoneSelectedTint() => ZestTokens.brand.withValues(alpha: 0.08);
