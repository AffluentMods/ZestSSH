import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';

/// The space each host's sessions were opened from (3.0; "sessions
/// keep their space"). A session keeps reading and writing its own space
/// after you switch to another one: its keys and jump hosts, its command
/// history, when you last connected, and its reconnects. A host lives in
/// exactly one space, so its id is enough to find it.
class SessionSpaces {
  SessionSpaces(this._ref);

  final Ref _ref;
  final _spaces = <String, Space>{};

  /// A session of [connectionId] is starting: from [space] where it is
  /// given (another session of the host, opened again or beside it, starts
  /// in the space that one works in), else from the space on screen.
  void opened(String connectionId, {Space? space}) =>
      _spaces[connectionId] = space ?? _ref.read(activeSpaceProvider);

  /// The space the host's sessions work in, where one has been opened.
  Space? spaceOf(String connectionId) => _spaces[connectionId];

  /// The database the host's sessions work in. Null when the host's space is
  /// an Orchard that has closed since (the app locked, or it left the
  /// device), so nothing of its sessions lands anywhere else.
  AppDatabase? database(String connectionId) {
    final space = _spaces[connectionId];
    if (space == null) return _ref.read(databaseProvider);
    return databaseForSpace(_ref, space);
  }

  /// [database] for reads: the space on screen when the host's own has
  /// closed.
  AppDatabase readDatabase(String connectionId) =>
      database(connectionId) ?? _ref.read(databaseProvider);

  /// The known hosts the host's sessions check keys against and trust them
  /// into: its own space's, never the one on screen (a reconnect after you
  /// switched spaces must not leave an Orchard host's key in your Tree).
  /// Null when that space has closed: then nothing is trusted.
  KnownHostsService? knownHosts(String connectionId) {
    final db = database(connectionId);
    return db == null ? null : KnownHostsService(db.knownHostsDao);
  }
}
