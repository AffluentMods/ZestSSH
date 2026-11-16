import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart' show wrapUnderDek;

/// The cryptography of Orchards and Crates (3.0): keys sealed to a
/// member for exactly one Orchard, Crate and generation; names and records
/// that open only where they belong; records signed by their author; and
/// item ids every device derives the same way.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _otherOrchard = '1d3f9b7f-6c2e-4e4b-8f58-3b72d1f0c8e4';
const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _otherCrate = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';

void main() {
  late AccountKeys me;
  late AccountKeys someoneElse;
  late Uint8List crateKey;
  late Uint8List idKey;

  setUp(() async {
    me = await AccountKeys.generate();
    someoneElse = await AccountKeys.generate();
    crateKey = newSpaceKey();
    idKey = await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _crate);
  });

  Future<List<int>?> onlyMe(String uid, int version) async =>
      uid == 'me' && version == me.version ? me.signingPublicKey : null;

  ItemRecord host({int editedAt = 1000, String label = 'web'}) => ItemRecord(
        kind: 'host',
        key: 'h-1',
        author: 'me',
        authorKeyVersion: me.version,
        editedAt: editedAt,
        data: {
          'connections': [
            {'id': 'h-1', 'label': label, 'host': '10.0.0.1', 'port': 22},
          ],
        },
      );

  ItemPlace placeOf(String itemId, {String crate = _crate, int generation = 1}) =>
      ItemPlace(orchardId: _orchard, crateId: crate, itemId: itemId, generation: generation);

  group('keys', () {
    test('a sealed Crate key opens for its member, Crate and generation only', () async {
      final key = newSpaceKey();
      final sealed = await sealCrateKey(me.encryption.publicKey, key,
          orchardId: _orchard, crateId: _crate, generation: 1);
      expect(
          await openCrateKey(me.encryption, sealed,
              orchardId: _orchard, crateId: _crate, generation: 1),
          key);

      Future<void> refused(Future<Object?> open) =>
          expectLater(open, throwsA(isA<SecretBoxAuthenticationError>()));
      await refused(openCrateKey(someoneElse.encryption, sealed,
          orchardId: _orchard, crateId: _crate, generation: 1));
      await refused(openCrateKey(me.encryption, sealed,
          orchardId: _orchard, crateId: _otherCrate, generation: 1));
      await refused(openCrateKey(me.encryption, sealed,
          orchardId: _otherOrchard, crateId: _crate, generation: 1));
      await refused(openCrateKey(me.encryption, sealed,
          orchardId: _orchard, crateId: _crate, generation: 2));
      await refused(openOrchardKey(me.encryption, sealed,
          orchardId: _orchard, generation: 1));
    });

    test('an Orchard key opens as that Orchard key only', () async {
      final key = newSpaceKey();
      final sealed = await sealOrchardKey(me.encryption.publicKey, key,
          orchardId: _orchard, generation: 1);
      expect(await openOrchardKey(me.encryption, sealed, orchardId: _orchard, generation: 1),
          key);
      await expectLater(
          openOrchardKey(me.encryption, sealed, orchardId: _otherOrchard, generation: 1),
          throwsA(isA<SecretBoxAuthenticationError>()));
    });
  });

  group('names', () {
    test('open with their own key, place and generation only', () async {
      final enc = await encryptCrateName(' Production ', crateKey,
          orchardId: _orchard, crateId: _crate, generation: 1);
      expect(
          await decryptCrateName(enc, crateKey,
              orchardId: _orchard, crateId: _crate, generation: 1),
          'Production',
          reason: 'names are stored trimmed');
      await expectLater(
          decryptCrateName(enc, crateKey,
              orchardId: _orchard, crateId: _otherCrate, generation: 1),
          throwsA(isA<SecretBoxAuthenticationError>()));
      await expectLater(
          decryptOrchardName(enc, crateKey, orchardId: _orchard, generation: 1),
          throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('an empty or overlong name is refused', () async {
      expect(() => encryptOrchardName('  ', crateKey, orchardId: _orchard, generation: 1),
          throwsArgumentError);
      expect(
          () => encryptOrchardName('x' * (kMaxSpaceNameBytes + 1), crateKey,
              orchardId: _orchard, generation: 1),
          throwsArgumentError);
    });
  });

  group('the note of a request for access', () {
    test('opens with the Orchard key, for that Orchard, member and generation only', () async {
      final key = newSpaceKey();
      final enc = await encryptAccessNote('  Staging, to check the release  ', key,
          orchardId: _orchard, uid: 'alice', generation: 2);
      Future<String> open(
              {List<int>? using, List<int>? bytes, String orchard = _orchard, String uid = 'alice', int generation = 2}) =>
          decryptAccessNote(bytes ?? enc, using ?? key, orchardId: orchard, uid: uid, generation: generation);
      expect(await open(), 'Staging, to check the release', reason: 'kept trimmed');

      Future<void> refused(Future<Object?> opened) =>
          expectLater(opened, throwsA(isA<SecretBoxAuthenticationError>()));
      await refused(open(using: newSpaceKey()));
      await refused(open(orchard: _otherOrchard));
      // The server cannot pass one member's note off as another's.
      await refused(open(uid: 'bob'));
      await refused(open(generation: 1));
      // It is not a name, though the same key encrypts those.
      await refused(decryptOrchardName(enc, key, orchardId: _orchard, generation: 2));
      // Changed on the way.
      await refused(open(bytes: Uint8List.fromList(enc)..[enc.length - 1] ^= 1));
      // Two of the same note do not look alike.
      final again =
          await encryptAccessNote('Staging, to check the release', key, orchardId: _orchard, uid: 'alice', generation: 2);
      expect(again, isNot(enc));
      expect(await open(bytes: again), 'Staging, to check the release');
    });

    test('is 1 to 200 characters, and never more than the server takes', () async {
      final key = newSpaceKey();
      Future<Uint8List> enc(String note) =>
          encryptAccessNote(note, key, orchardId: _orchard, uid: 'alice', generation: 1);
      Future<String> open(List<int> bytes) =>
          decryptAccessNote(bytes, key, orchardId: _orchard, uid: 'alice', generation: 1);
      expect(() => enc('   '), throwsArgumentError);
      expect(() => enc('x' * (kMaxAccessNoteLength + 1)), throwsArgumentError);
      expect(kMaxAccessNoteLength, 200);
      expect(await open(await enc('x' * 200)), 'x' * 200);
      // Characters, not the units a string is kept in: 200 that take two each.
      final orange = String.fromCharCode(0x1F34A);
      expect(orange.length, 2);
      expect(await open(await enc(orange * 200)), orange * 200);
      expect(() => enc(orange * 201), throwsArgumentError);
      // The bytes are held to as well: a character JSON writes as six.
      final bell = String.fromCharCode(7);
      final most = await enc(bell * 147);
      expect(await open(most), bell * 147);
      expect(() => enc(bell * 148), throwsArgumentError);
      // Whatever passes fits the server's limit for a note (1024 bytes).
      for (final sealed in [most, await enc(orange * 200), await enc(String.fromCharCode(0x4E2D) * 200)]) {
        expect(sealed.length, lessThanOrEqualTo(1024));
      }
      expect(most.length, 899 + 28, reason: 'what is encrypted, a nonce and a tag');
    });

    test('what opens but is not a note is refused', () async {
      final key = newSpaceKey();
      Future<void> notANote(String json) async => expectLater(
          decryptAccessNote(
              await wrapUnderDek(utf8.encode(json), key, purpose: 'zestssh.access-note.v1|$_orchard|alice|1'), key,
              orchardId: _orchard, uid: 'alice', generation: 1),
          throwsFormatException);
      await notANote('{"v":2,"note":"Staging"}');
      await notANote('{"v":1,"note":7}');
      await notANote('{"v":1}');
      await notANote('["Staging"]');
      await notANote('Staging');
      // The same bytes under the same words do open: this is the format.
      expect(
          await decryptAccessNote(
              await wrapUnderDek(utf8.encode('{"v":1,"note":"Staging"}'), key,
                  purpose: 'zestssh.access-note.v1|$_orchard|alice|1'),
              key,
              orchardId: _orchard,
              uid: 'alice',
              generation: 1),
          'Staging');
      // Too short to be anything.
      expect(() => decryptAccessNote(Uint8List(8), key, orchardId: _orchard, uid: 'alice', generation: 1),
          throwsArgumentError);
    });
  });

  group('item ids', () {
    test('are the same on every device, and differ by kind, key and Crate', () async {
      final again = await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _crate);
      final id = crateItemId(idKey, kind: 'host', key: 'h-1');
      expect(crateItemId(again, kind: 'host', key: 'h-1'), id);
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));

      expect(crateItemId(idKey, kind: 'key', key: 'h-1'), isNot(id));
      expect(crateItemId(idKey, kind: 'host', key: 'h-2'), isNot(id));
      final otherCrate =
          await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _otherCrate);
      expect(crateItemId(otherCrate, kind: 'host', key: 'h-1'), isNot(id));
      // Without the Crate's key the id tells nothing: a different key, a
      // different id.
      final stranger = await crateItemIdKey(newSpaceKey(), orchardId: _orchard, crateId: _crate);
      expect(crateItemId(stranger, kind: 'host', key: 'h-1'), isNot(id));
    });
  });

  group('records', () {
    test('open where they were written, signed by their author', () async {
      final id = crateItemId(idKey, kind: 'host', key: 'h-1');
      final sealed = await sealItem(host(), place: placeOf(id), crateKey: crateKey, signer: me);
      expect(sealed.signature, hasLength(64));
      final opened = await openItem(sealed,
          orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe);
      expect(opened.toJson(), host().toJson());
    });

    Future<void> rejected(SealedItem item,
        {String crate = _crate, List<int>? key, SigningKeyLookup? signers}) async {
      final crateIdKey = crate == _crate
          ? idKey
          : await crateItemIdKey(crateKey, orchardId: _orchard, crateId: crate);
      await expectLater(
        openItem(item,
            orchardId: _orchard,
            crateId: crate,
            crateKey: key ?? crateKey,
            idKey: crateIdKey,
            signers: signers ?? onlyMe),
        throwsA(isA<ItemRejected>()),
      );
    }

    test('cannot be moved to another Crate, item or generation', () async {
      final id = crateItemId(idKey, kind: 'host', key: 'h-1');
      final sealed = await sealItem(host(), place: placeOf(id), crateKey: crateKey, signer: me);
      await rejected(sealed, crate: _otherCrate);
      await rejected(SealedItem(
          itemId: crateItemId(idKey, kind: 'host', key: 'h-2'),
          keyGeneration: 1,
          deleted: false,
          record: sealed.record,
          signature: sealed.signature));
      await rejected(SealedItem(
          itemId: id,
          keyGeneration: 2,
          deleted: false,
          record: sealed.record,
          signature: sealed.signature));
      await rejected(sealed, key: newSpaceKey());
    });

    test('a changed byte, or a flipped deleted flag, is refused', () async {
      final id = crateItemId(idKey, kind: 'host', key: 'h-1');
      final sealed = await sealItem(host(), place: placeOf(id), crateKey: crateKey, signer: me);
      final tampered = Uint8List.fromList(sealed.record)..[20] ^= 1;
      await rejected(SealedItem(
          itemId: id, keyGeneration: 1, deleted: false, record: tampered, signature: sealed.signature));
      await rejected(SealedItem(
          itemId: id, keyGeneration: 1, deleted: true, record: sealed.record, signature: sealed.signature));
    });

    test('a record signed by anyone but the author it names is refused', () async {
      final id = crateItemId(idKey, kind: 'host', key: 'h-1');
      // Someone with the Crate key writes a record naming "me" as author.
      final forged =
          await sealItem(host(), place: placeOf(id), crateKey: crateKey, signer: someoneElse);
      await rejected(forged);
      // And an author this device does not know is refused too.
      final sealed = await sealItem(host(), place: placeOf(id), crateKey: crateKey, signer: me);
      await rejected(sealed, signers: (uid, version) async => null);
    });

    test('a record written under an id it does not belong to is refused', () async {
      // Sealed and signed properly, but for the id of another item.
      final wrongId = crateItemId(idKey, kind: 'host', key: 'h-2');
      final sealed =
          await sealItem(host(), place: placeOf(wrongId), crateKey: crateKey, signer: me);
      await rejected(sealed);
    });

    test('malformed records are refused', () {
      expect(() => ItemRecord.fromJson({'v': 2}), throwsFormatException);
      final json = host().toJson()..['deleted'] = true;
      expect(() => ItemRecord.fromJson(json), throwsFormatException,
          reason: 'a deleted item carries no rows');
      final moved = host().toJson()..['moved_to'] = _otherCrate;
      expect(() => ItemRecord.fromJson(moved), throwsFormatException,
          reason: 'only a deletion can be a move');
    });
  });

  group('a newer format', () {
    test('is read when it says this version can, and what it adds is kept', () async {
      final json = host().toJson()
        ..['v'] = 2
        ..['min_reader'] = 1
        ..['shared_with'] = ['ops'];
      final record = ItemRecord.fromJson(json);
      expect(record.extra, {
        'shared_with': ['ops'],
      });
      final back = record.toJson();
      expect(back['shared_with'], ['ops'], reason: 'written back untouched');
      expect(back['v'], 1, reason: 'in the format that holds it: an SSH host, format 1, as before 3.4');
      expect(back.containsKey('min_reader'), isFalse);

      // Sealed and opened, the added field stays with the record.
      final id = crateItemId(idKey, kind: 'host', key: 'h-1');
      final sealed = await sealItem(record, place: placeOf(id), crateKey: crateKey, signer: me);
      final opened = await openItem(sealed,
          orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe);
      expect(opened.extra, record.extra);
    });

    test('is refused when it says this version cannot read it', () {
      expect(() => ItemRecord.fromJson(host().toJson()..['v'] = kItemRecordFormat + 1), throwsFormatException,
          reason: 'a newer format names no older reader: its own format is the minimum');
      expect(
          () => ItemRecord.fromJson(host().toJson()
            ..['v'] = kItemRecordFormat + 2
            ..['min_reader'] = kItemRecordFormat + 1),
          throwsFormatException);
      expect(() => ItemRecord.fromJson(host().toJson()..['min_reader'] = '1'), throwsFormatException);
      expect(() => ItemRecord.fromJson(host().toJson()..['v'] = 0), throwsFormatException);
    });
  });

  group('format 2 (3.4): FTPS hosts and certificate pins', () {
    ItemRecord ftps(String protocol) => ItemRecord(
          kind: 'host',
          key: 'f-1',
          author: 'me',
          authorKeyVersion: me.version,
          editedAt: 1000,
          data: {
            'connections': [
              {'id': 'f-1', 'label': 'files', 'host': 'files.example.com', 'port': 21, 'protocol': protocol},
            ],
          },
        );
    ItemRecord pin(String line) => ItemRecord(
          kind: 'hostkey',
          key: 'files.example.com|21||$_crate',
          author: 'me',
          authorKeyVersion: me.version,
          editedAt: 1000,
          data: {
            'team_host_keys': [
              {'id': 'files.example.com|21||$_crate', 'host_keys': jsonEncode([line])},
            ],
          },
        );

    test('an FTPS host and a pinned certificate are written in format 2, everything else in format 1', () {
      expect(ftps('ftps').toJson()['v'], 2);
      expect(ftps('ftpsImplicit').toJson()['v'], 2);
      expect(ftps('sftp').toJson()['v'], 1);
      expect(host().toJson()['v'], 1);
      expect(pin('x509-sha256 MIIB').toJson()['v'], 2);
      expect(pin('ssh-ed25519 AAAA').toJson()['v'], 1);
      const deletion = ItemRecord(kind: 'host', key: 'f-1', author: 'me', authorKeyVersion: 1, editedAt: 1, deleted: true);
      expect(deletion.toJson()['v'], 1, reason: 'a deletion holds no rows');
    });

    test('3.4 reads it; a version before 3.4 (format 1) refuses it as a record that does not open', () async {
      for (final record in [ftps('ftps'), ftps('ftpsImplicit'), pin('x509-sha256 MIIB')]) {
        final json = record.toJson();
        expect(ItemRecord.fromJson(json).data, record.data);
        expect(() => ItemRecord.fromJson(json, readsFormat: 1), throwsFormatException);
        final id = crateItemId(idKey, kind: record.kind, key: record.key);
        final sealed = await sealItem(record, place: placeOf(id), crateKey: crateKey, signer: me);
        final opened = await openItem(sealed,
            orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe);
        expect(opened.data, record.data);
        await expectLater(
            openItem(sealed,
                orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe, readsFormat: 1),
            throwsA(isA<ItemRejected>()));
      }
      // An SSH host is read by both, byte for byte as before 3.4.
      expect(ItemRecord.fromJson(host().toJson(), readsFormat: 1).data, host().data);
    });
  });

  group('format 3 (4.0): remote screens', () {
    ItemRecord screen({String protocol = 'vnc'}) => ItemRecord(
          kind: 'host',
          key: 's-1',
          author: 'me',
          authorKeyVersion: me.version,
          editedAt: 1000,
          data: {
            'connections': [
              {
                'id': 's-1',
                'label': 'desk',
                'host': 'localhost',
                'port': 5900,
                'protocol': protocol,
                'connect_via_id': 'h-1',
                'screen_options': '{"v":1,"target":"tcp"}',
              },
            ],
          },
        );

    test('a VNC host is written in format 3; FTPS stays 2 and the rest 1', () {
      expect(kItemRecordFormat, greaterThanOrEqualTo(3));
      expect(screen().toJson()['v'], 3);
      expect(screen().toJson().containsKey('min_reader'), isFalse, reason: 'its own format is the least reader');
      expect(itemRecordFormatOf('host', screen().data), 3);
      expect(itemRecordFormatOf('host', screen(protocol: 'ftps').data), 2);
      expect(itemRecordFormatOf('host', screen(protocol: 'ssh').data), 1);
      expect(host().toJson()['v'], 1);
      // Another kind of item that names vnc somewhere is not a screen.
      expect(itemRecordFormatOf('snippet', {'snippets': [{'id': 'x', 'protocol': 'vnc'}]}), 1);
    });

    test('4.0 reads it; 3.4 (format 2) and versions before it refuse it as a record that does not open', () async {
      final record = screen();
      final json = record.toJson();
      expect(ItemRecord.fromJson(json).data, record.data);
      for (final older in [1, 2]) {
        expect(() => ItemRecord.fromJson(json, readsFormat: older), throwsFormatException, reason: 'reads $older');
      }
      final id = crateItemId(idKey, kind: record.kind, key: record.key);
      final sealed = await sealItem(record, place: placeOf(id), crateKey: crateKey, signer: me);
      final opened = await openItem(sealed,
          orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe);
      expect(opened.data, record.data);
      await expectLater(
          openItem(sealed,
              orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe, readsFormat: 2),
          throwsA(isA<ItemRejected>()));
      // What 3.4 reads it still reads.
      expect(ItemRecord.fromJson(host().toJson(), readsFormat: 2).data, host().data);
    });
  });

  group('format 4 (4.0): RDP hosts', () {
    ItemRecord pc({String protocol = 'rdp'}) => ItemRecord(
          kind: 'host',
          key: 'r-1',
          author: 'me',
          authorKeyVersion: me.version,
          editedAt: 1000,
          data: {
            'connections': [
              {
                'id': 'r-1',
                'label': 'office-pc',
                'host': 'localhost',
                'port': 3389,
                'protocol': protocol,
                'connect_via_id': 'h-1',
                'screen_options': '{"v":1,"nla":false}',
              },
            ],
          },
        );

    test('an RDP host is written in format 4; a VNC screen stays 3, FTPS 2 and the rest 1', () {
      expect(kItemRecordFormat, 4);
      expect(pc().toJson()['v'], 4);
      expect(pc().toJson().containsKey('min_reader'), isFalse, reason: 'its own format is the least reader');
      expect(itemRecordFormatOf('host', pc().data), 4);
      expect(itemRecordFormatOf('host', pc(protocol: 'vnc').data), 3);
      expect(itemRecordFormatOf('host', pc(protocol: 'ftps').data), 2);
      expect(itemRecordFormatOf('host', pc(protocol: 'ssh').data), 1);
      // Another kind of item that names rdp somewhere is not an RDP host.
      expect(itemRecordFormatOf('snippet', {'snippets': [{'id': 'x', 'protocol': 'rdp'}]}), 1);
    });

    test('a version with VNC and no RDP (format 3) refuses it as a record that does not open, as older ones do',
        () async {
      final record = pc();
      final json = record.toJson();
      expect(ItemRecord.fromJson(json).data, record.data);
      for (final older in [1, 2, 3]) {
        expect(() => ItemRecord.fromJson(json, readsFormat: older), throwsFormatException, reason: 'reads $older');
      }
      final id = crateItemId(idKey, kind: record.kind, key: record.key);
      final sealed = await sealItem(record, place: placeOf(id), crateKey: crateKey, signer: me);
      final opened = await openItem(sealed,
          orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe);
      expect(opened.data, record.data);
      await expectLater(
          openItem(sealed,
              orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe, readsFormat: 3),
          throwsA(isA<ItemRejected>()));
      // What that version reads it still reads: a VNC screen, and an SSH host.
      expect(ItemRecord.fromJson(pc(protocol: 'vnc').toJson(), readsFormat: 3).data, pc(protocol: 'vnc').data);
      expect(ItemRecord.fromJson(host().toJson(), readsFormat: 3).data, host().data);
    });
  });

  group('key copies', () {
    test('sign exactly the bytes the server checks', () {
      // Pinned in ZestSSH Cloud's test/key_copies_lib.test.js too.
      final crate = keyCopySignatureMessage(
        const KeyCopyPlace(
          orchardId: _orchard,
          crateId: _crate,
          generation: 3,
          recipient: 'uid-recipient',
          recipientKeyVersion: 2,
          sealer: 'uid-sealer',
          sealerKeyVersion: 5,
        ),
        List<int>.generate(92, (i) => i),
      );
      expect(crate.length, 255);
      expect(hash.sha256.convert(crate).toString(),
          '3f63be860a58572bf63fcce598a626911c48fd3ee8a4fce8a41bd3f597294468');
      final orchard = keyCopySignatureMessage(
        const KeyCopyPlace(
          orchardId: _orchard,
          generation: 1,
          recipient: 'uid-a',
          recipientKeyVersion: 1,
          sealer: 'uid-a',
          sealerKeyVersion: 1,
        ),
        List<int>.filled(92, 9),
      );
      expect(orchard.length, 208);
      expect(hash.sha256.convert(orchard).toString(),
          '7306f055c9e4eb0597177e2d0c1a05660af521a4d7898a8c33278c857bc465f7');
    });

    test('a signature holds for its own copy and signer only', () async {
      KeyCopyPlace place({
        String orchardId = _orchard,
        String? crateId = _crate,
        int generation = 1,
        String recipient = 'me',
        int? recipientKeyVersion,
        String sealer = 'me',
        int? sealerKeyVersion,
      }) =>
          KeyCopyPlace(
            orchardId: orchardId,
            crateId: crateId,
            generation: generation,
            recipient: recipient,
            recipientKeyVersion: recipientKeyVersion ?? me.version,
            sealer: sealer,
            sealerKeyVersion: sealerKeyVersion ?? me.version,
          );
      final sealed = await sealCrateKey(me.encryption.publicKey, crateKey,
          orchardId: _orchard, crateId: _crate, generation: 1);
      final signature = await signKeyCopy(me, place(), sealed);
      expect(await verifyKeyCopy(me.signingPublicKey, place(), sealed, signature), isTrue);

      for (final other in [
        place(orchardId: _otherOrchard),
        place(crateId: _otherCrate),
        place(crateId: null),
        place(generation: 2),
        place(recipient: 'you'),
        place(recipientKeyVersion: me.version + 1),
        place(sealer: 'you'),
        place(sealerKeyVersion: me.version + 1),
      ]) {
        expect(await verifyKeyCopy(me.signingPublicKey, other, sealed, signature), isFalse);
      }
      final otherBytes = Uint8List.fromList(sealed)..[10] ^= 1;
      expect(await verifyKeyCopy(me.signingPublicKey, place(), otherBytes, signature), isFalse);
      expect(await verifyKeyCopy(someoneElse.signingPublicKey, place(), sealed, signature),
          isFalse);
      expect(await verifyKeyCopy(me.signingPublicKey, place(), sealed, signature.sublist(1)),
          isFalse);
      expect(() => signKeyCopy(me, place(sealerKeyVersion: me.version + 1), sealed),
          throwsArgumentError);
    });
  });

  // A member's record nested 20,000 deep threw a stack overflow at every
  // reader that wrote it out again, and stopped every member's team sync
  // (found in a security review).
  group('how deep a record nests', () {
    /// [levels] lists, one inside the other, made without recursion.
    Object nested(int levels) {
      Object value = <Object?>[];
      for (var i = 1; i < levels; i++) {
        value = <Object?>[value];
      }
      return value;
    }

    test('up to the bound it is a record; past it, it is malformed, however deep', () {
      // The record is one level, so a field of it holds one less.
      final atBound = host().toJson()..['zz'] = nested(kItemRecordMaxDepth - 1);
      expect(ItemRecord.fromJson(atBound).extra['zz'], isA<List<Object?>>());
      for (final levels in [kItemRecordMaxDepth, 20000, 200000]) {
        expect(() => ItemRecord.fromJson(host().toJson()..['zz'] = nested(levels)), throwsFormatException,
            reason: '$levels levels');
      }
      // In its rows too: a column's value, or a table no app knows.
      final inRow = host().toJson();
      ((inRow['data']! as Map)['connections'] as List).single['label'] = nested(kItemRecordMaxDepth);
      expect(() => ItemRecord.fromJson(inRow), throwsFormatException);
      final inTable = host().toJson();
      (inTable['data']! as Map)['new_table'] = nested(kItemRecordMaxDepth);
      expect(() => ItemRecord.fromJson(inTable), throwsFormatException);
    });

    test('a blob in a row is well inside it', () {
      final json = host().toJson();
      ((json['data']! as Map)['connections'] as List).single['custom_icon'] = {'b64': 'AAEC'};
      expect(ItemRecord.fromJson(json).data, isNotNull);
    });

    test('a sealed one past the bound is refused as it opens, before anything writes it out', () async {
      final id = crateItemId(idKey, kind: 'host', key: 'h-1');
      final place = placeOf(id);
      final json = jsonEncode(host().toJson());
      const depth = 20000;
      final clear = '${json.substring(0, json.length - 1)},"zz":${'[' * depth}${']' * depth}}';
      final record = await wrapUnderDek(utf8.encode(clear), crateKey, purpose: 'zestssh.crate-item.v1|$_orchard|$_crate|$id|1');
      final sealed = SealedItem(
        itemId: id,
        keyGeneration: 1,
        deleted: false,
        record: record,
        signature: await me.sign(itemSignatureMessage(place, deleted: false, record: record)),
      );
      await expectLater(
        openItem(sealed, orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: onlyMe),
        throwsA(isA<ItemRejected>().having((e) => e.reason, 'reason', 'malformed record')),
      );
    });
  });

  // A member's version stamped at the latest time a record may say made every
  // later change one past it, which every other device refused: the item froze
  // for everyone (found in a security review).
  group('the time of a change', () {
    test('is later than the version it replaces, and never past the latest a record may say', () {
      expect(itemEditedAfter(1000, 5000), 5000, reason: 'now, where now is later');
      expect(itemEditedAfter(5000, 1000), 5001, reason: 'a clock behind still writes a later change');
      expect(itemEditedAfter(5000, 5000), 5001);
      expect(itemEditedAfter(kItemEditedAtMaxMs - 1, 0), kItemEditedAtMaxMs);
      expect(itemEditedAfter(kItemEditedAtMaxMs, 0), kItemEditedAtMaxMs, reason: 'at the bound, the same time');
      expect(itemEditedAfter(0, kItemEditedAtMaxMs + 1000), kItemEditedAtMaxMs, reason: 'a clock past it too');
      for (final (held, now) in [(kItemEditedAtMaxMs, 0), (0, kItemEditedAtMaxMs + 1000)]) {
        final record = host(editedAt: itemEditedAfter(held, now)).toJson();
        expect(ItemRecord.fromJson(record).editedAt, kItemEditedAtMaxMs, reason: 'every device takes it');
      }
    });
  });

  group('which version wins', () {
    test('the newer edit, then the account, then the content, the same both ways', () {
      final older = host(editedAt: 1000);
      final newer = host(editedAt: 2000);
      expect(versionWins(newer, older), isTrue);
      expect(versionWins(older, newer), isFalse);

      final a = host(editedAt: 1000, label: 'a');
      final b = host(editedAt: 1000, label: 'b');
      expect(versionWins(a, b), isNot(versionWins(b, a)),
          reason: 'a tie is broken the same way on every device');
      expect(versionWins(a, a), isFalse);
    });
  });
}
