// Session moderation in a live view (3.0; share_host.dart and
// share_viewer.dart): each person invited watches, may be handed the
// keyboard, or may end the session. Which of the three is in the invitation
// the person sharing signed. The device that shares acts on "end the
// session" only from someone it invited to, while they are watching, and
// once; from anyone else the same words do nothing. Whoever may end the
// session never types into it. Closing the session is the job of whoever
// hears the note (the app: share_session_hooks_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'share_fakes.dart';
import 'share_world.dart';

void main() {
  setUpAll(makeWorldKeys);

  /// The requests to end the session that the device that shares acted on.
  List<(ShareNote, String?)> endings(World w) => [
        for (final n in w.notes)
          if (n.$1 == ShareNote.endAsked) n,
      ];

  /// What crossed the relay towards the device that shares.
  int fromViewers(World w) => w.relay.passed.where((p) => !p.fromHost).length;

  group('who may end the session', () {
    test('the invitation says so, and that person is never one who types', () async {
      final w = World();
      addTearDown(w.dispose);
      // (eve is not invited: naming her as one who ends it invites nobody.)
      await w.share(['uid-sam', 'uid-kit', 'uid-noa'], enders: {'uid-kit', 'uid-noa', 'uid-eve'});
      expect(w.api.created.single.invites.keys.toSet(), {'uid-sam', 'uid-kit', 'uid-noa'});

      final parts = <String, (bool, bool)>{};
      for (final (uid, keys) in <(String, AccountKeys)>[('uid-sam', sam), ('uid-kit', kit), ('uid-noa', noa)]) {
        final i = (await w.invitationOf(uid, keys)).invitation;
        parts[uid] = (i.keyboard, i.mayEnd);
      }
      expect(parts, {
        'uid-sam': (true, false),
        'uid-kit': (false, true),
        // Someone who could watch only can still be the one who ends it.
        'uid-noa': (false, true),
      });
      expect(w.host.guests.map((g) => (g.uid, g.canType, g.canEnd)), [
        ('uid-sam', true, false),
        ('uid-kit', false, true),
        ('uid-noa', false, true),
      ]);
      expect(w.host.endersWatching, isEmpty, reason: 'nobody has joined yet');
    });

    test('it does not depend on whether the keyboard can be asked for', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-kit', 'uid-sam'], keyboardRequests: false, enders: {'uid-kit'});
      final forKit = (await w.invitationOf('uid-kit', kit)).invitation;
      final forSam = (await w.invitationOf('uid-sam', sam)).invitation;
      expect((forKit.keyboard, forKit.mayEnd), (false, true));
      expect((forSam.keyboard, forSam.mayEnd), (false, false));
      expect(w.host.guests.map((g) => (g.uid, g.canType, g.canEnd)), [
        ('uid-kit', false, true),
        ('uid-sam', true, false),
      ]);
    });

    test('invited later, someone can be the one who ends it; who is already invited keeps the part they have',
        () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam']);
      await w.host.invite([w.pinned['uid-kit']!, w.pinned['uid-sam']!], enders: {'uid-kit', 'uid-sam'});
      expect(w.host.guests.map((g) => (g.uid, g.canType, g.canEnd)), [
        ('uid-sam', true, false),
        ('uid-kit', false, true),
      ]);
      final forKit = (await w.invitationOf('uid-kit', kit)).invitation;
      expect((forKit.keyboard, forKit.mayEnd), (false, true));
      expect((await w.invitationOf('uid-sam', sam)).invitation.mayEnd, isFalse);
      expect(w.api.invited.single.invites.keys, ['uid-kit'], reason: 'sam was not invited a second time');

      final k = await w.watch('uid-kit', kit);
      await until(() => k.phase == ShareViewPhase.watching);
      k.endSession();
      await until(() => endings(w).isNotEmpty, what: 'the request to end the session');
      expect(endings(w), [(ShareNote.endAsked, 'uid-kit')]);
    });

    test('a shared tmux session has nobody who ends it', () async {
      final w = World(mode: ShareMode.tmux);
      addTearDown(w.dispose);
      await w.share(['uid-sam'], enders: {'uid-sam'});
      final i = (await w.invitationOf('uid-sam', sam)).invitation;
      expect((i.mode, i.keyboard, i.mayEnd), (ShareMode.tmux, false, false));
      expect((w.guest('uid-sam').canType, w.guest('uid-sam').canEnd), (false, false));
      await w.host.invite([w.pinned['uid-kit']!], enders: {'uid-kit'});
      expect((await w.invitationOf('uid-kit', kit)).invitation.mayEnd, isFalse);
      expect(w.guest('uid-kit').canEnd, isFalse);
      expect(w.host.endersWatching, isEmpty);
    });
  });

  group('ending the session', () {
    test('someone invited to says so: heard once; they watch and are never given the keyboard', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit'], enders: {'uid-kit'});
      expect(w.host.endersWatching, isEmpty);
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      expect((k.mayEnd, k.mayAsk), (true, false));
      expect((s.mayEnd, s.mayAsk), (false, true));
      expect(w.host.endersWatching, {'uid-kit'});

      // Never the keyboard: asking does nothing, it cannot be handed over,
      // and what they type goes nowhere.
      w.show('deploy@db-primary:~\$ ');
      k.askKeyboard();
      await settle();
      expect((k.isAsking, w.guest('uid-kit').asksKeyboard), (false, false));
      expect(w.host.giveKeyboard('uid-kit'), isFalse);
      expect(w.host.keyboardHolder, isNull);
      k.terminal.textInput('whoami\r');
      await settle();
      expect(w.terminal.typed, isEmpty);

      w.notes.clear();
      k.endSession();
      await until(() => w.notes.isNotEmpty, what: 'the request to end the session');
      expect(w.notes, [(ShareNote.endAsked, 'uid-kit')]);
      // Asked again (a second press, a second device): it was said already.
      k.endSession();
      await settle();
      expect(w.notes, [(ShareNote.endAsked, 'uid-kit')]);
      // The share itself ends with the session, which whoever heard the
      // note closes. Until then everyone goes on watching.
      expect(w.host.isEnded, isFalse);
      expect((w.guest('uid-kit').state, w.guest('uid-sam').state),
          (ShareGuestState.watching, ShareGuestState.watching));
      expect(w.terminal.typed, isEmpty);
    });

    test('with the keyboard in someone else\'s hands it is still theirs to end', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-kit'], enders: {'uid-kit'});
      final s = await w.watch('uid-sam', sam);
      final k = await w.watch('uid-kit', kit);
      await until(() => s.phase == ShareViewPhase.watching && k.phase == ShareViewPhase.watching);
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await until(() => s.isTyping && k.keyboard == ShareKeyboard.someoneElse);
      k.endSession();
      await until(() => endings(w).isNotEmpty, what: 'the request to end the session');
      expect(endings(w), [(ShareNote.endAsked, 'uid-kit')]);
      expect(w.host.keyboardHolder, 'uid-sam', reason: 'nothing else changes until the session is closed');
    });

    test('two may end it: it is said once, naming the first of them', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-kit', 'uid-noa'], enders: {'uid-kit', 'uid-noa'});
      final k = await w.watch('uid-kit', kit);
      final n = await w.watch('uid-noa', noa);
      await until(() => k.phase == ShareViewPhase.watching && n.phase == ShareViewPhase.watching);
      expect(w.host.endersWatching, {'uid-kit', 'uid-noa'});
      n.endSession();
      await until(() => endings(w).isNotEmpty, what: 'the request to end the session');
      k.endSession();
      await settle();
      expect(endings(w), [(ShareNote.endAsked, 'uid-noa')]);
    });

    test('the same words from anyone not invited to end it do nothing', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-sam', 'uid-noa', 'uid-kit'], enders: {'uid-kit'});

      // An honest device does not even send them.
      final n = await w.watch('uid-noa', noa);
      await until(() => n.phase == ShareViewPhase.watching);
      await settle();
      expect(n.mayEnd, isFalse);
      final sent = fromViewers(w);
      n.endSession();
      await settle();
      expect(fromViewers(w), sent, reason: 'not even sent');
      await n.leave();

      // A device that sends them anyway: someone who may type, without the
      // keyboard and with it.
      final typist = Rogue(w, 'uid-sam');
      await typist.connect();
      expect((await typist.join(await w.invitationOf('uid-sam', sam), sam))[0], ShareWire.accept);
      await typist.say(const ShareReady());
      await typist.say(const ShareEndSession());
      expect(w.host.giveKeyboard('uid-sam'), isTrue);
      await typist.say(const ShareEndSession());
      // And someone who can watch only.
      final watcher = Rogue(w, 'uid-noa');
      await watcher.connect();
      expect((await watcher.join(await w.invitationOf('uid-noa', noa), noa))[0], ShareWire.accept);
      await watcher.say(const ShareReady());
      await watcher.say(const ShareEndSession());
      expect(endings(w), isEmpty);
      expect(w.host.isEnded, isFalse);
      expect(w.host.endersWatching, isEmpty);

      // None of that used up the one time it is said: the person invited
      // to end it is heard.
      final k = await w.watch('uid-kit', kit);
      await until(() => k.phase == ShareViewPhase.watching);
      k.endSession();
      await until(() => endings(w).isNotEmpty, what: 'the request to end the session');
      expect(endings(w), [(ShareNote.endAsked, 'uid-kit')]);
    });

    test('someone invited to end it is heard only while watching: not before their device shows the screen, '
        'and not after they left', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-kit'], enders: {'uid-kit'});
      final early = Rogue(w, 'uid-kit');
      await early.connect();
      expect((await early.join(await w.invitationOf('uid-kit', kit), kit))[0], ShareWire.accept);
      await early.say(const ShareEndSession());
      expect(endings(w), isEmpty, reason: 'let in, not watching yet');
      expect(w.host.endersWatching, isEmpty);
      expect(w.guest('uid-kit').state, ShareGuestState.connected);

      await early.say(const ShareReady());
      expect(w.host.endersWatching, {'uid-kit'});
      await early.say(const ShareLeave());
      expect(w.host.endersWatching, isEmpty);
      await early.say(const ShareEndSession());
      expect(endings(w), isEmpty, reason: 'gone: nothing of theirs is taken');

      // Back and watching, they are heard.
      expect((await early.join(await w.invitationOf('uid-kit', kit), kit))[0], ShareWire.accept);
      await early.say(const ShareReady());
      await early.say(const ShareEndSession());
      expect(endings(w), [(ShareNote.endAsked, 'uid-kit')]);
    });

    test('someone whose invitation was taken back cannot end it', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-kit', 'uid-sam'], enders: {'uid-kit'});
      final gone = Rogue(w, 'uid-kit');
      await gone.connect();
      expect((await gone.join(await w.invitationOf('uid-kit', kit), kit))[0], ShareWire.accept);
      await gone.say(const ShareReady());
      expect(w.host.endersWatching, {'uid-kit'});
      await w.host.remove('uid-kit');
      expect(w.host.endersWatching, isEmpty);
      await gone.say(const ShareEndSession());
      expect(endings(w), isEmpty);
      expect(w.host.isEnded, isFalse);
    });

    test('once the share has stopped, nothing more is heard', () async {
      final w = World();
      addTearDown(w.dispose);
      await w.share(['uid-kit'], enders: {'uid-kit'});
      final late = Rogue(w, 'uid-kit');
      await late.connect();
      expect((await late.join(await w.invitationOf('uid-kit', kit), kit))[0], ShareWire.accept);
      await late.say(const ShareReady());
      await w.host.stop();
      await late.say(const ShareEndSession());
      expect(endings(w), isEmpty);
      expect(w.host.endersWatching, isEmpty);
    });
  });

  group('the device that watches', () {
    /// kit's device watching a share whose host is played by hand, as far
    /// as the join and, unless [screen] is false, the first screen.
    Future<(HandHost, ShareViewerController)> watching({required bool mayEnd, bool screen = true}) async {
      final hand = HandHost(FakeShareRelay());
      final v = await watchHand(hand, 'uid-kit', kit, mayEnd: mayEnd);
      addTearDown(v.dispose);
      await until(() => hand.said.whereType<ShareReady>().isNotEmpty, what: 'its "send me the screen"');
      if (screen) {
        await hand.say(const ShareScreen(columns: 60, rows: 12, text: 'deploy@host:~\$ '));
        await until(() => v.phase == ShareViewPhase.watching, what: 'the screen');
      }
      return (hand, v);
    }

    test('says it only when invited to and only while watching, as one message through the channel', () async {
      // Invited to end it, with no screen yet: nothing is said.
      final (hand, v) = await watching(mayEnd: true, screen: false);
      expect((v.mayEnd, v.mayAsk), (true, false));
      v.endSession();
      await settle();
      expect(hand.said.whereType<ShareEndSession>(), isEmpty);

      // Watching: said, sealed like everything else it says.
      await hand.say(const ShareScreen(columns: 60, rows: 12, text: 'deploy@host:~\$ '));
      await until(() => v.phase == ShareViewPhase.watching, what: 'the screen');
      v.endSession();
      await until(() => hand.said.whereType<ShareEndSession>().isNotEmpty, what: 'the request');
      expect(hand.said.whereType<ShareEndSession>(), hasLength(1));
      expect(hand.unreadable, 0);
      expect(v.phase, ShareViewPhase.watching, reason: 'it goes on watching until it is told the session closed');

      // The session closes: the view ends as for any session that closed,
      // and has nothing more to say.
      await hand.say(const ShareEnd(ShareEndReason.sessionClosed));
      await until(() => v.phase == ShareViewPhase.ended, what: 'the end');
      expect(v.end, ShareViewEnd.sessionClosed);
      final said = hand.said.length;
      v.endSession();
      await settle();
      expect(hand.said.length, said);
    });

    test('not invited to, it says nothing whatever is pressed', () async {
      final (hand, v) = await watching(mayEnd: false);
      expect(v.mayEnd, isFalse);
      v.endSession();
      await settle();
      expect(hand.said.whereType<ShareEndSession>(), isEmpty);
      expect(hand.unreadable, 0);
    });

    test('invited to end it, it types nothing even when a host says the keyboard is theirs', () async {
      final (hand, v) = await watching(mayEnd: true);
      await hand.say(const ShareKeyboardState(ShareKeyboard.you));
      await settle();
      v.terminal.textInput('whoami\r');
      await settle();
      expect(hand.typed, isEmpty);
      expect(v.isTyping, isFalse);
    });
  });
}
