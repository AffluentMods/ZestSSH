import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DriftSqlType, GeneratedColumn, Table, TableInfo, Variable;
import 'package:zestssh/core/models/host_icon_limits.dart';
import 'package:zestssh/core/models/shared_pins.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/utils/type_name.dart';

/// Whether a team's host may not say it is reached with [protocol]: a shell on
/// the computer of whoever opens it. A team's record is written by anyone who
/// may add or edit in its vault, and a local shell runs what its start-up
/// command says as that person, on their own computer (found in a security
/// review). What goes to an address may stay: Serial is SSH to a console
/// server, checked as any SSH host is.
bool teamMayNotOpenWith(String? protocol) {
  final p = protocol?.toLowerCase();
  return p == 'localshell' || p == 'local';
}

/// A record that is well made and that this device does not take: the rows stay
/// as they were, and it says why. A [FormatException], so that whatever writes
/// records treats it as any record that cannot be written.
class RecordRefused extends FormatException implements HasTypeName {
  const RecordRefused(super.message);

  @override
  String get typeName => 'RecordRefused';
}

/// An Orchard's items as rows (3.0): reads an item's rows as its
/// record carries them, and writes a record's rows back.
///
/// An item is the rows [AppDatabase.orchardItemTables] lists for its kind,
/// the main table first: a host is its connection, tags and per-network
/// overrides. A record carries only the columns that travel; the ones that
/// stay on this device (pins, order, when you last connected) keep their
/// values when a record is written over them.
class OrchardItemStore {
  OrchardItemStore(this._db);

  final AppDatabase _db;

  /// The tables of each kind, the main table first.
  static final Map<String, List<String>> tablesOfKind = () {
    final out = <String, List<String>>{};
    for (final e in AppDatabase.orchardItemTables.entries) {
      out.putIfAbsent(e.value.$1, () => []).add(e.key);
    }
    return out;
  }();

  static bool isKind(String kind) => tablesOfKind.containsKey(kind);

  List<String> _tables(String kind) {
    final tables = tablesOfKind[kind];
    if (tables == null) throw ArgumentError.value(kind, 'kind', 'not an item kind');
    return tables;
  }

  static String _keyColumn(String table) => AppDatabase.orchardItemTables[table]!.$2;

  static String _q(String column) => '"$column"';

  /// Columns a record carries only when they hold a value, table by table: a
  /// column a newer version added for one kind of item alone. Left out while
  /// null, so every other item's record stays exactly what the version before
  /// the column wrote, byte for byte (the remote screen's options, 4.0, are
  /// set on a VNC host only; a team host's shared SFTP bookmarks, 4.0, set
  /// only where a member shared one). A record that leaves one out clears it.
  static const writtenOnlyWhenSet = <String, Set<String>>{
    'connections': {'screen_options', 'shared_pins'},
  };

  /// Whether the item's main row exists.
  Future<bool> exists(String kind, String key) async {
    final main = _tables(kind).first;
    final rows = await _db.customSelect(
      'SELECT 1 FROM $main WHERE ${_q(_keyColumn(main))} = ? LIMIT 1',
      variables: [Variable<String>(key)],
    ).get();
    return rows.isNotEmpty;
  }

  /// The item's rows now, table by table, or null when its main row is gone.
  /// Rows are in a fixed order, so the same item reads the same on every
  /// device however its rows were written.
  Future<Map<String, Object?>?> read(String kind, String key) async {
    final tables = _tables(kind);
    final data = <String, Object?>{};
    for (final table in tables) {
      final columns = _db.orchardRecordColumns(table);
      final rows = await _db.customSelect(
        'SELECT ${columns.map(_q).join(', ')} FROM $table '
        'WHERE ${_q(_keyColumn(table))} = ?',
        variables: [Variable<String>(key)],
      ).get();
      if (table == tables.first && rows.isEmpty) return null;
      final onlyWhenSet = writtenOnlyWhenSet[table] ?? const <String>{};
      final encoded = [
        for (final r in rows)
          {
            for (final c in columns)
              if (r.data[c] != null || !onlyWhenSet.contains(c)) c: _encode(r.data[c]),
          },
      ]..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
      data[table] = encoded;
    }
    return data;
  }

  /// Writes an item as a record carries it, or deletes it when [data] is
  /// null. Columns this device does not know are left out; every row must
  /// belong to this item, and a row that would replace another item's is
  /// skipped. Throws [FormatException] on a malformed record (a value that is
  /// not of its column's type, or a required column left out, which would stop
  /// every reader of the table or the write), and [RecordRefused] on a host that
  /// would open a shell on this computer, or that would turn a host held here
  /// into another kind (SSH-like, FTPS, a remote screen), before anything is
  /// written. A host's
  /// uploaded picture over [kMaxHostIconChars] is dropped and the host kept.
  /// Call it inside a transaction that has switched the outbox triggers off.
  Future<void> write(
    String kind,
    String key, {
    required Map<String, Object?>? data,
    required int editedAt,
  }) async {
    final tables = _tables(kind);
    if (data == null) {
      for (final table in tables.reversed) {
        await _db.customStatement(
            'DELETE FROM $table WHERE ${_q(_keyColumn(table))} = ?', [key]);
      }
      return;
    }

    // Check everything first: a bad record changes nothing.
    final checked = <String, List<Map<String, Object?>>>{};
    for (final table in tables) {
      final raw = data[table];
      if (raw != null && raw is! List) throw FormatException('$table is not a list');
      final allowed = _db.orchardRecordColumns(table).toSet();
      final columns = {
        for (final c in _info(table).$columns)
          if (allowed.contains(c.name)) c.name: c,
      };
      checked[table] = [
        for (final row in (raw as List?) ?? const [])
          _checkRow(row, columns: columns, keyColumn: _keyColumn(table), key: key),
      ];
    }
    if (checked[tables.first]!.length != 1) {
      throw const FormatException('an item has exactly one main row');
    }
    if (kind == 'host') {
      final host = checked[tables.first]!.single;
      if (teamMayNotOpenWith(host['protocol'] as String?)) {
        throw const RecordRefused('a team host may not open a shell on this computer');
      }
      // A team's host never changes kind class (ConnectionProtocol.kindClassOf).
      // This device's own change is refused by the trigger
      // trg_gd_connections_kind, which is off while a record is written here,
      // so a record is asked the same. The app sends none (its trigger, the
      // editor, a setup file); a changed client of a member who may edit the
      // host could, and the host was then taken as another kind (found in a
      // security review). A record with no protocol leaves it as it is.
      if (host.containsKey('protocol')) {
        final main = tables.first;
        final held = await _db.customSelect(
          'SELECT protocol FROM $main WHERE ${_q(_keyColumn(main))} = ? LIMIT 1',
          variables: [Variable<String>(key)],
        ).get();
        if (held.isNotEmpty &&
            ConnectionProtocol.kindClassOf(held.single.data['protocol'] as String?) !=
                ConnectionProtocol.kindClassOf(host['protocol'] as String?)) {
          throw const RecordRefused('a team host does not change kind');
        }
      }
      final icon = host['custom_icon'];
      if (icon is String && icon.length > kMaxHostIconChars) host['custom_icon'] = null;
      // A remote screen's options belong to a VNC host alone, as a JSON
      // object within their bound; anything else is dropped and the host kept.
      if (host.containsKey('screen_options')) {
        host['screen_options'] = ConnectionProtocol.storedIsScreen(host['protocol'] as String?)
            ? ScreenOptions.sanitize(host['screen_options'])
            : null;
      }
      // The team's shared SFTP bookmarks, as a list within their bounds:
      // anything else is dropped and the host kept.
      if (host.containsKey('shared_pins')) {
        host['shared_pins'] = sanitizeSharedPinsJson(host['shared_pins']);
      }
    }

    final seconds = editedAt ~/ 1000;
    for (final table in tables) {
      final keyColumn = _keyColumn(table);
      final hasUpdatedAt = _hasUpdatedAt(table);
      if (table == tables.first) {
        final row = checked[table]!.single;
        // A column written only when set is cleared by a record without it.
        for (final c in writtenOnlyWhenSet[table] ?? const <String>{}) {
          row.putIfAbsent(c, () => null);
        }
        final columns = [...row.keys, if (hasUpdatedAt) 'updated_at'];
        final values = [...row.values, if (hasUpdatedAt) seconds];
        final updates = [
          for (final c in columns)
            if (c != keyColumn) '${_q(c)} = excluded.${_q(c)}',
        ];
        await _db.customStatement(
          'INSERT INTO $table (${columns.map(_q).join(', ')}) '
          'VALUES (${List.filled(columns.length, '?').join(', ')}) '
          'ON CONFLICT(${_q(keyColumn)}) DO '
          '${updates.isEmpty ? 'NOTHING' : 'UPDATE SET ${updates.join(', ')}'}',
          values,
        );
      } else {
        await _db.customStatement(
            'DELETE FROM $table WHERE ${_q(keyColumn)} = ?', [key]);
        for (final row in checked[table]!) {
          final columns = [...row.keys, if (hasUpdatedAt) 'updated_at'];
          final values = [...row.values, if (hasUpdatedAt) seconds];
          // OR IGNORE: a row whose id another item's row already has is
          // skipped, never taken over.
          await _db.customStatement(
            'INSERT OR IGNORE INTO $table (${columns.map(_q).join(', ')}) '
            'VALUES (${List.filled(columns.length, '?').join(', ')})',
            values,
          );
        }
      }
    }
  }

  /// What a record carries that this version does not know: its rows
  /// ([data]) hold whole tables and columns of known tables, and [record] is
  /// the record's own unknown fields. A column this version keeps on the
  /// device is known, so it is neither written nor carried along.
  ItemExtras extrasOf(
    String kind,
    Map<String, Object?> data, {
    Map<String, Object?> record = const {},
  }) {
    final tables = _tables(kind);
    final unknownTables = <String, Object?>{};
    final columns = <String, List<Map<String, Object?>>>{};
    for (final entry in data.entries) {
      final table = entry.key;
      if (!tables.contains(table)) {
        unknownTables[table] = entry.value;
        continue;
      }
      final rows = entry.value;
      if (rows is! List) continue;
      final known = _columnsOf(table);
      final key = _primaryKey(table);
      final kept = <Map<String, Object?>>[];
      for (final row in rows) {
        if (row is! Map<String, dynamic>) continue;
        final unknown = {
          for (final e in row.entries)
            if (!known.contains(e.key)) e.key: e.value,
        };
        if (unknown.isEmpty) continue;
        kept.add({for (final c in key) c: row[c], ...unknown});
      }
      if (kept.isNotEmpty) columns[table] = kept;
    }
    return ItemExtras(record: record, tables: unknownTables, columns: columns);
  }

  /// [data] read from this device with [extras] put back, to send: unknown
  /// tables whole, unknown columns into the rows they came from. A row
  /// deleted here takes its unknown columns with it.
  Map<String, Object?> withExtras(String kind, Map<String, Object?> data, ItemExtras extras) =>
      _merge(data, extras, keptWins: false);

  /// Takes into the rows what kept extras carry that this version now
  /// knows: after an update adds a column or a table, the values an older
  /// version kept for it are written in, quietly, as they arrived, and only
  /// what is still unknown stays kept. Runs when an Orchard's database
  /// opens, before anything can edit it, so a value never goes back out
  /// blank. Record fields a newer version learns are its own to take from
  /// [ItemExtras.record]. Returns how many items changed.
  Future<int> absorbKnownExtras() async {
    final kept = await _db
        .customSelect(
            'SELECT kind, item_key, edited_at, extra FROM crate_items_meta WHERE extra IS NOT NULL')
        .get();
    if (kept.isEmpty) return 0;
    var changed = 0;
    await _db.transaction(() async {
      await _db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      try {
        for (final row in kept) {
          final kind = row.read<String>('kind');
          if (!isKind(kind)) continue;
          final key = row.read<String>('item_key');
          final extras = ItemExtras.decode(row.read<String?>('extra'));
          if (!_knowsSomeOf(kind, extras)) continue;
          final data = await read(kind, key);
          if (data == null) continue;
          final merged = _merge(data, extras, keptWins: true);
          try {
            await write(kind, key,
                data: merged,
                editedAt: row.read<int?>('edited_at') ?? DateTime.now().millisecondsSinceEpoch);
          } on FormatException {
            continue; // Rows this version cannot take: they stay kept as they are.
          }
          await _db.customStatement(
            'UPDATE crate_items_meta SET extra = ? WHERE kind = ? AND item_key = ?',
            [extrasOf(kind, merged, record: extras.record).encode(), kind, key],
          );
          changed++;
        }
      } finally {
        await _db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      }
    });
    if (changed > 0) _db.notifyOrchardItemsChanged();
    return changed;
  }

  /// Whether [extras] hold a table or a column this version knows.
  bool _knowsSomeOf(String kind, ItemExtras extras) {
    final tables = _tables(kind);
    if (extras.tables.keys.any(tables.contains)) return true;
    for (final entry in extras.columns.entries) {
      if (!tables.contains(entry.key)) continue;
      final known = _columnsOf(entry.key);
      final key = _primaryKey(entry.key);
      for (final row in entry.value) {
        if (row.keys.any((c) => !key.contains(c) && known.contains(c))) return true;
      }
    }
    return false;
  }

  /// [data] with [extras] put back. A table with no rows here takes the
  /// kept rows whole; kept columns go into the rows with the same primary
  /// key. [keptWins] decides a column both have, which happens only after
  /// an update taught this version the column: then the kept value is the
  /// real one.
  Map<String, Object?> _merge(
    Map<String, Object?> data,
    ItemExtras extras, {
    required bool keptWins,
  }) {
    if (extras.tables.isEmpty && extras.columns.isEmpty) return data;
    final out = {...data};
    for (final entry in extras.tables.entries) {
      final here = out[entry.key];
      if (here is List && here.isNotEmpty) continue;
      out[entry.key] = entry.value;
    }
    for (final entry in extras.columns.entries) {
      final rows = out[entry.key];
      if (rows is! List) continue; // Only tables this version reads.
      final key = _primaryKey(entry.key);
      out[entry.key] = [
        for (final row in rows) _mergeRow(row, entry.value, key, keptWins: keptWins),
      ];
    }
    return out;
  }

  static Object? _mergeRow(
    Object? row,
    List<Map<String, Object?>> kept,
    List<String> key, {
    required bool keptWins,
  }) {
    if (row is! Map<String, Object?>) return row;
    for (final extra in kept) {
      if (!key.every((c) => extra[c] == row[c])) continue;
      final unknown = {
        for (final e in extra.entries)
          if (!key.contains(e.key)) e.key: e.value,
      };
      return keptWins ? {...row, ...unknown} : {...unknown, ...row};
    }
    return row;
  }

  Set<String> _columnsOf(String table) => {for (final c in _info(table).$columns) c.name};

  TableInfo<Table, Object?> _info(String table) =>
      _db.allTables.firstWhere((t) => t.actualTableName == table);

  List<String> _primaryKey(String table) =>
      [for (final c in _info(table).$primaryKey) c.name]..sort();

  bool _hasUpdatedAt(String table) =>
      _info(table).$columns.any((c) => c.name == 'updated_at');

  static Map<String, Object?> _checkRow(
    Object? raw, {
    required Map<String, GeneratedColumn> columns,
    required String keyColumn,
    required String key,
  }) {
    if (raw is! Map<String, dynamic>) throw const FormatException('a row is not an object');
    if (raw[keyColumn] != key) {
      throw const FormatException('a row belongs to another item');
    }
    final row = {
      for (final e in raw.entries)
        if (columns.containsKey(e.key)) e.key: _decode(e.value),
    };
    for (final c in columns.values) {
      final value = row[c.name];
      if (value == null) {
        final hasDefault = c.defaultValue != null || c.clientDefault != null;
        if (!c.$nullable && (row.containsKey(c.name) || !hasDefault)) {
          throw const FormatException('a row leaves out a column it needs');
        }
      } else if (!_fits(c, value)) {
        // SQLite would keep it, and every read of the table would then throw:
        // one such row took a whole space's hosts off everyone's screen.
        throw const FormatException('a value is not of its column\'s type');
      }
    }
    return row;
  }

  /// The first second of the year 1 and the last of the year 9999, in seconds
  /// since 1970: the dates a team item may hold.
  static const _earliestSeconds = -62135596800;
  static const _latestSeconds = 253402300799;

  /// Whether [value], not null, is what [column] holds.
  static bool _fits(GeneratedColumn column, Object value) => switch (column.type) {
        DriftSqlType.string => value is String,
        // A date is kept in seconds, and must be one a DateTime holds (the years 1
        // to 9999): a member's item whose date was 10^13 passed `is int`, and
        // every read of the team's hosts then threw (found in a
        // security review).
        DriftSqlType.dateTime => value is int && value >= _earliestSeconds && value <= _latestSeconds,
        DriftSqlType.int || DriftSqlType.bigInt || DriftSqlType.bool => value is int,
        DriftSqlType.double => value is num,
        DriftSqlType.blob => value is Uint8List,
        _ => true,
      };

  /// JSON has no bytes: a blob travels as {"b64": "..."}.
  static Object? _encode(Object? value) =>
      value is Uint8List ? {'b64': base64Encode(value)} : value;

  static Object? _decode(Object? value) {
    if (value == null || value is int || value is double || value is String) {
      return value;
    }
    if (value is bool) return value ? 1 : 0;
    if (value is Map && value.length == 1 && value['b64'] is String) {
      return base64Decode(value['b64'] as String);
    }
    throw const FormatException('a value is not a column value');
  }
}

/// What the last version of an item received from its Crate carried that
/// this app version does not know, kept beside the item
/// (crate_items_meta.extra): record fields, whole tables, and columns of
/// known tables with each row's primary key. Sent back with every version
/// this device writes, so an older app never erases what a newer one added,
/// and taken into the rows once an update teaches the app what they are
/// ([OrchardItemStore.absorbKnownExtras]).
class ItemExtras {
  const ItemExtras({
    this.record = const {},
    this.tables = const {},
    this.columns = const {},
  });

  static const none = ItemExtras();

  /// Record fields this version does not know.
  final Map<String, Object?> record;

  /// Tables this version does not know, their rows whole.
  final Map<String, Object?> tables;

  /// For each table this version knows, its rows' unknown columns, every
  /// row with its primary key.
  final Map<String, List<Map<String, Object?>>> columns;

  bool get isEmpty => record.isEmpty && tables.isEmpty && columns.isEmpty;

  /// As kept in crate_items_meta.extra: null when there is nothing.
  String? encode() => isEmpty
      ? null
      : jsonEncode({
          if (record.isNotEmpty) 'record': record,
          if (tables.isNotEmpty) 'tables': tables,
          if (columns.isNotEmpty) 'columns': columns,
        });

  /// Reads what [encode] wrote. Anything unreadable counts as nothing kept.
  static ItemExtras decode(String? json) {
    if (json == null) return none;
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return none;
    }
    if (decoded is! Map<String, dynamic>) return none;
    final record = decoded['record'];
    final tables = decoded['tables'];
    final columns = decoded['columns'];
    return ItemExtras(
      record: record is Map<String, dynamic> ? record : const {},
      tables: tables is Map<String, dynamic> ? tables : const {},
      columns: {
        if (columns is Map<String, dynamic>)
          for (final e in columns.entries)
            if (e.value is List)
              e.key: [
                for (final row in e.value as List)
                  if (row is Map<String, dynamic>) row,
              ],
      },
    );
  }
}
