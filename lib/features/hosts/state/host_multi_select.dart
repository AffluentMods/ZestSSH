import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/selection/list_selection.dart';

import 'host_arrange_mode.dart';

/// Where a selection of hosts was made: the Hosts page, or the hosts drawer
/// beside a session. Both show the one selection, and only the place it was
/// made shows its bulk bar: both did, two bars for one selection
/// before. A press anywhere in a place makes it the one.
enum HostSelectionPlace { page, drawer }

final hostSelectionPlaceProvider = StateProvider<HostSelectionPlace>((ref) => HostSelectionPlace.page);

/// State for the host-card multi-select feature on the Hosts home page: the
/// shared selection of a list ([ListSelectionState]), as every list that
/// selects has it (3.4).
///
///   * `active == false` - no selection is happening. Tapping a card
///     connects (the normal flow). Right-clicking shows a context menu.
///   * `active == true`  - user opted into selection mode (via the
///     right-click "Select" item, or by shift-dragging a rubber-band).
///     Tapping a card now toggles its membership in `selected`;
///     [HostBulkActionBar] is shown at the page bottom with Move /
///     Delete / Cancel actions.
typedef HostMultiSelectState = ListSelectionState;

/// State holder for [HostMultiSelectState]: the shared selection's
/// transitions ([ListSelectionNotifier]), with Arrange left as selecting
/// starts.
class HostMultiSelectNotifier extends ListSelectionNotifier {
  /// Selection mode and Arrange mode both repurpose the card's tap/drag,
  /// so they are mutually exclusive. Entering selection exits Arrange
  /// (Arrange's own `enter()` exits selection - both only ever call the
  /// other's `exit()`, so there is no recursion).
  @override
  void beforeSelecting() => ref.read(hostArrangeModeProvider.notifier).exit();

  /// The hosts a drag that starts on [id] carries: the whole selection when
  /// [id] is one of several selected, else [id] alone.
  Set<String> dragSetFor(String id) =>
      state.active && state.selected.length > 1 && state.selected.contains(id) ? state.selected : {id};
}

/// Riverpod provider for the multi-select state.
final hostMultiSelectProvider =
    NotifierProvider<HostMultiSelectNotifier, HostMultiSelectState>(
  HostMultiSelectNotifier.new,
);

/// Whether the key that adds one host to a selection is held: Cmd on a Mac,
/// Ctrl elsewhere.
bool hostToggleKeyHeld() => selectionToggleKeyHeld();

/// Whether a key that makes a click a selection click (Ctrl or Cmd, Shift)
/// is held now.
bool hostSelectionKeyHeld() => selectionKeyHeld();

/// A click on host [id] of [order] (the hosts in the order the page shows
/// them), taken as a selection click where it is one: with Ctrl (Cmd) it adds
/// or takes out the host, with Shift it selects the range from the host
/// clicked last, and a plain click while selection mode is on toggles the
/// host. [panelHostId] is the host chosen on its own before (open in the
/// page's panel), where selection starts from it. False for a plain click
/// outside selection mode, which the caller handles as it always did.
bool hostSelectionClick(WidgetRef ref, String id, List<String> order, {String? panelHostId}) =>
    selectionClick(ref.read(hostMultiSelectProvider.notifier), ref.read(hostMultiSelectProvider), id, order,
        openId: panelHostId);
