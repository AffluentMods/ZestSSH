part of 'orchard_service.dart';

// Activity (3.0). While an Orchard's owners have
// activity on in its record, each member's device notes what its person does
// with the Crates' items (reveal, copy, export, connect) and sends it with
// the next sync, each event sealed with the Orchard's key: the server keeps
// it without being able to read it, and hands it only to owners. The event
// names its member, and an owner's device keeps an event only when that is
// the account the server says sent it, so neither the server nor another
// member can pass one off as someone else's. While activity is off nothing
// is noted, and what was waiting is dropped.

/// What a member did with a Crate's item, as their team records it.
enum ActivityKind { reveal, copy, export, connect }

/// Where an Orchard's database keeps what this device did and has not sent.
const String _activityQueue = 'activity.queue';

/// The most kept waiting on a device; the oldest go first.
const int _activityQueueMax = 500;

/// The longest item name an event carries.
const int _activityNameMax = 200;

/// One thing a member did.
class ActivityEvent {
  const ActivityEvent({
    required this.uid,
    required this.kind,
    required this.at,
    this.crateId,
    this.itemKind,
    this.itemKey,
    this.name,
  });

  /// The member who did it.
  final String uid;
  final ActivityKind kind;

  /// When, by the member's device clock.
  final DateTime at;

  /// The Crate, and the item: its kind and key, and its name then.
  final String? crateId;
  final String? itemKind;
  final String? itemKey;
  final String? name;

  Map<String, Object?> toJson() => {
        'v': 1,
        'uid': uid,
        'kind': kind.name,
        'at': at.millisecondsSinceEpoch,
        'crate': ?crateId,
        'item_kind': ?itemKind,
        'item': ?itemKey,
        'name': ?name,
      };

  /// Read back from [toJson]'s JSON; null for anything else.
  static ActivityEvent? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) return null;
    final uid = json['uid'], kind = json['kind'], at = json['at'];
    final match = ActivityKind.values.where((k) => k.name == kind);
    if (uid is! String || uid.isEmpty || match.isEmpty || at is! int) return null;
    String? text(String k) => json[k] is String ? json[k] as String : null;
    return ActivityEvent(
      uid: uid,
      kind: match.single,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      crateId: text('crate'),
      itemKind: text('item_kind'),
      itemKey: text('item'),
      name: text('name'),
    );
  }
}

/// An event as an Orchard's owners read it: [event] names the member the
/// server says sent it, and the server took it at [receivedAt].
class TeamActivityEntry {
  const TeamActivityEntry({required this.id, required this.event, required this.receivedAt});

  final int id;
  final ActivityEvent event;
  final DateTime receivedAt;
}

/// A note of activity as the device that sends an Orchard's events on reads
/// it (event export): [event] is null for one that did not open, or that
/// names someone other than [uid], the account the server says sent it.
class TeamActivityRow {
  const TeamActivityRow({required this.id, required this.uid, required this.receivedAt, this.event});

  final int id;
  final String uid;
  final DateTime receivedAt;
  final ActivityEvent? event;
}

/// A page of an Orchard's activity, newest first.
class TeamActivityPage {
  const TeamActivityPage({required this.entries, required this.more, this.before, this.unreadable = 0});

  final List<TeamActivityEntry> entries;
  final bool more;

  /// Pass to read the next page.
  final int? before;

  /// Events on this page that did not open, or named someone other than
  /// who sent them, and were left out.
  final int unreadable;
}

extension OrchardActivity on OrchardService {
  /// Notes that this account did [kind] with an item of [orchardId], while
  /// its owners have activity on (as this device's copy of the record says);
  /// nothing is kept otherwise. It goes with the next sync. Never throws: a
  /// note that cannot be kept is not a reason for anything to fail.
  Future<void> recordActivity(
    String orchardId,
    ActivityKind kind, {
    String? crateId,
    String? itemKind,
    String? itemKey,
    String? name,
  }) async {
    try {
      final me = await author();
      if (me == null) return;
      final db = await databases.open(orchardId);
      if (!(await LocalRecord.load(db, orchardId)).latest.tracking.activity) return;
      final store = LocalStateStore(db);
      final queued = _queued(await store.read(_activityQueue));
      final trimmed = name?.trim();
      queued.add(ActivityEvent(
        uid: me.uid,
        kind: kind,
        at: DateTime.now(),
        crateId: crateId,
        itemKind: itemKind,
        itemKey: itemKey,
        name: trimmed == null || trimmed.isEmpty
            ? null
            : trimmed.length > _activityNameMax
                ? trimmed.substring(0, _activityNameMax)
                : trimmed,
      ).toJson());
      while (queued.length > _activityQueueMax) {
        queued.removeAt(0);
      }
      await store.write(_activityQueue, jsonEncode(queued));
    } catch (e) {
      AppLogger.info('Orchards: activity could not be noted ($e)');
    }
  }

  /// Sends what waits, 50 at a time, sealed with the Orchard's current key;
  /// returns how many went. While activity is off (by this device's copy of
  /// the record, or because the server says so), what waits is dropped.
  /// What cannot go now waits for the next sync.
  Future<int> activityRound(String orchardId) async {
    final db = await databases.open(orchardId);
    final store = LocalStateStore(db);
    final raw = await store.read(_activityQueue);
    if (raw == null) return 0;
    final queued = _queued(raw);
    if (queued.isEmpty || !(await LocalRecord.load(db, orchardId)).latest.tracking.activity) {
      await store.remove(_activityQueue);
      return 0;
    }
    final info = await db.customSelect('SELECT key_generation FROM orchard_info WHERE id = 1').getSingleOrNull();
    final generation = info?.read<int>('key_generation');
    final key = generation == null ? null : await OrchardService._secret(db, orchardId, null, generation);
    if (generation == null || key == null) return 0;
    var sent = 0;
    while (queued.isNotEmpty) {
      final batch = queued.take(50).toList();
      final sealed = [
        for (final e in batch)
          SealedActivity(
            keyGeneration: generation,
            sealed: await sealActivity(e, key, orchardId: orchardId, generation: generation),
          ),
      ];
      try {
        await server.sendActivity(orchardId, sealed);
      } on OrchardServerException catch (e) {
        if (e.status == 409 && e.code == 'activity-off') {
          await store.remove(_activityQueue);
          return sent;
        }
        rethrow;
      }
      queued.removeRange(0, batch.length);
      sent += batch.length;
      if (queued.isEmpty) {
        await store.remove(_activityQueue);
      } else {
        await store.write(_activityQueue, jsonEncode(queued));
      }
    }
    return sent;
  }

  /// [orchardId]'s activity, newest first, older than [before] when given
  /// (owners, while activity is on): each event opened with the Orchard's
  /// key of its generation, and kept only when it names the member the
  /// server says sent it.
  Future<TeamActivityPage> teamActivity(String orchardId, {int? before}) async {
    final db = await databases.open(orchardId);
    final page = await server.activity(orchardId, before: before);
    final out = <TeamActivityEntry>[];
    var unreadable = 0;
    for (final e in page.events) {
      final event = await _openedActivity(db, orchardId, e);
      if (event == null) {
        unreadable++;
        continue;
      }
      out.add(TeamActivityEntry(id: e.id, event: event, receivedAt: e.at));
    }
    return TeamActivityPage(
      entries: out,
      more: page.more,
      before: page.events.isEmpty ? null : page.events.last.id,
      unreadable: unreadable,
    );
  }

  /// [orchardId]'s activity from just after the note [after], oldest first,
  /// a page at a time ([more] says whether another follows): every note the
  /// server holds, also those that do not open or name someone else, each
  /// as what it is. For the device that sends an Orchard's events on.
  Future<({List<TeamActivityRow> rows, bool more})> teamActivityAfter(String orchardId, int after) async {
    final db = await databases.open(orchardId);
    final page = await server.activity(orchardId, after: after);
    return (
      rows: [
        for (final e in page.events)
          TeamActivityRow(id: e.id, uid: e.uid, receivedAt: e.at, event: await _openedActivity(db, orchardId, e)),
      ],
      more: page.more,
    );
  }

  /// [e] opened with the Orchard's key of its generation; null when it does
  /// not open, or names someone other than the account the server says
  /// sent it.
  static Future<ActivityEvent?> _openedActivity(AppDatabase db, String orchardId, ActivityEntry e) async {
    final key = await OrchardService._secret(db, orchardId, null, e.keyGeneration);
    if (key == null) return null;
    try {
      final event =
          ActivityEvent.fromJson(await openActivity(e.sealed, key, orchardId: orchardId, generation: e.keyGeneration));
      return event == null || event.uid != e.uid ? null : event;
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, Object?>> _queued(String? raw) {
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      return [
        if (decoded is List)
          for (final e in decoded)
            if (e is Map<String, Object?>) e,
      ];
    } on FormatException {
      return [];
    }
  }
}
