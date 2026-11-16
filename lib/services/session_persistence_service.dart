import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/logger.dart';

/// Persists the list of open sessions / tab groups across app restarts.
///
/// On desktop, when the app closes, the currently connected sessions and
/// their tab/group structure are saved. On next launch, the user can be
/// prompted to restore everything in the exact same shape they left it
/// (including duplicates of the same connection in the same group).
///
/// The snapshot names every SFTP pane's remote and local folder and the
/// remote user, so it lives in the encrypted database ([LocalStateStore],
/// schema v36) rather than in preferences. A snapshot an older build left in
/// preferences is imported once and the preference removed.
class SessionPersistenceService {
  static const _prefsKey = 'persisted_sessions';
  static const _tabsKey = 'persisted_tab_snapshots_v1';
  static const _activeTabKey = 'persisted_active_tab_index';

  final SharedPreferences _prefs;
  final LocalStateStore _store;

  SessionPersistenceService(this._prefs, this._store);

  bool _imported = false;

  /// Move whatever an older build left in preferences into the store, once
  /// per service. The store copy wins when both exist.
  Future<void> _importLegacy() async {
    if (_imported) return;
    _imported = true;
    for (final key in [_prefsKey, _tabsKey]) {
      await _store.importFromPrefs(
        key,
        () => _prefs.getString(key),
        () => _prefs.remove(key),
      );
    }
    final active = _prefs.getInt(_activeTabKey);
    if (active != null) {
      if (await _store.read(_activeTabKey) == null) {
        await _store.writeInt(_activeTabKey, active);
      }
      await _prefs.remove(_activeTabKey);
    }
  }

  // ── Legacy flat-list persistence (kept for backwards-compat) ──────

  /// Save the current open sessions for later restoration.
  Future<void> saveOpenSessions(List<PersistedSession> sessions) async {
    final json = sessions.map((s) => s.toJson()).toList();
    await _store.write(_prefsKey, jsonEncode(json));
    AppLogger.info('Saved ${sessions.length} sessions for restoration');
  }

  /// Load previously saved sessions.
  Future<List<PersistedSession>> loadSavedSessions() async {
    await _importLegacy();
    final raw = await _store.read(_prefsKey);
    if (raw == null) return [];

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) =>
              PersistedSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      AppLogger.error('Failed to load persisted sessions', e);
      return [];
    }
  }

  /// Clear saved sessions (after they've been restored).
  Future<void> clearSavedSessions() async {
    await _store.remove(_prefsKey);
    await _store.remove(_tabsKey);
    await _store.remove(_activeTabKey);
    // Any pre-v36 copies, whatever the import state.
    await _prefs.remove(_prefsKey);
    await _prefs.remove(_tabsKey);
    await _prefs.remove(_activeTabKey);
  }

  /// Check if there are saved sessions to restore (either format).
  Future<bool> hasSavedSessions() async {
    await _importLegacy();
    return await _store.read(_prefsKey) != null ||
        await _store.read(_tabsKey) != null;
  }

  // ── Group-aware persistence (preferred) ────────────────────────────

  /// Save the current work-tab structure as [TabSnapshot]s. Each snapshot's
  /// pane tree contains *connection ids* (not session ids), so the launcher
  /// can spawn a fresh session per leaf occurrence - preserving duplicates
  /// of the same connection within the same tab/group.
  Future<void> saveTabSnapshots(
    List<TabSnapshot> snapshots, {
    int? activeTabIndex,
  }) async {
    if (snapshots.isEmpty) {
      await _store.remove(_tabsKey);
      await _store.remove(_activeTabKey);
      return;
    }
    final json = snapshots.map((s) => s.toJson()).toList();
    await _store.write(_tabsKey, jsonEncode(json));
    if (activeTabIndex != null) {
      await _store.writeInt(_activeTabKey, activeTabIndex);
    } else {
      await _store.remove(_activeTabKey);
    }
    AppLogger.info('Saved ${snapshots.length} tab snapshots for restoration');
  }

  /// Load saved tab snapshots, or empty record if none.
  Future<({List<TabSnapshot> tabs, int? activeTabIndex})>
      loadTabSnapshots() async {
    await _importLegacy();
    final raw = await _store.read(_tabsKey);
    if (raw == null) {
      return (tabs: const <TabSnapshot>[], activeTabIndex: null);
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final tabs = <TabSnapshot>[];
      for (final entry in list) {
        final snap = TabSnapshot.fromJson(entry as Map<String, dynamic>);
        if (snap != null) tabs.add(snap);
      }
      return (tabs: tabs, activeTabIndex: await _store.readInt(_activeTabKey));
    } catch (e) {
      AppLogger.error('Failed to load persisted tab snapshots', e);
      return (tabs: const <TabSnapshot>[], activeTabIndex: null);
    }
  }
}

/// Minimal data needed to reconnect a session.
class PersistedSession {
  final String connectionId;
  final String label;
  final String host;
  final int port;
  final String username;

  const PersistedSession({
    required this.connectionId,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
  });

  Map<String, dynamic> toJson() => {
        'connectionId': connectionId,
        'label': label,
        'host': host,
        'port': port,
        'username': username,
      };

  factory PersistedSession.fromJson(Map<String, dynamic> json) {
    return PersistedSession(
      connectionId: json['connectionId'] as String,
      label: json['label'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      username: json['username'] as String,
    );
  }
}
