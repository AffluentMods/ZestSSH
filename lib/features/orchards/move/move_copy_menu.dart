import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart';
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart' show RedactableDisplay;
import 'package:zestssh/ui/widgets/top_snackbar.dart';

// An editor's Move or copy (4.0: a dropdown at the top right
// of the places there is access to, Personal and each team, a team picked
// and then a vault, then move or duplicate): a button in
// the header of the editor of a saved item opens a menu of the places it can
// go, Personal and each team with its vaults, the place it is in marked and
// not offered; under a place, Move here and Copy here. Either opens the one
// place picker's dialog with the place picked already (showMoveCopyDialog),
// so the questions, the rules and the line that says what was done are the
// ones Move to... and Copy to... have. "Copy", not "Duplicate": Duplicate is
// the app's word for a copy in the same place, Copy to... for one elsewhere.

/// Builds the button the menu hangs from, in the look of the editor's header:
/// [open] opens the menu, [label] is its tooltip and what a screen reader
/// says, and [focusNode] goes on the button (the menu hands focus back to it).
typedef MoveCopyButtonBuilder = Widget Function(
  BuildContext context,
  VoidCallback open,
  String label,
  FocusNode focusNode,
);

/// The Move or copy button of the editor of the saved item [itemKey] of
/// [kind] (one of [TransferKinds]) in the space on screen. Not shown where
/// there is nowhere else to put it (no team, teams off) or where it may go
/// nowhere ([transferOffer]); a new item has "Save in" instead and no button.
class MoveCopyMenuButton extends ConsumerStatefulWidget {
  const MoveCopyMenuButton({
    super.key,
    required this.kind,
    required this.itemKey,
    this.onMoved,
    this.hasUnsavedChanges,
    this.builder,
    this.iconSize,
    this.color,
  });

  final String kind;
  final String itemKey;

  /// After the item moved (it is not here any more): the editor closes.
  final VoidCallback? onMoved;

  /// Whether the editor holds changes not saved: then the menu does not open
  /// and a line says to save first (what moves is what is saved).
  final bool Function()? hasUnsavedChanges;

  /// The button; null: an [IconButton] of [iconSize] in [color] (null: the
  /// app bar's or the theme's).
  final MoveCopyButtonBuilder? builder;
  final double? iconSize;
  final Color? color;

  @override
  ConsumerState<MoveCopyMenuButton> createState() => _MoveCopyMenuButtonState();
}

class _MoveCopyMenuButtonState extends ConsumerState<MoveCopyMenuButton> {
  final _menu = MenuController();
  final _buttonFocus = FocusNode(debugLabel: 'move-copy-button');
  final _firstFocus = FocusNode(debugLabel: 'move-copy-first');

  @override
  void dispose() {
    _buttonFocus.dispose();
    _firstFocus.dispose();
    super.dispose();
  }

  void _open() {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    if (widget.hasUnsavedChanges?.call() ?? false) {
      showTopSnackBar(context, AppLocalizations.of(context)!.moveCopyMenuSaveFirst, isInfo: true);
      return;
    }
    _menu.open();
    // Opened from the keyboard: on its first place, so the arrows go on
    // from there (a mouse's menu opens with nothing lit).
    if (FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _menu.isOpen) _firstFocus.requestFocus();
      });
    }
  }

  Future<void> _go(PlaceChoice place, TransferMode mode) async {
    final result = await showMoveCopyDialog(context, ref,
        kind: widget.kind, keys: [widget.itemKey], mode: mode, to: place);
    if (!mounted) return;
    if (mode == TransferMode.move && result != null && result.done > 0) widget.onMoved?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!kOrchardsEnabled) return const SizedBox.shrink();
    // What the offer is made of, watched: the button comes and goes with a
    // team, a vault, the space on screen and where the item is.
    ref.watch(activeSpaceProvider);
    ref.watch(activeOrchardProvider);
    ref.watch(itemCratesProvider(widget.kind));
    final l10n = AppLocalizations.of(context)!;
    final places = savePlaces(ref, l10n);
    final offer = transferOffer(ref, widget.kind, [widget.itemKey]);
    if (!offer.move && !offer.copy) return const SizedBox.shrink();
    final here = placesOf(ref, widget.kind, [widget.itemKey]);
    final current = here.length == 1 ? here.single : null;
    final label = l10n.moveCopyMenuButton;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _buttonFocus,
      alignmentOffset: const Offset(0, 4),
      style: _menuStyle,
      menuChildren: _items(context, l10n, places, current, offer),
      child: KeyedSubtree(
        key: const ValueKey('move-copy-button'),
        child: widget.builder?.call(context, _open, label, _buttonFocus) ??
            IconButton(
              focusNode: _buttonFocus,
              icon: Icon(LucideIcons.folderInput, size: widget.iconSize),
              color: widget.color,
              tooltip: label,
              onPressed: _open,
            ),
      ),
    );
  }

  MenuStyle get _menuStyle => MenuStyle(
        backgroundColor: WidgetStatePropertyAll(ZestTokens.surfaceRaised),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ZestTokens.border),
        )),
      );

  List<Widget> _items(
    BuildContext context,
    AppLocalizations l10n,
    List<PlaceChoice> places,
    SavePlace? current,
    ({bool move, bool copy}) offer,
  ) {
    final touch = touchSizedAt(context);
    final itemSize = Size(touch ? 240 : 220, touch ? 48 : 34);
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: touch ? 15 : 13);
    var first = true;
    FocusNode? firstNode() {
      if (!first) return null;
      first = false;
      return _firstFocus;
    }

    String id(SavePlace p) => '${p.orchardId ?? 'personal'}-${p.crateId ?? ''}';

    Widget placeEntry(PlaceChoice p) {
      final icon = Icon(
        p.team == null ? LucideIcons.user : (p.ownersOnly ? LucideIcons.lock : LucideIcons.package),
        size: 15,
      );
      final name = Text(Redactable.freeText(p.name).displayIn(ref), maxLines: 1, overflow: TextOverflow.ellipsis);
      // Where it is now: said, not offered.
      if (p.place == current) {
        return MenuItemButton(
          key: ValueKey('move-copy-place-${id(p.place)}'),
          leadingIcon: icon,
          trailingIcon: Text(l10n.transferHere, style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary)),
          style: MenuItemButton.styleFrom(textStyle: textStyle, minimumSize: itemSize),
          onPressed: null,
          child: name,
        );
      }
      return SubmenuButton(
        key: ValueKey('move-copy-place-${id(p.place)}'),
        focusNode: firstNode(),
        leadingIcon: icon,
        menuStyle: _menuStyle,
        style: SubmenuButton.styleFrom(textStyle: textStyle, minimumSize: itemSize),
        menuChildren: [
          MenuItemButton(
            key: ValueKey('move-copy-move-${id(p.place)}'),
            leadingIcon: const Icon(LucideIcons.folderInput, size: 15),
            style: MenuItemButton.styleFrom(textStyle: textStyle, minimumSize: itemSize),
            onPressed: offer.move ? () => _go(p, TransferMode.move) : null,
            child: Text(l10n.moveCopyMenuMoveHere),
          ),
          MenuItemButton(
            key: ValueKey('move-copy-copy-${id(p.place)}'),
            leadingIcon: const Icon(LucideIcons.copyPlus, size: 15),
            style: MenuItemButton.styleFrom(textStyle: textStyle, minimumSize: itemSize),
            onPressed: offer.copy ? () => _go(p, TransferMode.copy) : null,
            child: Text(l10n.moveCopyMenuCopyHere),
          ),
        ],
        child: name,
      );
    }

    // Personal, then each team (in the picker's order) with its vaults.
    final teams = <String, List<PlaceChoice>>{};
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Text(
          l10n.moveCopyMenuHead.toUpperCase(),
          style: TextStyle(fontSize: 10.5, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: ZestTokens.textTertiary),
        ),
      ),
    ];
    for (final p in places) {
      final team = p.place.orchardId;
      if (team == null) {
        children.add(placeEntry(p));
      } else {
        teams.putIfAbsent(team, () => []).add(p);
      }
    }
    for (final MapEntry(key: team, value: vaults) in teams.entries) {
      children.add(SubmenuButton(
        key: ValueKey('move-copy-team-$team'),
        focusNode: firstNode(),
        leadingIcon: const Icon(LucideIcons.users, size: 15),
        menuStyle: _menuStyle,
        style: SubmenuButton.styleFrom(textStyle: textStyle, minimumSize: itemSize),
        menuChildren: [for (final v in vaults) placeEntry(v)],
        child: Text(Redactable.freeText(vaults.first.team!).displayIn(ref), maxLines: 1, overflow: TextOverflow.ellipsis),
      ));
    }
    return children;
  }
}
