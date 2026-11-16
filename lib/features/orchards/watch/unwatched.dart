import 'package:flutter/foundation.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';

// A session to a watched Crate's host with nobody watching (3.0, the outage
// work). A watched session is shared as a live view with
// someone who manages the Crate, and a live view goes through ZestSSH
// Cloud: while the service cannot be reached nobody can be asked, and the
// service being away must never be why a team cannot reach its machines.
// So, then and only then: an owner may connect after giving a reason, and
// so may anyone else who may connect there where the owners allowed it for
// the Crate. The device keeps what it reports of the session, sealed with
// the Crate's key, and puts it into the Orchard's record once it is back:
// who connected is the entry's author, and the host, the reason and how the
// service stood are for those who hold the Crate's key.
//
// It is the app that keeps this rule, as it keeps watching itself
// (session_watch.dart): what the record says is who may, and what was
// reported.

/// The longest reason a report carries, and the longest host name, in
/// characters: with both at their longest what is sealed stays under what
/// an entry takes ([kMaxUnwatchedSealed]).
const int kUnwatchedReasonMax = 300;
const int kUnwatchedHostMax = 120;

/// What a device reports of a session that went on with nobody watching:
/// the part of the report that is sealed.
@immutable
class UnwatchedReport {
  const UnwatchedReport({required this.host, required this.reason, required this.reach});

  /// The host as the person who connected named it.
  final String host;

  /// Why they connected with nobody watching, in their words.
  final String reason;

  /// How ZestSSH Cloud stood, as their device knew it ([unwatchedReach]):
  /// the name of a CloudReach value ('down', 'deviceOffline', ...), with
  /// the HTTP status after it where the service answered with a fault.
  final String reach;

  Map<String, Object?> toJson() => {'v': 1, 'host': host, 'reason': reason, 'reach': reach};

  /// What [json] reports, or null when it is no report this app reads.
  static UnwatchedReport? fromJson(Map<String, Object?> json) {
    final host = json['host'], reason = json['reason'], reach = json['reach'];
    if (json['v'] != 1 || host is! String || reason is! String || reach is! String) return null;
    return UnwatchedReport(host: host, reason: reason, reach: reach);
  }

  @override
  bool operator ==(Object other) =>
      other is UnwatchedReport && other.host == host && other.reason == reason && other.reach == reach;

  @override
  int get hashCode => Object.hash(host, reason, reach);

  @override
  String toString() => 'UnwatchedReport($host, $reason, $reach)';
}

/// Whether the account [uid] may connect to a host of the watched Crate
/// [crateId] with nobody watching while ZestSSH Cloud cannot be reached, by
/// [record]: an owner always, anyone else who is in the Orchard where the
/// owners allowed it for the Crate.
bool mayGoUnwatched(OrchardRecord record, String crateId, String uid) =>
    record.isActive(uid) && (record.isOwner(uid) || (record.crates[crateId]?.unwatchedAway ?? false));

/// How ZestSSH Cloud stands ([state]) as a report says it: the name of
/// what the app found, and where the service answered with a fault of its
/// own, the HTTP status after it ("fault 503").
String unwatchedReach(CloudReachState state) =>
    state.status == null ? state.reach.name : '${state.reach.name} ${state.status}';

/// What a report says of how ZestSSH Cloud stood ([written], by
/// [unwatchedReach]) as a state again; null where this app does not know
/// the name (a report written by a later one).
CloudReachState? unwatchedReachRead(String written) {
  final parts = written.split(' ');
  final reach = CloudReach.values.where((r) => r.name == parts.first).firstOrNull;
  if (reach == null || parts.length > 2) return null;
  final status = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (parts.length == 2 && status == null) return null;
  return CloudReachState(reach, status: status);
}

/// [raw] as a report carries a reason: every run of blanks one space,
/// nothing blank at either end, and no longer than [kUnwatchedReasonMax].
/// Null when nothing is left: a reason is asked for.
String? unwatchedReason(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  return _cut(text, kUnwatchedReasonMax);
}

/// [label] as a report names a host: as [unwatchedReason] takes a reason,
/// and no longer than [kUnwatchedHostMax].
String unwatchedHost(String label) => _cut(label.replaceAll(RegExp(r'\s+'), ' ').trim(), kUnwatchedHostMax);

/// The first [max] characters of [text], never half of one that is written
/// with two code units.
String _cut(String text, int max) {
  final runes = text.runes;
  return runes.length <= max ? text : String.fromCharCodes(runes.take(max));
}
