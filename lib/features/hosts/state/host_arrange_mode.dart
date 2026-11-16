import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'host_multi_select.dart';

/// Arrange mode for the Hosts home page (Part B / B5).
///
/// When active, hosts within each group section become drag-reorderable and
/// their manual order is written to `Connections.sortOrder`. Mutually
/// exclusive with multi-select - both repurpose the card's tap/drag, so
/// entering one exits the other.
class HostArrangeModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void enter() {
    ref.read(hostMultiSelectProvider.notifier).exit();
    state = true;
  }

  void exit() => state = false;

  void toggle() => state ? exit() : enter();
}

final hostArrangeModeProvider =
    NotifierProvider<HostArrangeModeNotifier, bool>(
  HostArrangeModeNotifier.new,
);
