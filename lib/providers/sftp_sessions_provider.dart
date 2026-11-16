import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sftp_service.dart';

/// Registry of currently-open [SftpService] instances, keyed by session ID.
///
/// This solves the "let any pane in any screen pick which SFTP host it
/// browses" problem: when a pane opens an SFTP service it [register]s it
/// here, and other panes (or the source dropdown) can list / look up open
/// services without lifting state across the widget tree.
///
/// Lifetime: the SftpService is kept alive as long as it stays registered.
/// The registering widget MUST [unregister] when it closes the pane,
/// otherwise the service leaks.
///
/// Snapshots returned by `state` are immutable; mutations create a new map
/// (Riverpod expects state replacement, not in-place mutation).
class SftpSessionsNotifier extends StateNotifier<Map<String, SftpService>> {
  SftpSessionsNotifier() : super(const {});

  /// Add or replace a service for the given session id.
  void register(String sessionId, SftpService service) {
    state = {...state, sessionId: service};
  }

  /// Remove a session's service from the registry. Does NOT close the
  /// service - closing is the registrar's responsibility. With [only], only
  /// that service: one registered for the session since stays.
  void unregister(String sessionId, {SftpService? only}) {
    if (!state.containsKey(sessionId)) return;
    if (only != null && !identical(state[sessionId], only)) return;
    final next = {...state}..remove(sessionId);
    state = next;
  }

  /// [unregister] once the frame being built is done: for a widget that is
  /// disposed, as no provider may change while the widget tree is built or
  /// taken down (a tab with the SFTP dock open, left for another tab, threw
  /// that in a debug build). Only [service] is taken out, so a pane of the
  /// session mounted meanwhile keeps its own.
  void unregisterLater(String sessionId, SftpService service) {
    Future.microtask(() {
      if (mounted) unregister(sessionId, only: service);
    });
  }

  /// Look up a service without subscribing.
  SftpService? get(String sessionId) => state[sessionId];
}

/// Provider for the SFTP service registry. Watch to react to opens/closes;
/// read with `.notifier` to register/unregister.
final sftpSessionsProvider =
    StateNotifierProvider<SftpSessionsNotifier, Map<String, SftpService>>(
  (ref) => SftpSessionsNotifier(),
);

/// One row in the source dropdown - pairs a registered SFTP service with
/// its human-readable label for the picker. Computed by joining the SFTP
/// registry against the active terminal sessions.
class SftpSessionEntry {
  final String sessionId;
  final String label;
  final SftpService service;

  const SftpSessionEntry({
    required this.sessionId,
    required this.label,
    required this.service,
  });
}

/// Computed list of all open SFTP sessions with their connection labels,
/// suitable for rendering the source dropdown.
///
/// Filters defensively:
///   * The [SftpService] must be `isOpen` - if it was closed without
///     unregistering (network drop, buggy code path), it would lead to
///     the user picking it and seeing "SFTP not open. Call open()
///     first." on every operation. Better to hide it from the picker
///     so the dropdown only ever lists usable hosts.
///   * The underlying SSH session must be `connected` and not
///     `isHidden`. A registered service whose terminal session was
///     closed via the in-tab X button is a stale entry - surfacing it
///     would let the user "swap" to a host they already closed.
final activeSftpSessionEntriesProvider =
    Provider<List<SftpSessionEntry>>((ref) {
  final sftpMap = ref.watch(sftpSessionsProvider);
  final terminalSessions = ref.watch(activeSessionsProvider);

  final result = <SftpSessionEntry>[];
  for (final entry in sftpMap.entries) {
    if (!entry.value.isOpen) continue;
    final terminal = terminalSessions[entry.key];
    if (terminal == null) continue;
    if (terminal.status != SessionStatus.connected) continue;
    if (terminal.isHidden) continue;
    final label = terminal.connectionLabel.isNotEmpty
        ? terminal.connectionLabel
        : (terminal.host ?? entry.key);
    result.add(SftpSessionEntry(
      sessionId: entry.key,
      label: label,
      service: entry.value,
    ));
  }
  return result;
});

/// Remembers the last directory each SFTP / local pane was viewing,
/// keyed by `sourceId` (i.e. SSH session id for remote sources, or the
/// literal string `"local"` for the local-files pane).
///
/// When an [SftpPane] is unmounted (e.g. the user clicks back to the
/// terminal, switches tabs, or the pane tree rebuilds), its widget
/// state - including the current path - is destroyed. The next time
/// the same source is mounted the pane re-bootstraps to the home
/// directory, which feels broken if the user just navigated five
/// levels deep. This provider closes that gap: each navigation writes
/// the new path here, and [_bootstrap] consults it before falling
/// back to `homeDirectory()`.
///
/// In-memory only - surviving a full app restart would require
/// keying by *connection id* instead of session id (session ids are
/// regenerated on reconnect). That's a future enhancement; for now
/// "remembered for this app session" is the bar.
final lastSftpPathProvider = StateProvider<Map<String, String>>((_) => {});

/// Helper notifier-style API for [lastSftpPathProvider] so call sites
/// don't have to spread copy-with logic across the codebase.
class LastSftpPaths {
  LastSftpPaths(this._ref);
  final Ref _ref;

  String? get(String sourceId) =>
      _ref.read(lastSftpPathProvider)[sourceId];

  void set(String sourceId, String path) {
    final current = _ref.read(lastSftpPathProvider);
    if (current[sourceId] == path) return; // no-op
    _ref.read(lastSftpPathProvider.notifier).state = {
      ...current,
      sourceId: path,
    };
  }

  void forget(String sourceId) {
    final current = _ref.read(lastSftpPathProvider);
    if (!current.containsKey(sourceId)) return;
    final next = Map<String, String>.from(current)..remove(sourceId);
    _ref.read(lastSftpPathProvider.notifier).state = next;
  }
}

final lastSftpPathsProvider = Provider<LastSftpPaths>(
  (ref) => LastSftpPaths(ref),
);
