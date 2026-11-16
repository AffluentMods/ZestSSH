import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';

/// SharedPreferences key holding the set of hosts with an unresolved
/// changed-key event.
const String _changedHostKeysPrefsKey = 'changed_host_keys';

/// Persisted set of hosts that presented a CHANGED host key which the user has
/// NOT yet resolved (by trusting the new key). Each entry is
/// `normalizedHost:port`.
///
/// This lets the host card surface the security condition WITHOUT requiring a
/// fresh connection attempt (F2): it's marked the moment a change is detected
/// in the verify flow and cleared only when the user explicitly trusts the new
/// key. A cancelled/aborted connection leaves the mark in place, so the card
/// keeps warning until the user deliberately resolves it.
///
/// A lightweight prefs-backed store (rather than a schema field) is used on
/// purpose: the state is per-device transient security UX, not synced app
/// data, so it doesn't warrant a v19→v20 migration.
final changedHostKeysProvider =
    NotifierProvider<ChangedHostKeysNotifier, Set<String>>(
  ChangedHostKeysNotifier.new,
);

class ChangedHostKeysNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_changedHostKeysPrefsKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
    } catch (_) {
      // Corrupt entry - start clean rather than crashing the home screen.
      return const {};
    }
  }

  Future<void> _persist() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(
        _changedHostKeysPrefsKey, jsonEncode(state.toList()));
  }

  /// Record that [host]:[port] presented a changed key (unresolved). Idempotent.
  Future<void> markChanged(String host, int port) async {
    final key = _key(host, port);
    if (state.contains(key)) return;
    state = {...state, key};
    await _persist();
  }

  /// Clear the changed-key mark for [host]:[port] (the user trusted the new
  /// key, or the condition was otherwise resolved). Idempotent.
  Future<void> resolve(String host, int port) async {
    final key = _key(host, port);
    if (!state.contains(key)) return;
    state = {...state}..remove(key);
    await _persist();
  }

  /// Whether [host]:[port] currently has an unresolved changed-key event.
  bool isChanged(String host, int port) => state.contains(_key(host, port));

  static String _key(String host, int port) =>
      '${normalizeKnownHost(host)}:$port';
}

/// Canonicalise a host string the SAME way `KnownHostsService` does for its
/// trust lookups (lowercase, trim, strip a trailing FQDN dot, strip IPv6
/// literal brackets). Keeping the rules identical ensures the changed-key set
/// keys line up whether written by the verify flow (the raw challenge host) or
/// read by the host card (the connection's stored host string).
String normalizeKnownHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.endsWith('.') && h.length > 1) {
    h = h.substring(0, h.length - 1);
  }
  if (h.startsWith('[') && h.endsWith(']') && h.length > 2) {
    h = h.substring(1, h.length - 1);
  }
  return h;
}
