import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/hosts/widgets/group_tiles.dart' show hostDragActive;
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/host_card_settings_provider.dart';
import '../models/host_card_settings.dart' show HostCardDensity;
import 'package:zestssh/ui/widgets/redacted_text.dart';

import 'package:zestssh/utils/logger.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../core/theme/zest_colors.dart';
import '../../workspaces/widgets/workspace_identity.dart';
import '../state/host_multi_select.dart';
import 'host_card.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// Drop-in replacement for the plain `Wrap` of [HostCard]s on the Hosts
/// home page. Adds rubber-band selection and file-manager clicks on top of
/// the click-to-connect / right-click-to-menu / tap-to-toggle behaviour.
///
/// Behaviour matrix (matches Finder / file-manager conventions):
/// * **Plain drag from empty space** (between the cards, beside them, or
///   below the last row down to [minHeight]) → live-updates a fresh
///   selection to whatever the rectangle overlaps.
/// * **Ctrl- or Shift-drag from empty space** (Cmd on a Mac) → adds the
///   rectangle's overlaps to the existing selection (live).
/// * **Ctrl-click** (Cmd-click) a card → in or out of the selection, the
///   card is not opened; **Shift-click** → the range from the card clicked
///   last, in the order shown ([hostSelectionClick]).
/// * **Drag from a card** → never starts a band. The card drags: a card of
///   a selection of several carries all of them (onto a group tile), else
///   the card alone.
///
/// Cards' own gesture detectors keep working - the band only fires once
/// the pan recogniser passes its slop threshold AND the pointer-down
/// landed on empty space.
class HostGridArea extends ConsumerStatefulWidget {
  const HostGridArea({
    super.key,
    required this.hostCards,
    required this.itemWidth,
    this.compact = false,
    required this.onConnect,
    required this.onShowContextMenu,
    this.onEdit,
    this.onNewConnection,
    this.onReorder,
    this.selectedHostId,
    this.onSelect,
    this.onSelectionGesture,
    this.minHeight = 0,
  });

  /// A click or a band changed the selection: the page takes the keyboard,
  /// so Escape and Ctrl+A reach it.
  final VoidCallback? onSelectionGesture;

  /// At least this tall: the page passes the room left below the cards, so
  /// a band can start in the empty space under the last row too.
  final double minHeight;

  /// Cards to render. Order is preserved; the parent is responsible for
  /// any filtering / sorting upstream.
  final List<({HostCardData data, ConnectionWithDetails connectionWithDetails})>
      hostCards;

  /// Width of each card. Matches the host home grid's responsive math.
  final double itemWidth;

  /// The compact grid: every card at its compact size.
  final bool compact;

  /// Plain tap on a card outside selection mode. Inside selection mode
  /// the card toggles itself - the parent doesn't see those taps.
  final ValueChanged<ConnectionWithDetails> onConnect;

  /// Right-click / long-press on a card. The Offset is in *global*
  /// coordinates (suitable for [showMenu]'s `position` argument).
  final void Function(
    Offset globalPosition,
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry,
  ) onShowContextMenu;

  /// Hover-revealed edit-pencil click. When null, the pencil doesn't
  /// render - useful for views (e.g. Recently Connected) where editing
  /// would be a confusing affordance.
  final void Function(
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry,
  )? onEdit;

  /// When set, a dashed "New Connection" tile trails the last card in the
  /// grid flow (so it sits right after the final host, not on its own row).
  /// Null hides it. The parent only sets it for the LAST grid on the page
  /// (the flat grid, or the last group section) so it appears exactly once.
  /// It is also suppressed while a multi-select is active.
  final VoidCallback? onNewConnection;

  /// The host open in the page's panel (highlighted).
  final String? selectedHostId;

  /// Set on desktop: a click selects the host (the page opens its panel) and
  /// a double click connects. Null keeps click-to-connect.
  final ValueChanged<ConnectionWithDetails>? onSelect;

  /// When set, cards become drop targets for each other so a host can be
  /// dragged straight onto another to reorder them in place (Start-menu
  /// style), no separate "Arrange" mode. Fires `(draggedId, targetId)` for a
  /// drop of one card onto another within THIS grid. Null disables reordering
  /// (e.g. any non-manual sort, where a manual order would just be overwritten
  /// on the next sort). Cross-grid drops are rejected; group reassignment
  /// stays on the sidebar group chips. Suppressed during multi-select.
  final void Function(String draggedId, String targetId)? onReorder;

  @override
  ConsumerState<HostGridArea> createState() => _HostGridAreaState();
}

class _HostGridAreaState extends ConsumerState<HostGridArea> {
  // Drag state - null when no rubber-band is active.
  Offset? _dragStart;
  Offset? _dragCurrent;
  Set<String> _initialSelection = const {};

  /// Stable GlobalKey per connection id so we can resolve each card's
  /// rendered RenderBox at hit-test time. Keyed by id (not index) so
  /// the keys survive list re-orderings caused by filters / sorts.
  final Map<String, GlobalKey> _cardKeys = {};

  /// Container key - anchor for converting global drag coords to local.
  final GlobalKey _containerKey = GlobalKey();

  /// Ctrl (Cmd) or Shift is held. While it is, a card answers a click on
  /// its release alone (no press-to-open, no double click), so a selection
  /// click is taken at once and never also opens the host.
  bool _selectionKeyHeld = false;

  /// The hosts being dragged now (dimmed in place), empty when none is.
  Set<String> _dragging = const {};

  @override
  void initState() {
    super.initState();
    _selectionKeyHeld = hostSelectionKeyHeld();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent _) {
    final held = hostSelectionKeyHeld();
    if (held != _selectionKeyHeld && mounted) setState(() => _selectionKeyHeld = held);
    return false;
  }

  /// A click on a card that is not a selection click: the page's panel on a
  /// computer, else connect.
  void _tap(({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry) {
    final order = [for (final e in widget.hostCards) e.data.id];
    if (hostSelectionClick(ref, entry.data.id, order, panelHostId: widget.selectedHostId)) {
      widget.onSelectionGesture?.call();
      return;
    }
    if (widget.onSelect != null) {
      widget.onSelect!(entry.connectionWithDetails);
    } else {
      widget.onConnect(entry.connectionWithDetails);
    }
  }

  /// A card's drag: at once under a mouse, after a long press under a finger
  /// (touch sized, 4.0), whose drag scrolls the page.
  Widget _cardDraggable({
    required bool touch,
    required Key key,
    required ConnectionWithDetails data,
    required VoidCallback onDragStarted,
    required void Function(DraggableDetails) onDragEnd,
    required Widget feedback,
    required Widget childWhenDragging,
    required Widget child,
  }) {
    if (touch) {
      return LongPressDraggable<ConnectionWithDetails>(
        key: key,
        data: data,
        onDragStarted: onDragStarted,
        onDragEnd: onDragEnd,
        feedback: feedback,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        childWhenDragging: childWhenDragging,
        child: child,
      );
    }
    return Draggable<ConnectionWithDetails>(
      key: key,
      data: data,
      onDragStarted: onDragStarted,
      onDragEnd: onDragEnd,
      feedback: feedback,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      childWhenDragging: childWhenDragging,
      child: child,
    );
  }

  GlobalKey _keyFor(String id) {
    return _cardKeys.putIfAbsent(id, () => GlobalKey());
  }

  bool _hitTestCard(Offset globalPos) {
    for (final entry in widget.hostCards) {
      final key = _cardKeys[entry.data.id];
      final ctx = key?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox) continue;
      final origin = box.localToGlobal(Offset.zero);
      final rect = Rect.fromLTWH(
        origin.dx,
        origin.dy,
        box.size.width,
        box.size.height,
      );
      if (rect.contains(globalPos)) return true;
    }
    return false;
  }

  // Drag callbacks invoked by [_RubberBandPanRecognizer] once it wins
  // the gesture arena. By that point the pointer demonstrably did NOT
  // start on a card (the recognizer skips card pointers), so we don't
  // need a defensive `_pointerStartedOnCard` check here anymore.

  void _onPanStart(DragStartDetails details) {
    // Shift, or Ctrl (Cmd on a Mac), adds to what is selected.
    final shift = hostSelectionKeyHeld();
    widget.onSelectionGesture?.call();
    final notifier = ref.read(hostMultiSelectProvider.notifier);
    final current = ref.read(hostMultiSelectProvider);
    // A HostGridArea only owns the cards in ITS section. A plain drag must
    // therefore replace only this section's contribution to the (global)
    // selection and PRESERVE cards selected in other sections - otherwise
    // starting a marquee in one group silently wipes a selection made in
    // another. A shift-drag stays purely additive.
    final mySectionIds = {for (final e in widget.hostCards) e.data.id};
    final initial = shift
        ? Set<String>.from(current.selected)
        : current.selected.where((id) => !mySectionIds.contains(id)).toSet();
    setState(() {
      _dragStart = details.localPosition;
      _dragCurrent = details.localPosition;
      _initialSelection = initial;
    });
    if (!current.active) {
      notifier.enter();
    }
    // Reflect the starting baseline immediately: drops this section's prior
    // cards on a plain drag, keeps other sections' cards (and, on shift, this
    // section's too). The band then adds its hits on top in _applyBandSelection.
    notifier.replaceSelection(initial);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragStart == null) return;
    setState(() => _dragCurrent = details.localPosition);
    _applyBandSelection();
  }

  void _onPanEnd(DragEndDetails _) => _resetBand();
  void _onPanCancel() => _resetBand();

  void _resetBand() {
    if (_dragStart == null) return;
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
    });
  }

  void _applyBandSelection() {
    final start = _dragStart;
    final cur = _dragCurrent;
    if (start == null || cur == null) return;

    final containerBox = _containerKey.currentContext?.findRenderObject();
    if (containerBox is! RenderBox) return;

    final bandRect = Rect.fromPoints(start, cur);
    final hits = <String>{};

    for (final entry in widget.hostCards) {
      final key = _cardKeys[entry.data.id];
      final ctx = key?.currentContext;
      if (ctx == null) continue;
      final cardBox = ctx.findRenderObject();
      if (cardBox is! RenderBox) continue;

      // Translate the card's bounds into the container's coordinate
      // space - the same space the band rect lives in.
      final origin =
          cardBox.localToGlobal(Offset.zero, ancestor: containerBox);
      final cardRect = Rect.fromLTWH(
        origin.dx,
        origin.dy,
        cardBox.size.width,
        cardBox.size.height,
      );
      if (cardRect.overlaps(bandRect)) {
        hits.add(entry.data.id);
      }
    }

    final notifier = ref.read(hostMultiSelectProvider.notifier);
    // _initialSelection already encodes the shift-vs-plain baseline (other
    // sections always preserved), so the band is simply layered on top.
    final next = <String>{..._initialSelection, ...hits};
    notifier.replaceSelection(next);
  }

  @override
  Widget build(BuildContext context) {
    final multiSelect = ref.watch(hostMultiSelectProvider);
    // Every card is one column wide: hosts are one size (the
    // per-host size was taken away).
    final notifier = ref.read(hostMultiSelectProvider.notifier);
    // A click answered on its release alone: in selection mode, while Ctrl
    // or Shift is held, and where there is no panel (click connects). On a
    // computer otherwise, a press opens the panel and a double click
    // connects, as before.
    final releaseOnly = multiSelect.active || _selectionKeyHeld || widget.onSelect == null;
    // Touch sized (a tablet, 4.0): a tap is answered at its release (a press
    // that scrolls the page picks nothing), a double tap still connects, and
    // a card is dragged after a long press (a finger's drag scrolls).
    final touch = touchSizedAt(context);

    // RawGestureDetector with a custom [_RubberBandPanRecognizer] that
    // refuses to track pointers landing on a card. So:
    //   * Pointer-down on a card → recognizer skips → card's Draggable
    //     wins the arena unopposed → drag-to-group works.
    //   * Pointer-down on empty space → recognizer claims after slop →
    //     beats the parent SCV's vertical drag → rubber-band fires.
    //   * Pointer-down on empty space without movement → recognizer
    //     never accepts → underlying tap-target / SCV behaviour is
    //     unaffected.
    //
    // This is the canonical Flutter pattern for the "rubber-band over
    // a Wrap of draggable items inside a scroll view" problem; the
    // earlier Listener / plain GestureDetector approaches lost in the
    // arena to either Draggable or the SCV.
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _RubberBandPanRecognizer:
            GestureRecognizerFactoryWithHandlers<_RubberBandPanRecognizer>(
          () => _RubberBandPanRecognizer(
            isPointerOnCard: _hitTestCard,
          ),
          (recognizer) {
            recognizer
              ..onStart = _onPanStart
              ..onUpdate = _onPanUpdate
              ..onEnd = _onPanEnd
              ..onCancel = _onPanCancel;
          },
        ),
      },
      // SizedBox forces the Stack (and therefore the
      // RawGestureDetector's hit-area) to fill the available width.
      // Without this, the Stack sizes to the Wrap's natural bounds
      // and the rubber-band area gets cropped to whatever space the
      // cards leave behind - usually a few pixels of right-edge
      // whitespace. With width: infinity, dragging anywhere along the
      // full row width works for selection.
      child: SizedBox(
        width: double.infinity,
        child: LayoutBuilder(builder: (context, constraints) {
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: widget.minHeight),
          child: Stack(
          key: _containerKey,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ...widget.hostCards.map((entry) {
                // Per-tile boundary: a build throw for one card (a bad record,
                // or the clamp below in a too-narrow pane) must NOT blank the
                // whole grid - degrade that one tile to a placeholder instead.
                try {
                  final id = entry.data.id;
                  final tileWidth = widget.itemWidth;
                  final card = HostCard(
                    data: entry.data,
                    compact: widget.compact,
                    isSelectionMode: multiSelect.active,
                    isSelected: multiSelect.isSelected(id),
                    highlighted: !multiSelect.active && id == widget.selectedHostId,
                    onTapDown: releaseOnly || touch
                        ? null
                        : () => widget.onSelect!(entry.connectionWithDetails),
                    onDoubleTap: releaseOnly
                        ? null
                        : () => widget.onConnect(entry.connectionWithDetails),
                    onTap: releaseOnly || touch ? () => _tap(entry) : null,
                    // Enter on the card, and a screen reader's double tap: what
                    // a click does (a press opens the panel on a computer).
                    onActivate: releaseOnly || touch || widget.onSelect == null
                        ? () => _tap(entry)
                        : () => widget.onSelect!(entry.connectionWithDetails),
                    onConnect: () => widget.onConnect(entry.connectionWithDetails),
                    onSecondaryTap: (pos) =>
                        widget.onShowContextMenu(pos, entry),
                    onEdit: widget.onEdit == null
                        ? null
                        : () => widget.onEdit!(entry),
                  );
                  // A host dragged with others is dimmed in place with them.
                  final content = _dragging.contains(id) ? Opacity(opacity: 0.35, child: card) : card;
                  // What a drag from this card carries: the selection when the
                  // card is one of several selected, else the card alone. The
                  // page's drop on a group tile reads the same set
                  // ([HostMultiSelectNotifier.dragSetFor]).
                  final carried = notifier.dragSetFor(id);
                  final tile = SizedBox(
                    key: _keyFor(id),
                    width: tileWidth,
                    // Draggable lets the user drop the card onto a group tile
                    // to move it (and the hosts selected with it), or (when
                    // reordering is on) onto another card to reorder in
                    // place. A tap is not a drag: toggles still toggle.
                    child: _cardDraggable(
                      touch: touch,
                      key: ValueKey('host-drag-$id'),
                      data: entry.connectionWithDetails,
                      onDragStarted: () {
                        hostDragActive.value = true;
                        setState(() => _dragging = carried);
                      },
                      onDragEnd: (_) {
                        hostDragActive.value = false;
                        if (mounted) setState(() => _dragging = const {});
                      },
                      feedback: _HostDragChip(
                        data: carried.length > 1 ? null : entry.data,
                        label: carried.length > 1
                            ? AppLocalizations.of(context)!.hostsSelDragCount(carried.length)
                            : Redactable.host(entry.data.name).displayIn(ref),
                        several: carried.length > 1,
                      ),
                      childWhenDragging: Opacity(
                        opacity: 0.35,
                        child: card,
                      ),
                      child: content,
                    ),
                  );
                  // Drop-to-reorder (Start-menu style, no Arrange mode): each
                  // card is a drop target for another card in the SAME grid.
                  // Off in selection mode and when reordering is disabled
                  // (non-manual sorts, where a manual order would be lost).
                  if (widget.onReorder == null || multiSelect.active) {
                    return tile;
                  }
                  return DragTarget<ConnectionWithDetails>(
                    onWillAcceptWithDetails: (d) =>
                        d.data.connection.id != entry.data.id &&
                        widget.hostCards.any(
                            (c) => c.data.id == d.data.connection.id),
                    onAcceptWithDetails: (d) => widget.onReorder!(
                        d.data.connection.id, entry.data.id),
                    builder: (context, candidate, rejected) {
                      if (candidate.isEmpty) return tile;
                      // Accent outline marks where the dragged card will land.
                      return Stack(
                        children: [
                          tile,
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: ZestColors.accentPrimary
                                      .withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: ZestColors.accentPrimary,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                } catch (e, st) {
                  AppLogger.error(
                      'Host tile build failed; showing placeholder', e, st);
                  return HostTileNotShown(
                    key: ValueKey('hostcard-error-${entry.data.id}'),
                    width: widget.itemWidth,
                  );
                }
                }),
                // Trails the last host in the SAME grid flow: beside it when
                // the last row has room, else at the start of the next row,
                // where the next card would go (it
                // was hidden on a full row and came back only when the host
                // panel narrowed the grid). Hidden during multi-select.
                if (widget.onNewConnection != null && !multiSelect.active)
                  _NewConnectionTile(
                    width: widget.itemWidth,
                    height: (widget.compact ? HostCardDensity.compact : ref.watch(hostCardSettingsProvider).density)
                        .heightFor(MediaQuery.textScalerOf(context)),
                    // The same words as the page's New host button.
                    label: AppLocalizations.of(context)!.hostsNewHost,
                    onTap: widget.onNewConnection!,
                  ),
              ],
            ),
            // Rubber-band overlay - only painted while a band drag is
            // in flight. Wrapped in IgnorePointer so it never intercepts
            // hover / tap events on the cards beneath it.
            if (_dragStart != null && _dragCurrent != null)
              Positioned.fromRect(
                rect: Rect.fromPoints(_dragStart!, _dragCurrent!),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ZestColors.accentPrimary.withValues(alpha: 0.10),
                      border: Border.all(
                        color: ZestColors.accentPrimary.withValues(alpha: 0.55),
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
          ],
        ),
        );
        }),
      ),
    );
  }
}

/// The dashed "+  New Connection" tile that trails the host grid as its final
/// cell (so it flows right after the last host, not onto its own row). A ghost
/// slot: no fill, a dashed outline, and just the plus and label centred,
/// brightening to the brand accent on hover. One grid column wide, card height.
class _NewConnectionTile extends StatefulWidget {
  const _NewConnectionTile({
    required this.width,
    required this.height,
    required this.label,
    required this.onTap,
  });

  final double width;
  final double height;
  final String label;
  final VoidCallback onTap;

  @override
  State<_NewConnectionTile> createState() => _NewConnectionTileState();
}

class _NewConnectionTileState extends State<_NewConnectionTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final fg = _hovering ? ZestColors.accentInk : ZestColors.textTertiary;
    final border = _hovering
        ? ZestColors.accentPrimary.withValues(alpha: 0.55)
        : ZestColors.borderDefault;
    return SizedBox(
      width: widget.width,
      // Reached with Tab and said as a button (4.0, the accessibility pass).
      child: ZestPressable(
          onTap: widget.onTap,
          onHover: (h) => setState(() => _hovering = h),
          minSize: 0,
          borderRadius: 12,
          child: WorkspaceDashedBox(
            padding: EdgeInsets.zero,
            radius: 12,
            color: border,
            child: SizedBox(
              width: double.infinity,
              height: widget.height,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.plus, size: 17, color: fg),
                  const SizedBox(width: 9),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
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

/// Floating chip rendered under the cursor while a host card is being
/// dragged toward a group chip. Compact so it doesn't obscure the
/// drop targets - just an icon + the host's display name.
class _HostDragChip extends StatelessWidget {
  const _HostDragChip({required this.label, this.several = false, this.data});
  final String label;

  /// The one host it carries, whose icon it shows.
  final HostCardData? data;

  /// Several hosts ride on it: a stack of servers, not one.
  final bool several;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: ZestColors.bgElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: ZestColors.accentPrimary.withValues(alpha: 0.6),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (data != null)
              HostIcon(
                iconId: data!.iconId,
                customIcon: data!.customIcon,
                osId: data!.osId,
                iconColor: data!.iconColor,
                size: 18,
                cornerRadius: 5,
              )
            else
              Icon(
                LucideIcons.layers,
                size: 14,
                color: ZestColors.accentInk,
              ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: ZestColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Subclass of [PanGestureRecognizer] that **refuses to track pointers
/// whose pointer-down event landed on a host card**. This is the key
/// to making rubber-band selection coexist with per-card [Draggable]
/// drag-to-group and the surrounding [SingleChildScrollView]:
///
/// - Pointer down on a card → [isPointerAllowed] returns false →
///   recognizer never accepts the pointer → card's Draggable claims
///   the drag unopposed.
/// - Pointer down on empty space → [isPointerAllowed] returns true →
///   recognizer enters the arena → after kPanSlop movement it claims
///   the pointer. Because this recognizer is wrapped DEEPER in the
///   widget tree than the SCV's [VerticalDragGestureRecognizer], it
///   wins the tie and the page does not scroll while the user is
///   selecting.
/// - Click without movement → recognizer never accepts → underlying
///   tap-target receives the click.
///
/// `isPointerOnCard` is invoked at hit-test time with the global
/// pointer position; the host grid widget hit-tests the cards and
/// returns true if the position is inside any card's RenderBox.
class _RubberBandPanRecognizer extends PanGestureRecognizer {
  _RubberBandPanRecognizer({required this.isPointerOnCard});

  final bool Function(Offset globalPosition) isPointerOnCard;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (event.buttons != kPrimaryButton) return false;
    if (isPointerOnCard(event.position)) return false;
    return super.isPointerAllowed(event);
  }

  // A laptop trackpad two-finger scroll arrives as a pan-zoom gesture,
  // which DragGestureRecognizer would otherwise convert into a drag -
  // hijacking the scroll into a rubber-band selection (and winning the
  // arena over the scroll view because this recognizer sits deeper). Refuse
  // pan-zoom entirely so trackpad scrolling stays scrolling; the marquee is
  // a genuine mouse / primary-button click-drag only.
  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;
}

/// What stands in a host's place when its card could not be drawn: a frame
/// and a sentence in the theme's own colours (they were a fixed white, white
/// on white on a light theme).
class HostTileNotShown extends StatelessWidget {
  const HostTileNotShown({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: 64,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: ZestColors.borderDefault),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(AppLocalizations.of(context)!.hostNotShown,
                  style: TextStyle(color: ZestColors.textFaint, fontSize: 12)),
            ),
          ),
        ),
      );
}
