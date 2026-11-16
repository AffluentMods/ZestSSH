import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_messages.dart';

/// Someone a session could be shared with: a member who can open the host's
/// Crate now.
@immutable
class ShareCandidate {
  const ShareCandidate({
    required this.uid,
    required this.email,
    required this.level,
    required this.party,
    this.canManage = false,
  });

  final String uid;
  final String? email;

  /// What they may do in the Crate.
  final CrateLevel level;

  /// They manage the Crate: who watches a watched Crate's sessions (3.0).
  ///
  final bool canManage;

  /// The keys this device has for them; null when it has none yet.
  final ShareParty? party;

  /// Nothing is shared with someone whose keys changed since they were
  /// compared, or whose keys this device has never seen: compare them
  /// first.
  bool get keysChanged => party == null || party!.keysChanged;

  /// In a live view, someone at the lowest level watches and is never given
  /// the keyboard.
  bool get watchOnly => level == CrateLevel.connect;
}

/// What sharing a session of one host involves, worked out from the
/// Orchard's record and the keys this device has pinned.
@immutable
class ShareContext {
  const ShareContext({
    required this.orchardId,
    required this.crateId,
    required this.crateName,
    required this.connectionId,
    required this.myUid,
    required this.people,
    required this.withoutAccess,
    required this.sessionLogs,
    required this.synced,
    this.watched = false,
  });

  final String orchardId;
  final String crateId;
  final String crateName;
  final String connectionId;
  final String myUid;

  /// Everyone else who can open the Crate now.
  final List<ShareCandidate> people;

  /// Members of the Orchard who cannot open the Crate (their addresses, or
  /// their ids when this device has none): they cannot join.
  final List<String> withoutAccess;

  /// The Crate logs sessions: the shared one is logged too.
  final bool sessionLogs;

  /// The Crate's sessions are watched (3.0): this one runs only
  /// while someone who manages the Crate watches it.
  final bool watched;

  /// The host has reached ZestSSH Cloud, so the others have it too. A
  /// shared tmux session needs that: people connect to the host themselves.
  final bool synced;
}

/// What sharing a session of the host [connectionId] in [db] involves, or
/// null when the host is not in a Crate (it is in your Tree, where ZestSSH
/// knows nobody else and has checked nobody's keys).
Future<ShareContext?> shareContextFor(
  AppDatabase db,
  String connectionId, {
  required String myUid,
  required int nowSeconds,
}) async {
  if (!db.isOrchard) return null;
  final info = await db.customSelect('SELECT orchard_id FROM orchard_info WHERE id = 1').getSingleOrNull();
  final orchardId = info?.read<String?>('orchard_id');
  final crateId = await CratePlacement(db).crateOf('host', connectionId);
  if (orchardId == null || crateId == null) return null;
  final record = (await LocalRecord.load(db, orchardId)).latest;
  if (!record.crates.containsKey(crateId)) return null;
  final name = await db
      .customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?', variables: [Variable(crateId)])
      .getSingleOrNull();
  final meta = await db.customSelect(
    "SELECT server_revision FROM crate_items_meta WHERE kind = 'host' AND item_key = ?",
    variables: [Variable(connectionId)],
  ).getSingleOrNull();

  final directory = MemberDirectory(db);
  final views = {for (final v in await directory.view(myUid)) v.uid: v};
  final pins = await directory.pins();
  final holders = record.holdersAt(crateId, nowSeconds).toSet();
  final people = <ShareCandidate>[];
  final without = <String>[];
  for (final m in record.members.values) {
    if (m.uid == myUid || m.status != MemberStatus.active) continue;
    final view = views[m.uid];
    if (!holders.contains(m.uid)) {
      without.add(view?.email ?? m.uid);
      continue;
    }
    final pin = pins[m.uid];
    final switches = record.switchesAt(m.uid, crateId, nowSeconds);
    people.add(ShareCandidate(
      uid: m.uid,
      email: view?.email,
      level: levelOf(switches) ?? CrateLevel.connect,
      canManage: switches.contains(CrateSwitches.manage),
      party: pin == null
          ? null
          : ShareParty(
              uid: m.uid,
              keyVersion: pin.keyVersion,
              signingKey: pin.signingKey,
              encryptionKey: pin.encryptionKey,
              keysChanged: view == null || view.hardStop || view.replacedSinceCompared,
            ),
    ));
  }
  int byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  people.sort((a, b) => byName(a.email ?? a.uid, b.email ?? b.uid));
  without.sort(byName);
  return ShareContext(
    orchardId: orchardId,
    crateId: crateId,
    crateName: name?.read<String?>('name') ?? '',
    connectionId: connectionId,
    myUid: myUid,
    people: people,
    withoutAccess: without,
    sessionLogs: record.crates[crateId]?.sessionLogs ?? false,
    synced: meta?.read<int?>('server_revision') != null,
    watched: record.crates[crateId]?.watched ?? false,
  );
}

/// The keys [db]'s device has pinned for [uid] now, as a share needs them;
/// null when it has none.
Future<ShareParty?> sharePartyOf(AppDatabase db, String uid, {required String myUid}) async {
  final directory = MemberDirectory(db);
  final pin = await directory.pin(uid);
  if (pin == null) return null;
  MemberView? view;
  for (final v in await directory.view(myUid)) {
    if (v.uid == uid) view = v;
  }
  return ShareParty(
    uid: uid,
    keyVersion: pin.keyVersion,
    signingKey: pin.signingKey,
    encryptionKey: pin.encryptionKey,
    keysChanged: view == null || view.hardStop || view.replacedSinceCompared,
  );
}

/// The shared sessions of this run, by session id: what the session's
/// terminal feeds, and what the session header shows. A session is shared
/// once at a time; its share ends with it.
abstract final class SessionShares {
  static final _hosts = <String, ShareHostController>{};
  static final _listeners = <String, VoidCallback>{};
  static final _names = <String, Map<String, String>>{};

  /// The sessions being shared, for whoever shows them.
  static final active = ValueNotifier<Map<String, ShareHostController>>(const {});

  static ShareHostController? of(String sessionId) => _hosts[sessionId];

  static void _publish() => active.value = Map.unmodifiable(_hosts);

  /// Who the account [uid] is in the share of [sessionId]: their address
  /// when this device knows it, else the id.
  static String nameOf(String sessionId, String uid) => _names[sessionId]?[uid] ?? uid;

  /// More names for the share of [sessionId] (people invited later).
  static void addNames(String sessionId, Map<String, String> names) {
    if (_hosts.containsKey(sessionId)) (_names[sessionId] ??= {}).addAll(names);
  }

  /// [sessionId] is now shared through [controller]; [names] are the
  /// addresses of the people it could be shared with. A share it already
  /// had is stopped.
  static void add(String sessionId, ShareHostController controller, {Map<String, String> names = const {}}) {
    final before = _hosts[sessionId];
    if (before != null) {
      _forget(sessionId);
      unawaited(before.stop());
    }
    _hosts[sessionId] = controller;
    _names[sessionId] = {...names};
    // One that ends from the other side (the server ended it, this device
    // was signed out) is no longer shown as shared. (It is this session's
    // share for as long as this listens: [_forget] takes the listener off.)
    void ended() {
      if (controller.isEnded) {
        _forget(sessionId);
        _publish();
      }
    }

    _listeners[sessionId] = ended;
    controller.addListener(ended);
    _publish();
  }

  static void _forget(String sessionId) {
    _names.remove(sessionId);
    final controller = _hosts.remove(sessionId);
    final listener = _listeners.remove(sessionId);
    if (controller != null && listener != null) controller.removeListener(listener);
  }

  /// The terminal of [sessionId] was just sent [text] and shows it.
  static void output(String sessionId, String text) => _hosts[sessionId]?.output(text);

  /// The terminal of [sessionId] is now [columns] by [rows].
  static void resized(String sessionId, int columns, int rows) => _hosts[sessionId]?.resized(columns, rows);

  /// The person sharing stops sharing [sessionId].
  static Future<void> stop(String sessionId) async {
    final controller = _hosts[sessionId];
    if (controller == null) return;
    _forget(sessionId);
    _publish();
    await controller.stop();
  }

  /// [sessionId] closed (or lost its connection): its share ends, and those
  /// watching are told the session closed.
  static void sessionClosed(String sessionId) {
    final controller = _hosts[sessionId];
    if (controller == null) return;
    _forget(sessionId);
    _publish();
    unawaited(controller.stop(ShareEndReason.sessionClosed));
  }

  /// The app locked: nobody else types into a session whose owner is not
  /// looking. Watching goes on; the keyboard is given again by hand.
  static void appLocked() {
    for (final c in _hosts.values) {
      c.takeBack();
    }
  }

  /// Every share ends (signing out).
  static Future<void> stopAll() async {
    final all = _hosts.keys.toList();
    for (final id in all) {
      await stop(id);
    }
  }

  /// Forgets everything without telling anyone (tests).
  @visibleForTesting
  static void reset() {
    for (final id in _hosts.keys.toList()) {
      _forget(id);
    }
    _publish();
  }
}
