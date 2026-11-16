import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';

// The key log's tools (3.0, "key log"): the Orchard's signed record
// checked again from its first entry on request, saved whole for an audit
// (every entry exactly as it was signed, so anyone can check it without
// ZestSSH), and which changes are about keys.

/// Lower-case hex of [bytes].
String hexOf(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// Changes that bring, replace or retire a key: an Orchard made (its first
/// keys), a member added or added again (their keys trusted), a member's
/// keys replaced or given back by two owners, a Crate's or the Orchard's key
/// replaced, and a Crate's certificate authority.
const kKeyChangeKinds = {
  TeamChangeKind.created,
  TeamChangeKind.memberAdded,
  TeamChangeKind.memberAddedAgain,
  TeamChangeKind.memberKeys,
  TeamChangeKind.memberRecovered,
  TeamChangeKind.crateKey,
  TeamChangeKind.orchardKey,
  TeamChangeKind.certificateAuthority,
};

bool isKeyChange(TeamChange c) => kKeyChangeKinds.contains(c.kind);

/// What checking the record again found: every entry holds ([failedSeq]
/// null), or the first that does not, and why.
class RecordCheck {
  const RecordCheck({required this.entries, required this.head, this.failedSeq, this.reason});

  /// How many entries were checked (all of them when it holds).
  final int entries;

  /// The head the entries lead to.
  final Uint8List head;

  final int? failedSeq;

  /// Why [failedSeq] does not hold, as the record's rules word it.
  final String? reason;

  bool get holds => failedSeq == null;
}

/// Checks [entries] (the Orchard [orchardId]'s record as this device keeps
/// it, oldest first) again from the first: each signature, each link to the
/// entry before, each change against the rules as they stood, and that they
/// lead to [head], the head this device keeps. Nothing is taken on trust,
/// not even what this device checked when the entries arrived.
Future<RecordCheck> checkRecordAgain(String orchardId, List<RecordEntry> entries, Uint8List head) async {
  final state = OrchardRecord(orchardId);
  var expect = 1;
  for (final e in entries) {
    if (e.seq != expect) {
      return RecordCheck(entries: expect - 1, head: state.head, failedSeq: expect, reason: 'entry $expect is missing');
    }
    try {
      await state.append(e);
    } on RecordRejected catch (r) {
      return RecordCheck(entries: e.seq - 1, head: state.head, failedSeq: r.seq, reason: r.reason);
    } catch (err) {
      return RecordCheck(entries: e.seq - 1, head: state.head, failedSeq: e.seq, reason: '$err');
    }
    expect++;
  }
  if (hexOf(state.head) != hexOf(head)) {
    return RecordCheck(
      entries: entries.length,
      head: state.head,
      failedSeq: entries.isEmpty ? 0 : entries.last.seq,
      reason: 'the entries lead to ${hexOf(state.head)}, not the head kept here, ${hexOf(head)}',
    );
  }
  return RecordCheck(entries: entries.length, head: state.head);
}

/// One entry as the log saves it: everything that was signed, exactly as
/// signed ([body_json] is the canonical body), its signature, the link to
/// the entry before and its own hash.
Map<String, Object?> recordEntryJson(String orchardId, RecordEntry e) {
  Object? body;
  try {
    body = jsonDecode(e.bodyJson);
  } catch (_) {
    body = null;
  }
  return {
    'seq': e.seq,
    'type': e.type,
    'by': e.by,
    'by_key_version': e.byKeyVersion,
    'prev': hexOf(e.prev),
    'hash': hexOf(e.hash(orchardId)),
    'signature': base64Encode(e.signature),
    'body_json': e.bodyJson,
    'body': body,
  };
}

/// The whole record for an audit: the Orchard's id, its head, when it was
/// saved and every entry, oldest first. It holds nothing secret: names are
/// sealed, keys are public keys and key commitments.
String recordLogDocument(String orchardId, List<RecordEntry> entries, Uint8List head, {required DateTime savedAt}) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': 'zestssh-orchard-record',
      'version': 1,
      'orchard': orchardId,
      'head': hexOf(head),
      'entries_count': entries.length,
      'saved_at': savedAt.toUtc().toIso8601String(),
      // Enough to check the file with nothing else (it said "as ZestSSH's
      // Orchard record format lays them out", which nobody outside could
      // follow, and nothing of the hash).
      'how_to_check':
          'Each entry is signed with Ed25519 by the member named in "by", with that member\'s keys at '
          '"by_key_version" as the record stood before it (a member\'s keys are in the entry that added '
          'them, or in their latest change of keys: "ed25519_pub", with "key_version"). The signed message '
          'is, in this order: the text "$kRecordLabel", the Orchard id, "seq", "prev", "type", "body_json", '
          '"by" and "by_key_version"; a number ("seq", "by_key_version") as 4 bytes, big-endian; everything '
          'else as a 4-byte big-endian length followed by its bytes (text in UTF-8, "prev" as the bytes its '
          'hex names, none for the first entry). An entry\'s hash is SHA-256 over its signed message '
          'followed by its signature as a 4-byte big-endian length and the signature\'s bytes ("signature" '
          'is base64). "prev" is the hash of the entry before, and the last entry\'s hash is "head".',
      'entries': [for (final e in entries) recordEntryJson(orchardId, e)],
    });

/// A file name for the log of [orchardId] saved on [day].
String recordLogFileName(String orchardId, DateTime day) {
  String two(int n) => n.toString().padLeft(2, '0');
  final short = orchardId.length >= 8 ? orchardId.substring(0, 8) : orchardId;
  return 'orchard-record-$short-${day.year}${two(day.month)}${two(day.day)}.json';
}
