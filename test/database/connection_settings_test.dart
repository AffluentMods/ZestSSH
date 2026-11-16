import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/setup/setup_command_host.dart';

/// `zestssh admin` beside the open app, or a second start, works on the same
/// database file. No connection waited for a lock
/// another one held, so a write in either failed at once with "database is
/// locked"; and a run for a command opened every saved tab and then cleared
/// them, so the next ordinary start had none to bring back.
void main() {
  test('every connection waits up to five seconds for a lock and logs ahead', () {
    final dir = Directory.systemTemp.createTempSync('zest_conn_settings_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = sqlite.sqlite3.open('${dir.path}/a.db');
    addTearDown(db.dispose);
    AppDatabase.applyConnectionSettings(db);
    expect(db.select('PRAGMA busy_timeout').first.values.first, 5000);
    expect(db.select('PRAGMA journal_mode').first.values.first, 'wal');
  });

  test('a write waits for another connection that holds the lock a moment, instead of failing', () async {
    final dir = Directory.systemTemp.createTempSync('zest_conn_lock_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/a.db';
    final holder = sqlite.sqlite3.open(path);
    addTearDown(holder.dispose);
    AppDatabase.applyConnectionSettings(holder);
    holder.execute('CREATE TABLE t (x INTEGER)');
    holder.execute('BEGIN IMMEDIATE');
    holder.execute('INSERT INTO t VALUES (1)');
    // The other connection runs in an isolate of its own, as another process
    // would, while this one holds the write lock for 300 ms.
    final other = Isolate.run(() {
      final db = sqlite.sqlite3.open(path);
      try {
        AppDatabase.applyConnectionSettings(db);
        db.execute('INSERT INTO t VALUES (2)');
        return 'written';
      } catch (e) {
        return '$e';
      } finally {
        db.dispose();
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    holder.execute('COMMIT');
    expect(await other, 'written');
    expect(holder.select('SELECT COUNT(*) FROM t').first.values.first, 2);
  });

  test('a run for a command brings no saved tab back; an ordinary start does', () {
    addTearDown(() => startedForACommand = false);
    expect(restoresSavedTabsAtStart(), isTrue);
    startedForACommand = true;
    expect(restoresSavedTabsAtStart(), isFalse);
  });
}
