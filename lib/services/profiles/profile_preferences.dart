import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/error_kind.dart';

/// The app's preferences for a person's settings: the one helper they are read
/// and written through.
///
/// Each key is tagged profile or device ([SettingsService.isProfileKey]): a
/// device key stays in the system's store, and a profile key lives in the
/// profile's database, so it is locked with it. Reads stay as they were, from
/// memory; a write goes to memory at once and to the database in order.
///
/// While the app lock has the database closed, what was read stays in memory
/// (the app's own state holds as much) and what is written waits for the
/// unlock. Before a profile's settings were ever read a profile key reads as
/// none, and a write to one is dropped: a default written then must not take
/// the place of what the database holds.
///
/// A phone never has one of these ([sharedPreferencesProvider] is the system's
/// store there), and a test that does not ask for one neither.
class ProfilePreferences implements SharedPreferences {
  ProfilePreferences(this._device);

  final SharedPreferences _device;

  /// The one in this app: what has no provider to ask finds it here
  /// ([appPreferences]).
  static ProfilePreferences? instance;

  /// Settings in the database are kept under this beginning in its local
  /// store, which is never synced and never in a backup.
  static const storePrefix = 'pref.';

  /// The lock's own switches with profiles, under new names: an older version
  /// run after the move finds its own off, and does not sit at a PIN it can no
  /// longer check.
  static const renamed = {
    'security_lock_enabled': 'lock2_app_lock',
    'encrypting_lock_enabled': 'lock2_encrypting',
  };

  /// Settings that follow the person where one is open, and otherwise show the
  /// last one's: what the lock screen looks like and speaks before any profile
  /// is open.
  static const layered = {'app_locale', 'app_theme_id', 'custom_accent_color', 'follow_system_theme'};

  Map<String, Object>? _person;
  AppDatabase? _db;
  final _waiting = <String, Object?>{};
  Future<void> _lastWrite = Future<void>.value();

  /// Whether a profile's settings are in memory.
  bool get loaded => _person != null;

  /// Reads the settings of the profile whose database [db] is, in place of any
  /// before it.
  Future<void> load(AppDatabase db) async {
    await _lastWrite;
    _db = db;
    _person = await readStored(db);
    _waiting.clear();
  }

  /// The same database opened again after the lock: what was written while it
  /// was closed goes in now.
  Future<void> reattach(AppDatabase db) async {
    _db = db;
    final waiting = Map<String, Object?>.of(_waiting);
    _waiting.clear();
    for (final entry in waiting.entries) {
      _store(entry.key, entry.value);
    }
    await _lastWrite;
  }

  /// The database closes with the app lock: what was read stays.
  Future<void> detach() async {
    await _lastWrite;
    _db = null;
  }

  /// No profile is open any more: nothing of one stays in memory.
  Future<void> forget() async {
    await detach();
    _person = null;
    _waiting.clear();
  }

  /// What [db] holds.
  static Future<Map<String, Object>> readStored(AppDatabase db) async {
    final rows = await (db.select(db.localState)..where((t) => t.key.like('$storePrefix%'))).get();
    final out = <String, Object>{};
    for (final row in rows) {
      if (!row.key.startsWith(storePrefix)) continue;
      final value = _decode(row.value);
      if (value != null) out[row.key.substring(storePrefix.length)] = value;
    }
    return out;
  }

  /// [values] kept in [db], in one transaction, each only where none is kept
  /// yet (the move, which can run twice). The database's own wins.
  static Future<void> importInto(AppDatabase db, Map<String, Object> values) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction(() async {
      for (final entry in values.entries) {
        await db.into(db.localState).insert(
              LocalStateCompanion.insert(key: '$storePrefix${entry.key}', value: _encode(entry.value), updatedAt: now),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  /// [value] kept in [db] under [key], over what is kept there: for what comes into a
  /// profile from outside (guest data). Whoever holds it in memory reads it again ([load]).
  static Future<void> writeStored(AppDatabase db, String key, Object value) =>
      db.into(db.localState).insertOnConflictUpdate(LocalStateCompanion(
            key: Value('$storePrefix$key'),
            value: Value(_encode(value)),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ));

  static String _encode(Object value) => jsonEncode(value);

  static Object? _decode(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is bool || v is int || v is double || v is String) return v as Object;
      if (v is List) return [for (final e in v) e as String];
    } catch (_) {/* not one of ours */}
    return null;
  }

  void _store(String key, Object? value) {
    final db = _db;
    if (db == null) {
      _waiting[key] = value;
      return;
    }
    _lastWrite = _lastWrite.then((_) async {
      try {
        final name = '$storePrefix$key';
        if (value == null) {
          await (db.delete(db.localState)..where((t) => t.key.equals(name))).go();
        } else {
          await db.into(db.localState).insertOnConflictUpdate(LocalStateCompanion(
                key: Value(name),
                value: Value(_encode(value)),
                updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
              ));
        }
      } catch (e) {
        // The database closed under it (a lock), or a value that cannot be
        // written. Tried again at the next open where it was the first.
        AppLogger.warning('A setting was not kept: ${errorKind(e)}');
        if (identical(_db, db)) return;
        _waiting[key] = value;
      }
    });
  }

  bool _isPerson(String key) => SettingsService.isProfileKey(key);

  String _deviceKey(String key) => renamed[key] ?? key;

  /// When every write so far is in the database.
  Future<void> get settled => _lastWrite;

  @override
  Set<String> getKeys() {
    final out = <String>{};
    final names = renamed.map((k, v) => MapEntry(v, k));
    for (final key in _device.getKeys()) {
      if (renamed.containsKey(key)) continue; // the old switch, kept off for an older version
      final name = names[key] ?? key;
      if (_isPerson(name) && !layered.contains(name)) continue;
      out.add(name);
    }
    out.addAll(_person?.keys ?? const <String>[]);
    return out;
  }

  @override
  Object? get(String key) {
    if (!_isPerson(key)) return _device.get(_deviceKey(key));
    final person = _person;
    if (person != null && person.containsKey(key)) return person[key];
    return layered.contains(key) ? _device.get(key) : null;
  }

  @override
  bool? getBool(String key) => get(key) as bool?;

  @override
  int? getInt(String key) => get(key) as int?;

  @override
  double? getDouble(String key) => get(key) as double?;

  @override
  String? getString(String key) => get(key) as String?;

  @override
  bool containsKey(String key) => get(key) != null;

  @override
  List<String>? getStringList(String key) {
    final list = get(key) as List?;
    return list?.cast<String>().toList();
  }

  Future<bool> _setPerson(String key, Object value) async {
    final person = _person;
    if (person == null) {
      AppLogger.warning('A setting of a person was written while no profile is open, and dropped');
      return false;
    }
    person[key] = value;
    _store(key, value);
    await _lastWrite;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    if (!_isPerson(key)) return _device.setBool(_deviceKey(key), value);
    if (layered.contains(key)) await _device.setBool(key, value);
    return _setPerson(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) async {
    if (!_isPerson(key)) return _device.setInt(_deviceKey(key), value);
    if (layered.contains(key)) await _device.setInt(key, value);
    return _setPerson(key, value);
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    if (!_isPerson(key)) return _device.setDouble(_deviceKey(key), value);
    if (layered.contains(key)) await _device.setDouble(key, value);
    return _setPerson(key, value);
  }

  @override
  Future<bool> setString(String key, String value) async {
    if (!_isPerson(key)) return _device.setString(_deviceKey(key), value);
    if (layered.contains(key)) await _device.setString(key, value);
    return _setPerson(key, value);
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    if (!_isPerson(key)) return _device.setStringList(_deviceKey(key), value);
    if (layered.contains(key)) await _device.setStringList(key, value);
    return _setPerson(key, List<String>.of(value));
  }

  @override
  Future<bool> remove(String key) async {
    if (!_isPerson(key)) return _device.remove(_deviceKey(key));
    if (layered.contains(key)) await _device.remove(key);
    final person = _person;
    if (person == null) return false;
    person.remove(key);
    _store(key, null);
    await _lastWrite;
    return true;
  }

  /// Everything of the person, and nothing of the device's: the settings of
  /// the profile open now. (Everything on the device goes through the store
  /// itself: ProfileManager.wipeEverything.)
  @override
  Future<bool> clear() async {
    final person = _person;
    if (person == null) return false;
    for (final key in person.keys.toList()) {
      if (layered.contains(key)) await _device.remove(key);
      person.remove(key);
      _store(key, null);
    }
    await _lastWrite;
    return true;
  }

  @override
  Future<void> reload() => _device.reload();

  @Deprecated('This method is now a no-op, and should no longer be called. Will be removed in a future version.')
  @override
  Future<bool> commit() async => true;
}

/// The app's preferences, for what has no provider to ask (a test's store on a
/// phone's path, the helper on a computer). The one place outside the helper
/// that asks the system for its store: a test fails for another.
Future<SharedPreferences> appPreferences() async => ProfilePreferences.instance ?? await SharedPreferences.getInstance();

/// The system's store itself, for the start of the app and the helper.
Future<SharedPreferences> systemPreferences() => SharedPreferences.getInstance();
