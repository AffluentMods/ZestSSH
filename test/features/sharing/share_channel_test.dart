import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/sharing/share_channel.dart';

/// The secure channel of a live view (session sharing, 3.0): both ends agree
/// on the same keys and nobody else does, a frame opens once, in order and
/// only in its own direction, and anything the relay could do to the stream
/// (change, repeat, drop, reorder, reflect, replay a join) ends the channel
/// instead of being believed.
void main() {
  const share = 'sh_0123456789abcdef';
  final transcript = Uint8List.fromList(List.generate(32, (i) => i));
  final nonce = Uint8List.fromList(List.generate(32, (i) => 200 - i));

  Future<(ShareChannel host, ShareChannel viewer)> pair({
    String shareId = share,
    List<int>? hostTranscript,
    List<int>? viewerTranscript,
    List<int>? hostNonce,
    List<int>? viewerNonce,
    int seed = 7,
  }) async {
    final hostKeys = await ShareHostKeys.generate(random: Random(seed));
    final viewerKeys = await ShareViewerKeys.generate(hostKeys.offer, random: Random(seed + 1));
    final host = await hostKeys.accept(viewerKeys.join,
        shareId: shareId, transcript: hostTranscript ?? transcript, hostNonce: hostNonce ?? nonce);
    final viewer = await viewerKeys.complete(
        shareId: shareId, transcript: viewerTranscript ?? transcript, hostNonce: viewerNonce ?? nonce);
    return (host, viewer);
  }

  Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

  Future<void> expectBroken(Future<Object?> Function() body) =>
      expectLater(body, throwsA(isA<ShareChannelBroken>()));

  test('both ends read what the other writes, in both directions, frame after frame', () async {
    final (host, viewer) = await pair();
    for (var i = 0; i < 50; i++) {
      final down = text('output $i \x1b[32mgreen\x1b[0m');
      expect(await viewer.open(await host.seal(down)), down);
      final up = text('key $i');
      expect(await host.open(await viewer.seal(up)), up);
    }
    expect(host.sent, 50);
    expect(host.received, 50);
    expect(viewer.sent, 50);
    expect(viewer.received, 50);
    // Nothing at all is a frame too (a keep-alive).
    expect(await viewer.open(await host.seal(const [])), isEmpty);
  });

  test('a frame is the counter, the ciphertext and a 16-byte tag, and hides what it carries', () async {
    final (host, _) = await pair();
    final plain = text('top secret output');
    final first = await host.seal(plain);
    final second = await host.seal(plain);
    expect(first.length, 8 + plain.length + 16);
    expect(ByteData.sublistView(first).getUint64(0), 0);
    expect(ByteData.sublistView(second).getUint64(0), 1);
    expect(first.sublist(8), isNot(second.sublist(8)), reason: 'the same text twice is two different frames');
    expect(latin1.decode(first), isNot(contains('top secret')));
  });

  test('the same keys and nonces give the same frames: the construction is pinned', () async {
    // If this changes, two builds of the app can no longer share a session:
    // bump kShareChannelLabel instead of changing the construction in place.
    final (host, viewer) = await pair();
    final down = await host.seal(text('pinned'));
    final up = await viewer.seal(text('pinned'));
    expect(_hex(down), _pinnedDown);
    expect(_hex(up), _pinnedUp);
  });

  test('a frame opens only in its own direction: one sent back to its sender ends the channel', () async {
    final (host, viewer) = await pair();
    final fromHost = await host.seal(text('to the viewer'));
    await expectBroken(() => host.open(fromHost));
    expect(host.isBroken, isTrue);
    // The viewer's end is untouched by what happened on the host's.
    expect(await viewer.open(fromHost), text('to the viewer'));
  });

  test('a frame repeated, skipped or out of order ends the channel', () async {
    for (final attack in ['repeat', 'skip', 'reorder']) {
      final (host, viewer) = await pair();
      final a = await host.seal(text('a'));
      final b = await host.seal(text('b'));
      final c = await host.seal(text('c'));
      switch (attack) {
        case 'repeat':
          expect(await viewer.open(a), text('a'));
          await expectBroken(() => viewer.open(a));
        case 'skip':
          expect(await viewer.open(a), text('a'));
          await expectBroken(() => viewer.open(c));
        case 'reorder':
          await expectBroken(() => viewer.open(b));
      }
      expect(viewer.isBroken, isTrue, reason: attack);
      // Finished for good: even the right frame is refused now, and nothing
      // more can be sent.
      await expectBroken(() => viewer.open(attack == 'reorder' ? a : b));
      await expectBroken(() => viewer.seal(text('x')));
    }
  });

  test('a single changed bit anywhere in a frame ends the channel', () async {
    final (probe, _) = await pair();
    final length = (await probe.seal(text('integrity'))).length;
    for (final position in [0, 7, 8, 12, length - 17, length - 16, length - 1]) {
      final (host, viewer) = await pair();
      final frame = await host.seal(text('integrity'));
      frame[position] ^= 0x01;
      await expectBroken(() => viewer.open(frame));
      expect(viewer.isBroken, isTrue, reason: 'byte $position');
    }
  });

  test('a frame cut short, emptied or padded ends the channel', () async {
    for (final change in ['short', 'empty', 'padded', 'huge']) {
      final (host, viewer) = await pair();
      final frame = await host.seal(text('whole'));
      final List<int> sent = switch (change) {
        'short' => frame.sublist(0, frame.length - 1),
        'empty' => const <int>[],
        'padded' => [...frame, 0],
        _ => List<int>.filled(8 + kShareFramePlainMax + 17, 0),
      };
      await expectBroken(() => viewer.open(sent));
    }
    // One larger than a frame can be is refused for its size, before any
    // work is done to open it; the largest there is, changed, for what it
    // holds.
    Matcher brokenFor(String why) =>
        throwsA(isA<ShareChannelBroken>().having((e) => e.reason, 'reason', contains(why)));
    final (host, viewer) = await pair();
    await expectLater(() => viewer.open(Uint8List(8 + kShareFramePlainMax + 17)), brokenFor('size'));
    final (host2, viewer2) = await pair();
    final most = await host2.seal(Uint8List(kShareFramePlainMax));
    most[most.length - 1] ^= 0x01;
    await expectLater(() => viewer2.open(most), brokenFor('does not open'));
    expect(host.isBroken, isFalse);
  });

  test('a frame carries at most 32 kb', () async {
    final (host, viewer) = await pair();
    final most = Uint8List(kShareFramePlainMax);
    expect((await viewer.open(await host.seal(most))).length, kShareFramePlainMax);
    await expectLater(() => host.seal(Uint8List(kShareFramePlainMax + 1)), throwsArgumentError);
    expect(host.isBroken, isFalse, reason: 'refusing to send is not a broken channel');
  });

  test('the keys belong to one share, one transcript and one acceptance', () async {
    Future<void> apart(Future<(ShareChannel, ShareChannel)> made, String what) async {
      final (host, viewer) = await made;
      await expectBroken(() async => viewer.open(await host.seal(text('x'))));
      expect(viewer.isBroken, isTrue, reason: what);
    }

    final other = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    await apart(pair(viewerTranscript: other), 'another transcript');
    await apart(pair(viewerNonce: other), 'another host nonce');

    // The share is in the key schedule and in what every frame is bound to.
    final hostKeys = await ShareHostKeys.generate(random: Random(3));
    final viewerKeys = await ShareViewerKeys.generate(hostKeys.offer, random: Random(4));
    final host = await hostKeys.accept(viewerKeys.join, shareId: share, transcript: transcript, hostNonce: nonce);
    final viewer =
        await viewerKeys.complete(shareId: 'sh_another_share', transcript: transcript, hostNonce: nonce);
    await expectBroken(() async => viewer.open(await host.seal(text('x'))));
  });

  test('a join replayed to the host makes new keys, never the same ones again', () async {
    final hostKeys = await ShareHostKeys.generate(random: Random(11));
    final viewerKeys = await ShareViewerKeys.generate(hostKeys.offer, random: Random(12));
    final first = await hostKeys.accept(viewerKeys.join,
        shareId: share, transcript: transcript, hostNonce: ShareHostKeys.newNonce(random: Random(1)));
    final replayed = await hostKeys.accept(viewerKeys.join,
        shareId: share, transcript: transcript, hostNonce: ShareHostKeys.newNonce(random: Random(2)));
    final a = await first.seal(text('same text, same counter'));
    final b = await replayed.seal(text('same text, same counter'));
    expect(a.sublist(0, 8), b.sublist(0, 8), reason: 'the same counter');
    expect(a.sublist(8), isNot(b.sublist(8)), reason: 'under different keys');
    expect(ShareHostKeys.newNonce(), isNot(ShareHostKeys.newNonce()));
    expect(ShareHostKeys.newNonce(), hasLength(kShareHostNonceLength));
  });

  test('both halves of the key agreement matter: changing either one changes the keys', () async {
    final hostKeys = await ShareHostKeys.generate(random: Random(21));
    final viewerKeys = await ShareViewerKeys.generate(hostKeys.offer, random: Random(22));
    final viewer = await viewerKeys.complete(shareId: share, transcript: transcript, hostNonce: nonce);
    final good = viewerKeys.join;

    // Another X25519 key in the join (the relay swapping it).
    final stranger = await ShareViewerKeys.generate(hostKeys.offer, random: Random(23));
    final swappedCurve = ShareJoin(x25519Key: stranger.join.x25519Key, kemCiphertext: good.kemCiphertext);
    var host = await hostKeys.accept(swappedCurve, shareId: share, transcript: transcript, hostNonce: nonce);
    await expectBroken(() async => host.open(await viewer.seal(text('x'))));

    // A changed ML-KEM ciphertext: decapsulation gives an unrelated secret,
    // never an error, and nothing opens.
    final changed = Uint8List.fromList(good.kemCiphertext);
    changed[100] ^= 0x40;
    final viewer2 = await viewerKeys.complete(shareId: share, transcript: transcript, hostNonce: nonce);
    host = await hostKeys.accept(ShareJoin(x25519Key: good.x25519Key, kemCiphertext: changed),
        shareId: share, transcript: transcript, hostNonce: nonce);
    await expectBroken(() async => host.open(await viewer2.seal(text('x'))));

    // The honest join still works after those attempts.
    final viewer3 = await viewerKeys.complete(shareId: share, transcript: transcript, hostNonce: nonce);
    host = await hostKeys.accept(good, shareId: share, transcript: transcript, hostNonce: nonce);
    expect(await host.open(await viewer3.seal(text('fine'))), text('fine'));
  });

  test('someone who saw the invitation and the join but holds neither secret cannot read a frame', () async {
    final hostKeys = await ShareHostKeys.generate(random: Random(31));
    final viewerKeys = await ShareViewerKeys.generate(hostKeys.offer, random: Random(32));
    final host = await hostKeys.accept(viewerKeys.join, shareId: share, transcript: transcript, hostNonce: nonce);
    final frame = await host.seal(text('for the viewer only'));

    // The relay knows the offer, the join, the transcript and the nonce. It
    // can run the viewer's side against the offer itself, with its own keys.
    final relay = await ShareViewerKeys.generate(hostKeys.offer, random: Random(33));
    final guess = await relay.complete(shareId: share, transcript: transcript, hostNonce: nonce);
    await expectBroken(() => guess.open(frame));
  });

  test('an offer or a join of the wrong shape is refused before any key is made', () async {
    final hostKeys = await ShareHostKeys.generate(random: Random(41));
    expect(hostKeys.offer.x25519Key, hasLength(kShareX25519Length));
    expect(hostKeys.offer.kemKey, hasLength(kShareKemKeyLength));
    final viewerKeys = await ShareViewerKeys.generate(hostKeys.offer, random: Random(42));
    expect(viewerKeys.join.x25519Key, hasLength(kShareX25519Length));
    expect(viewerKeys.join.kemCiphertext, hasLength(kShareKemCiphertextLength));

    expect(() => ShareOffer(x25519Key: Uint8List(31), kemKey: hostKeys.offer.kemKey), throwsArgumentError);
    expect(() => ShareOffer(x25519Key: hostKeys.offer.x25519Key, kemKey: Uint8List(1183)), throwsArgumentError);
    expect(() => ShareJoin(x25519Key: Uint8List(33), kemCiphertext: viewerKeys.join.kemCiphertext),
        throwsArgumentError);
    expect(() => ShareJoin(x25519Key: viewerKeys.join.x25519Key, kemCiphertext: Uint8List(1087)),
        throwsArgumentError);
    // An ML-KEM key that is not a key (coefficients out of range).
    final badKem = Uint8List.fromList(List.filled(kShareKemKeyLength, 0xff));
    await expectLater(
        () => ShareViewerKeys.generate(ShareOffer(x25519Key: hostKeys.offer.x25519Key, kemKey: badKem)),
        throwsArgumentError);
    await expectLater(
        () => hostKeys.accept(viewerKeys.join, shareId: share, transcript: transcript, hostNonce: Uint8List(8)),
        throwsArgumentError);
  });

  test('an X25519 key that would give an all-zero secret is refused on both sides', () async {
    // The all-zero point: any private key times it is zero, so the channel
    // would rest on ML-KEM alone without anybody knowing.
    final hostKeys = await ShareHostKeys.generate(random: Random(51));
    final zero = Uint8List(32);
    await expectLater(
        () => ShareViewerKeys.generate(ShareOffer(x25519Key: zero, kemKey: hostKeys.offer.kemKey)),
        throwsArgumentError);
    final viewerKeys = await ShareViewerKeys.generate(hostKeys.offer, random: Random(52));
    await expectLater(
        () => hostKeys.accept(ShareJoin(x25519Key: zero, kemCiphertext: viewerKeys.join.kemCiphertext),
            shareId: share, transcript: transcript, hostNonce: nonce),
        throwsArgumentError);
  });

  test('keys made without a seed are different every time', () async {
    final a = await ShareHostKeys.generate();
    final b = await ShareHostKeys.generate();
    expect(a.offer.x25519Key, isNot(b.offer.x25519Key));
    expect(a.offer.kemKey, isNot(b.offer.kemKey));
    final j1 = await ShareViewerKeys.generate(a.offer);
    final j2 = await ShareViewerKeys.generate(a.offer);
    expect(j1.join.x25519Key, isNot(j2.join.x25519Key));
    expect(j1.join.kemCiphertext, isNot(j2.join.kemCiphertext));
  });

  test('the transcript is the hash of both signed messages, each in its place', () {
    final a = shareTranscript(text('invitation'), text('join'));
    expect(a, hasLength(32));
    expect(shareTranscript(text('invitation'), text('join')), a);
    expect(shareTranscript(text('join'), text('invitation')), isNot(a));
    // Moving a byte from one message to the other is a different transcript.
    expect(shareTranscript(text('invitationj'), text('oin')), isNot(a));
    expect(shareTranscript(text('invitation'), text('join2')), isNot(a));
  });
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// Seeds 7 and 8, the share, transcript and nonce above, the text "pinned".
const _pinnedDown = '0000000000000000b2892f4e6cdbf23ca0e5c7118b0fe77294f440eddf09';
const _pinnedUp = '0000000000000000b16245a1c4216f1d5469599f88da508b11b66b42486b';
