import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/hosts/host_card_face.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

/// In-memory + SharedPreferences cache of detected OS per connection ID.
///
/// The cache persists across app restarts via SharedPreferences so the
/// OS icon appears immediately without waiting for the next SSH connection.
/// Detection runs once on first connect; subsequent connects skip detection
/// if a cached value already exists.
final osDetectionCacheProvider =
    StateNotifierProvider<OsDetectionCacheNotifier, Map<String, OsKind>>(
  (ref) => OsDetectionCacheNotifier(ref.read(sharedPreferencesProvider)),
);

/// Convenience provider to look up a single connection's detected OS.
final detectedOsProvider = Provider.family<OsKind?, String>((ref, connectionId) {
  final cache = ref.watch(osDetectionCacheProvider);
  return cache[connectionId];
});

class OsDetectionCacheNotifier extends StateNotifier<Map<String, OsKind>> {
  final SharedPreferences _prefs;

  static const _prefsPrefix = 'os_kind_';

  OsDetectionCacheNotifier(this._prefs) : super({}) {
    _loadFromPrefs();
  }

  /// Load previously detected OS values from SharedPreferences.
  void _loadFromPrefs() {
    final loaded = <String, OsKind>{};
    for (final key in _prefs.getKeys()) {
      if (key.startsWith(_prefsPrefix)) {
        final connectionId = key.substring(_prefsPrefix.length);
        final value = _prefs.getString(key);
        if (value != null) {
          final kind = _parseOsKind(value);
          if (kind != null) {
            loaded[connectionId] = kind;
          }
        }
      }
    }
    if (loaded.isNotEmpty) {
      state = {...state, ...loaded};
    }
  }

  /// Store a detected OS for a connection.
  void set(String connectionId, OsKind kind) {
    state = {...state, connectionId: kind};
    _prefs.setString('$_prefsPrefix$connectionId', kind.name);
  }

  /// Check whether a connection already has a cached OS.
  bool has(String connectionId) => state.containsKey(connectionId);

  /// Remove the cached OS for a connection (e.g. on connection delete).
  void remove(String connectionId) {
    final updated = Map<String, OsKind>.from(state);
    updated.remove(connectionId);
    state = updated;
    _prefs.remove('$_prefsPrefix$connectionId');
  }

  /// Parse a stored enum name back to [OsKind].
  static OsKind? _parseOsKind(String name) {
    for (final kind in OsKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// Keeps the icons of the systems seen on personal hosts on the hosts
/// themselves, where they have none of their own ([detectedIconsToKeep]), so
/// they sync to every device (3.2). [onlyId] limits it to one host (a system
/// just seen); otherwise every host this device has seen a system on (once a
/// start). Team hosts are not in this table and are never written. Returns
/// how many hosts took an icon.
Future<int> keepDetectedHostIcons({
  required ConnectionsDao dao,
  required ConnectionCrudNotifier crud,
  required Map<String, OsKind> seen,
  String? onlyId,
}) async {
  if (seen.isEmpty) return 0;
  final hosts = onlyId == null ? await dao.getAll() : [?await dao.getById(onlyId)];
  final keep = detectedIconsToKeep(hosts, seen);
  for (final e in keep.entries) {
    await crud.update(id: e.key, iconId: e.value, customIcon: null, setIcon: true);
  }
  return keep.length;
}
