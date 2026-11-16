/// What bringing guest data into an account does with each table of a personal
/// database, so that nothing goes with the guest profile unsaid (a review found
/// that workflows and scheduled tasks came with nothing, and the local shells
/// a restore turns away went with the profile). A new table has no fate until someone
/// gives it one: a test walks the tables and fails, and until then one that holds rows
/// keeps the guest profile where it is.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/saved_tab_group.dart' show kSavedTabGroupsKey;
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// What comes of a table's rows when guest data is brought in.
enum GuestTableFate {
  /// They come through the restore, the later of two copies standing; what it turns
  /// away (a local shell's port, a serial line's address) is copied as it is, and what
  /// each device decides for itself is kept, as this is the same device.
  restored,

  /// They are copied as they are: no restore knows them. What the account holds under
  /// the same key stays.
  copied,

  /// They go with the guest profile, and nothing is lost by it: [kGuestTables] says why.
  leftOut,

  /// A team's, which a team's own database holds: a personal one has none. Where one
  /// does, the guest profile stays, and the person is told ([guestTablesThatStay]).
  teamOnly,
}

/// Every table of a personal database.
const Map<String, GuestTableFate> kGuestTables = {
  'connections': GuestTableFate.restored,
  'identities': GuestTableFate.restored,
  'connection_groups': GuestTableFate.restored,
  // A pinned key that disagrees with the account's stays out, as in any restore, and
  // the account's pin decides: connecting says so if the host's key is another. So does
  // any key of a host the account confirmed itself, and what comes is not confirmed here.
  'known_hosts': GuestTableFate.restored,
  'snippets': GuestTableFate.restored,
  'snippet_categories': GuestTableFate.restored,
  'port_forward_rules': GuestTableFate.restored,
  'port_forward_network_overrides': GuestTableFate.restored,
  'networks': GuestTableFate.restored,
  'host_network_overrides': GuestTableFate.restored,
  'connection_tags': GuestTableFate.restored,
  'host_accounts': GuestTableFate.restored,
  'terminal_triggers': GuestTableFate.restored,
  'command_history': GuestTableFate.restored,

  'workflows': GuestTableFate.copied,
  'scheduled_tasks': GuestTableFate.copied,
  'automation_history': GuestTableFate.copied,
  'monitor_samples': GuestTableFate.copied,
  'sftp_sync_manifest': GuestTableFate.copied,
  'feedback_queue': GuestTableFate.copied,
  'support_tickets': GuestTableFate.copied,
  'ticket_outbox': GuestTableFate.copied,

  // What guest data deleted once is none of the account's business: a sync would carry
  // it to every device of the account.
  'tombstones': GuestTableFate.leftOut,
  // Its saved tab groups and custom themes come. The rest is what its own screen was
  // doing (open tabs, counters), its settings (the account's stay) and its sync's
  // bookkeeping; what of that a person would miss is said before it goes ([whatStaysOut]).
  'local_state': GuestTableFate.leftOut,

  'crate_items_meta': GuestTableFate.teamOnly,
  'crate_leftovers': GuestTableFate.teamOnly,
  'crate_outbox': GuestTableFate.teamOnly,
  'orchard_info': GuestTableFate.teamOnly,
  'orchard_crates': GuestTableFate.teamOnly,
  'space_keys': GuestTableFate.teamOnly,
  'orchard_secrets': GuestTableFate.teamOnly,
  'orchard_sync_control': GuestTableFate.teamOnly,
  'member_keys': GuestTableFate.teamOnly,
  'orchard_record_entries': GuestTableFate.teamOnly,
  'change_next': GuestTableFate.teamOnly,
  'team_host_keys': GuestTableFate.teamOnly,
};

/// What stays out of a Bring and goes with the guest profile, that a person would miss:
/// the question says so before it goes (nothing vanishes unsaid).
class GuestStaysOut {
  const GuestStaysOut({this.apiKeys = 0, this.backupDestinations = 0, this.keys = 0, this.themes = 0, this.others = false});

  /// Automation API keys: the account gets none, and a task that came naming one shows
  /// that it needs a key.
  final int apiKeys;

  final int backupDestinations;

  /// Keys this account deleted after they last changed: that deletion stands, and guest
  /// data's copy goes, with what may be the only copy of the private key.
  final int keys;

  /// Custom themes the account has another by the same name of.
  final int themes;

  /// Saved password managers, a Prometheus server, pinned hosts or workspaces.
  final bool others;

  bool get any => apiKeys > 0 || backupDestinations > 0 || keys > 0 || themes > 0 || others;
}

/// The settings that hold custom themes, each with how a theme of it is numbered.
const _themeKeys = <(String, String)>[
  ('custom_terminal_themes', 'custom_'),
  ('custom_app_themes_v1', 'custom_app_'),
];

/// Settings a person set up by hand, which do not come ([GuestStaysOut.others]).
const _settingsThatGo = [
  'password_managers_v1',
  'prometheus_url',
  'desktop_pinned_connections',
  'pinned_connection_ids',
  'desktop_workspaces',
];

/// Where AutomationKeysNotifier keeps a person's automation API keys.
const _apiKeysKey = 'automation_api_keys';

/// What [from] (guest data, with its own [keychain]) holds that stays out of [into], the
/// account on screen, if it is brought in. Nothing changes by asking.
Future<GuestStaysOut> whatStaysOut({required AppDatabase from, required FlutterSecureStorage keychain, AppDatabase? into}) async {
  final theirs = await ProfilePreferences.readStored(from);
  final mine = into == null ? const <String, Object>{} : await ProfilePreferences.readStored(into);
  var themes = 0;
  for (final (key, numbered) in _themeKeys) {
    themes += _unreadable(() => _themesComing(theirs[key], mine[key], numbered).stayOut, 0, 'Custom themes');
  }
  var apiKeys = 0;
  try {
    apiKeys = _countIn(await keychain.read(key: _apiKeysKey));
  } catch (e) {
    AppLogger.warning('Guest data\'s automation API keys could not be counted (${errorKind(e)})');
  }
  return GuestStaysOut(
    apiKeys: apiKeys,
    backupDestinations: _countIn(theirs['backup_destinations']),
    keys: into == null ? 0 : await _keysDeletedHere(from, into),
    themes: themes,
    others: _settingsThatGo.any((key) => _holdsSomething(theirs[key])),
  );
}

/// [read], or [otherwise] where a setting holds what is no list of what it should.
T _unreadable<T>(T Function() read, T otherwise, String what) {
  try {
    return read();
  } on FormatException catch (e) {
    AppLogger.warning('$what could not be read (${errorKind(e)})');
  } on TypeError catch (e) {
    AppLogger.warning('$what could not be read (${errorKind(e)})');
  }
  return otherwise;
}

/// How many a setting's JSON list holds.
int _countIn(Object? raw) =>
    _unreadable(() => raw is String && raw.isNotEmpty ? (jsonDecode(raw) as List).length : 0, 0, 'A list of guest data');

bool _holdsSomething(Object? value) => switch (value) {
      null => false,
      final String text => text.isNotEmpty && text != '[]' && text != '{}',
      final List<Object?> list => list.isNotEmpty,
      _ => true,
    };

/// How many keys of [from] stay out of [into], as it deleted them after they last changed.
Future<int> _keysDeletedHere(AppDatabase from, AppDatabase into) async {
  final deletions = await _deletionsIn(into, 'identities');
  if (deletions.isEmpty) return 0;
  var out = 0;
  for (final row in await from.customSelect('SELECT id, updated_at FROM identities').get()) {
    final data = row.data;
    if (!deletions.containsKey(data['id'])) continue;
    if (await _holds(into, 'identities', const ['id'], data)) continue;
    if (_deletionStands(deletions[data['id']], data['updated_at'])) out++;
  }
  return out;
}

/// What [into] has deleted of [table]: the id of each, and when.
Future<Map<String, int?>> _deletionsIn(AppDatabase into, String table) async => {
      for (final t in await into
          .customSelect('SELECT entity_id, deleted_at FROM tombstones WHERE entity_type = ?', variables: [Variable(table)])
          .get())
        t.read<String>('entity_id'): t.data['deleted_at'] as int?,
    };

/// A deletion stands over a copy that has not changed since.
bool _deletionStands(int? deletedAt, Object? changedAt) => deletedAt == null || changedAt is! int || changedAt <= deletedAt;

/// The tables a restore brings whose rows stand for themselves, parents first: their
/// key, and the table and column a row needs its parent in.
const _keyed = <(String, List<String>, (String, String)?)>[
  ('connection_groups', ['id'], null),
  ('identities', ['id'], null),
  ('snippets', ['id'], null),
  ('connections', ['id'], null),
  // One a restore would not take for lack of a device that recorded it was still
  // pinned here, on this device.
  ('known_hosts', ['host', 'port', 'key_type', 'via_scope'], null),
  ('snippet_categories', ['name'], null),
  ('networks', ['id'], null),
  ('port_forward_rules', ['id'], ('connections', 'connection_id')),
  ('terminal_triggers', ['id'], null),
  ('command_history', ['id'], null),
  ('host_network_overrides', ['connection_id', 'network_id'], ('connections', 'connection_id')),
  ('port_forward_network_overrides', ['rule_id', 'network_id'], ('port_forward_rules', 'rule_id')),
];

/// What a restore leaves out, sets to its safe value or reads as now: what each device
/// decides for itself, what it worked out itself, when a row was made. For a row that
/// came from guest data they stay as they were, as this is the same device.
const _ownColumns = <String, List<String>>{
  'identities': [
    'allow_unattended',
    'agent_socket_path',
    'cert_serial',
    'cert_key_id',
    'cert_principals',
    'cert_ca_fingerprint',
    'cert_valid_before',
    'cert_valid_after',
    'created_at',
  ],
  'connections': ['last_connected', 'created_at'],
  'connection_groups': ['created_at'],
  'snippets': ['created_at'],
  'networks': ['created_at'],
  'port_forward_rules': ['auto_start', 'gateway_ports', 'bind_address', 'created_at'],
  'terminal_triggers': ['created_at'],
  'command_history': ['exit_code', 'duration_ms', 'cwd', 'created_at'],
};

/// A copied table with no key of its own to tell a row it brought already, as a Bring
/// that is run again does: the columns that tell one. Its own number is left to the
/// table.
const _noKey = <String, List<String>>{
  'monitor_samples': ['connection_id', 'captured_at', 'resolution_seconds'],
};

/// The tables of [db], whatever made them.
Future<List<String>> personalTables(AppDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'")
      .get();
  return [for (final r in rows) r.read<String>('name')]..sort();
}

/// What [from] holds that nothing can carry: tables with rows, a team's or one no
/// version of this list knows.
Future<List<String>> guestTablesThatStay(AppDatabase from) async {
  final stay = <String>[];
  for (final table in await personalTables(from)) {
    final fate = kGuestTables[table];
    if (fate != null && fate != GuestTableFate.teamOnly) continue;
    if ((await from.customSelect('SELECT 1 FROM "$table" LIMIT 1').get()).isNotEmpty) stay.add(table);
  }
  return stay;
}

/// Brings from [from] into [into] what the restore did not: the rows it turned away,
/// what it leaves to each device of the rows in [taken] (the items it wrote), the
/// tables it does not know, and the saved tab groups. Run again it brings nothing
/// twice. All of it or none.
Future<void> carryGuestTables({required AppDatabase from, required AppDatabase into, required Set<String> taken}) async {
  final touched = <String>{};
  await into.transaction(() async {
    await _whatTheRestoreLeft(from, into, touched);
    await _whatEachDeviceDecides(from, into, taken, touched);
    for (final entry in kGuestTables.entries) {
      if (entry.value == GuestTableFate.copied) await _copy(from, into, entry.key, touched);
    }
    await _savedTabGroups(from, into);
    await _customThemes(from, into);
    await _whatPointsAtNothing(into, touched);
  });
  // Written by plain statements, which tell no one: what shows them reads again.
  if (touched.isNotEmpty) into.notifyUpdates({for (final table in touched) TableUpdate(table)});
}

Future<void> _insert(AppDatabase into, String table, Map<String, Object?> row) {
  final columns = row.keys.toList();
  return into.customStatement(
    'INSERT OR IGNORE INTO "$table" (${columns.map((c) => '"$c"').join(', ')}) '
    'VALUES (${List.filled(columns.length, '?').join(', ')})',
    [for (final c in columns) row[c]],
  );
}

Future<bool> _holds(AppDatabase db, String table, List<String> key, Map<String, Object?> row) async {
  final found = await db
      .customSelect(
        'SELECT 1 FROM "$table" WHERE ${key.map((c) => '"$c" IS ?').join(' AND ')} LIMIT 1',
        variables: [for (final c in key) _variable(row[c])],
      )
      .get();
  return found.isNotEmpty;
}

Variable<Object> _variable(Object? value) => Variable<Object>(value);

/// Rows of the restore's tables that are not here, as the restore turned them away (a
/// local shell's port, a serial line's address) and not as this account deleted them
/// since they last changed: they come as they are, a host with its tags and accounts.
/// A host key comes as any restore's does ([_hostKeyComes]).
Future<void> _whatTheRestoreLeft(AppDatabase from, AppDatabase into, Set<String> touched) async {
  final hosts = <String>[];
  for (final (table, key, parent) in _keyed) {
    final deletions = await _deletionsIn(into, table);
    for (final row in await from.customSelect('SELECT * FROM "$table"').get()) {
      var data = row.data;
      if (await _holds(into, table, key, data)) continue;
      if (table == 'known_hosts') {
        if (!await _hostKeyComes(into, data)) continue;
        data = {...data, 'locally_verified': 0};
      }
      final id = (data['id'] ?? data['name'])?.toString();
      if (deletions.containsKey(id) && _deletionStands(deletions[id], data['updated_at'])) continue;
      if (parent != null) {
        final (parentTable, column) = parent;
        final up = await into
            .customSelect('SELECT 1 FROM "$parentTable" WHERE id IS ? LIMIT 1', variables: [_variable(data[column])])
            .get();
        if (up.isEmpty) continue;
      }
      await _insert(into, table, data);
      touched.add(table);
      if (table == 'connections') hosts.add(data['id'] as String);
    }
  }
  for (final host in hosts) {
    for (final table in const ['connection_tags', 'host_accounts']) {
      for (final row in await from
          .customSelect('SELECT * FROM "$table" WHERE connection_id = ?', variables: [Variable(host)])
          .get()) {
        await _insert(into, table, row.data);
        touched.add(table);
      }
    }
  }
}

/// Whether guest data's key for a host comes into the account: not where the account
/// confirmed that host itself, on any route to it, as any restore keeps out a key type new
/// to a host confirmed under another (SyncDataService._mergedHostKey; found in a security
/// review). One that comes is the account's to confirm at its
/// first connection: someone else may have used guest data, and accepted a man in the
/// middle's key there, which came in confirmed and was trusted with no question (found in an
/// independent review).
Future<bool> _hostKeyComes(AppDatabase into, Map<String, Object?> key) async {
  final confirmed = await into
      .customSelect(
        'SELECT 1 FROM known_hosts WHERE host IS ? AND port IS ? AND locally_verified = 1 LIMIT 1',
        variables: [_variable(key['host']), _variable(key['port'])],
      )
      .get();
  return confirmed.isEmpty;
}

Future<void> _whatEachDeviceDecides(AppDatabase from, AppDatabase into, Set<String> taken, Set<String> touched) async {
  for (final entry in _ownColumns.entries) {
    final table = entry.key;
    final columns = entry.value;
    final rows = await from.customSelect('SELECT id, updated_at, ${columns.join(', ')} FROM "$table"').get();
    for (final row in rows) {
      final data = row.data;
      if (!taken.contains('$table/${data['id']}')) continue;
      await into.customStatement(
        'UPDATE "$table" SET ${columns.map((c) => '$c = ?').join(', ')} WHERE id = ?',
        [for (final c in columns) data[c], data['id']],
      );
      // A change with no time of its own is stamped as made now: this was none.
      await into.customStatement('UPDATE "$table" SET updated_at = ? WHERE id = ?', [data['updated_at'], data['id']]);
      touched.add(table);
    }
  }
}

Future<void> _copy(AppDatabase from, AppDatabase into, String table, Set<String> touched) async {
  final tells = _noKey[table];
  for (final row in await from.customSelect('SELECT * FROM "$table"').get()) {
    final data = {...row.data};
    if (tells != null) {
      if (await _holds(into, table, tells, data)) continue;
      data.remove('id');
    }
    await _insert(into, table, data);
    touched.add(table);
  }
}

/// Its saved tab groups come after the account's, one the account holds under the same
/// id staying as it is. The list is one row of [LocalState]: nothing else of that table
/// comes.
Future<void> _savedTabGroups(AppDatabase from, AppDatabase into) async {
  final theirs = await LocalStateStore(from).read(kSavedTabGroupsKey);
  if (theirs == null) return;
  final store = LocalStateStore(into);
  final here = await store.read(kSavedTabGroupsKey);
  try {
    final came = jsonDecode(theirs) as List;
    final mine = here == null ? const <Object?>[] : jsonDecode(here) as List;
    final ids = {for (final group in mine) if (group is Map) group['id']};
    final fresh = [for (final group in came) if (group is Map && !ids.contains(group['id'])) group];
    if (fresh.isNotEmpty) await store.write(kSavedTabGroupsKey, jsonEncode([...mine, ...fresh]));
  } on FormatException catch (e) {
    AppLogger.warning('Saved tab groups could not be read (${errorKind(e)})');
  } on TypeError catch (e) {
    AppLogger.warning('Saved tab groups could not be read (${errorKind(e)})');
  }
}

/// Its custom themes come after the account's. One the account has by that name stays
/// as it is, and a number the account uses is changed for a free one, as each profile
/// counts its own. In the settings kept in the database, so whoever holds them in memory
/// reads them again (ProfileController.bringGuestData).
Future<void> _customThemes(AppDatabase from, AppDatabase into) async {
  final theirs = await ProfilePreferences.readStored(from);
  final mine = await ProfilePreferences.readStored(into);
  for (final (key, numbered) in _themeKeys) {
    final coming = _unreadable(() => _themesComing(theirs[key], mine[key], numbered), null, 'Custom themes');
    if (coming == null || coming.come.isEmpty) continue;
    await ProfilePreferences.writeStored(into, key, jsonEncode([...coming.here, ...coming.come]));
  }
}

/// Of the custom themes in the setting [theirs], what comes after those in [mine], and how
/// many stay out: the account has another by the name of each. One it has just the same
/// loses nothing by staying out, as in a Bring that is run again. Throws where a setting
/// is no list of themes.
({List<Object?> here, List<Map<String, dynamic>> come, int stayOut}) _themesComing(Object? theirs, Object? mine, String numbered) {
  List<Object?> read(Object? raw) => raw is String && raw.isNotEmpty ? jsonDecode(raw) as List<Object?> : const [];
  String colours(Map<String, dynamic> theme) => jsonEncode({...theme}..remove('id'));
  final here = read(mine);
  final byName = <Object?, Map<String, dynamic>>{};
  final ids = <Object?>{};
  for (final theme in here.whereType<Map<String, dynamic>>()) {
    byName[theme['name']] = theme;
    ids.add(theme['id']);
  }
  final come = <Map<String, dynamic>>[];
  var stayOut = 0;
  for (final theme in read(theirs).whereType<Map<String, dynamic>>()) {
    if (theme['name'] is! String || theme['id'] is! String) continue;
    final same = byName[theme['name']];
    if (same != null) {
      if (colours(same) != colours(theme)) stayOut++;
      continue;
    }
    var id = theme['id'] as String;
    if (ids.contains(id)) {
      var n = 1;
      while (ids.contains('$numbered$n')) {
        n++;
      }
      id = '$numbered$n';
    }
    ids.add(id);
    byName[theme['name']] = theme;
    come.add({...theme, 'id': id});
  }
  return (here: here, come: come, stayOut: stayOut);
}

/// What came naming what this account has deleted since, as a restore writes each row as
/// it was. A host in a group that is gone shows under no group and not under Ungrouped; a
/// forward of a host that is gone, and what hangs on such a host, belongs to nothing and
/// would sync as it is.
Future<void> _whatPointsAtNothing(AppDatabase into, Set<String> touched) async {
  Future<void> clear(String table, String statement) async {
    if (await into.customUpdate(statement) > 0) touched.add(table);
  }

  await clear(
    'connections',
    'UPDATE connections SET group_id = NULL WHERE group_id IS NOT NULL AND group_id NOT IN (SELECT id FROM connection_groups)',
  );
  for (final table in const ['port_forward_rules', 'host_network_overrides', 'connection_tags', 'host_accounts']) {
    await clear(table, 'DELETE FROM "$table" WHERE connection_id NOT IN (SELECT id FROM connections)');
  }
  await clear(
    'port_forward_network_overrides',
    'DELETE FROM port_forward_network_overrides WHERE rule_id NOT IN (SELECT id FROM port_forward_rules)',
  );
}
