import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show canonicalJson;
import 'package:zestssh/features/orchards/orchard_service.dart' show UnwatchedSession;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';

// Event export (3.0). While an Orchard records activity, its owners
// can have the team's events sent on to a system of their own (a log
// collector): every change to the Orchard's record, and what members do
// with the Crates' items. ZestSSH Cloud cannot read the activity (it is
// sealed with the Orchard's key), so it sends nothing: one device of the
// owner who set it up does, straight to the address they gave.
//
// This file is what goes over the wire and nothing else: an event as JSON,
// the bytes its signature is made over, and a request's body. Every event
// is signed with the Ed25519 key the Orchard's record names (export.set),
// so the receiver can check that it came from the team and was not changed
// on the way:
//
//   signature = Ed25519(key, "zestssh.export-event.v1" + "\n" + canonical)
//
// where canonical is the event without its "sig" member, as JSON with the
// keys of every object sorted, no spaces, and strings escaped the shortest
// way (only the quote, the backslash and the characters below U+0020), in
// UTF-8. Python's json.dumps(event, sort_keys=True, separators=(',', ':'),
// ensure_ascii=False) and JavaScript's JSON.stringify of an object built
// with sorted keys give the same bytes.

/// What an event's signature is made under, on a line of its own before the
/// event.
const String kExportEventLabel = 'zestssh.export-event.v1';

/// The version every event carries as "v".
const int kExportEventVersion = 1;

/// The most events one request carries.
const int kExportBatchMax = 100;

/// How a request's body is laid out.
enum ExportFormat {
  /// One event on each line (JSON lines): what most collectors take.
  lines('lines', 'application/x-ndjson'),

  /// All events of the request as one JSON array.
  array('array', 'application/json');

  const ExportFormat(this.id, this.contentType);

  /// As the settings keep it.
  final String id;
  final String contentType;

  static ExportFormat? of(Object? id) => values.where((f) => f.id == id).firstOrNull;
}

/// The names this device has for what an event is about: they go along so
/// the receiver reads addresses and names, not only ids.
class ExportNames {
  const ExportNames({this.orchard, this.emails = const {}, this.crates = const {}, this.roles = const {}});

  /// The Orchard's name.
  final String? orchard;

  /// Each member's address, by account id.
  final Map<String, String?> emails;

  /// Each Crate's name, by id.
  final Map<String, String?> crates;

  /// The names of the roles the owners made, by id.
  final Map<String, String?> roles;

  String? _named(Map<String, String?> names, String id) {
    final name = names[id]?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  /// An account as an event names it.
  Map<String, Object?> person(String uid) => {'uid': uid, 'email': ?_named(emails, uid)};

  /// A Crate as an event names it.
  Map<String, Object?> crate(String id) => {'id': id, 'name': ?_named(crates, id)};

  /// A role as an event names it: the two fixed ones by their English
  /// names, the others by the name the owners gave them.
  Map<String, Object?> role(String id) => {
        'id': id,
        'name': ?switch (id) {
          FixedRoles.owner => 'Owner',
          FixedRoles.admin => 'Admin',
          _ => _named(roles, id),
        },
      };

  /// The Orchard as an event names it.
  Map<String, Object?> orchardOf(String id) {
    final name = orchard?.trim();
    return {'id': id, if (name != null && name.isNotEmpty) 'name': name};
  }
}

/// [t] as an event carries a time: UTC, to the millisecond.
String exportTime(DateTime t) {
  final u = t.toUtc();
  String p(int n, [int width = 2]) => n.toString().padLeft(width, '0');
  return '${p(u.year, 4)}-${p(u.month)}-${p(u.day)}T${p(u.hour)}:${p(u.minute)}:${p(u.second)}.${p(u.millisecond, 3)}Z';
}

/// [camel] with an underscore before each capital, in small letters:
/// memberAddedAgain, member_added_again.
String _snake(String camel) =>
    camel.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

Map<String, Object?> _event(
  String orchardId,
  ExportNames names, {
  required String id,
  required String type,
  required String action,
  required DateTime time,
  required String timeSource,
  required String actor,
  required String message,
}) =>
    {
      'v': kExportEventVersion,
      'source': 'zestssh',
      'orchard': names.orchardOf(orchardId),
      'id': id,
      'type': type,
      'action': action,
      'time': exportTime(time),
      'time_source': timeSource,
      'actor': names.person(actor),
      'message': message,
    };

/// An entry of the Orchard's record as an event: who wrote it, what it
/// changed ([change], worked out against the record as it stood before, and
/// [message], the same in a sentence), and where it stands in the record,
/// so it can be matched with the signed record itself. An entry carries no
/// time: [seen] is when the sending device first saw it (null for an entry
/// it kept before it noted that, which then goes out with [sent], the time
/// of sending).
Map<String, Object?> exportRecordEvent({
  required String orchardId,
  required ExportNames names,
  required RecordEntry entry,
  required TeamChange change,
  required DateTime? seen,
  required DateTime sent,
  required String message,
  UnwatchedSession? unwatched,
}) =>
    {
      ..._event(
        orchardId,
        names,
        id: 'record-${entry.seq}',
        type: 'record',
        action: entry.type,
        time: seen ?? sent,
        timeSource: seen == null ? 'sent' : 'seen',
        actor: entry.by,
        message: message,
      ),
      'change': _snake(change.kind.name),
      if (change.member case final uid? when uid != entry.by) 'target': names.person(uid),
      if (change.approver case final uid?) 'approver': names.person(uid),
      if (change.crateId case final id?) 'crate': names.crate(id),
      if (change.roleId case final id?) 'role': names.role(id),
      if (change.until case final until?) 'until': exportTime(secondsAsDate(until)),
      // A Crate's own offline limit, as a number a rule can be written on.
      'offline_hours': ?change.hours,
      // A session that ran with nobody watching ([unwatched], as the
      // sending device reads the member's report): when by their device's
      // clock, and, where this device holds the Crate's key, the host, the
      // reason they gave and how ZestSSH Cloud stood for them.
      if (unwatched != null)
        'session': {
          'at': exportTime(DateTime.fromMillisecondsSinceEpoch(unwatched.at * 1000)),
          'host': ?unwatched.report?.host,
          'reason': ?unwatched.report?.reason,
          'service': ?unwatched.report?.reach,
        },
      'record': {'seq': entry.seq, 'hash': _hex(entry.hash(orchardId)), 'prev': _hex(entry.prev)},
    };

/// Something a member did with a Crate's item (activity) as an event:
/// [uid] did [action] (reveal, copy, export or connect) at [at] by their
/// device's clock, and ZestSSH Cloud took the note at [received].
Map<String, Object?> exportActivityEvent({
  required String orchardId,
  required ExportNames names,
  required int id,
  required String uid,
  required String action,
  required DateTime at,
  required DateTime received,
  required String message,
  String? crateId,
  String? itemKind,
  String? itemKey,
  String? itemName,
}) =>
    {
      ..._event(
        orchardId,
        names,
        id: 'activity-$id',
        type: 'activity',
        action: action,
        time: at,
        timeSource: 'device',
        actor: uid,
        message: message,
      ),
      'received': exportTime(received),
      'crate': ?(crateId == null ? null : names.crate(crateId)),
      if (itemKind != null || itemKey != null || itemName != null)
        'item': {'kind': ?itemKind, 'id': ?itemKey, 'name': ?itemName},
    };

/// A note of activity that did not open with the Orchard's key, or named
/// someone other than the account that sent it ([uid], as ZestSSH Cloud
/// says): it goes out as what it is, so nothing a member's device sent is
/// left out of what the receiver gets.
Map<String, Object?> exportUnreadableEvent({
  required String orchardId,
  required ExportNames names,
  required int id,
  required String uid,
  required DateTime received,
  required String message,
}) =>
    {
      ..._event(
        orchardId,
        names,
        id: 'activity-$id',
        type: 'activity',
        action: 'unreadable',
        time: received,
        timeSource: 'received',
        actor: uid,
        message: message,
      ),
      'received': exportTime(received),
    };

/// An event that says nothing happened: sent on request, to see that the
/// receiver takes what this device sends and can check its signature.
Map<String, Object?> exportTestEvent({
  required String orchardId,
  required ExportNames names,
  required String uid,
  required DateTime now,
  required String message,
}) =>
    _event(
      orchardId,
      names,
      id: 'test-${now.toUtc().millisecondsSinceEpoch}',
      type: 'test',
      action: 'test',
      time: now,
      timeSource: 'sent',
      actor: uid,
      message: message,
    );

/// The bytes the signature of [event] is made over: the label and a line
/// end, then the event without its signature as canonical JSON.
List<int> exportEventMessage(Map<String, Object?> event) => utf8.encode('$kExportEventLabel\n'
    '${canonicalJson({
          for (final e in event.entries)
            if (e.key != 'sig') e.key: e.value,
        })}');

/// [event] with the key it is signed with ("key", [publicKey] in base64) and
/// its signature ("sig"), made by [sign] over [exportEventMessage].
Future<Map<String, Object?>> signExportEvent(
  Map<String, Object?> event, {
  required List<int> publicKey,
  required Future<List<int>> Function(List<int> message) sign,
}) async {
  final signed = {...event, 'key': base64Encode(publicKey)};
  return {...signed, 'sig': base64Encode(await sign(exportEventMessage(signed)))};
}

/// Whether [event] is signed by the key it names, and that key is [key]
/// when given (the one the Orchard's record names). What a receiver does.
Future<bool> verifyExportEvent(Map<String, Object?> event, {List<int>? key}) async {
  final named = event['key'], sig = event['sig'];
  if (named is! String || sig is! String) return false;
  try {
    if (key != null && base64Encode(key) != named) return false;
    return await Ed25519().verify(
      exportEventMessage(event),
      signature: Signature(base64Decode(sig),
          publicKey: SimplePublicKey(base64Decode(named), type: KeyPairType.ed25519)),
    );
  } catch (_) {
    // Not base64, or not what the library takes as a key or a signature.
    return false;
  }
}

/// The body of a request that carries [events], each as canonical JSON:
/// one on each line, or all of them as one array.
String exportBody(List<Map<String, Object?>> events, ExportFormat format) => switch (format) {
      ExportFormat.lines => [for (final e in events) '${canonicalJson(e)}\n'].join(),
      ExportFormat.array => '[${events.map(canonicalJson).join(',')}]',
    };
