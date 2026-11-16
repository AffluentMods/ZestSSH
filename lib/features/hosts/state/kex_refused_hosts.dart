import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The hosts that refused a connection from this device for an old key
/// exchange that Compatibility mode would take (3.4, for
/// an import of 42 end-of-life servers, each turned on by
/// hand). Their cards say "Old key exchange", and a bulk edit offers the
/// mode for just them. Kept while the app runs: a host leaves the set once
/// it connects.
class KexRefusedHosts extends StateNotifier<Set<String>> {
  KexRefusedHosts() : super(const {});

  /// The host [connectionId] refused a connection for an old key exchange.
  void refused(String connectionId) {
    if (state.contains(connectionId)) return;
    state = {...state, connectionId};
  }

  /// The host [connectionId] was connected to.
  void connected(String connectionId) {
    if (!state.contains(connectionId)) return;
    state = {...state}..remove(connectionId);
  }
}

final kexRefusedHostsProvider = StateNotifierProvider<KexRefusedHosts, Set<String>>((ref) => KexRefusedHosts());
