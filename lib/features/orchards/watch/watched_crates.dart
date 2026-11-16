import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/l10n_global.dart';

// Watched Crates on this device (3.0, session moderation). An
// Orchard's owners can mark a Crate as watched, in the signed record: a
// session to one of its hosts then starts only once someone else who
// manages the Crate has joined to watch it, is held while nobody does, and
// can be ended by whoever watches (session_watch.dart). ZestSSH puts no
// machine of its own between a member and a host, so this is a rule the
// app keeps, like the other guardrails (guardrails.dart): what a device
// reads here is its own copy of the record, and it is the device that
// holds to it.

// (The reader of that copy lives beside the record itself; it is handed on
// from here under its name, for whoever asked for it here.)
export 'package:zestssh/features/orchards/record/local_record.dart' show latestRecordIn;

/// The watched Crate a host is in.
@immutable
class WatchedHost {
  const WatchedHost({required this.orchardId, required this.crateId, required this.crateName});

  final String orchardId;
  final String crateId;

  /// The Crate's name as this device has it ('' when it has none).
  final String crateName;
}

/// The watched Crate the host [connectionId] of [db] is in, or null when
/// its sessions are not watched: your Tree's hosts never are, and an
/// Orchard's are when the record marks their Crate as watched. A host that
/// is not saved (a quick connect) counts as one of the Crate new items go
/// into, as everywhere.
Future<WatchedHost?> watchedHostIn(AppDatabase db, String connectionId) async {
  final record = await latestRecordIn(db);
  if (record == null) return null;
  final crateId = await CratePlacement(db).crateOf('host', connectionId);
  if (crateId == null || !(record.crates[crateId]?.watched ?? false)) return null;
  final name = await db
      .customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?', variables: [Variable(crateId)])
      .getSingleOrNull();
  return WatchedHost(orchardId: record.orchardId, crateId: crateId, crateName: name?.read<String?>('name') ?? '');
}

/// Whether sessions to the host [connectionId] of [db] are watched.
Future<bool> hostIsWatchedIn(AppDatabase db, String connectionId) async =>
    await watchedHostIn(db, connectionId) != null;

/// A remote screen (4.0) is never opened where its team watches sessions: a
/// watched session is a terminal someone else who manages the Crate follows,
/// and nobody can follow a screen yet. Throws [OrchardAccessRefused] with
/// [refusal] when the screen [screenId] of [db], or its carrier [carrierId]
/// (the SSH host it is reached through, a hop of the session), is in a
/// watched Crate: said before anything is asked of anyone or dialled, as a
/// files-only session to such a host is.
Future<void> refuseScreenWhereWatched(AppDatabase db, String screenId,
    {String? carrierId, required String refusal}) async {
  if (await hostIsWatchedIn(db, screenId)) throw OrchardAccessRefused(refusal);
  if (carrierId != null && await hostIsWatchedIn(db, carrierId)) throw OrchardAccessRefused(refusal);
}

/// Whether a test connection from the host editor would sign in to a
/// watched Crate's host, or with one of a watched Crate's keys: [hostId]
/// is the host being edited (null for a new one, which would go into the
/// Crate new items go into) and [keyId] the key the test would use.
Future<bool> testWouldGoUnwatchedIn(AppDatabase db, {String? hostId, String? keyId}) async {
  final record = await latestRecordIn(db);
  if (record == null) return false;
  final placement = CratePlacement(db);
  final crates = [
    await placement.crateOf('host', hostId ?? ''),
    if (keyId != null) await placement.crateOf('key', keyId),
  ];
  return crates.any((c) => c != null && (record.crates[c]?.watched ?? false));
}

/// Whether the account [uid] may watch a session of the Crate [crateId] at
/// [nowSeconds], by [record]: they manage the Crate.
bool mayWatch(OrchardRecord record, String crateId, String uid, int nowSeconds) =>
    record.switchesAt(uid, crateId, nowSeconds).contains(CrateSwitches.manage);

/// Throws [OrchardAccessRefused] when the key [identityId] of [db] is in a
/// watched Crate and would sign in to anything but a host of that same
/// Crate. Sessions to those hosts are the ones that are watched, so the
/// Crate's keys sign in nowhere else: not to a host of another Crate, and
/// not to an address typed for a quick connect.
Future<void> requireWatchedKeyHostIn(AppDatabase db, String identityId, String connectionId) async {
  final record = await latestRecordIn(db);
  if (record == null) return;
  final placement = CratePlacement(db);
  final keyCrate = await placement.crateOf('key', identityId);
  if (keyCrate == null || !(record.crates[keyCrate]?.watched ?? false)) return;
  if (await placement.crateOf('host', connectionId) != keyCrate) {
    throw OrchardAccessRefused(gl10n.watchedKeyOtherHost);
  }
}
