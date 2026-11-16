import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Selecting several items of a list at once (3.4): what the hosts' select
// does, shared by every list that selects (hosts, keys, snippets, port
// forwards), so the keys and the taps are the same everywhere: a click (or
// its box) in or out, Shift for a range from the one clicked last, Ctrl (Cmd
// on a Mac) to add or take out one, Ctrl+A for every one shown, Esc to stop.

/// What is selected in a list, and whether it is selecting at all.
///
/// Two modes:
///   * `active == false` - no selection is happening. A tap on an item does
///     what it always did (connects, opens its details).
///   * `active == true` - the person is selecting: a tap puts an item in or
///     takes it out of [selected], and the list's selection bar shows.
@immutable
class ListSelectionState {
  const ListSelectionState({
    this.active = false,
    this.selected = const {},
  });

  /// True once selecting has started. Stays true even when [selected] is
  /// empty, so the last item can be taken out without leaving the mode.
  final bool active;

  /// The ids selected. Order is irrelevant: the list says the order.
  final Set<String> selected;

  bool get hasSelection => selected.isNotEmpty;
  int get count => selected.length;
  bool isSelected(String id) => selected.contains(id);

  ListSelectionState copyWith({
    bool? active,
    Set<String>? selected,
  }) {
    return ListSelectionState(
      active: active ?? this.active,
      selected: selected ?? this.selected,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ListSelectionState && other.active == active && setEquals(other.selected, selected);
  }

  @override
  int get hashCode => Object.hash(active, Object.hashAllUnordered(selected));
}

/// The selection of one list. Kept tiny on purpose: transitions are pure
/// value swaps and the list rebuilds on each one.
abstract class ListSelectionNotifier extends Notifier<ListSelectionState> {
  @override
  ListSelectionState build() => const ListSelectionState();

  /// Called where selecting starts (and where a range or Select all makes a
  /// new selection), before the state changes: the hosts leave Arrange here,
  /// which repurposes the same taps.
  @protected
  void beforeSelecting() {}

  /// The item a Shift-click's range starts from: the one clicked last (a
  /// plain or Ctrl-click in selection mode, or the item selection began
  /// with). Not part of the state: nothing is drawn from it.
  String? _anchor;

  /// Enter selection mode, optionally with one item ([initialId], the one
  /// right-clicked or long-pressed) already selected.
  void enter([String? initialId]) {
    beforeSelecting();
    _anchor = initialId;
    state = ListSelectionState(
      active: true,
      selected: initialId == null ? const <String>{} : {initialId},
    );
  }

  /// Toggle a single item in or out of the selection. No-op if the list is
  /// not selecting (defends against stray taps from stale handlers).
  void toggle(String id) {
    if (!state.active) return;
    _anchor = id;
    final next = Set<String>.from(state.selected);
    if (!next.add(id)) next.remove(id);
    state = state.copyWith(selected: next);
  }

  /// A Ctrl-click (Cmd-click on a Mac) on [id]: in or out of the selection,
  /// starting selection mode where it was off. [alsoSelect] is the item that
  /// was already chosen on its own (the one open beside the list), taken into
  /// the new selection with it, as a file manager does.
  void toggleAt(String id, {String? alsoSelect}) {
    if (state.active) {
      toggle(id);
      return;
    }
    beforeSelecting();
    _anchor = id;
    state = ListSelectionState(active: true, selected: {?alsoSelect, id});
  }

  /// A Shift-click on [id]: every item from the last one clicked to this one,
  /// in [order] (the order the list shows them). [add] (Ctrl and Shift) keeps
  /// what was selected besides; else the range is the selection. Where no
  /// item was clicked before, the range starts at [fallbackAnchor] (the item
  /// open beside the list) or is [id] alone. The anchor stays where it was, so
  /// a second Shift-click changes the range rather than starting another.
  void selectRange(String id, List<String> order, {bool add = false, String? fallbackAnchor}) {
    final to = order.indexOf(id);
    if (to < 0) return;
    var anchor = _anchor;
    if (anchor == null || !order.contains(anchor)) anchor = fallbackAnchor;
    if (anchor == null || !order.contains(anchor)) anchor = id;
    _anchor = anchor;
    final from = order.indexOf(anchor);
    final range = order.sublist(from < to ? from : to, (from < to ? to : from) + 1);
    beforeSelecting();
    state = ListSelectionState(
      active: true,
      selected: {if (add && state.active) ...state.selected, ...range},
    );
  }

  /// Replace the entire selection. The caller makes sure the ids are of
  /// items the list shows: they are not checked here.
  void replaceSelection(Set<String> ids) {
    if (!state.active) {
      beforeSelecting();
      state = ListSelectionState(active: true, selected: ids);
    } else {
      state = state.copyWith(selected: ids);
    }
  }

  /// Add ids to the current selection (a drag's band, Select all shown).
  void addAll(Iterable<String> ids) {
    if (!state.active) {
      beforeSelecting();
      state = ListSelectionState(active: true, selected: ids.toSet());
      return;
    }
    state = state.copyWith(selected: {...state.selected, ...ids});
  }

  /// Remove ids from the current selection. Stays in selection mode even if
  /// the result is empty.
  void removeAll(Iterable<String> ids) {
    if (!state.active) return;
    final next = Set<String>.from(state.selected)..removeAll(ids);
    state = state.copyWith(selected: next);
  }

  /// Select every id in [allIds] (Ctrl+A, the count's Select all).
  void selectAll(Iterable<String> allIds) {
    beforeSelecting();
    state = ListSelectionState(active: true, selected: allIds.toSet());
  }

  /// Drop the selection but stay in selection mode.
  void clearSelection() {
    if (!state.active) return;
    state = state.copyWith(selected: const <String>{});
  }

  /// Exit selection mode entirely. The selection is discarded.
  void exit() {
    _anchor = null;
    state = const ListSelectionState();
  }
}

/// Whether the key that adds one item to a selection is held: Cmd on a Mac,
/// Ctrl elsewhere.
bool selectionToggleKeyHeld() {
  final keys = HardwareKeyboard.instance;
  return defaultTargetPlatform == TargetPlatform.macOS ? keys.isMetaPressed : keys.isControlPressed;
}

/// Whether a key that makes a click a selection click (Ctrl or Cmd, Shift)
/// is held now.
bool selectionKeyHeld() => selectionToggleKeyHeld() || HardwareKeyboard.instance.isShiftPressed;

/// The name of the key that adds one item ([selectionToggleKeyHeld]), as a
/// hint or a tooltip says it.
String selectionToggleKeyName() => defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl';

/// A click on item [id] of [order] (the items in the order the list shows
/// them), taken as a selection click where it is one: with Ctrl (Cmd) it
/// adds or takes out the item, with Shift it selects the range from the item
/// clicked last, and a plain click while selecting toggles the item.
/// [openId] is the item chosen on its own before (open beside the list),
/// where selection starts from it. False for a plain click outside selection
/// mode, which the caller handles as it always did.
bool selectionClick(ListSelectionNotifier notifier, ListSelectionState state, String id, List<String> order,
    {String? openId}) {
  final toggleKey = selectionToggleKeyHeld();
  if (HardwareKeyboard.instance.isShiftPressed) {
    notifier.selectRange(id, order, add: toggleKey, fallbackAnchor: openId);
    return true;
  }
  if (toggleKey) {
    notifier.toggleAt(id, alsoSelect: openId);
    return true;
  }
  if (!state.active) return false;
  notifier.toggle(id);
  return true;
}
