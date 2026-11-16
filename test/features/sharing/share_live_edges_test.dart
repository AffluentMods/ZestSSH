// What a live view holds to at its edges, each side on its own: the device
// that shares against a relay that says what an honest one never would and
// against a viewer that speaks the protocol by hand (share_host.dart), and
// the device that watches against a host played by hand, so that what it
// sends and what it shows is seen exactly (share_viewer.dart). End to end
// each of these is also caught by the other side; here each side is held to
// it alone.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';

import 'share_fakes.dart';
import 'share_world.dart';

/// Frames of the channel the host sent to [lane] so far.
int framesTo(FakeShareRelay relay, int lane) =>
    relay.passed.where((p) => p.fromHost && p.lane == lane && p.bytes[0] == ShareWire.frame).length;

/// Frames of the channel that came from [lane] so far.
int framesFrom(FakeShareRelay relay, int lane) =>
    relay.passed.where((p) => !p.fromHost && p.lane == lane && p.bytes[0] == ShareWire.frame).length;

void main() {
  setUpAll(makeWorldKeys);

  group('the device that shares', () {
    /// A world where [uids] watch.
    Future<(World, List<ShareViewerController>)> watching(List<String> uids, {bool keyboardRequests = true}) async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(uids, keyboardRequests: keyboardRequests);
      final keys = {'uid-sam': sam, 'uid-kit': kit, 'uid-noa': noa};
      final viewers = <ShareViewerController>[];
      for (final uid in uids) {
        final v = await w.watch(uid, keys[uid]!);
        await until(() => v.phase == ShareViewPhase.watching, what: '$uid watching');
        viewers.add(v);
      }
      await settle();
      return (w, viewers);
    }

    test('a size that is not a terminal is not passed on', () async {
      final (w, [v]) = await watching(['uid-sam']);
      final lane = w.relay.laneOf('uid-sam')!;
      final before = framesTo(w.relay, lane);
      for (final (columns, rows) in [(0, 24), (80, 0), (-1, 24), (kShareMaxColumns + 1, 24), (80, kShareMaxRows + 1)]) {
        w.host.resized(columns, rows);
        w.host.flush();
        await settle();
      }
      expect(framesTo(w.relay, lane), before, reason: 'nothing was sent for any of them');
      expect((v.terminal.viewWidth, v.terminal.viewHeight), (60, 12));
      expect(v.phase, ShareViewPhase.watching);
      // One that is a terminal's goes through.
      w.terminal.terminal.resize(100, 30);
      w.host.resized(100, 30);
      w.host.flush();
      await settle();
      expect((v.terminal.viewWidth, v.terminal.viewHeight), (100, 30));
    });

    test('someone who fell behind is sent nothing that follows, not even a new size, until the screen afresh',
        () async {
      final (w, [v]) = await watching(['uid-sam']);
      // More at once than the rate allows (the clock stands still), then a
      // new size and one more line, all in one gathering.
      final flood = '${'x' * 1022}\r\n' * 1024;
      w.terminal.terminal.write(flood);
      w.host.output(flood);
      w.terminal.terminal.resize(100, 30);
      w.host.resized(100, 30);
      w.terminal.terminal.write('TAIL\r\n');
      w.host.output('TAIL\r\n');
      w.host.flush();
      await settle(200);
      expect((v.terminal.viewWidth, v.terminal.viewHeight), (60, 12),
          reason: 'the new size was made for what came after the part that was skipped');
      expect(w.terminal.snapshots, 1);

      // Time passes: the screen as it is now, size and all.
      w.clock = w.clock.add(const Duration(seconds: 10));
      await until(() => w.terminal.snapshots >= 2, what: 'the screen afresh', turns: 6000);
      await settle();
      sameScreen(w.terminal.terminal, v.terminal);
    });

    test('the window is a number of frames too; someone who took none of them gets no screen on top', () async {
      final (w, [v]) = await watching(['uid-sam']);
      // (The first frames are acknowledged by now.)
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final lane = w.relay.laneOf('uid-sam')!;
      w.relay.holdWhere = (p) => p.fromHost && p.lane == lane;
      final before = framesTo(w.relay, lane);
      // Small lines, each its own frame, well within the rate and far below
      // the window's size in bytes.
      for (var i = 0; i < ShareHostController.windowFrames + 60; i++) {
        w.clock = w.clock.add(const Duration(milliseconds: 100));
        w.show('$i\r\n');
        if (i % 50 == 0) await settle(4);
      }
      await settle();
      final sent = framesTo(w.relay, lane) - before;
      expect(sent, lessThanOrEqualTo(ShareHostController.windowFrames));
      expect(sent, greaterThan(ShareHostController.windowFrames - 8));

      // Nothing more while they have taken none of it, however long it lasts
      // and however much the rate would allow.
      final snapshots = w.terminal.snapshots;
      w.clock = w.clock.add(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(w.terminal.snapshots, snapshots, reason: 'no screen is sent on top of what they have not taken');
      expect(framesTo(w.relay, lane) - before, sent);

      // The line recovers: they take it, and get the screen as it is.
      w.relay.release();
      await until(() => w.terminal.snapshots > snapshots, what: 'the screen afresh', turns: 8000);
      await settle();
      sameScreen(w.terminal.terminal, v.terminal);
    });

    test('behind by size: no screen until most of what is on its way was taken', () async {
      final (w, [v]) = await watching(['uid-sam']);
      final lane = w.relay.laneOf('uid-sam')!;
      w.relay.holdWhere = (p) => p.fromHost && p.lane == lane;
      final step = '${'#' * 8000}\r\n';
      for (var i = 0; i < 200; i++) {
        w.clock = w.clock.add(const Duration(seconds: 1));
        w.show('step $i $step');
        await settle(3);
      }
      await settle();
      final snapshots = w.terminal.snapshots;
      final sent = framesTo(w.relay, lane);
      w.clock = w.clock.add(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(w.terminal.snapshots, snapshots, reason: 'a megabyte is still on its way to them');
      expect(framesTo(w.relay, lane), sent);
      w.relay.release();
      await until(() => w.terminal.snapshots > snapshots, what: 'the screen afresh', turns: 8000);
      await settle();
      sameScreen(w.terminal.terminal, v.terminal);
    });

    test('stopping sends what was still gathered, then the last word', () async {
      final (w, [v]) = await watching(['uid-sam']);
      w.show('last words\r\n', gather: true);
      await w.host.stop();
      await until(() => v.phase == ShareViewPhase.ended, what: 'the end');
      expect(v.end, ShareViewEnd.stopped);
      sameScreen(w.terminal.terminal, v.terminal);
    });

    test('a line that says it is ready once more is a new line: nothing agreed before counts', () async {
      final (w, [s, _]) = await watching(['uid-sam', 'uid-kit']);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      w.notes.clear();
      w.relay.sayReadyAgain();
      await settle();
      expect(w.host.keyboardHolder, isNull);
      expect(w.notes, [(ShareNote.keyboardBack, 'uid-sam')]);
      expect([for (final g in w.host.guests) g.state], [ShareGuestState.connected, ShareGuestState.connected],
          reason: 'there, and to join again before they are shown or heard');
      // Sam's device was told nothing and still believes the keyboard is
      // his: what it sends is not typed.
      s.terminal.textInput('typed into nothing');
      await settle();
      expect(w.terminal.typed, isEmpty);
    });

    test('someone who appears on a new connection without the old one having gone does not keep the keyboard',
        () async {
      final (w, [s]) = await watching(['uid-sam']);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      final lane = w.relay.laneOf('uid-sam')!;
      w.relay.sayViewer(lane + 40, 'uid-sam', on: true);
      await settle();
      expect(w.host.keyboardHolder, isNull);
      expect(w.guest('uid-sam').state, ShareGuestState.connected);
      s.terminal.textInput('from the old connection');
      await settle();
      expect(w.terminal.typed, isEmpty);
    });

    test('an older connection reported gone after a newer one opened takes nothing with it', () async {
      final (w, [s]) = await watching(['uid-sam']);
      final old = w.relay.laneOf('uid-sam')!;
      w.relay.dropViewerLine('uid-sam');
      await until(() => w.relay.laneOf('uid-sam') != old && s.phase == ShareViewPhase.watching, what: 'sam back');
      await settle();
      w.notes.clear();
      w.relay.sayViewer(old, 'uid-sam', on: false);
      await settle();
      expect(w.guest('uid-sam').state, ShareGuestState.watching);
      expect(w.notes, isEmpty);
      w.show('still here\r\n');
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
    });

    test('someone who says no from another device while watching is dropped: the keyboard comes back, '
        'and nothing more is sent to them', () async {
      final (w, [s]) = await watching(['uid-sam']);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      final lane = w.relay.laneOf('uid-sam')!;
      w.relay.declined('uid-sam');
      await settle();
      expect(w.host.keyboardHolder, isNull);
      expect(w.guest('uid-sam').state, ShareGuestState.declined);
      final sent = framesTo(w.relay, lane);
      w.show('not for them\r\n');
      await settle();
      expect(framesTo(w.relay, lane), sent);
    });

    test('a shared tmux session reads nothing: bytes pushed through are neither taken nor answered', () async {
      final w = World(mode: ShareMode.tmux);
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final link = w.relay.viewer('uid-sam')..start();
      addTearDown(link.close);
      await settle();
      final lane = w.relay.laneOf('uid-sam')!;
      expect(w.guest('uid-sam').state, ShareGuestState.connected);
      w.relay.pushToHost(lane, Uint8List.fromList([ShareWire.join, 1, 2, 3]));
      w.relay.pushToHost(lane, Uint8List.fromList([ShareWire.frame, 1, 2, 3]));
      await settle();
      expect(w.relay.tried.where((p) => p.fromHost), isEmpty, reason: 'nothing was read, so nothing was answered');
    });

    test('a channel that breaks takes the keyboard back there and then, not when they join again', () async {
      final (w, [s]) = await watching(['uid-sam']);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      await settle();
      final lane = w.relay.laneOf('uid-sam')!;
      // The relay changes what sam sends next, and keeps the host's "join
      // again" from him, so that he does not.
      w.relay.tamper = (p) {
        if (!p.fromHost && p.lane == lane && p.bytes[0] == ShareWire.frame) {
          return Uint8List.fromList(p.bytes)..[p.bytes.length - 1] ^= 0x01;
        }
        if (p.fromHost && p.lane == lane && p.bytes[0] == ShareWire.refuse) return null;
        return p.bytes;
      };
      w.notes.clear();
      s.terminal.textInput('x');
      await settle();
      expect(w.host.keyboardHolder, isNull);
      expect(w.notes, [(ShareNote.keyboardBack, 'uid-sam')]);
      expect(w.guest('uid-sam').state, ShareGuestState.connected);
      expect(w.terminal.typed, isEmpty);
    });

    test('a request for the keyboard: not heard when requests are off, and heard once', () async {
      // Off: a device that asks anyway is not listened to.
      final off = World();
      addTearDown(off.dispose);
      await off.share(['uid-sam'], keyboardRequests: false);
      final rogue = Rogue(off, 'uid-sam');
      await rogue.connect();
      expect((await rogue.join(await off.invitationOf('uid-sam', sam), sam))[0], ShareWire.accept);
      await rogue.say(const ShareReady());
      expect(off.guest('uid-sam').state, ShareGuestState.watching);
      off.notes.clear();
      await rogue.say(const ShareAskKeyboard());
      expect(off.guest('uid-sam').asksKeyboard, isFalse);
      expect(off.notes, isEmpty);
      // The person sharing can still hand it over.
      expect(off.host.giveKeyboard('uid-sam'), isTrue);

      // On: asking twice is one request.
      final on = World();
      addTearDown(on.dispose);
      await on.share(['uid-kit']);
      final again = Rogue(on, 'uid-kit');
      await again.connect();
      expect((await again.join(await on.invitationOf('uid-kit', kit), kit))[0], ShareWire.accept);
      await again.say(const ShareReady());
      on.notes.clear();
      await again.say(const ShareAskKeyboard());
      await again.say(const ShareAskKeyboard());
      expect(on.guest('uid-kit').asksKeyboard, isTrue);
      expect(on.notes, [(ShareNote.askedKeyboard, 'uid-kit')]);
    });

    test('someone who says they leave gives the keyboard back, whatever their line does', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      final rogue = Rogue(w, 'uid-sam');
      await rogue.connect();
      expect((await rogue.join(await w.invitationOf('uid-sam', sam), sam))[0], ShareWire.accept);
      await rogue.say(const ShareReady());
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await settle();
      w.notes.clear();
      // "I leave", and the line stays open.
      await rogue.say(const ShareLeave());
      expect(w.host.keyboardHolder, isNull);
      expect(w.notes, [(ShareNote.keyboardBack, 'uid-sam'), (ShareNote.left, 'uid-sam')]);
      expect(w.guest('uid-sam').state, ShareGuestState.connected);
      await rogue.say(ShareInput(Uint8List.fromList(utf8.encode('typed after leaving\r'))));
      expect(w.terminal.typed, isEmpty);
    });

    test('someone who joins while output waits to go out gets it once, in the screen', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching, what: 'sam watching');
      await settle();
      final samLane = w.relay.laneOf('uid-sam')!;
      // Kit's device joins; its "send me the screen" is held on the way.
      w.relay.holdWhere = (p) => !p.fromHost && p.lane != samLane && p.bytes[0] == ShareWire.frame;
      final k = await w.watch('uid-kit', kit);
      await until(
          () => w.relay.passed.any((p) => !p.fromHost && p.lane != samLane && p.bytes[0] == ShareWire.frame),
          what: 'kit ready');
      // The terminal shows a line that has not gone out yet, and kit's word
      // arrives in the same moment.
      w.show('pending line\r\n', gather: true);
      w.relay.release();
      await until(() => k.phase == ShareViewPhase.watching, what: 'kit watching');
      w.host.flush();
      await settle();
      sameScreen(w.terminal.terminal, k.terminal);
      sameScreen(w.terminal.terminal, s.terminal);
    });

    test('someone who joins is told who types', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit']);
      final s = await w.watch('uid-sam', sam);
      await until(() => s.phase == ShareViewPhase.watching);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping);
      final k = await w.watch('uid-kit', kit);
      await until(() => k.phase == ShareViewPhase.watching);
      await settle();
      expect(k.keyboard, ShareKeyboard.someoneElse);
      expect(s.keyboard, ShareKeyboard.you);
    });

    test('what was queued for a channel is not sent once that channel is gone', () async {
      final (w, [s]) = await watching(['uid-sam']);
      final lane = w.relay.laneOf('uid-sam')!;
      // A lot is on its way out (each piece still to be sealed) when the
      // host's line drops and comes back.
      final text = '${'y' * 1022}\r\n' * 512;
      w.terminal.terminal.write(text);
      w.host.output(text);
      w.host.flush();
      final from = w.relay.passed.length;
      w.relay.dropHostLine();
      await until(() => w.relay.passed.skip(from).any((p) => p.fromHost && p.bytes[0] == ShareWire.accept),
          what: 'a new channel');
      final after = w.relay.passed.skip(from).where((p) => p.fromHost && p.lane == lane).toList();
      final stale = after.takeWhile((p) => p.bytes[0] != ShareWire.accept).where((p) => p.bytes[0] == ShareWire.frame);
      expect(stale.length, lessThanOrEqualTo(1), reason: 'at most the one that was being sealed as the line dropped');
      await until(() => s.phase == ShareViewPhase.watching, what: 'sam watching again');
      await settle();
      sameScreen(w.terminal.terminal, s.terminal);
    });
  });

  group('the device that watches', () {
    /// Sam's device watching a share whose host is played by hand, past
    /// the join and, unless [screen] is false, the first screen.
    Future<(HandHost, ShareViewerController)> watchingHand({bool screen = true, bool keyboard = true}) async {
      final hand = HandHost(FakeShareRelay());
      final v = await watchHand(hand, 'uid-sam', sam, keyboard: keyboard);
      addTearDown(v.dispose);
      await until(() => hand.said.whereType<ShareReady>().isNotEmpty, what: 'its "send me the screen"');
      if (screen) {
        await hand.say(const ShareScreen(columns: 60, rows: 12, text: 'deploy@host:~\$ '));
        await until(() => v.phase == ShareViewPhase.watching, what: 'the screen');
      }
      return (hand, v);
    }

    Future<void> giveKeyboard(HandHost hand, ShareViewerController v) async {
      await hand.say(const ShareKeyboardState(ShareKeyboard.you));
      await until(() => v.isTyping, what: 'the keyboard');
    }

    test('the hand-played host and the viewer agree: screen, output, keys', () async {
      final (hand, v) = await watchingHand();
      await hand.say(const ShareOutput('ls\r\nnotes.txt\r\n'));
      final want = Terminal(maxLines: 2000)
        ..resize(60, 12)
        ..write('deploy@host:~\$ ')
        ..write('ls\r\nnotes.txt\r\n');
      sameScreen(want, v.terminal);
      expect(hand.unreadable, 0);
      expect(hand.typed, isEmpty);
      await giveKeyboard(hand, v);
      v.terminal.textInput('whoami\r');
      await until(() => hand.typed.length == 7, what: 'the keys');
      expect(utf8.decode(hand.typed), 'whoami\r');
    });

    test('its terminal answers nothing: what a program asks is the other terminal\'s to answer', () async {
      final (hand, v) = await watchingHand();
      await giveKeyboard(hand, v);
      // Where is the cursor, what are you, how are you.
      await hand.say(const ShareOutput('\x1b[6n\x1b[c\x1b[5n\x1b[>c'));
      await settle();
      expect(hand.typed, isEmpty, reason: 'an answer from here would reach the program as if someone had typed it');
      v.terminal.textInput('ok');
      await until(() => hand.typed.isNotEmpty, what: 'what the person typed');
      expect(utf8.decode(hand.typed), 'ok');
    });

    test('asks for the keyboard once; asking again while the answer is awaited sends nothing', () async {
      final (hand, v) = await watchingHand();
      v.askKeyboard();
      v.askKeyboard();
      await settle();
      expect(hand.said.whereType<ShareAskKeyboard>(), hasLength(1));
      expect(v.isAsking, isTrue);
      // Told how things stand (no): it may ask again.
      await hand.say(const ShareKeyboardState(ShareKeyboard.host));
      expect(v.isAsking, isFalse);
      v.askKeyboard();
      await settle();
      expect(hand.said.whereType<ShareAskKeyboard>(), hasLength(2));
    });

    test('someone who was not told they may ask does not ask', () async {
      final (hand, v) = await watchingHand(keyboard: false);
      expect(v.mayAsk, isFalse);
      v.askKeyboard();
      await settle();
      expect(hand.said.whereType<ShareAskKeyboard>(), isEmpty);
      expect(v.isAsking, isFalse);
    });

    test('leaving says so before the line closes', () async {
      final (hand, v) = await watchingHand();
      await v.leave();
      await settle();
      expect(hand.said.last, isA<ShareLeave>());
      expect((v.phase, v.end), (ShareViewPhase.ended, ShareViewEnd.left));
    });

    test('while its line is down it holds nothing: no keyboard, no channel', () async {
      final (hand, v) = await watchingHand();
      await giveKeyboard(hand, v);
      final lane = hand.lane;
      hand.relay.dropViewerLine('uid-sam', comeBack: false);
      await settle();
      expect(v.phase, ShareViewPhase.connecting);
      expect(v.keyboard, ShareKeyboard.host);
      expect(v.isTyping, isFalse);
      final sent = framesFrom(hand.relay, lane);
      v.terminal.textInput('typed while away');
      await settle();
      expect(framesFrom(hand.relay, lane), sent);
    });

    test('an answer that names another join is not acted on: no channel is made of it', () async {
      final hand = HandHost(FakeShareRelay())..answerJoins = false;
      final v = await watchHand(hand, 'uid-sam', sam);
      addTearDown(v.dispose);
      await until(() => hand.joins.isNotEmpty, what: 'the join');
      final lane = hand.relay.laneOf('uid-sam')!;
      // A well-formed answer to some other join.
      hand.link.send(
          Uint8List.fromList([ShareWire.accept, ...ShareHostKeys.newNonce(), ...List<int>.filled(32, 7)]),
          lane: lane);
      await settle();
      expect(v.phase, ShareViewPhase.joining, reason: 'still waiting for the answer to its own');
      expect(framesFrom(hand.relay, lane), 0, reason: 'nothing was said through a channel made of it');
      // The answer to its own is taken.
      await hand.accept(lane, hand.joins.single);
      await until(() => hand.said.whereType<ShareReady>().isNotEmpty, what: 'its "send me the screen"');
      expect(hand.unreadable, 0);
    });

    test('nothing is shown before the screen: output and a size that come first are passed over', () async {
      final (hand, v) = await watchingHand(screen: false);
      await hand.say(const ShareOutput('EARLY OUTPUT\r\n'));
      await hand.say(const ShareResize(columns: 100, rows: 30));
      expect(v.phase, ShareViewPhase.joining);
      sameScreen(Terminal(maxLines: 2000), v.terminal);
      await hand.say(const ShareScreen(columns: 60, rows: 12, text: 'the screen'));
      await until(() => v.phase == ShareViewPhase.watching, what: 'the screen');
      sameScreen(
          Terminal(maxLines: 2000)
            ..resize(60, 12)
            ..write('the screen'),
          v.terminal);
    });

    test('told the keyboard is theirs before there is a screen, it types nothing', () async {
      final (hand, v) = await watchingHand(screen: false);
      await hand.say(const ShareKeyboardState(ShareKeyboard.you));
      expect(v.phase, ShareViewPhase.joining);
      expect(v.isTyping, isFalse);
      v.terminal.textInput('typed blind');
      await settle();
      expect(hand.typed, isEmpty);
    });

    test('keys go out no faster than their rate, and what waited is dropped when the keyboard goes, '
        'also when it comes back at once', () async {
      final (hand, v) = await watchingHand();
      await giveKeyboard(hand, v);
      // More than goes out at once: the rest waits.
      v.terminal.textInput('p' * (ShareViewerController.inputBurst + 200 * 1024));
      await until(() => hand.typed.length >= ShareViewerController.inputBurst - kShareInputMax, what: 'the first part');
      await settle();
      final first = hand.typed.length;
      expect(first, lessThanOrEqualTo(ShareViewerController.inputBurst));
      // Taken back, and given again a moment later.
      await hand.say(const ShareKeyboardState(ShareKeyboard.host));
      await hand.say(const ShareKeyboardState(ShareKeyboard.you));
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(hand.typed.length, first, reason: 'what waited went with the keyboard');
      expect(v.isTyping, isTrue);
      // What is typed now goes.
      v.terminal.textInput('new');
      await until(() => hand.typed.length == first + 3, what: 'new keys');
    });

    test('a paste larger than what may wait is not sent at all', () async {
      final (hand, v) = await watchingHand();
      await giveKeyboard(hand, v);
      v.terminal.textInput('q' * (ShareViewerController.inputQueueMax + 1));
      await settle();
      expect(hand.typed, isEmpty);
      v.terminal.textInput('fits');
      await until(() => hand.typed.length == 4, what: 'what fits');
    });

    test('an acknowledgement goes back soon after a frame, also when only one came', () async {
      final (hand, v) = await watchingHand();
      // (Whatever the screen set off has gone.)
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final acks = hand.said.whereType<ShareAck>().length;
      await hand.say(const ShareOutput('one line\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      final now = hand.said.whereType<ShareAck>().toList();
      expect(now.length, acks + 1);
      expect(now.last.received, hand.channel!.sent, reason: 'it says how far this device has read');
      expect(v.phase, ShareViewPhase.watching);
    });

    test('what waited for a channel is not sent once that channel is gone', () async {
      final (hand, v) = await watchingHand();
      await giveKeyboard(hand, v);
      await settle();
      final lane = hand.lane;
      final before = framesFrom(hand.relay, lane);
      // Twenty messages of keys, and the host goes in the same breath.
      v.terminal.textInput('k' * (kShareInputMax * 20));
      hand.relay.dropHostLine(comeBack: false);
      await settle();
      expect(framesFrom(hand.relay, lane) - before, lessThanOrEqualTo(1),
          reason: 'at most the one being sealed as the host went');
      expect(v.phase, ShareViewPhase.waitingForHost);
    });
  });
}
