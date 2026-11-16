import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// The tables of your Tree a backup holds (SyncDataService.gatherAll): a
/// change to any of them is a change the next backup should carry.
///
/// Left out: the command history, which changes with every command typed and
/// would make every session end in a backup (it still rides along in each
/// backup made); the settings, which are not in the database (the daily or
/// weekly backup carries them). A key's secrets change with its row.
List<TableInfo<Table, Object?>> backupTables(AppDatabase db) => [
      db.connections,
      db.identities,
      db.connectionGroups,
      db.knownHosts,
      db.snippets,
      db.snippetCategories,
      db.portForwardRules,
      db.terminalTriggers,
      db.networks,
      db.hostNetworkOverrides,
      db.portForwardNetworkOverrides,
      db.connectionTags,
      db.hostAccounts,
    ];

/// The columns of those tables that the app writes by itself as it is used,
/// and that are no change of the person's (3.4.2): each connect writes when
/// the host was last connected to and when its key was last seen (and that
/// this device has now seen it), and that alone marked the backup changed,
/// so every connect ended in a backup on going to the background. A write
/// to one of these tables marks it only where something else in it changed.
Map<TableInfo<Table, Object?>, Set<String>> bookkeepingColumns(AppDatabase db) => {
      db.connections: {'last_connected'},
      db.knownHosts: {'last_seen', 'locally_verified'},
    };

/// What [table] holds, less its [bookkeeping] columns, as one short value:
/// it differs where anything else in it differs.
Future<String> backupContentOf(AppDatabase db, TableInfo<Table, Object?> table, Set<String> bookkeeping) async {
  final name = table.actualTableName;
  final rows = await db.customSelect('SELECT * FROM "$name" ORDER BY rowid', readsFrom: {table}).get();
  final all = BytesBuilder(copy: false);
  for (final row in rows) {
    final kept = {
      for (final e in row.data.entries)
        if (!bookkeeping.contains(e.key)) e.key: e.value is Uint8List ? base64Encode(e.value as Uint8List) : e.value,
    };
    all
      ..add(utf8.encode(jsonEncode(kept)))
      ..addByte(10);
  }
  return sha256.convert(all.takeBytes()).toString();
}

/// Marks the backup dirty ([backupDirtyProvider]) when what a backup holds
/// changes in your Tree, so a backup is made when the app goes to the
/// background (22 October 2026: the flag followed the host list as filtered
/// on screen, so typing in the search box set it, and a change to a key, a
/// snippet or a network did not). Listened to for as long as the app runs;
/// it follows the database as it opens and closes with the app lock, and
/// never an Orchard's. What the app writes by itself as it is used
/// ([bookkeepingColumns]) does not mark it.
final backupDirtyWatchProvider = Provider<void>((ref) {
  final tree = ref.watch(databaseSessionProvider);
  if (tree == null) return;
  var gone = false;
  void mark() {
    if (!gone) ref.read(backupDirtyProvider.notifier).state = true;
  }

  final bookkeeping = bookkeepingColumns(tree);
  final plain = [
    for (final t in backupTables(tree))
      if (!bookkeeping.containsKey(t)) t,
  ];
  final subscriptions = <StreamSubscription<void>>[
    tree.tableUpdates(TableUpdateQuery.onAllTables(plain)).listen((_) => mark()),
  ];
  for (final entry in bookkeeping.entries) {
    // What it held when the watch began, then after each write to it, in
    // turn: a write is a change only where the rest differs.
    Future<String?> last = backupContentOf(tree, entry.key, entry.value).then<String?>((v) => v, onError: (_) => null);
    subscriptions.add(tree.tableUpdates(TableUpdateQuery.onTable(entry.key)).listen((_) {
      last = last.then((before) async {
        if (gone) return before;
        try {
          final now = await backupContentOf(tree, entry.key, entry.value);
          if (now != before) mark();
          return now;
        } catch (_) {
          // (Not read: the database closed meanwhile, or it could not be
          // read. Taken for a change, as every write was before.)
          mark();
          return null;
        }
      });
    }));
  }
  ref.onDispose(() {
    gone = true;
    for (final s in subscriptions) {
      unawaited(s.cancel());
    }
  });
});
