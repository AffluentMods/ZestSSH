import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show UnwatchedSession;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';

/// Event export (3.0) as it goes over the wire: what an event's
/// signature is made over (the same bytes a receiver works out in Node or
/// Python, numbers from there held here), each kind of event, and a
/// request's body.

const _orchard = '11111111-1111-4111-8111-111111111111';
const _crate = '22222222-2222-4222-8222-222222222222';
const _role = '33333333-3333-4333-8333-333333333333';

const _names = ExportNames(
  orchard: 'Acme',
  emails: {'uid-owner': 'owner@example.com', 'uid-zoe': 'zoë@example.com', 'uid-new': null, 'uid-blank': '  '},
  crates: {_crate: 'Production'},
  roles: {_role: 'Operators'},
);

/// Text with everything a serializer could spell another way: letters
/// outside ASCII, a quote, a backslash, a line end and a control character.
const _awkward = '東京 "db"\\1\n\u0001';

RecordEntry _entry(int seq, String type, Map<String, Object?> body, {String by = 'uid-owner'}) => RecordEntry(
      seq: seq,
      prev: Uint8List.fromList(List.filled(32, seq)),
      type: type,
      bodyJson: jsonEncode(body),
      by: by,
      byKeyVersion: 1,
      signature: Uint8List(64),
    );

void main() {
  test('the signature: the label on a line of its own, then the event without its signature, keys sorted, '
      'no spaces, the shortest escapes (numbers worked out in Node and in Python)', () async {
    final key = await DeviceIdentity.fromSeed(List.filled(32, 7));
    expect(key.key, '6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=');
    final event = exportActivityEvent(
      orchardId: _orchard,
      names: _names,
      id: 42,
      uid: 'uid-zoe',
      action: 'reveal',
      at: DateTime.utc(2026, 10, 2, 8, 9, 10, 11),
      received: DateTime.utc(2026, 10, 2, 8, 9, 12),
      message: 'zoë@example.com opened the secrets of $_awkward',
      crateId: _crate,
      itemKind: 'key',
      itemKey: 'k-1',
      itemName: _awkward,
    );
    final signed = await signExportEvent(event, publicKey: key.publicKey, sign: key.sign);
    expect(signed['key'], key.key);
    final message = exportEventMessage(signed);
    expect(message.length, 593);
    expect(sha256.convert(message).toString(), '04d0459c40f929bd1e56c5377a8be3c09e827a06e870001dd2ee559992084c50');
    expect(
      utf8.decode(message),
      'zestssh.export-event.v1\n'
      r'{"action":"reveal","actor":{"email":"zoë@example.com","uid":"uid-zoe"},'
      r'"crate":{"id":"22222222-2222-4222-8222-222222222222","name":"Production"},"id":"activity-42",'
      r'"item":{"id":"k-1","kind":"key","name":"東京 \"db\"\\1\n\u0001"},'
      r'"key":"6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=",'
      r'"message":"zoë@example.com opened the secrets of 東京 \"db\"\\1\n\u0001",'
      r'"orchard":{"id":"11111111-1111-4111-8111-111111111111","name":"Acme"},'
      r'"received":"2026-10-02T08:09:12.000Z","source":"zestssh","time":"2026-10-02T08:09:10.011Z",'
      r'"time_source":"device","type":"activity","v":1}',
    );
    // Ed25519 signs the same bytes the same way every time.
    expect(signed['sig'], 'Z2GNS/AIBrPCJWDzoJ9nHtwoq8be/1441j2cTmmEYVp8GIwwK0DhYd3+S2OAjHa/pthAFjJtNs/T3nj1uO3QDg==');
    // The signature is not part of what is signed; the key is.
    expect(exportEventMessage({...signed, 'sig': 'anything'}), message);
    expect(exportEventMessage({...signed}..remove('sig')), message);
    expect(exportEventMessage({...signed}..remove('key')), isNot(message));
    // Signing again what already carries a signature and a key replaces both.
    final other = await DeviceIdentity.fromSeed(List.filled(32, 8));
    final again = await signExportEvent(signed, publicKey: other.publicKey, sign: other.sign);
    expect(again['key'], other.key);
    expect(again['sig'], isNot(signed['sig']));
    expect(await verifyExportEvent(again), isTrue);
    expect({...again}..remove('sig')..remove('key'), event);
  });

  test('checking an event as a receiver does: signed by the key it names, and that key the one expected',
      () async {
    final key = await DeviceIdentity.fromSeed(List.filled(32, 7));
    final other = await DeviceIdentity.fromSeed(List.filled(32, 8));
    final event = exportTestEvent(
        orchardId: _orchard, names: _names, uid: 'uid-owner', now: DateTime.utc(2026, 10, 2), message: 'Test');
    final signed = await signExportEvent(event, publicKey: key.publicKey, sign: key.sign);
    expect(await verifyExportEvent(signed), isTrue);
    expect(await verifyExportEvent(signed, key: key.publicKey), isTrue);
    expect(await verifyExportEvent(signed, key: other.publicKey), isFalse, reason: 'not the key the record names');
    // Anything changed on the way.
    expect(await verifyExportEvent({...signed, 'message': 'Test.'}), isFalse);
    expect(await verifyExportEvent({...signed, 'extra': 1}), isFalse);
    expect(await verifyExportEvent({...signed, 'actor': {'uid': 'uid-zoe'}}), isFalse);
    // Another key named for the same signature, or the signature of another key.
    expect(await verifyExportEvent({...signed, 'key': other.key}), isFalse);
    final theirs = await signExportEvent(event, publicKey: other.publicKey, sign: other.sign);
    expect(await verifyExportEvent({...signed, 'sig': theirs['sig']}), isFalse);
    // A signature made over the event alone, without the label before it.
    final bare = base64Encode(await key.sign(utf8.encode(utf8.decode(exportEventMessage(signed)).split('\n').last)));
    expect(await verifyExportEvent({...signed, 'sig': bare}), isFalse);
    // Not a key, not a signature, or neither there.
    expect(await verifyExportEvent({...signed}..remove('sig')), isFalse);
    expect(await verifyExportEvent({...signed}..remove('key')), isFalse);
    expect(await verifyExportEvent({...signed, 'key': 7}), isFalse);
    expect(await verifyExportEvent({...signed, 'sig': 7}), isFalse);
    expect(await verifyExportEvent({...signed, 'key': 'not base64 !'}), isFalse);
    expect(await verifyExportEvent({...signed, 'sig': 'not base64 !'}), isFalse);
    expect(await verifyExportEvent({...signed, 'key': base64Encode(List.filled(31, 1))}), isFalse);
    expect(await verifyExportEvent({...signed, 'sig': base64Encode(List.filled(63, 1))}), isFalse);
  });

  test('a time is UTC to the millisecond, whatever clock it came from', () {
    expect(exportTime(DateTime.utc(2026, 1, 2, 3, 4, 5)), '2026-01-02T03:04:05.000Z');
    expect(exportTime(DateTime.utc(2026, 12, 31, 23, 59, 59, 999, 999)), '2026-12-31T23:59:59.999Z');
    expect(exportTime(DateTime.utc(987, 6, 5, 4, 3, 2, 1)), '0987-06-05T04:03:02.001Z');
    final local = DateTime(2026, 10, 2, 10, 30);
    expect(exportTime(local), exportTime(local.toUtc()));
    expect(DateTime.parse(exportTime(local)).isAtSameMomentAs(local), isTrue);
  });

  test('an entry of the record as an event: who wrote it, what it changed, and where it stands in the record',
      () {
    final entry = _entry(7, RecordTypes.memberAdd, {'uid': 'uid-zoe', 'role': _role});
    const change = TeamChange(
        seq: 7, kind: TeamChangeKind.memberAddedAgain, by: 'uid-owner', byKeyVersion: 1, member: 'uid-zoe', roleId: _role);
    final seen = DateTime.utc(2026, 10, 2, 8, 9, 10);
    final event = exportRecordEvent(
      orchardId: _orchard,
      names: _names,
      entry: entry,
      change: change,
      seen: seen,
      sent: DateTime.utc(2027),
      message: 'owner@example.com: Added zoë@example.com again, as Operators',
    );
    expect(event, {
      'v': 1,
      'source': 'zestssh',
      'orchard': {'id': _orchard, 'name': 'Acme'},
      'id': 'record-7',
      'type': 'record',
      'action': 'member.add',
      'time': '2026-10-02T08:09:10.000Z',
      'time_source': 'seen',
      'actor': {'uid': 'uid-owner', 'email': 'owner@example.com'},
      'message': 'owner@example.com: Added zoë@example.com again, as Operators',
      'change': 'member_added_again',
      'target': {'uid': 'uid-zoe', 'email': 'zoë@example.com'},
      'role': {'id': _role, 'name': 'Operators'},
      'record': {
        'seq': 7,
        'hash': [for (final b in entry.hash(_orchard)) b.toRadixString(16).padLeft(2, '0')].join(),
        'prev': '07' * 32,
      },
    });
    expect((event['record'] as Map)['hash'], hasLength(64));

    Map<String, Object?> of(TeamChange c, {RecordEntry? e, DateTime? at}) => exportRecordEvent(
        orchardId: _orchard, names: _names, entry: e ?? entry, change: c, seen: at, sent: DateTime.utc(2027), message: 'm');
    TeamChange c(TeamChangeKind kind,
            {String? member, String? crate, String? role, String? approver, int? until, int? hours}) =>
        TeamChange(
            seq: 7,
            kind: kind,
            by: 'uid-owner',
            byKeyVersion: 1,
            member: member,
            crateId: crate,
            roleId: role,
            approver: approver,
            until: until,
            hours: hours);

    // An entry kept before its time was noted goes out with the time of
    // sending, and says so.
    final undated = of(change);
    expect((undated['time'], undated['time_source']), ('2027-01-01T00:00:00.000Z', 'sent'));
    // About its author: no target. The one word and the many of a change.
    final own = of(c(TeamChangeKind.memberKeys, member: 'uid-owner'), at: seen);
    expect(own.containsKey('target'), isFalse);
    expect(own['change'], 'member_keys');
    expect(of(c(TeamChangeKind.created), at: seen)['change'], 'created');
    expect(of(c(TeamChangeKind.exportOn), at: seen)['change'], 'export_on');
    expect(of(c(TeamChangeKind.created), at: seen).keys.toSet(),
        {'v', 'source', 'orchard', 'id', 'type', 'action', 'time', 'time_source', 'actor', 'message', 'change', 'record'});
    // A Crate, the fixed roles by their English names, a role nobody named,
    // a second owner's approval, and an end.
    final access = of(c(TeamChangeKind.accessGiven, member: 'uid-zoe', crate: _crate, until: 1790000000), at: seen);
    expect(access['crate'], {'id': _crate, 'name': 'Production'});
    expect(access['until'], '2026-09-21T14:13:20.000Z');
    // One further off than a date can say, from a server before there was a
    // limit, does not stop the events after it.
    final far = of(c(TeamChangeKind.accessGiven, member: 'uid-zoe', crate: _crate, until: 9007199254740991), at: seen);
    expect(far['until'], contains('275760'));
    expect(access.containsKey('offline_hours'), isFalse);
    // A Crate's own offline limit: which Crate, and the length as a number
    // a rule can be written on; taken off, no length.
    final limited = of(c(TeamChangeKind.crateOfflineSet, crate: _crate, hours: 24), at: seen);
    expect((limited['change'], limited['offline_hours']), ('crate_offline_set', 24));
    expect(limited['crate'], {'id': _crate, 'name': 'Production'});
    final lifted = of(c(TeamChangeKind.crateOfflineOff, crate: _crate), at: seen);
    expect(lifted['change'], 'crate_offline_off');
    expect(lifted.containsKey('offline_hours'), isFalse);
    expect(lifted.containsKey('session'), isFalse);
    // Who connects with nobody watching while ZestSSH Cloud cannot be
    // reached, and a session that ran so: when by the member's device, and
    // what the sending device could open of the report. One it cannot open
    // goes out with its time and nothing made up.
    expect(of(c(TeamChangeKind.unwatchedAwayOn, crate: _crate), at: seen)['change'], 'unwatched_away_on');
    expect(of(c(TeamChangeKind.unwatchedAwayOff, crate: _crate), at: seen)['change'], 'unwatched_away_off');
    Map<String, Object?> ran(UnwatchedSession session) => exportRecordEvent(
        orchardId: _orchard,
        names: _names,
        entry: entry,
        change: c(TeamChangeKind.sessionUnwatched, crate: _crate),
        seen: seen,
        sent: seen,
        message: 'm',
        unwatched: session);
    final opened = ran(const UnwatchedSession(
        seq: 7,
        by: 'uid-zoe',
        crateId: _crate,
        at: 1790000000,
        report: UnwatchedReport(host: 'db-primary', reason: 'restoring the database', reach: 'fault 503')));
    expect(opened['change'], 'session_unwatched');
    expect(opened['crate'], {'id': _crate, 'name': 'Production'});
    expect(opened['session'], {
      'at': '2026-09-21T14:13:20.000Z',
      'host': 'db-primary',
      'reason': 'restoring the database',
      'service': 'fault 503',
    });
    expect(ran(const UnwatchedSession(seq: 7, by: 'uid-zoe', crateId: _crate, at: 1790000000))['session'],
        {'at': '2026-09-21T14:13:20.000Z'});
    expect(of(c(TeamChangeKind.sessionUnwatched, crate: _crate), at: seen).containsKey('session'), isFalse,
        reason: 'nothing read of it: nothing said of it');
    expect(of(c(TeamChangeKind.crateAdded, crate: 'another'), at: seen)['crate'], {'id': 'another'});
    expect(of(c(TeamChangeKind.memberRole, member: 'uid-zoe', role: FixedRoles.owner), at: seen)['role'],
        {'id': 'owner', 'name': 'Owner'});
    expect(of(c(TeamChangeKind.memberRole, member: 'uid-zoe', role: FixedRoles.admin), at: seen)['role'],
        {'id': 'admin', 'name': 'Admin'});
    expect(of(c(TeamChangeKind.roleAdded, role: 'unnamed'), at: seen)['role'], {'id': 'unnamed'});
    final recovered = of(c(TeamChangeKind.memberRecovered, member: 'uid-zoe', approver: 'uid-new'), at: seen);
    expect(recovered['approver'], {'uid': 'uid-new'}, reason: 'no address known: the id alone');
    expect(recovered['target'], {'uid': 'uid-zoe', 'email': 'zoë@example.com'});
    // Someone this device has no address for, or a blank one; an Orchard
    // without a name.
    expect(of(c(TeamChangeKind.memberAdded, member: 'uid-blank'), at: seen)['target'], {'uid': 'uid-blank'});
    expect(of(c(TeamChangeKind.memberAdded, member: 'uid-nobody'), at: seen)['target'], {'uid': 'uid-nobody'});
    for (final name in [null, '', '  ']) {
      final e = exportRecordEvent(
          orchardId: _orchard,
          names: ExportNames(orchard: name),
          entry: entry,
          change: change,
          seen: seen,
          sent: seen,
          message: 'm');
      expect(e['orchard'], {'id': _orchard});
      expect(e['actor'], {'uid': 'uid-owner'});
    }
    expect(
        exportRecordEvent(
            orchardId: _orchard,
            names: const ExportNames(orchard: ' Acme '),
            entry: entry,
            change: change,
            seen: seen,
            sent: seen,
            message: 'm')['orchard'],
        {'id': _orchard, 'name': 'Acme'});
  });

  test('what a member did as an event, one that could not be read, and a test event', () {
    final at = DateTime.utc(2026, 10, 2, 8, 9, 10, 11);
    final received = DateTime.utc(2026, 10, 2, 8, 9, 12);
    expect(
      exportActivityEvent(
        orchardId: _orchard,
        names: _names,
        id: 42,
        uid: 'uid-zoe',
        action: 'connect',
        at: at,
        received: received,
        message: 'zoë@example.com connected to web-01',
        crateId: _crate,
        itemKind: 'connection',
        itemKey: 'c-1',
        itemName: 'web-01',
      ),
      {
        'v': 1,
        'source': 'zestssh',
        'orchard': {'id': _orchard, 'name': 'Acme'},
        'id': 'activity-42',
        'type': 'activity',
        'action': 'connect',
        'time': '2026-10-02T08:09:10.011Z',
        'time_source': 'device',
        'actor': {'uid': 'uid-zoe', 'email': 'zoë@example.com'},
        'message': 'zoë@example.com connected to web-01',
        'received': '2026-10-02T08:09:12.000Z',
        'crate': {'id': _crate, 'name': 'Production'},
        'item': {'kind': 'connection', 'id': 'c-1', 'name': 'web-01'},
      },
    );
    // With nothing known of the item or its Crate, neither is there.
    final bare = exportActivityEvent(
        orchardId: _orchard, names: _names, id: 1, uid: 'uid-zoe', action: 'export', at: at, received: received, message: 'm');
    expect(bare.containsKey('crate'), isFalse);
    expect(bare.containsKey('item'), isFalse);
    // Each part of the item on its own.
    for (final (kind, key, name, item) in [
      ('key', null, null, {'kind': 'key'}),
      (null, 'k-1', null, {'id': 'k-1'}),
      (null, null, 'deploy', {'name': 'deploy'}),
    ]) {
      expect(
          exportActivityEvent(
              orchardId: _orchard,
              names: _names,
              id: 1,
              uid: 'uid-zoe',
              action: 'copy',
              at: at,
              received: received,
              message: 'm',
              itemKind: kind,
              itemKey: key,
              itemName: name)['item'],
          item);
    }

    expect(
      exportUnreadableEvent(
          orchardId: _orchard, names: _names, id: 43, uid: 'uid-zoe', received: received, message: 'not read'),
      {
        'v': 1,
        'source': 'zestssh',
        'orchard': {'id': _orchard, 'name': 'Acme'},
        'id': 'activity-43',
        'type': 'activity',
        'action': 'unreadable',
        'time': '2026-10-02T08:09:12.000Z',
        'time_source': 'received',
        'actor': {'uid': 'uid-zoe', 'email': 'zoë@example.com'},
        'message': 'not read',
        'received': '2026-10-02T08:09:12.000Z',
      },
    );

    expect(
      exportTestEvent(orchardId: _orchard, names: _names, uid: 'uid-owner', now: at, message: 'Test'),
      {
        'v': 1,
        'source': 'zestssh',
        'orchard': {'id': _orchard, 'name': 'Acme'},
        'id': 'test-${at.millisecondsSinceEpoch}',
        'type': 'test',
        'action': 'test',
        'time': '2026-10-02T08:09:10.011Z',
        'time_source': 'sent',
        'actor': {'uid': 'uid-owner', 'email': 'owner@example.com'},
        'message': 'Test',
      },
    );
  });

  test("a request's body: one event on each line, or all of them as an array, each as canonical JSON", () {
    final events = [
      {'b': 1, 'a': 'x\ny'},
      {'z': {'k': 2, 'j': 1}, 'a': [3, 2, 1]},
    ];
    expect(exportBody(events, ExportFormat.lines), '{"a":"x\\ny","b":1}\n{"a":[3,2,1],"z":{"j":1,"k":2}}\n');
    expect(exportBody(events, ExportFormat.array), '[{"a":"x\\ny","b":1},{"a":[3,2,1],"z":{"j":1,"k":2}}]');
    expect(exportBody(const [], ExportFormat.lines), '');
    expect(exportBody(const [], ExportFormat.array), '[]');
    expect(exportBody([events.first], ExportFormat.lines).split('\n'), hasLength(2), reason: 'a line end after each');
    // What each format is called, and what it says it is.
    expect([for (final f in ExportFormat.values) (f.id, f.contentType)],
        [('lines', 'application/x-ndjson'), ('array', 'application/json')]);
    expect(ExportFormat.of('lines'), ExportFormat.lines);
    expect(ExportFormat.of('array'), ExportFormat.array);
    expect(ExportFormat.of('csv'), isNull);
    expect(ExportFormat.of(null), isNull);
    expect((kExportEventLabel, kExportEventVersion, kExportBatchMax), ('zestssh.export-event.v1', 1, 100));
  });
}
