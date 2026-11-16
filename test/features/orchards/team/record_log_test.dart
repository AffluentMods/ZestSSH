import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/record_log.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../../helpers/record_commits.dart';

/// The key log's tools (3.0) on a real signed record: the
/// record checked again from its first entry (a changed body, a missing
/// entry, a change nobody was allowed to make and a head that differs are
/// each caught where they happen), and the record saved for an audit exactly
/// as it was signed.

const orchardId = '5a1f0c2e-3b4d-4e6f-8a9b-0c1d2e3f4a5b';
const crateId = '6b2e1d3f-4c5e-4f7a-9b0c-1d2e3f4a5b6c';

/// A record: made by the owner, Alice added, her role changed, the rules set.
Future<(List<RecordEntry>, AccountKeys, AccountKeys)> signedRecord() async {
  final owner = await AccountKeys.generate();
  final alice = await AccountKeys.generate();
  final chain = <RecordEntry>[];
  Future<void> add(AccountKeys keys, String by, String type, Map<String, Object?> body) async {
    chain.add(await signRecordEntry(keys,
        orchardId: orchardId,
        seq: chain.length + 1,
        prev: chain.isEmpty ? const [] : chain.last.hash(orchardId),
        type: type,
        body: body,
        by: by));
  }

  Map<String, Object?> role(String id, int rank) => {
        'id': id,
        'rank': rank,
        'name_enc': base64Encode(utf8.encode('sealed-$id')),
        'name_gen': 1,
        'can': const <String>[],
        'crates': {crateId: ['connect']},
      };
  await add(owner, 'owner-1', RecordTypes.create, {
    'owner': {...recordKeysBody(await owner.publish('owner-1')), 'uid': 'owner-1'},
    'key_commit': testCommit('orchard'),
    'crate': {'id': crateId, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(crateId)},
    'roles': [role('role-dev', 10), role('role-lead', 20)],
  });
  await add(owner, 'owner-1', RecordTypes.memberAdd,
      {...recordKeysBody(await alice.publish('alice-1')), 'uid': 'alice-1', 'role': 'role-dev'});
  await add(owner, 'owner-1', RecordTypes.memberSet, {'uid': 'alice-1', 'role': 'role-lead'});
  return (chain, owner, alice);
}

void main() {
  late List<RecordEntry> entries;
  late AccountKeys owner;
  late AccountKeys alice;
  late Uint8List head;

  setUpAll(() async {
    (entries, owner, alice) = await signedRecord();
    head = entries.last.hash(orchardId);
  });

  RecordEntry copyOf(RecordEntry e, {String? bodyJson, int? seq, Uint8List? signature}) => RecordEntry(
        seq: seq ?? e.seq,
        prev: e.prev,
        type: e.type,
        bodyJson: bodyJson ?? e.bodyJson,
        by: e.by,
        byKeyVersion: e.byKeyVersion,
        signature: signature ?? e.signature,
      );

  test('a record that holds is checked from its first entry to the head kept here', () async {
    final check = await checkRecordAgain(orchardId, entries, head);
    expect(check.holds, isTrue);
    expect(check.entries, 3);
    expect(hexOf(check.head), hexOf(head));
    expect(check.failedSeq, isNull);
  });

  test('nothing is taken on trust: a body changed after signing is caught where it is', () async {
    final changed = entries[1].bodyJson.replaceFirst('role-dev', 'role-lead');
    expect(changed, isNot(entries[1].bodyJson));
    final check = await checkRecordAgain(orchardId, [entries[0], copyOf(entries[1], bodyJson: changed), entries[2]], head);
    expect(check.holds, isFalse);
    expect(check.failedSeq, 2);
    expect(check.entries, 1, reason: 'the first still holds');
    expect(check.reason, isNotEmpty);
    // A signature that is not the signer's.
    final forged = Uint8List.fromList(entries[2].signature)..[0] ^= 1;
    final bad = await checkRecordAgain(orchardId, [entries[0], entries[1], copyOf(entries[2], signature: forged)], head);
    expect((bad.holds, bad.failedSeq), (false, 3));
  });

  test('a missing entry, a change nobody could make, and another head are each caught', () async {
    var check = await checkRecordAgain(orchardId, [entries[0], entries[2]], head);
    expect((check.holds, check.failedSeq, check.reason), (false, 2, 'entry 2 is missing'));

    // Alice, a member, making herself an owner: well signed, not allowed.
    final grab = await signRecordEntry(alice,
        orchardId: orchardId,
        seq: 4,
        prev: head,
        type: RecordTypes.memberSet,
        body: {'uid': 'alice-1', 'role': FixedRoles.owner},
        by: 'alice-1');
    check = await checkRecordAgain(orchardId, [...entries, grab], grab.hash(orchardId));
    expect((check.holds, check.failedSeq), (false, 4));
    expect(check.entries, 3);

    // The same entries, a head this device did not keep.
    final other = Uint8List.fromList(head)..[0] ^= 0xff;
    check = await checkRecordAgain(orchardId, entries, other);
    expect(check.holds, isFalse);
    expect(check.reason, contains('not the head kept here'));
    expect(check.reason, contains(hexOf(other)));
    expect(hexOf(check.head), hexOf(head), reason: 'what the entries lead to');
  });

  test('saved for an audit: every entry exactly as signed, linked and hashed', () async {
    final savedAt = DateTime.utc(2026, 9, 25, 14, 30);
    final doc = jsonDecode(recordLogDocument(orchardId, entries, head, savedAt: savedAt)) as Map<String, Object?>;
    expect(doc['format'], 'zestssh-orchard-record');
    expect(doc['version'], 1);
    expect(doc['orchard'], orchardId);
    expect(doc['head'], hexOf(head));
    expect(doc['entries_count'], 3);
    expect(doc['saved_at'], '2026-09-25T14:30:00.000Z');
    final saved = (doc['entries'] as List).cast<Map<String, Object?>>();
    expect(saved.map((e) => e['seq']), [1, 2, 3]);
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      expect(saved[i]['body_json'], e.bodyJson, reason: 'the body exactly as signed');
      expect(saved[i]['body'], jsonDecode(e.bodyJson));
      expect(saved[i]['signature'], base64Encode(e.signature));
      expect(saved[i]['type'], e.type);
      expect(saved[i]['by'], e.by);
      expect(saved[i]['by_key_version'], e.byKeyVersion);
      expect(saved[i]['hash'], hexOf(e.hash(orchardId)));
      expect(saved[i]['prev'], i == 0 ? '' : saved[i - 1]['hash'], reason: 'each links to the one before');
    }
    expect(saved.last['hash'], doc['head']);

    // Read back, the saved entries check exactly as the originals do.
    final back = [
      for (final s in saved)
        RecordEntry(
          seq: s['seq'] as int,
          prev: Uint8List.fromList([
            for (var i = 0; i < (s['prev'] as String).length; i += 2) int.parse((s['prev'] as String).substring(i, i + 2), radix: 16)
          ]),
          type: s['type'] as String,
          bodyJson: s['body_json'] as String,
          by: s['by'] as String,
          byKeyVersion: s['by_key_version'] as int,
          signature: base64Decode(s['signature'] as String),
        ),
    ];
    expect((await checkRecordAgain(orchardId, back, head)).holds, isTrue);
  });

  test('the file says how to check it, and its words alone are enough: every signature holds, and the hashes '
      'chain to the head', () async {
    final doc = jsonDecode(recordLogDocument(orchardId, entries, head, savedAt: DateTime.utc(2026, 10, 20)))
        as Map<String, Object?>;
    final how = doc['how_to_check'] as String;
    for (final word in [
      'Ed25519',
      kRecordLabel,
      '"ed25519_pub"',
      'as 4 bytes, big-endian',
      'a 4-byte big-endian length followed by its bytes',
      'SHA-256 over its signed message followed by its signature',
    ]) {
      expect(how, contains(word));
    }
    // A reader's own check, written from those words alone: the key from the
    // entry that added its member, the message, the signature, the hash.
    List<int> length(List<int> bytes) => [...(ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List(), ...bytes];
    List<int> number(int n) => (ByteData(4)..setUint32(0, n)).buffer.asUint8List();
    List<int> bytesOf(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    final saved = (doc['entries'] as List).cast<Map<String, Object?>>();
    final keys = {
      'owner-1': base64Decode(((saved.first['body']! as Map)['owner'] as Map)['ed25519_pub'] as String),
    };
    var prev = <int>[];
    for (final e in saved) {
      expect(bytesOf(e['prev'] as String), prev, reason: 'entry ${e['seq']} names the one before');
      final message = [
        ...length(utf8.encode(kRecordLabel)),
        ...length(utf8.encode(doc['orchard'] as String)),
        ...number(e['seq'] as int),
        ...length(bytesOf(e['prev'] as String)),
        ...length(utf8.encode(e['type'] as String)),
        ...length(utf8.encode(e['body_json'] as String)),
        ...length(utf8.encode(e['by'] as String)),
        ...number(e['by_key_version'] as int),
      ];
      final signature = base64Decode(e['signature'] as String);
      final holds = await Ed25519().verify(message,
          signature: Signature(signature, publicKey: SimplePublicKey(keys[e['by']]!, type: KeyPairType.ed25519)));
      expect(holds, isTrue, reason: 'entry ${e['seq']}: its signature');
      prev = sha256.convert([...message, ...length(signature)]).bytes;
      expect(hexOf(Uint8List.fromList(prev)), e['hash'], reason: 'entry ${e['seq']}: its hash');
    }
    expect(hexOf(Uint8List.fromList(prev)), doc['head']);
  });

  test('its file name, and which changes are about keys', () {
    expect(recordLogFileName(orchardId, DateTime(2026, 9, 5)), 'orchard-record-5a1f0c2e-20260905.json');
    TeamChange c(TeamChangeKind k) => TeamChange(seq: 1, kind: k, by: 'owner-1', byKeyVersion: 1);
    for (final k in TeamChangeKind.values) {
      final key = {
        TeamChangeKind.created,
        TeamChangeKind.memberAdded,
        TeamChangeKind.memberAddedAgain,
        TeamChangeKind.memberKeys,
        TeamChangeKind.memberRecovered,
        TeamChangeKind.crateKey,
        TeamChangeKind.orchardKey,
        TeamChangeKind.certificateAuthority,
      }.contains(k);
      expect(isKeyChange(c(k)), key, reason: k.name);
    }
    expect(hexOf([0, 15, 255]), '000fff');
    expect(owner.version, 1);
  });
}
