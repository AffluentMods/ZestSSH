// The two signed messages of a share (share_invitation.dart): the exact
// bytes, what is refused as not being one, and what each side checks before
// it acts on the other's: the signature against the pinned keys, the people
// against the Orchard's record, and everything the server said against what
// was signed.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';

const shareId = '11111111-1111-4111-8111-111111111111';
const orchardId = '22222222-2222-4222-8222-222222222222';
const crateId = '33333333-3333-4333-8333-333333333333';
const connectionId = '44444444-4444-4444-8444-444444444444';
const otherId = '55555555-5555-4555-8555-555555555555';
const now = 1790000000;

List<int> lp(List<int> b) =>
    [(b.length >> 24) & 0xff, (b.length >> 16) & 0xff, (b.length >> 8) & 0xff, b.length & 0xff, ...b];
List<int> text(String s) => lp(utf8.encode(s));
List<int> u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> u64(int v) => [...u32(v ~/ 0x100000000), ...u32(v & 0xffffffff)];

void main() {
  late AccountKeys dana; // shares
  late AccountKeys sam; // is invited
  late AccountKeys eve; // someone else
  late ShareHostKeys hostKeys;

  setUpAll(() async {
    dana = await AccountKeys.fromSeeds(
        encryptionSeed: List.filled(32, 1), signingSeed: List.filled(32, 2), version: 3, createdAt: 1);
    sam = await AccountKeys.fromSeeds(
        encryptionSeed: List.filled(32, 3), signingSeed: List.filled(32, 4), version: 1, createdAt: 1);
    eve = await AccountKeys.generate();
    hostKeys = await ShareHostKeys.generate();
  });

  ShareInvitation live({
    String share = shareId,
    String to = 'uid-sam',
    int expiresAt = now + 3600,
    bool keyboard = true,
    bool mayEnd = false,
    String remoteUser = 'deploy',
  }) =>
      ShareInvitation(
        shareId: share,
        orchardId: orchardId,
        crateId: crateId,
        fromUid: 'uid-dana',
        fromKeyVersion: 3,
        toUid: to,
        mode: ShareMode.live,
        connectionId: connectionId,
        remoteUser: remoteUser,
        keyboard: keyboard,
        mayEnd: mayEnd,
        offer: hostKeys.offer,
        expiresAt: expiresAt,
      );

  ShareInvitation tmux({String session = 'shared-k7q'}) => ShareInvitation(
        shareId: shareId,
        orchardId: orchardId,
        crateId: crateId,
        fromUid: 'uid-dana',
        fromKeyVersion: 3,
        toUid: 'uid-sam',
        mode: ShareMode.tmux,
        connectionId: connectionId,
        tmuxSession: session,
        remoteUser: 'deploy',
        expiresAt: now + 3600,
      );

  /// The bytes of an invitation, built here field by field.
  List<int> inviteBytes({
    String label = kShareInviteLabel,
    String share = shareId,
    String orchard = orchardId,
    String crate = crateId,
    String from = 'uid-dana',
    int keyVersion = 3,
    String to = 'uid-sam',
    int mode = 1,
    String connection = connectionId,
    String session = '',
    String user = 'deploy',
    int keyboard = 1,
    List<int>? x25519,
    List<int>? kem,
    List<int>? expires,
    List<int> tail = const [],
  }) =>
      [
        ...text(label),
        ...text(share),
        ...text(orchard),
        ...text(crate),
        ...text(from),
        ...u32(keyVersion),
        ...text(to),
        mode,
        ...text(connection),
        ...text(session),
        ...text(user),
        keyboard,
        ...lp(x25519 ?? hostKeys.offer.x25519Key),
        ...lp(kem ?? hostKeys.offer.kemKey),
        ...(expires ?? u64(now + 3600)),
        ...tail,
      ];

  /// A record where dana and sam open the Crate, and pat is in the Orchard
  /// without it.
  OrchardRecord record({String orchard = orchardId}) {
    RecordKeys keys(AccountKeys k) => RecordKeys(
          version: k.version,
          signingKey: k.signingPublicKey,
          encryptionKey: k.encryption.publicKey,
          createdAt: k.createdAt,
          selfSignature: Uint8List(64),
        );
    final r = OrchardRecord(orchard);
    r.crates[crateId] = RecordCrate(id: crateId, ownersOnly: false, allow: {'sftp', 'forward'});
    r.roles['members'] = RecordRole(
        id: 'members', rank: 100, nameEnc: '', nameGeneration: 1, can: {}, crates: {crateId: levelSwitches(CrateLevel.connect)});
    r.roles['others'] = RecordRole(id: 'others', rank: 50, nameEnc: '', nameGeneration: 1, can: {}, crates: {});
    r.members['uid-dana'] = RecordMember(uid: 'uid-dana', role: 'members', keys: {3: keys(dana)}, since: 1);
    r.members['uid-sam'] = RecordMember(uid: 'uid-sam', role: 'members', keys: {1: keys(sam)}, since: 2);
    r.members['uid-pat'] = RecordMember(uid: 'uid-pat', role: 'others', keys: {1: keys(eve)}, since: 3);
    return r;
  }

  ShareParty party(String uid, AccountKeys k, {bool keysChanged = false, int? version, Uint8List? signingKey}) => ShareParty(
        uid: uid,
        keyVersion: version ?? k.version,
        signingKey: signingKey ?? k.signingPublicKey,
        encryptionKey: k.encryption.publicKey,
        keysChanged: keysChanged,
      );

  group('an invitation', () {
    test('the bytes that are signed, field by field', () {
      expect(live().message(), inviteBytes());
      expect(
          tmux().message(),
          inviteBytes(mode: 2, session: 'shared-k7q', keyboard: 0, x25519: const [], kem: const []));
      expect(kShareInviteLabel, 'zestssh.share.invite.v1');
      // The part someone has in a live view is one byte: 0 watches, 1 may
      // be handed the keyboard, 2 may end the session.
      expect(live(keyboard: false).message(), inviteBytes(keyboard: 0));
      expect(live(keyboard: false, mayEnd: true).message(), inviteBytes(keyboard: 2));
    });

    test('someone invited has one part: who may end the session is never handed the keyboard', () {
      expect(() => live(keyboard: true, mayEnd: true), throwsFormatException);
      expect(live(keyboard: false, mayEnd: true).mayEnd, isTrue);
      expect((live().keyboard, live().mayEnd), (true, false));
      expect((live(keyboard: false).keyboard, live(keyboard: false).mayEnd), (false, false));
      // A shared tmux session has nobody who ends it: everyone there signs
      // in to the host by themselves.
      expect(
          () => ShareInvitation(
                shareId: shareId,
                orchardId: orchardId,
                crateId: crateId,
                fromUid: 'uid-dana',
                fromKeyVersion: 3,
                toUid: 'uid-sam',
                mode: ShareMode.tmux,
                connectionId: connectionId,
                tmuxSession: 'shared-k7q',
                remoteUser: 'deploy',
                mayEnd: true,
                expiresAt: now + 3600,
              ),
          throwsFormatException);
      expect(tmux().mayEnd, isFalse);
    });

    test('reads back as what was written, for a live view and for a shared tmux session', () {
      final i = ShareInvitation.parse(live().message());
      expect([i.shareId, i.orchardId, i.crateId, i.connectionId], [shareId, orchardId, crateId, connectionId]);
      expect([i.fromUid, i.fromKeyVersion, i.toUid], ['uid-dana', 3, 'uid-sam']);
      expect([i.mode, i.keyboard, i.remoteUser, i.tmuxSession], [ShareMode.live, true, 'deploy', '']);
      expect(i.mayEnd, isFalse);
      expect(i.expiresAt, now + 3600);
      expect(i.offer!.x25519Key, hostKeys.offer.x25519Key);
      expect(i.offer!.kemKey, hostKeys.offer.kemKey);
      final watcher = ShareInvitation.parse(live(keyboard: false).message());
      expect((watcher.keyboard, watcher.mayEnd), (false, false));
      final ender = ShareInvitation.parse(live(keyboard: false, mayEnd: true).message());
      expect((ender.keyboard, ender.mayEnd), (false, true));
      expect(ender.message(), inviteBytes(keyboard: 2), reason: 'written again, it is the same bytes');

      final t = ShareInvitation.parse(tmux().message());
      expect([t.mode, t.tmuxSession, t.remoteUser, t.keyboard, t.offer], [ShareMode.tmux, 'shared-k7q', 'deploy', false, null]);
      expect(t.mayEnd, isFalse);
      expect(ShareInvitation.parse(inviteBytes(user: '')).remoteUser, '');
    });

    test('anything that is not exactly an invitation is refused', () {
      void bad(List<int> bytes, String why) =>
          expect(() => ShareInvitation.parse(bytes), throwsFormatException, reason: why);
      bad(const [], 'nothing');
      bad(inviteBytes(label: 'zestssh.share.join.v1'), 'another label');
      bad(inviteBytes(label: 'zestssh.share.invite.v2'), 'another version');
      bad(inviteBytes(tail: const [0]), 'a byte too many');
      bad(inviteBytes().sublist(0, inviteBytes().length - 1), 'a byte short');
      bad(inviteBytes(mode: 0), 'no way of sharing');
      bad(inviteBytes(mode: 3), 'a third way of sharing');
      bad(inviteBytes(keyboard: 3), 'a fourth part');
      bad(inviteBytes(keyboard: 255), 'not a part at all');
      for (final id in ['nope', '', shareId.toUpperCase().replaceAll('1', 'A'), '$shareId ', 'g1111111-1111-4111-8111-111111111111']) {
        bad(inviteBytes(share: id), 'share id "$id"');
        bad(inviteBytes(orchard: id), 'orchard id "$id"');
        bad(inviteBytes(crate: id), 'crate id "$id"');
      }
      // A host's key in the Crate is not always a UUID, but it is a short
      // plain string.
      for (final key in ['h-1', 'conn_1790000000', connectionId, 'x' * 128]) {
        expect(ShareInvitation.parse(inviteBytes(connection: key)).connectionId, key);
      }
      bad(inviteBytes(connection: ''), 'no host');
      bad(inviteBytes(connection: 'x' * 129), 'a host key too long');
      bad(inviteBytes(connection: 'a\nb'), 'a host key with a line break');
      bad(inviteBytes(connection: 'a\x00b'), 'a host key with a control character');
      bad(inviteBytes(from: ''), 'nobody shares');
      bad(inviteBytes(to: ''), 'nobody is invited');
      bad(inviteBytes(to: 'x' * 129), 'a uid too long');
      bad(inviteBytes(from: 'uid-sam'), 'inviting yourself');
      bad(inviteBytes(keyVersion: 0), 'no key version');
      bad(inviteBytes(keyVersion: 1000001), 'a key version out of range');
      bad(inviteBytes(expires: u64(0)), 'no time');
      bad(inviteBytes(expires: u64(0x100000000)), 'a time far beyond any share');
      bad(inviteBytes(expires: const [0x80, 0, 0, 0, 0, 0, 0, 0]), 'not a number');
      bad(inviteBytes(user: 'u' * 65), 'a user name too long');
      // A live view carries both keys, of the right size, and no tmux name.
      bad(inviteBytes(x25519: List.filled(31, 1)), 'a short X25519 key');
      bad(inviteBytes(kem: List.filled(1183, 1)), 'a short ML-KEM key');
      bad(inviteBytes(x25519: const []), 'one key only');
      bad(inviteBytes(kem: const []), 'the other key only');
      bad(inviteBytes(x25519: const [], kem: const []), 'a live view with no keys');
      bad(inviteBytes(session: 'main'), 'a live view naming a tmux session');
      // A shared tmux session carries a plain name, no keys and no keyboard.
      List<int> t({String session = 'main', int keyboard = 0, List<int> x = const [], List<int> k = const []}) =>
          inviteBytes(mode: 2, session: session, keyboard: keyboard, x25519: x, kem: k);
      expect(ShareInvitation.parse(t()).tmuxSession, 'main');
      bad(t(keyboard: 1), 'a keyboard in tmux');
      bad(t(keyboard: 2), 'someone who ends a shared tmux session');
      bad(t(x: hostKeys.offer.x25519Key, k: hostKeys.offer.kemKey), 'keys in tmux');
      for (final name in [
        '',
        'two words',
        'a;b',
        r'$(reboot)',
        'a"b',
        "a'b",
        'a`b',
        'a|b',
        'a&b',
        'a\nb',
        'a/b',
        'a.b',
        'a:b',
        'é',
        'x' * 33,
      ]) {
        bad(t(session: name), 'the tmux name ${jsonEncode(name)}');
      }
      for (final name in ['main', 'shared-k7q', 'A_b-9', 'x' * 32]) {
        expect(ShareInvitation.parse(t(session: name)).tmuxSession, name);
      }
      // Not UTF-8.
      final broken = inviteBytes();
      broken[4] = 0xff;
      bad(broken, 'a label that is not text');
    });

    test('signed: the wire is the message and the signature, and only the signer\'s key checks it', () async {
      final signed = await SignedShareInvitation.sign(live(), dana);
      expect(signed.wire, [...lp(inviteBytes()), ...await dana.sign(inviteBytes())]);
      expect(await signed.signedBy(dana.signingPublicKey), isTrue);
      expect(await signed.signedBy(sam.signingPublicKey), isFalse);
      expect(await signed.signedBy(Uint8List(31)), isFalse);

      final back = SignedShareInvitation.decode(signed.wire);
      expect(back.invitation.message(), inviteBytes());
      expect(back.wire, signed.wire);
      expect(back.digest, signed.digest);
      expect(back.digest.length, 32);
      expect(await back.signedBy(dana.signingPublicKey), isTrue);

      // A byte changed anywhere: not an invitation any more, or not signed.
      for (final at in [0, 3, 4, 40, 200, signed.wire.length - 70, signed.wire.length - 64, signed.wire.length - 1]) {
        final changed = Uint8List.fromList(signed.wire)..[at] ^= 1;
        try {
          expect(await SignedShareInvitation.decode(changed).signedBy(dana.signingPublicKey), isFalse,
              reason: 'byte $at');
        } on FormatException {
          // Refused before the signature is looked at.
        }
      }
      expect(() => SignedShareInvitation.decode(signed.wire.sublist(0, 67)), throwsFormatException);
      expect(() => SignedShareInvitation.decode([...signed.wire, 0]), throwsFormatException);
      expect(() => SignedShareInvitation.decode(Uint8List(4097)), throwsFormatException);
      expect(() => SignedShareInvitation.decode(const []), throwsFormatException);
      // The version named has to be the version that signs.
      await expectLater(SignedShareInvitation.sign(live(), sam), throwsArgumentError);
    });

    test('sealed to the invited person, for this share only', () async {
      final signed = await SignedShareInvitation.sign(live(), dana);
      final sealed = await signed.sealTo(sam.encryption.publicKey);
      expect(sealed.length, lessThanOrEqualTo(kShareSealedMax), reason: 'fits what the server takes');
      expect(sealed.length, greaterThan(signed.wire.length));

      final opened = await SignedShareInvitation.open(sealed, sam.encryption, shareId: shareId);
      expect(opened.wire, signed.wire);
      expect(await opened.signedBy(dana.signingPublicKey), isTrue);

      Future<void> bad(Future<Object?> f, String why) => expectLater(f, throwsFormatException, reason: why);
      await bad(SignedShareInvitation.open(sealed, sam.encryption, shareId: otherId), 'listed under another share');
      await bad(SignedShareInvitation.open(sealed, eve.encryption, shareId: shareId), 'someone else\'s keys');
      await bad(SignedShareInvitation.open(sealed, dana.encryption, shareId: shareId), 'not even the sender\'s');
      await bad(SignedShareInvitation.open(Uint8List.fromList(sealed)..[60] ^= 1, sam.encryption, shareId: shareId),
          'a changed byte');
      await bad(SignedShareInvitation.open(sealed.sublist(0, 20), sam.encryption, shareId: shareId), 'too short');
      await bad(SignedShareInvitation.open(Uint8List(kShareSealedMax + 1), sam.encryption, shareId: shareId), 'too long');
      await bad(SignedShareInvitation.open(sealed, sam.encryption, shareId: 'nope'), 'not a share id');
      // Something sealed to them, for this share, that is not an invitation.
      final junk = await sealTo(sam.encryption.publicKey, [1, 2, 3], context: '$kShareInviteLabel $shareId');
      await bad(SignedShareInvitation.open(junk, sam.encryption, shareId: shareId), 'not an invitation inside');
      // One larger than the server takes is not opened at all, though it
      // is sealed to them, for this share, and begins with a real invitation.
      final padded = await sealTo(
          sam.encryption.publicKey, [...signed.wire, ...List<int>.filled(kShareSealedMax, 0)],
          context: '$kShareInviteLabel $shareId');
      await expectLater(
          SignedShareInvitation.open(padded, sam.encryption, shareId: shareId),
          throwsA(isA<FormatException>().having((e) => e.message, 'why', 'not a sealed invitation')),
          reason: 'refused for its size, unopened');
      await expectLater(
          SignedShareInvitation.open(junk, sam.encryption, shareId: shareId),
          throwsA(isA<FormatException>().having((e) => e.message, 'why', isNot('not a sealed invitation'))),
          reason: 'one of a size it takes is opened and read');
      // Sealed twice, it is never the same bytes.
      expect(await signed.sealTo(sam.encryption.publicKey), isNot(sealed));

      // The largest invitation there is still fits the server's limit.
      final big = await SignedShareInvitation.sign(
          ShareInvitation(
            shareId: shareId,
            orchardId: orchardId,
            crateId: crateId,
            fromUid: 'd' * 128,
            fromKeyVersion: 3,
            toUid: 's' * 128,
            mode: ShareMode.live,
            connectionId: connectionId,
            remoteUser: 'u' * 64,
            keyboard: true,
            offer: hostKeys.offer,
            expiresAt: now + 3600,
          ),
          dana);
      expect((await big.sealTo(sam.encryption.publicKey)).length, lessThanOrEqualTo(kShareSealedMax));
    });
  });

  group('whether to join an invitation', () {
    late SignedShareInvitation signed;
    setUpAll(() async => signed = await SignedShareInvitation.sign(live(), dana));

    Future<ShareProblem?> check({
      SignedShareInvitation? invitation,
      String share = shareId,
      String orchard = orchardId,
      String crate = crateId,
      String from = 'uid-dana',
      ShareMode mode = ShareMode.live,
      String me = 'uid-sam',
      OrchardRecord? rec,
      ShareParty? host,
      bool noHost = false,
      int at = now,
    }) =>
        shareInvitationProblem(
          invitation ?? signed,
          shareId: share,
          orchardId: orchard,
          crateId: crate,
          fromUid: from,
          mode: mode,
          me: me,
          record: rec ?? record(),
          host: noHost ? null : (host ?? party('uid-dana', dana)),
          nowSeconds: at,
        );

    test('signed by the pinned keys of someone who can open the Crate, for me, in time: yes', () async {
      expect(await check(), isNull);
      expect(await check(at: now + 3599), isNull, reason: 'until its last second');
    });

    test('what the server said has to be what was signed', () async {
      expect(await check(share: otherId), ShareProblem.mismatch);
      expect(await check(orchard: otherId), ShareProblem.mismatch);
      expect(await check(rec: record(orchard: otherId)), ShareProblem.mismatch, reason: 'the record of another Orchard');
      expect(await check(crate: otherId), ShareProblem.mismatch);
      expect(await check(from: 'uid-pat'), ShareProblem.mismatch);
      expect(await check(mode: ShareMode.tmux), ShareProblem.mismatch);
      expect(await check(me: 'uid-pat'), ShareProblem.mismatch, reason: 'made for someone else');
    });

    test('its time: not after it, and never further off than a share can last', () async {
      expect(await check(at: now + 3600), ShareProblem.expired);
      expect(await check(at: now + 99999), ShareProblem.expired);
      final far = await SignedShareInvitation.sign(live(expiresAt: now + kShareLifetimeSeconds + 301), dana);
      expect(await check(invitation: far), ShareProblem.expired);
      final most = await SignedShareInvitation.sign(live(expiresAt: now + kShareLifetimeSeconds + 300), dana);
      expect(await check(invitation: most), isNull);
    });

    test('both have to be able to open the Crate now, by the record', () async {
      OrchardRecord changed(void Function(OrchardRecord r) f) {
        final r = record();
        f(r);
        return r;
      }

      expect(await check(rec: changed((r) => r.members.remove('uid-dana'))), ShareProblem.senderNoAccess);
      expect(await check(rec: changed((r) => r.members['uid-dana']!.status = MemberStatus.suspended)),
          ShareProblem.senderNoAccess);
      expect(await check(rec: changed((r) => r.members['uid-dana']!.status = MemberStatus.removed)),
          ShareProblem.senderNoAccess);
      expect(await check(rec: changed((r) => r.members['uid-dana']!.role = 'others')), ShareProblem.senderNoAccess);
      expect(await check(rec: changed((r) => r.members['uid-dana']!.endsAt = now)), ShareProblem.senderNoAccess,
          reason: 'their access ended');
      expect(await check(rec: changed((r) => r.members['uid-dana']!.endsAt = now + 1)), isNull);
      expect(await check(rec: changed((r) => r.members['uid-sam']!.role = 'others')), ShareProblem.noAccess);
      expect(await check(rec: changed((r) => r.members['uid-sam']!.status = MemberStatus.suspended)),
          ShareProblem.noAccess);
      expect(await check(rec: changed((r) => r.crates.remove(crateId))), ShareProblem.senderNoAccess);
    });

    test('the keys this device pinned for the sender, unchanged since they were compared', () async {
      expect(await check(noHost: true), ShareProblem.keysChanged, reason: 'no keys pinned');
      expect(await check(host: party('uid-dana', dana, keysChanged: true)), ShareProblem.keysChanged);
      expect(await check(host: party('uid-dana', dana, version: 4)), ShareProblem.keysChanged,
          reason: 'signed with a version this device does not follow');
      expect(await check(host: party('uid-pat', dana)), ShareProblem.keysChanged, reason: 'the keys of someone else');
      expect(await check(host: party('uid-dana', dana, signingKey: eve.signingPublicKey)), ShareProblem.notSigned);
      // Made by someone else in the sender's name.
      final dana2 = await AccountKeys.fromSeeds(
          encryptionSeed: List.filled(32, 8), signingSeed: List.filled(32, 9), version: 3, createdAt: 1);
      final forged = await SignedShareInvitation.sign(live(), dana2);
      expect(await check(invitation: forged), ShareProblem.notSigned);
    });
  });

  group('a join', () {
    late SignedShareInvitation invitation;
    late ShareViewerKeys viewerKeys;
    setUpAll(() async {
      invitation = await SignedShareInvitation.sign(live(), dana);
      viewerKeys = await ShareViewerKeys.generate(hostKeys.offer);
    });

    ShareJoinRequest request({String share = shareId, String viewer = 'uid-sam', int version = 1, Uint8List? digest}) =>
        ShareJoinRequest(
          shareId: share,
          viewerUid: viewer,
          viewerKeyVersion: version,
          invitationDigest: digest ?? invitation.digest,
          join: viewerKeys.join,
        );

    List<int> joinBytes({
      String label = kShareJoinLabel,
      String share = shareId,
      String viewer = 'uid-sam',
      int version = 1,
      List<int>? digest,
      List<int>? x25519,
      List<int>? ciphertext,
      List<int> tail = const [],
    }) =>
        [
          ...text(label),
          ...text(share),
          ...text(viewer),
          ...u32(version),
          ...lp(digest ?? invitation.digest),
          ...lp(x25519 ?? viewerKeys.join.x25519Key),
          ...lp(ciphertext ?? viewerKeys.join.kemCiphertext),
          ...tail,
        ];

    test('the bytes, and reading them back', () {
      expect(request().message(), joinBytes());
      expect(kShareJoinLabel, 'zestssh.share.join.v1');
      final j = ShareJoinRequest.parse(joinBytes());
      expect([j.shareId, j.viewerUid, j.viewerKeyVersion], [shareId, 'uid-sam', 1]);
      expect(j.invitationDigest, invitation.digest);
      expect(j.join.x25519Key, viewerKeys.join.x25519Key);
      expect(j.join.kemCiphertext, viewerKeys.join.kemCiphertext);
    });

    test('anything that is not exactly a join is refused', () {
      void bad(List<int> bytes, String why) =>
          expect(() => ShareJoinRequest.parse(bytes), throwsFormatException, reason: why);
      bad(const [], 'nothing');
      bad(joinBytes(label: kShareInviteLabel), 'an invitation\'s label');
      bad(joinBytes(tail: const [0]), 'a byte too many');
      bad(joinBytes().sublist(0, joinBytes().length - 1), 'a byte short');
      bad(joinBytes(share: 'nope'), 'not a share id');
      bad(joinBytes(viewer: ''), 'nobody');
      bad(joinBytes(viewer: 'x' * 129), 'a uid too long');
      bad(joinBytes(version: 0), 'no key version');
      bad(joinBytes(digest: List.filled(31, 1)), 'a short hash');
      bad(joinBytes(digest: List.filled(33, 1)), 'a long hash');
      bad(joinBytes(x25519: List.filled(31, 1)), 'a short key');
      bad(joinBytes(ciphertext: List.filled(1087, 1)), 'a short ciphertext');
      bad(joinBytes(ciphertext: List.filled(1089, 1)), 'a long ciphertext');
    });

    test('signed by the viewer, and only their key checks it', () async {
      final signed = await SignedShareJoin.sign(request(), sam);
      expect(signed.wire, [...lp(joinBytes()), ...await sam.sign(joinBytes())]);
      expect(await signed.signedBy(sam.signingPublicKey), isTrue);
      expect(await signed.signedBy(dana.signingPublicKey), isFalse);
      final back = SignedShareJoin.decode(signed.wire);
      expect(back.request.message(), joinBytes());
      expect(await back.signedBy(sam.signingPublicKey), isTrue);
      expect(signed.wire.length, lessThan(2048), reason: 'one small message through the relay');
      for (final at in [0, 5, 60, 500, signed.wire.length - 64, signed.wire.length - 1]) {
        final changed = Uint8List.fromList(signed.wire)..[at] ^= 1;
        try {
          expect(await SignedShareJoin.decode(changed).signedBy(sam.signingPublicKey), isFalse, reason: 'byte $at');
        } on FormatException {
          // Refused before the signature is looked at.
        }
      }
      expect(() => SignedShareJoin.decode([...signed.wire, 0]), throwsFormatException);
      await expectLater(SignedShareJoin.sign(request(version: 2), sam), throwsArgumentError);
    });

    group('whether the host lets them in', () {
      Future<ShareProblem?> check({
        ShareJoinRequest? join,
        AccountKeys? signer,
        SignedShareInvitation? made,
        OrchardRecord? rec,
        ShareParty? viewer,
        bool noViewer = false,
        int at = now,
      }) async =>
          shareJoinProblem(
            await SignedShareJoin.sign(join ?? request(), signer ?? sam),
            invitation: made ?? invitation,
            record: rec ?? record(),
            viewer: noViewer ? null : (viewer ?? party('uid-sam', sam)),
            nowSeconds: at,
          );

      test('the person invited, with their pinned keys, answering this invitation: yes', () async {
        expect(await check(), isNull);
      });

      test('it has to answer exactly the invitation made for that person', () async {
        expect(await check(join: request(share: otherId)), ShareProblem.mismatch);
        expect(await check(join: request(viewer: 'uid-pat'), signer: sam), ShareProblem.mismatch);
        expect(await check(join: request(digest: Uint8List(32))), ShareProblem.mismatch);
        final toPat = await SignedShareInvitation.sign(live(to: 'uid-pat'), dana);
        expect(await check(made: toPat), ShareProblem.mismatch, reason: 'the invitation was someone else\'s');
        final another = await SignedShareInvitation.sign(live(keyboard: false), dana);
        expect(await check(made: another), ShareProblem.mismatch, reason: 'another invitation to the same person');
        // The part is in what was signed: answering an invitation to watch
        // does not answer one to end the session, or the other way round.
        final toEnd = await SignedShareInvitation.sign(live(keyboard: false, mayEnd: true), dana);
        expect(await check(made: toEnd), ShareProblem.mismatch, reason: 'the same person in another part');
        expect(toEnd.digest, isNot(another.digest));
      });

      test('not after the invitation ran out, and not once they cannot open the Crate', () async {
        expect(await check(at: now + 3600), ShareProblem.expired);
        OrchardRecord changed(void Function(OrchardRecord r) f) {
          final r = record();
          f(r);
          return r;
        }

        expect(await check(rec: changed((r) => r.members['uid-sam']!.status = MemberStatus.removed)),
            ShareProblem.senderNoAccess);
        expect(await check(rec: changed((r) => r.members['uid-sam']!.role = 'others')), ShareProblem.senderNoAccess);
        expect(await check(rec: changed((r) => r.members['uid-sam']!.endsAt = now - 1)), ShareProblem.senderNoAccess);
      });

      test('their pinned keys, unchanged since compared, are what signed it', () async {
        expect(await check(noViewer: true), ShareProblem.keysChanged);
        expect(await check(viewer: party('uid-sam', sam, keysChanged: true)), ShareProblem.keysChanged);
        expect(await check(viewer: party('uid-sam', sam, version: 2)), ShareProblem.keysChanged);
        expect(await check(viewer: party('uid-dana', sam)), ShareProblem.keysChanged);
        expect(await check(viewer: party('uid-sam', sam, signingKey: eve.signingPublicKey)), ShareProblem.notSigned);
        final sam2 = await AccountKeys.fromSeeds(
            encryptionSeed: List.filled(32, 6), signingSeed: List.filled(32, 7), version: 1, createdAt: 1);
        expect(await check(signer: sam2), ShareProblem.notSigned, reason: 'someone else, in their name');
      });
    });

    test('the two messages make one channel between exactly these two devices', () async {
      final join = await SignedShareJoin.sign(request(), sam);
      final nonce = ShareHostKeys.newNonce();
      final transcript = shareTranscript(invitation.wire, join.wire);
      final host = await hostKeys.accept(viewerKeys.join, shareId: shareId, transcript: transcript, hostNonce: nonce);
      final viewer = await viewerKeys.complete(shareId: shareId, transcript: transcript, hostNonce: nonce);

      final screen = const ShareScreen(columns: 80, rows: 24, text: 'deploy@db-primary:~\$ ').encode();
      final got = ShareMessage.decode(await viewer.open(await host.seal(screen)), fromHost: true) as ShareScreen;
      expect(got.text, 'deploy@db-primary:~\$ ');
      final keys = ShareInput(Uint8List.fromList(utf8.encode('ls\r'))).encode();
      final typed = ShareMessage.decode(await host.open(await viewer.seal(keys)), fromHost: false) as ShareInput;
      expect(utf8.decode(typed.bytes), 'ls\r');

      // A viewer who was shown a different invitation, or whose join was
      // changed on the way, ends up with keys that open nothing.
      final otherInvitation = await SignedShareInvitation.sign(live(keyboard: false), dana);
      final wrong = await viewerKeys.complete(
          shareId: shareId, transcript: shareTranscript(otherInvitation.wire, join.wire), hostNonce: nonce);
      final host2 = await hostKeys.accept(viewerKeys.join, shareId: shareId, transcript: transcript, hostNonce: nonce);
      await expectLater(wrong.open(await host2.seal(screen)), throwsA(isA<ShareChannelBroken>()));
    });
  });
}
