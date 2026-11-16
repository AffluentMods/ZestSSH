// A live view, end to end on one machine: the device that shares
// (share_host.dart), the devices that watch (share_viewer.dart) and a relay
// in memory between them that behaves as ZestSSH Cloud's does. What is
// shown is what the terminal shows; only the people invited get in, by
// their pinned keys and the record; the keyboard goes to exactly who the
// person sharing gave it to; and a relay that changes, drops or repeats
// anything, or a viewer that falls behind, costs a moment and nothing else.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'share_fakes.dart';
import 'share_world.dart';

void main() {
  setUpAll(makeWorldKeys);

  group('starting a share', () {
    test('one invitation for each person, sealed to them, signed, and saying what they may do', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-noa']);
      final call = w.api.created.single;
      expect((call.id, call.crateId, call.mode), (shareId, crateId, ShareMode.live));
      expect(call.invites.keys.toSet(), {'uid-sam', 'uid-noa'});

      final forSam = await w.invitationOf('uid-sam', sam);
      final i = forSam.invitation;
      expect([i.shareId, i.orchardId, i.crateId, i.connectionId], [shareId, orchardId, crateId, connectionId]);
      expect([i.fromUid, i.fromKeyVersion, i.toUid, i.mode], ['uid-dana', 2, 'uid-sam', ShareMode.live]);
      expect([i.keyboard, i.remoteUser, i.tmuxSession], [true, 'deploy', '']);
      expect(i.expiresAt, w.clock.millisecondsSinceEpoch ~/ 1000 + kShareLifetimeSeconds);
      expect(
          await shareInvitationProblem(forSam,
              shareId: shareId,
              orchardId: orchardId,
              crateId: crateId,
              fromUid: 'uid-dana',
              mode: ShareMode.live,
              me: 'uid-sam',
              record: w.record,
              host: partyOf('uid-dana', dana),
              nowSeconds: w.clock.millisecondsSinceEpoch ~/ 1000),
          isNull);
      // Someone who can watch only is not told they may ask.
      final forNoa = await w.invitationOf('uid-noa', noa);
      expect(forNoa.invitation.keyboard, isFalse);
      // Each has one-time keys of their own, and cannot open the other's.
      expect(forNoa.invitation.offer!.x25519Key, isNot(i.offer!.x25519Key));
      expect(forNoa.invitation.offer!.kemKey, isNot(i.offer!.kemKey));
      await expectLater(
          SignedShareInvitation.open(call.invites['uid-sam']!, noa.encryption, shareId: shareId), throwsFormatException);

      expect(w.host.guests.map((g) => (g.uid, g.state, g.canType)), [
        ('uid-sam', ShareGuestState.invited, true),
        ('uid-noa', ShareGuestState.invited, false),
      ]);
      await settle();
      expect(w.host.isLineOpen, isTrue);
      expect(w.host.isEnded, isFalse);
    });

    test('when ZestSSH Cloud refuses, nothing is shared', () async {
      final w = World();
      w.api.failNext = StateError('refused');
      await expectLater(w.share(['uid-sam']), throwsStateError);
      expect(w.api.created, isEmpty);
      final v = w.relay.viewer('uid-sam')..start();
      final events = <ShareLineEvent>[];
      v.events.listen(events.add);
      await settle();
      expect((events.single as ShareLineReady).hostOnline, isFalse, reason: 'the line to the relay was never opened');
    });

    test('nobody, the person sharing, someone whose keys changed, or a ninth person is not invited', () async {
      final w = World();
      await expectLater(w.share([]), throwsArgumentError);
      w.pinned['uid-dana'] = partyOf('uid-dana', dana);
      await expectLater(w.share(['uid-dana']), throwsArgumentError);
      w.pinned['uid-sam'] = partyOf('uid-sam', sam, keysChanged: true);
      await expectLater(w.share(['uid-sam']), throwsArgumentError);
      for (var n = 0; n < 9; n++) {
        w.pinned['uid-$n'] = partyOf('uid-$n', kit);
      }
      await expectLater(w.share([for (var n = 0; n < 9; n++) 'uid-$n']), throwsArgumentError);
      expect(w.api.created, isEmpty);
      // A live view needs a terminal to show.
      await expectLater(
          ShareHostController.start(
            shareId: shareId,
            mode: ShareMode.live,
            orchardId: orchardId,
            crateId: crateId,
            connectionId: connectionId,
            people: [partyOf('uid-kit', kit)],
            myUid: 'uid-dana',
            keys: dana,
            api: w.api,
            link: w.relay.host(),
            record: () async => w.record,
            party: (uid) async => null,
          ),
          throwsArgumentError);
    });
  });

  group('watching', () {
    test('a viewer sees the screen as it is, then everything that follows, at the size it has', () async {
      final w = World();
      addTearDown(w.dispose);
      w.terminal.terminal.write('deploy@db-primary:~\$ \x1b[1;32mls\x1b[0m\r\nnotes.txt  \x1b[34msrc\x1b[0m\r\ndeploy@db-primary:~\$ ');
      await w.share(['uid-sam']);
      final v = await w.watch('uid-sam', sam);
      expect(v.phase, isNot(ShareViewPhase.watching));
      await until(() => v.phase == ShareViewPhase.watching, what: 'the screen');
      sameScreen(w.terminal.terminal, v.terminal);
      expect(w.guest('uid-sam').state, ShareGuestState.watching);
      expect(w.notes, [(ShareNote.joined, 'uid-sam')]);
      expect(v.keyboard, ShareKeyboard.host);
      expect(v.isTyping, isFalse);

      w.show('top\r\n');
      w.show('\x1b[?1049h\x1b[H\x1b[2Jtop - 12:00:01 up 3 days\r\n\x1b[7m  PID USER \x1b[0m\r\n');
      await settle();
      sameScreen(w.terminal.terminal, v.terminal);

      // The window is resized: the viewer's terminal follows.
      w.terminal.terminal.resize(100, 30);
      w.host.resized(100, 30);
      w.host.flush();
      w.show('\x1b[5;1H 4821 deploy   20   0  node\r\n');
      await settle();
      sameScreen(w.terminal.terminal, v.terminal);
      expect((v.terminal.viewWidth, v.terminal.viewHeight), (100, 30));
      // A size that is not a terminal's is not passed on.
      w.host.resized(0, 30);
      w.host.resized(5000, 30);
      w.host.flush();
      await settle();
      expect((v.terminal.viewWidth, v.terminal.viewHeight), (100, 30));
    });

    test('what crosses the relay holds neither the screen nor the keys typed, and each viewer has keys of their own', () async {
      final w = World();
      addTearDown(w.dispose);
      w.terminal.terminal.write('export DB_PASSWORD=TOP-SECRET-MARKER\r\n\$ ');
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      w.show('cat notes.txt\r\nANOTHER-MARKER-ON-SCREEN\r\n\$ ');
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
      sameScreen(w.terminal.terminal, k.terminal);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      s.terminal.textInput('TYPED-MARKER');
      await until(() => w.terminal.typed.length == 'TYPED-MARKER'.length);
      expect(utf8.decode(w.terminal.typed), 'TYPED-MARKER');

      expect(w.relay.passed.length, greaterThan(8));
      for (final marker in ['TOP-SECRET-MARKER', 'ANOTHER-MARKER-ON-SCREEN', 'TYPED-MARKER', 'DB_PASSWORD', 'notes.txt']) {
        for (final p in w.relay.passed) {
          expect(bytesContain(p.bytes, utf8.encode(marker)), isFalse, reason: '$marker in what the relay carried');
        }
      }
      // The same output went to both, and never as the same bytes.
      final sLane = w.relay.laneOf('uid-sam')!;
      final kLane = w.relay.laneOf('uid-kit')!;
      List<Uint8List> framesTo(int lane) => [
            for (final p in w.relay.passed)
              if (p.fromHost && p.lane == lane && p.bytes[0] == ShareWire.frame) p.bytes,
          ];
      for (final a in framesTo(sLane)) {
        for (final b in framesTo(kLane)) {
          expect(a, isNot(b));
        }
      }
      // A frame meant for one does not open for the other: delivered to the
      // wrong person, it only breaks their channel.
      final strayForKit = framesTo(sLane).last;
      final joins = w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length;
      var swapped = 0;
      w.relay.tamper = (p) {
        if (p.fromHost && p.lane == kLane && p.bytes[0] == ShareWire.frame && swapped == 0) {
          swapped++;
          return strayForKit;
        }
        return p.bytes;
      };
      w.show('more\r\n');
      await until(() => w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length > joins,
          what: 'kit joining again');
      await until(() => k.phase == ShareViewPhase.watching);
      await settle();
      sameScreen(w.terminal.terminal, k.terminal);
    });

    test('someone who joins later starts from the screen as it is then', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      for (var i = 0; i < 40; i++) {
        w.show('line $i of the build log\r\n');
      }
      await settle();
      final k = await w.watch('uid-kit', kit);
      await until(() => k.phase == ShareViewPhase.watching);
      await settle();
      sameScreen(w.terminal.terminal, k.terminal);
      sameScreen(w.terminal.terminal, s.terminal);
      // What was shown while kit joined was not sent to kit twice.
      w.show('done\r\n\$ ');
      await settle();
      sameScreen(w.terminal.terminal, k.terminal);
      sameScreen(w.terminal.terminal, s.terminal);
      expect(w.terminal.snapshots, 2, reason: 'one screen for each, and no more');
    });

    test('output that arrives together goes out together, and none when nobody watches', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      w.show('nobody is watching this\r\n', gather: true);
      await Future<void>.delayed(ShareHostController.gather * 3);
      expect(w.relay.passed.where((p) => p.fromHost), isEmpty);

      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      await settle();
      final before = w.relay.passed.where((p) => p.fromHost).length;
      for (var i = 0; i < 50; i++) {
        w.show('x', gather: true);
      }
      w.terminal.terminal.resize(70, 20);
      w.host.resized(70, 20);
      expect(w.relay.passed.where((p) => p.fromHost).length, before, reason: 'nothing yet');
      // By itself, a moment later: fifty writes are one frame, then the size.
      await until(() => w.relay.passed.where((p) => p.fromHost).length == before + 2, what: 'the gathered output');
      await settle();
      expect(w.relay.passed.where((p) => p.fromHost).length, before + 2);
      sameScreen(w.terminal.terminal, s.terminal);
    });

    test('a resize and the output around it reach a viewer in the order they happened', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      await settle();
      int sent() => w.relay.passed.where((p) => p.fromHost).length;

      // A full-screen program: the window is resized and it draws itself
      // again for the new size, all within one gathering. What it drew for
      // the new size is taken at the new size, not at the old one.
      var before = sent();
      w.show('\x1b[?1049h\x1b[H\x1b[2Jdrawn for 60 columns\r\n', gather: true);
      w.terminal.terminal.resize(90, 20);
      w.host.resized(90, 20);
      w.show('\x1b[H\x1b[2J${'=' * 90}\x1b[20;70Hrow 20, column 70', gather: true);
      await until(() => sent() == before + 3, what: 'text, the size, text');
      await settle();
      expect(sent(), before + 3);
      expect((s.terminal.viewWidth, s.terminal.viewHeight), (90, 20));
      sameScreen(w.terminal.terminal, s.terminal);

      // Two sizes in a row: only the last is worth sending.
      before = sent();
      w.terminal.terminal.resize(40, 8);
      w.host.resized(40, 8);
      w.terminal.terminal.resize(44, 10);
      w.host.resized(44, 10);
      w.show('\x1b[H\x1b[2J${'#' * 44}\x1b[10;20Hrow 10, col 20', gather: true);
      await until(() => sent() == before + 2, what: 'the size, text');
      await settle();
      expect(sent(), before + 2);
      expect((s.terminal.viewWidth, s.terminal.viewHeight), (44, 10));
      sameScreen(w.terminal.terminal, s.terminal);
    });
  });

  group('the keyboard', () {
    test('nothing a viewer types goes anywhere until the keyboard is theirs', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final v = await w.watch('uid-sam', sam);
      await until(() => v.phase == ShareViewPhase.watching);
      await settle();
      final sent = w.relay.passed.where((p) => !p.fromHost).length;
      v.terminal.textInput('rm -rf /\r');
      v.terminal.keyInput(TerminalKey.enter);
      await settle();
      expect(w.terminal.typed, isEmpty);
      expect(w.relay.passed.where((p) => !p.fromHost).length, sent, reason: 'not even sent');
    });

    test('asking, being told no, asking again, being given it: then their keys are typed, in order', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      w.notes.clear();
      expect(s.mayAsk, isTrue);

      s.askKeyboard();
      expect(s.isAsking, isTrue);
      await until(() => w.guest('uid-sam').asksKeyboard);
      expect(w.notes, [(ShareNote.askedKeyboard, 'uid-sam')]);
      expect(w.guest('uid-sam').state, ShareGuestState.watching, reason: 'asking gives nothing');
      s.askKeyboard();
      await settle();
      expect(w.notes.length, 1, reason: 'asked once');

      w.host.denyKeyboard('uid-sam');
      await until(() => !s.isAsking);
      expect(w.guest('uid-sam').asksKeyboard, isFalse);
      expect(s.isTyping, isFalse);

      s.askKeyboard();
      await until(() => w.guest('uid-sam').asksKeyboard);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      expect(s.keyboard, ShareKeyboard.you);
      expect(s.isAsking, isFalse);
      await until(() => k.keyboard == ShareKeyboard.someoneElse);
      expect(w.host.keyboardHolder, 'uid-sam');
      expect(w.guest('uid-sam').state, ShareGuestState.typing);
      expect(w.guest('uid-sam').asksKeyboard, isFalse);
      expect(w.guest('uid-kit').state, ShareGuestState.watching);
      expect(w.notes.last, (ShareNote.keyboardGiven, 'uid-sam'));

      s.terminal.textInput('ls -la');
      s.terminal.keyInput(TerminalKey.enter);
      s.terminal.textInput('é漢😀');
      await until(() => w.terminal.typed.length >= utf8.encode('ls -la\ré漢😀').length);
      expect(utf8.decode(w.terminal.typed), 'ls -la\ré漢😀');
      // The one who does not have it still types nowhere.
      k.terminal.textInput('whoami\r');
      await settle();
      expect(utf8.decode(w.terminal.typed), 'ls -la\ré漢😀');
    });

    test('one holder at a time; taking it back stops their keys at once', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);
      w.host.giveKeyboard('uid-kit');
      await until(() => k.isTyping && !s.isTyping);
      expect(s.keyboard, ShareKeyboard.someoneElse);
      expect(w.host.keyboardHolder, 'uid-kit');
      expect(w.guest('uid-sam').state, ShareGuestState.watching);

      w.notes.clear();
      w.host.takeBack();
      expect(w.host.keyboardHolder, isNull);
      expect(w.notes, [(ShareNote.keyboardBack, 'uid-kit')]);
      // Kit's device has not heard yet and still sends: it is dropped here.
      k.terminal.textInput('too late');
      await settle();
      expect(w.terminal.typed, isEmpty);
      expect(k.isTyping, isFalse);
      expect(k.keyboard, ShareKeyboard.host);
      expect(s.keyboard, ShareKeyboard.host);
      w.host.takeBack();
      expect(w.notes.length, 1, reason: 'taking back what is not out says nothing');
    });

    test('someone who can watch only is never given it, whatever their device says', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-noa', 'uid-sam']);
      final n = await w.watch('uid-noa', noa);
      await until(() => n.phase == ShareViewPhase.watching);
      expect(n.mayAsk, isFalse);
      n.askKeyboard();
      await settle();
      expect(n.isAsking, isFalse);
      expect(w.guest('uid-noa').asksKeyboard, isFalse);
      expect(w.host.giveKeyboard('uid-noa'), isFalse);
      expect(w.host.keyboardHolder, isNull);
      await n.leave();

      // A device that asks anyway, and types anyway.
      final rogue = Rogue(w, 'uid-noa');
      await rogue.connect();
      final answer = await rogue.join(await w.invitationOf('uid-noa', noa), noa);
      expect(answer[0], ShareWire.accept);
      await rogue.say(const ShareReady());
      await rogue.say(const ShareAskKeyboard());
      expect(w.guest('uid-noa').asksKeyboard, isFalse);
      await rogue.say(ShareInput(Uint8List.fromList(utf8.encode('id\r'))));
      expect(w.terminal.typed, isEmpty);
      expect(w.host.giveKeyboard('uid-noa'), isFalse);
      // Nor does someone not there get it, or someone not invited.
      expect(w.host.giveKeyboard('uid-sam'), isFalse, reason: 'invited, not watching');
      expect(w.host.giveKeyboard('uid-eve'), isFalse);
    });

    test('a viewer without the keyboard cannot type by sending keys anyway', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final k = await w.watch('uid-kit', kit);
      await until(() => k.phase == ShareViewPhase.watching);
      final rogue = Rogue(w, 'uid-sam');
      await rogue.connect();
      expect((await rogue.join(await w.invitationOf('uid-sam', sam), sam))[0], ShareWire.accept);
      await rogue.say(ShareInput(Uint8List.fromList(utf8.encode('before ready\r'))));
      await rogue.say(const ShareReady());
      await rogue.say(ShareInput(Uint8List.fromList(utf8.encode('no keyboard\r'))));
      w.host.giveKeyboard('uid-kit');
      await rogue.say(ShareInput(Uint8List.fromList(utf8.encode('someone else has it\r'))));
      await rogue.say(const ShareGiveBack());
      expect(w.host.keyboardHolder, 'uid-kit', reason: 'only the holder hands it back');
      expect(w.terminal.typed, isEmpty);
      // Given it, the same keys are typed.
      w.host.giveKeyboard('uid-sam');
      await rogue.say(ShareInput(Uint8List.fromList(utf8.encode('now\r'))));
      expect(utf8.decode(w.terminal.typed), 'now\r');
    });

    test('with requests off, asking does nothing; the person sharing can still hand it over', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam'], keyboardRequests: false);
      expect(w.host.keyboardRequests, isFalse);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      expect(s.mayAsk, isFalse);
      s.askKeyboard();
      await settle();
      expect(w.guest('uid-sam').asksKeyboard, isFalse);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      s.terminal.textInput('ok');
      await until(() => w.terminal.typed.length == 2);
    });

    test('the keyboard comes back when its holder hands it back, leaves or drops', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      var s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);

      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);
      s.giveBack();
      expect(s.isTyping, isFalse, reason: 'at once on their side');
      await until(() => w.host.keyboardHolder == null);
      expect(w.notes.last, (ShareNote.keyboardBack, 'uid-sam'));

      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);
      w.relay.dropViewerLine('uid-sam');
      await until(() => w.host.keyboardHolder == null);
      await until(() => s.phase == ShareViewPhase.watching, what: 'sam back after the drop');
      expect(s.isTyping, isFalse, reason: 'it has to be given again');
      s.terminal.textInput('nope');
      await settle();
      expect(w.terminal.typed, isEmpty);

      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);
      await s.leave();
      await until(() => w.host.keyboardHolder == null);
      expect(s.end, ShareViewEnd.left);
      await until(() => w.guest('uid-sam').state == ShareGuestState.invited);
      expect(w.notes.where((n) => n.$1 == ShareNote.left), isNotEmpty);
    });

    test('a large paste arrives whole and in order', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);
      final paste = [for (var i = 0; i < 3000; i++) 'line $i é\n'].join();
      s.terminal.textInput(paste);
      final want = utf8.encode(paste);
      await until(() => w.terminal.typed.length >= want.length, what: 'the paste');
      expect(w.terminal.typed, want);
      // No message carried more than the limit.
      final sLane = w.relay.laneOf('uid-sam')!;
      for (final p in w.relay.passed.where((p) => !p.fromHost && p.lane == sLane)) {
        expect(p.bytes.length, lessThanOrEqualTo(1 + 8 + 1 + kShareInputMax + 16));
      }
    });
  });

  group('who is let in', () {
    test('only the person invited, by the keys pinned for them, while they can open the Crate', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final forSam = await w.invitationOf('uid-sam', sam);
      final refusal = [ShareWire.refuse, ShareRefusal.notTrusted.index];
      final notAccepted = [ShareWire.refuse, ShareRefusal.notAccepted.index];

      final rogue = Rogue(w, 'uid-sam');
      await rogue.connect();
      // Signed by someone else, in sam's name.
      expect(await rogue.join(forSam, eve), refusal);
      // Naming someone else, or another share, or another invitation.
      expect(await rogue.join(forSam, sam, viewerUid: 'uid-kit'), notAccepted);
      expect(await rogue.join(forSam, sam, share: '99999999-9999-4999-8999-999999999999'), notAccepted);
      expect(await rogue.join(forSam, sam, digest: Uint8List(32)), notAccepted);
      // Not a join at all.
      expect(await rogue.join(forSam, sam, rawWire: Uint8List.fromList(List.filled(200, 7))), notAccepted);
      // A key no honest device sends (the all-zero point).
      final zero = ShareJoin(
          x25519Key: Uint8List(32), kemCiphertext: (await ShareViewerKeys.generate(forSam.invitation.offer!)).join.kemCiphertext);
      expect(await rogue.join(forSam, sam, keys: zero), notAccepted);
      expect(w.guest('uid-sam').state, ShareGuestState.connected, reason: 'none of them got in');

      // Their keys changed since dana compared them.
      w.pinned['uid-sam'] = partyOf('uid-sam', sam, keysChanged: true);
      expect(await rogue.join(forSam, sam), refusal);
      // No keys pinned for them at all.
      w.pinned.remove('uid-sam');
      expect(await rogue.join(forSam, sam), refusal);
      w.pinned['uid-sam'] = partyOf('uid-sam', sam);
      // Removed from the Crate since they were invited.
      w.record = teamRecord(orchardId, crateId, {'uid-dana': dana, 'uid-kit': kit});
      expect(await rogue.join(forSam, sam), refusal);
      w.record = teamRecord(orchardId, crateId, {'uid-dana': dana, 'uid-sam': sam, 'uid-kit': kit});
      // The invitation ran out.
      final later = w.clock;
      w.clock = w.clock.add(const Duration(hours: 13));
      expect(await rogue.join(forSam, sam), notAccepted);
      w.clock = later;

      // The honest join is accepted, once: the same bytes again are not.
      expect((await rogue.join(forSam, sam))[0], ShareWire.accept);
      final accepted = w.relay.passed.lastWhere((p) => !p.fromHost && p.bytes[0] == ShareWire.join).bytes;
      final before = rogue.heard.length;
      rogue.link.send(accepted);
      await until(() => rogue.heard.length > before);
      expect(rogue.heard.last, notAccepted, reason: 'a repeat');

      // Someone else's invitation does not get kit's place for sam.
      final other = Rogue(w, 'uid-kit');
      await other.connect();
      expect(await other.join(forSam, sam, viewerUid: 'uid-sam'), notAccepted,
          reason: 'on kit\'s lane, sam\'s join answers the wrong invitation');
      expect(w.terminal.typed, isEmpty);
    });

    test('a record this device cannot read lets nobody in', () async {
      final w = World();
      addTearDown(w.dispose);
      late ShareHostController host;
      host = await ShareHostController.start(
        shareId: shareId,
        mode: ShareMode.live,
        orchardId: orchardId,
        crateId: crateId,
        connectionId: connectionId,
        people: [w.pinned['uid-sam']!],
        myUid: 'uid-dana',
        keys: dana,
        api: w.api,
        link: w.relay.host(),
        record: () async => null,
        party: (uid) async => w.pinned[uid],
        terminal: w.terminal,
      );
      w.host = host;
      final rogue = Rogue(w, 'uid-sam');
      await rogue.connect();
      expect(await rogue.join(await w.invitationOf('uid-sam', sam), sam),
          [ShareWire.refuse, ShareRefusal.notTrusted.index]);
    });

    test('a viewer the host does not trust is told so and does not keep trying', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      w.pinned['uid-sam'] = partyOf('uid-sam', sam, keysChanged: true);
      final v = await w.watch('uid-sam', sam);
      await until(() => v.phase == ShareViewPhase.ended);
      expect(v.end, ShareViewEnd.refused);
      expect(w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length, 1);
    });
  });

  group('a relay that does not play by the rules', () {
    for (final (name, tamper) in <(String, Object? Function(Passing, int))>[
      ('changes a frame on its way to a viewer', (p, n) => p.fromHost && n == 0 ? (Uint8List.fromList(p.bytes)..[20] ^= 1) : p.bytes),
      ('drops a frame on its way to a viewer', (p, n) => p.fromHost && n == 0 ? null : p.bytes),
      ('sends a frame to a viewer twice', (p, n) => p.fromHost && n == 0 ? [p.bytes, p.bytes] : p.bytes),
      ('changes a frame on its way to the host', (p, n) => !p.fromHost && n == 0 ? (Uint8List.fromList(p.bytes)..[12] ^= 1) : p.bytes),
      ('sends a frame to the host twice', (p, n) => !p.fromHost && n == 0 ? [p.bytes, p.bytes] : p.bytes),
    ]) {
      test('$name: the view breaks for a moment and comes back true', () async {
        final w = World();
        addTearDown(w.dispose);
        await w.share(['uid-sam']);
        final v = await w.watch('uid-sam', sam);
        await until(() => v.phase == ShareViewPhase.watching);
        w.host.giveKeyboard('uid-sam');
        await until(() => v.isTyping);
        await settle();
        final joinsBefore = w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length;

        var hit = 0;
        var touched = 0;
        w.relay.tamper = (p) {
          if (p.bytes[0] != ShareWire.frame) return p.bytes;
          final wanted = name.contains('to the host') ? !p.fromHost : p.fromHost;
          if (!wanted) return p.bytes;
          final out = tamper(p, hit);
          hit++;
          if (hit == 1) touched++;
          return out;
        };
        w.show('one\r\n');
        v.terminal.textInput('a');
        w.show('two\r\n');
        await until(() => touched == 1, what: 'the frame to be tampered with');
        await until(
            () => w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length > joinsBefore,
            what: 'a new join');
        w.relay.tamper = null;
        await until(() => v.phase == ShareViewPhase.watching, what: 'watching again');
        w.show('three\r\n\$ ');
        await settle();
        sameScreen(w.terminal.terminal, v.terminal);
        // The keyboard did not survive the break: it is given again or not at all.
        expect(w.host.keyboardHolder, isNull);
        expect(v.isTyping, isFalse);
      });
    }

    test('changes the answer to a join: keys that do not match open nothing, and the next join works', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      // The answer's nonce is changed on the way back, the first time.
      var changed = 0;
      w.relay.tamper = (p) {
        if (p.fromHost && p.bytes[0] == ShareWire.accept && changed == 0) {
          changed++;
          return Uint8List.fromList(p.bytes)..[5] ^= 1;
        }
        return p.bytes;
      };
      final v = await w.watch('uid-sam', sam);
      await until(() => v.phase == ShareViewPhase.watching, what: 'the second join');
      expect(changed, 1);
      expect(w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length, 2,
          reason: 'the first channel opened nothing; the viewer joined again');
      await settle();
      sameScreen(w.terminal.terminal, v.terminal);
    });

    test('keeps changing every answer: the viewer gives up after a few tries, having seen nothing', () async {
      final w = World();
      addTearDown(w.dispose);
      w.terminal.terminal.write('SECRET ON SCREEN\r\n');
      await w.share(['uid-sam']);
      w.relay.tamper =
          (p) => p.fromHost && p.bytes[0] == ShareWire.accept ? (Uint8List.fromList(p.bytes)..[5] ^= 1) : p.bytes;
      final v = await w.watch('uid-sam', sam);
      await until(() => v.phase == ShareViewPhase.ended, turns: 8000);
      expect(v.end, ShareViewEnd.failed);
      expect(v.terminal.buffer.lines[0].toString().trim(), isEmpty);
      expect(w.guest('uid-sam').state, isNot(ShareGuestState.watching));
      expect(w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length,
          ShareViewerController.maxAttempts);
    });

    test('an answer to another join is not taken for this one', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      // The relay answers the join itself, with an answer the host gave
      // someone else's join earlier (here: made up, naming another join).
      w.relay.tamper = (p) {
        if (p.fromHost && p.bytes[0] == ShareWire.accept) {
          final other = Uint8List.fromList(p.bytes);
          for (var i = 33; i < other.length; i++) {
            other[i] ^= 0xff;
          }
          return [other, p.bytes];
        }
        return p.bytes;
      };
      final v = await w.watch('uid-sam', sam);
      await until(() => v.phase == ShareViewPhase.watching);
      expect(w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length, 1,
          reason: 'the stray answer was ignored, the real one taken');
    });

    test('loses a frame on its way to the host: found out by the next one, at the latest a heartbeat later', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final v = await w.watch('uid-sam', sam, heartbeat: const Duration(milliseconds: 40));
      await until(() => v.phase == ShareViewPhase.watching);
      await settle();
      final joins = w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length;
      var lost = 0;
      w.relay.tamper = (p) {
        if (!p.fromHost && p.bytes[0] == ShareWire.frame && lost == 0) {
          lost++;
          return null;
        }
        return p.bytes;
      };
      // Nothing is shown and nothing typed: only the heartbeat speaks.
      await until(() => w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length > joins,
          what: 'the viewer joining again');
      await until(() => v.phase == ShareViewPhase.watching);
      expect(lost, 1);
      sameScreen(w.terminal.terminal, v.terminal);
    });

    test('loses a frame on its way to a viewer while nothing is shown: found out a heartbeat or two later', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final v = await w.watch('uid-sam', sam, heartbeat: const Duration(milliseconds: 40));
      await until(() => v.phase == ShareViewPhase.watching);
      await settle();
      final joins = w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length;
      // The word that the keyboard is theirs never arrives.
      var lost = 0;
      w.relay.tamper = (p) {
        if (p.fromHost && p.bytes[0] == ShareWire.frame && lost == 0) {
          lost++;
          return null;
        }
        return p.bytes;
      };
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await settle();
      expect(v.isTyping, isFalse);
      await until(() => w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length > joins,
          what: 'the viewer joining again');
      await until(() => v.phase == ShareViewPhase.watching);
      // The channel is new: the keyboard is with the host until given again.
      expect(w.host.keyboardHolder, isNull);
      expect(v.isTyping, isFalse);
      sameScreen(w.terminal.terminal, v.terminal);
    });

    test('a join changed on the way is refused, and an answer to another join is not taken', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      var changed = 0;
      w.relay.tamper = (p) {
        if (!p.fromHost && p.bytes[0] == ShareWire.join && changed == 0) {
          changed++;
          return Uint8List.fromList(p.bytes)..[40] ^= 1;
        }
        return p.bytes;
      };
      final v = await w.watch('uid-sam', sam);
      await until(() => v.phase == ShareViewPhase.ended);
      expect(v.end, ShareViewEnd.refused, reason: 'the host saw a join nobody signed');
    });
  });

  group('falling behind', () {
    test('a viewer that takes nothing is sent a window and no more; caught up, it gets the screen afresh', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      await settle();
      final sLane = w.relay.laneOf('uid-sam')!;
      int bytesToSam() =>
          w.relay.passed.where((p) => p.fromHost && p.lane == sLane).fold(0, (n, p) => n + p.bytes.length);

      // Sam's phone is on a slow line: what is sent to it does not arrive
      // for now. Output comes steadily, well within the rate.
      w.relay.holdWhere = (p) => p.fromHost && p.lane == sLane;
      final before = bytesToSam();
      final step = '${'#' * 8000}\r\n';
      for (var i = 0; i < 400; i++) {
        w.clock = w.clock.add(const Duration(seconds: 1));
        w.show('step $i $step');
        await settle(3);
      }
      await settle();
      final sent = bytesToSam() - before;
      expect(sent, lessThanOrEqualTo(ShareHostController.windowBytes + 64 * 1024),
          reason: 'a window goes to someone who takes nothing, and no more');
      expect(sent, greaterThan(ShareHostController.windowBytes ~/ 2));
      // Kit, who keeps up, got all of it.
      sameScreen(w.terminal.terminal, k.terminal);

      // The line recovers: what was held arrives, sam takes it, and the
      // screen as it is now follows, not the steps that were skipped.
      final snapshots = w.terminal.snapshots;
      w.relay.release();
      await until(() => w.terminal.snapshots > snapshots, what: 'a fresh screen for sam', turns: 8000);
      w.show('done\r\n\$ ');
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
      sameScreen(w.terminal.terminal, k.terminal);
    });

    test('many small frames are not "behind": a slow link is not a reason to start over', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      await settle();
      // Three hundred lines, each its own frame, before a single ack is back.
      for (var i = 0; i < 300; i++) {
        w.show('line $i\r\n');
      }
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
      expect(w.terminal.snapshots, 1, reason: 'no second screen was needed');
    });

    test('a flood is not sent faster than its rate: the viewer gets where it ended, not a backlog', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      await settle();
      final sLane = w.relay.laneOf('uid-sam')!;
      int bytesToSam() =>
          w.relay.passed.where((p) => p.fromHost && p.lane == sLane).fold(0, (n, p) => n + p.bytes.length);
      final before = bytesToSam();

      // Four megabytes at once, with the clock standing still.
      final chunk = '${'x' * 1022}\r\n';
      for (var i = 0; i < 4096; i++) {
        w.show(chunk, gather: i % 64 != 0);
        if (i % 64 == 0) await settle(4);
      }
      w.host.flush();
      await settle();
      expect(bytesToSam() - before, lessThan(ShareHostController.outputBurst + 64 * 1024),
          reason: 'what was saved up, and no more');

      // Time passes: the screen as it is now goes, and it is the true one.
      w.show('END OF FLOOD\r\n\$ ');
      w.clock = w.clock.add(const Duration(seconds: 10));
      await until(() => w.terminal.snapshots >= 2, what: 'the screen afresh', turns: 6000);
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
    });
  });

  group('the line', () {
    test('the host\'s line drops and comes back: everyone watches again, the keyboard is back with the host', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);
      w.show('before the drop\r\n');
      await settle();

      w.relay.dropHostLine();
      await until(() => w.host.keyboardHolder == null);
      w.show('shown while the line was down\r\n');
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching,
          what: 'both watching again');
      await until(() => w.host.guests.every((g) => g.state == ShareGuestState.watching));
      expect(w.host.isLineOpen, isTrue);
      w.show('after\r\n\$ ');
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
      sameScreen(w.terminal.terminal, k.terminal);
      expect(s.isTyping, isFalse);
      s.terminal.textInput('x');
      await settle();
      expect(w.terminal.typed, isEmpty);
    });

    test('while the host is away, viewers wait; when it never comes back, the share ends for them', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      w.relay.dropHostLine(comeBack: false);
      await until(() => s.phase == ShareViewPhase.waitingForHost);
      expect(w.host.isLineOpen, isFalse);
      expect(w.guest('uid-sam').state, ShareGuestState.invited);
      w.relay.end();
      await until(() => s.phase == ShareViewPhase.ended);
      expect(s.end, ShareViewEnd.ended);
    });

    test('a viewer whose line drops comes back on a new lane and sees the true screen', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      final lane = w.relay.laneOf('uid-sam');
      w.notes.clear();
      w.relay.dropViewerLine('uid-sam');
      w.show('shown during the drop\r\n');
      await until(() => s.phase == ShareViewPhase.watching && w.guest('uid-sam').state == ShareGuestState.watching);
      expect(w.relay.laneOf('uid-sam'), isNot(lane));
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
      expect(w.notes.map((n) => n.$1), [ShareNote.left, ShareNote.joined]);
    });

    test('however the relay ends a viewer\'s line, the viewer says why', () async {
      for (final (why, end) in [
        (ShareLineEnd.ended, ShareViewEnd.ended),
        (ShareLineEnd.notFound, ShareViewEnd.notFound),
        (ShareLineEnd.signedOut, ShareViewEnd.signedOut),
        (ShareLineEnd.replaced, ShareViewEnd.elsewhere),
        (ShareLineEnd.full, ShareViewEnd.full),
        (ShareLineEnd.refused, ShareViewEnd.refused),
      ]) {
        final w = World();
        await w.share(['uid-sam']);
        final s = await w.watch('uid-sam', sam);
        await until(() => s.phase == ShareViewPhase.watching);
        w.relay.kick('uid-sam', why);
        await until(() => s.phase == ShareViewPhase.ended);
        expect(s.end, end, reason: '$why');
        expect(s.isTyping, isFalse);
        await until(() => w.guest('uid-sam').state == ShareGuestState.invited);
        await w.dispose();
      }
    });

    test('when the share ends at the server, the person sharing is told, and nothing more is sent', () async {
      final w = World();
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      w.host.giveKeyboard('uid-sam');
      w.notes.clear();
      w.relay.end(ShareLineEnd.notFound);
      await until(() => w.host.isEnded);
      expect(w.host.endedBy, ShareLineEnd.notFound);
      expect(w.host.keyboardHolder, isNull);
      expect(w.host.isLineOpen, isFalse);
      expect(w.notes.last, (ShareNote.endedElsewhere, null));
      final passed = w.relay.passed.length;
      w.show('after the end\r\n');
      w.host.flush();
      await settle();
      expect(w.relay.passed.length, passed);
      expect(w.host.giveKeyboard('uid-sam'), isFalse);
      w.host.dispose();
      s.dispose();
    });
  });

  group('stopping', () {
    for (final reason in [ShareEndReason.stopped, ShareEndReason.sessionClosed]) {
      test('stop (${reason.name}): everyone watching is told why, the share ends at the server, the line closes', () async {
        final w = World();
        await w.share(['uid-sam', 'uid-kit']);
        final s = await w.watch('uid-sam', sam);
        final k = await w.watch('uid-kit', kit);
        await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
        w.host.giveKeyboard('uid-sam');
        await until(() => s.isTyping);
        w.show('the last thing shown\r\n');

        await w.host.stop(reason);
        expect(w.host.isEnded, isTrue);
        expect(w.host.endedBy, isNull, reason: 'ended here, not from the other side');
        expect(w.host.keyboardHolder, isNull);
        expect(w.api.ended, [shareId]);
        await until(() => s.phase == ShareViewPhase.ended && k.phase == ShareViewPhase.ended);
        final want = reason == ShareEndReason.stopped ? ShareViewEnd.stopped : ShareViewEnd.sessionClosed;
        expect([s.end, k.end], [want, want]);
        // They saw everything up to the end.
        sameScreen(w.terminal.terminal, s.terminal);
        expect(w.notes.last, (ShareNote.stopped, null));

        // Nothing after: no output, no keys, and stopping twice is once.
        final passed = w.relay.passed.length;
        w.show('after\r\n');
        w.host.flush();
        s.terminal.textInput('x');
        await settle();
        expect(w.relay.passed.length, passed);
        expect(w.terminal.typed, isEmpty);
        await w.host.stop();
        expect(w.api.ended, [shareId]);
        w.host.dispose();
        s.dispose();
        k.dispose();
      });
    }

    test('stopping still closes the line when the server cannot be reached', () async {
      final w = World();
      await w.share(['uid-sam']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      w.api.failNext = StateError('offline');
      await w.host.stop();
      expect(w.host.isEnded, isTrue);
      await until(() => s.phase == ShareViewPhase.ended);
      expect(s.end, ShareViewEnd.stopped);
      final again = w.relay.viewer('uid-kit')..start();
      final events = <ShareLineEvent>[];
      again.events.listen(events.add);
      await settle();
      expect((events.single as ShareLineReady).hostOnline, isFalse, reason: 'the host left the relay');
      w.host.dispose();
      s.dispose();
    });

    test('taking one person\'s invitation back: they are told, dropped, and gone from the list', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);

      await w.host.remove('uid-sam');
      expect(w.api.removed, [(shareId, 'uid-sam')]);
      expect(w.host.guests.map((g) => g.uid), ['uid-kit']);
      expect(w.host.keyboardHolder, isNull);
      await until(() => s.phase == ShareViewPhase.ended);
      expect(s.end, ShareViewEnd.removed);
      // What their device still sends reaches nothing.
      final rogue = Rogue(w, 'uid-sam');
      await rogue.connect();
      rogue.link.send(Uint8List.fromList([ShareWire.join, 1, 2, 3]));
      await settle();
      expect(rogue.heard, isEmpty, reason: 'not even an answer');
      // Kit is untouched.
      w.show('still here\r\n');
      await settle();
      sameScreen(w.terminal.terminal, k.terminal);
      await w.host.remove('uid-nobody');
      expect(w.api.removed.length, 1);
    });

    test('the server is asked to cut someone off only once their device has read why', () async {
      final w = World();
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);

      // Asked earlier, the server could cut the line before the last word
      // got through, and they would see the view end without a reason.
      final asked = <String, List<Object?>>{};
      w.api.onCall = (call) => asked[call] = [s.end, w.relay.laneOf('uid-sam'), k.end, w.relay.laneOf('uid-kit')];
      final clock = Stopwatch()..start();
      await w.host.remove('uid-sam');
      expect(asked['removeInvite']!.sublist(0, 2), [ShareViewEnd.removed, null],
          reason: 'sam was told and had gone from the relay when the server was asked');
      expect(asked['removeInvite']!.sublist(2), [null, isNotNull], reason: 'kit goes on watching');

      w.show('the last thing shown\r\n');
      await w.host.stop();
      expect(asked['end']!.sublist(2), [ShareViewEnd.stopped, null]);
      expect(clock.elapsed, lessThan(ShareHostController.goodbyeWait), reason: 'nobody was waited for');
      sameScreen(w.terminal.terminal, k.terminal);
      w.host.dispose();
      s.dispose();
      k.dispose();
    });

    test('a device that does not go is waited for a second, not longer, and one already gone not at all', () async {
      final w = World();
      await w.share(['uid-sam', 'uid-kit', 'uid-noa']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      final n = await w.watch('uid-noa', noa);
      await until(() => [s, k, n].every((v) => v.phase == ShareViewPhase.watching));

      // sam's device reads nothing more (a phone in a tunnel).
      final sLane = w.relay.laneOf('uid-sam');
      w.relay.holdWhere = (p) => p.fromHost && p.lane == sLane;
      var clock = Stopwatch()..start();
      await w.host.remove('uid-sam');
      expect(clock.elapsed, greaterThanOrEqualTo(ShareHostController.goodbyeWait));
      expect(clock.elapsed, lessThan(ShareHostController.goodbyeWait * 2));
      expect(w.api.removed, [(shareId, 'uid-sam')]);
      expect(w.host.guests.map((g) => g.uid), ['uid-kit', 'uid-noa']);
      expect(s.phase, ShareViewPhase.watching, reason: 'it has read nothing; the server cuts it off');

      // kit's device reads nothing either, and then the host's own line
      // drops: there is nobody left to wait for.
      final kLane = w.relay.laneOf('uid-kit');
      w.relay.holdWhere = (p) => p.fromHost && (p.lane == sLane || p.lane == kLane);
      clock = Stopwatch()..start();
      final removing = w.host.remove('uid-kit');
      await settle();
      expect(w.api.removed.length, 1, reason: 'still waiting for kit\'s device');
      // (From here on nothing gets through, so nobody joins again.)
      w.relay.tamper = (p) => null;
      w.relay.dropHostLine();
      await removing;
      expect(clock.elapsed, lessThan(ShareHostController.goodbyeWait));
      expect(w.api.removed.last, (shareId, 'uid-kit'));

      // noa's device is connected, with no channel: there is nothing to
      // tell it and nothing to wait for.
      await until(() => w.guest('uid-noa').state == ShareGuestState.connected);
      clock = Stopwatch()..start();
      await w.host.stop();
      expect(clock.elapsed, lessThan(ShareHostController.goodbyeWait));
      expect(w.api.ended, [shareId]);
      w.host.dispose();
      for (final v in [s, k, n]) {
        v.dispose();
      }
    });

    test('someone told to go is sent nothing after the last word, and nothing of theirs is taken', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);

      // sam's device is slow to read that it was removed; meanwhile the
      // session goes on, and sam still types.
      final sLane = w.relay.laneOf('uid-sam')!;
      w.relay.holdWhere = (p) => p.fromHost && p.lane == sLane;
      final removing = w.host.remove('uid-sam');
      await settle();
      final toSam = w.relay.passed.where((p) => p.fromHost && p.lane == sLane).length;
      w.show('after sam was removed\r\n');
      s.terminal.textInput('typed after being removed');
      await settle();
      expect(w.relay.passed.where((p) => p.fromHost && p.lane == sLane).length, toSam,
          reason: 'nothing more for sam');
      expect(w.terminal.typed, isEmpty);
      sameScreen(w.terminal.terminal, k.terminal);
      w.relay.release();
      await removing;
      await until(() => s.phase == ShareViewPhase.ended);
      expect(s.end, ShareViewEnd.removed);
    });

    test('inviting someone else later: they get an invitation of their own and can join', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      await w.host.invite([w.pinned['uid-kit']!, w.pinned['uid-noa']!], watchOnly: {'uid-noa'});
      expect(w.api.invited.single.id, shareId);
      expect(w.api.invited.single.invites.keys.toSet(), {'uid-kit', 'uid-noa'});
      expect(w.host.guests.map((g) => (g.uid, g.canType)), [('uid-sam', true), ('uid-kit', true), ('uid-noa', false)]);
      final k = await w.watch('uid-kit', kit);
      await until(() => k.phase == ShareViewPhase.watching);
      sameScreen(w.terminal.terminal, k.terminal);
      // Refused by the server: nobody is added.
      w.api.failNext = StateError('share-full');
      w.pinned['uid-eve'] = partyOf('uid-eve', eve);
      await expectLater(w.host.invite([w.pinned['uid-eve']!]), throwsStateError);
      expect(w.host.guests.length, 3);
    });

    test('someone already invited keeps the invitation they have; someone who said no is asked again', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      w.host.giveKeyboard('uid-sam');
      await until(() => s.isTyping);

      // sam again, while he watches: no new invitation, and his view (made
      // with the one he has) goes on, keyboard and all.
      await w.host.invite([w.pinned['uid-sam']!]);
      expect(w.api.invited, isEmpty);
      expect(w.guest('uid-sam').state, ShareGuestState.typing);
      w.show('still here\r\n');
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);

      // kit said no, and is asked again together with sam: only kit gets an
      // invitation, a new one, and keeps the place on the list.
      w.relay.declined('uid-kit');
      await until(() => w.guest('uid-kit').state == ShareGuestState.declined);
      final first = await w.invitationOf('uid-kit', kit);
      await w.host.invite([w.pinned['uid-sam']!, w.pinned['uid-kit']!]);
      expect(w.api.invited.single.invites.keys, ['uid-kit']);
      expect(w.guest('uid-kit').state, ShareGuestState.invited);
      expect(w.host.guests.map((g) => g.uid), ['uid-sam', 'uid-kit']);
      final second = await w.invitationOf('uid-kit', kit);
      expect(second.digest, isNot(first.digest));
      final k = await w.watch('uid-kit', kit);
      await until(() => k.phase == ShareViewPhase.watching);
      sameScreen(w.terminal.terminal, k.terminal);
      expect(w.guest('uid-sam').state, ShareGuestState.typing);
    });

    test('someone who declines is shown as having declined', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      await settle();
      w.relay.declined('uid-kit');
      await until(() => w.guest('uid-kit').state == ShareGuestState.declined);
      expect(w.notes, [(ShareNote.declined, 'uid-kit')]);
      expect(w.guest('uid-sam').state, ShareGuestState.invited);
      w.relay.declined('uid-nobody');
      await settle();
      expect(w.notes.length, 1);
    });
  });

  group('a shared tmux session', () {
    test('the invitation names the session and carries no keys; the relay only says who is attached', () async {
      final w = World(mode: ShareMode.tmux);
      await w.share(['uid-sam', 'uid-kit']);
      expect(w.api.created.single.mode, ShareMode.tmux);
      final i = (await w.invitationOf('uid-sam', sam)).invitation;
      expect([i.mode, i.tmuxSession, i.remoteUser, i.keyboard, i.offer], [ShareMode.tmux, 'shared-k7q', 'deploy', false, null]);
      expect(w.host.keyboardRequests, isFalse);
      expect(w.host.guests.every((g) => !g.canType), isTrue);

      final s = w.relay.viewer('uid-sam')..start();
      await until(() => w.guest('uid-sam').state == ShareGuestState.connected);
      expect(w.notes, [(ShareNote.joined, 'uid-sam')]);
      expect(w.host.giveKeyboard('uid-sam'), isFalse, reason: 'there is no keyboard to hand over in tmux');
      // Output is not sent anywhere.
      w.host.output('nothing of the terminal goes through here');
      w.host.resized(80, 24);
      w.host.flush();
      await settle();
      expect(w.relay.passed, isEmpty);

      await s.close();
      await until(() => w.guest('uid-sam').state == ShareGuestState.invited);
      expect(w.notes.last, (ShareNote.left, 'uid-sam'));
      await w.host.stop();
      expect(w.api.ended, [shareId]);
      w.host.dispose();
    });
  });

  group('the viewer', () {
    test('only an invitation to a live view makes one', () async {
      final w = World(mode: ShareMode.tmux);
      await w.share(['uid-sam']);
      final invitation = await w.invitationOf('uid-sam', sam);
      expect(() => ShareViewerController(invitation: invitation, keys: sam, link: w.relay.viewer('uid-sam')),
          throwsArgumentError);
      await w.host.stop();
      w.host.dispose();
    });

    test('a host that never answers the join is tried a few times, then the view fails', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      w.relay.tamper = (p) => !p.fromHost ? null : p.bytes;
      final v = await w.watch('uid-sam', sam, joinTimeout: const Duration(milliseconds: 20));
      await until(() => v.phase == ShareViewPhase.ended, turns: 8000);
      expect(v.end, ShareViewEnd.failed);
      expect(w.relay.passed.where((p) => !p.fromHost && p.bytes[0] == ShareWire.join).length,
          ShareViewerController.maxAttempts);
    });

    test('keys this device does not hold for the invitation are refused before anything is sent', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final invitation = await w.invitationOf('uid-sam', sam);
      // Sam's device somehow runs with another version of the keys.
      final other = await AccountKeys.generate(version: 5);
      final v = ShareViewerController(invitation: invitation, keys: other, link: w.relay.viewer('uid-sam'));
      w.viewers.add(v);
      v.start();
      await until(() => v.phase == ShareViewPhase.ended || v.phase == ShareViewPhase.watching);
      expect(v.end, ShareViewEnd.refused, reason: 'the host pinned version 1');
    });

    test('the phases follow what happens: joining while the host has not answered, then watching', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      w.relay.hold = true;
      final v = await w.watch('uid-sam', sam);
      expect(v.phase, ShareViewPhase.connecting);
      await until(() => v.phase == ShareViewPhase.joining);
      await settle();
      expect(v.phase, ShareViewPhase.joining, reason: 'the join has not reached the host');
      w.terminal.terminal.write('ready\r\n');
      w.relay.release();
      await until(() => v.phase == ShareViewPhase.watching);
      sameScreen(w.terminal.terminal, v.terminal);
    });
  });
}
