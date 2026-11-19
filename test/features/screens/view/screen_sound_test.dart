// Remote screens (4.0): the remote's sound, as a session's view decides it. The
// engine is told to play only while the view's person wants it and the view may play it (seen,
// not covered, not locked); a session that has no sound is never told anything.
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_sound_gate.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';

import 'screen_view_fixture.dart';

Future<(FakeScreenSession, ScreenController)> _connect(WidgetTester tester, Map<String, Object?> sound) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(const ScreenConnectOptions.rdp(sound: true, soundOn: false), native: native);
  final engine = native.sessions.single;
  engine.emitJson(ScreenEventKind.connected, {'protocol': 'rdp', 'width': 800, 'height': 500, 'sound': sound});
  await tester.pump();
  final controller = ScreenController(session, decodeTile: syncDecode);
  addTearDown(() {
    controller.dispose();
    session.close();
  });
  await tester.pump();
  return (engine, controller);
}

void main() {
  group('the host', () {
    test('a computer plays it and a phone does not unless its person chose; the choice is kept, written only when made',
        () {
      const none = ScreenOptions();
      expect(none.soundOn(phone: false), isTrue);
      expect(none.soundOn(phone: true), isFalse);
      expect(none.toJson().containsKey('sound'), isFalse, reason: 'a column of before stays byte for byte');
      for (final chosen in [true, false]) {
        final o = ScreenOptions.decode(const ScreenOptions().copyWith(sound: chosen).encode());
        expect(o.sound, chosen);
        expect((o.soundOn(phone: false), o.soundOn(phone: true)), (chosen, chosen));
      }
      expect(ScreenOptions.decode('{"v":1,"sound":"loud"}').sound, isNull, reason: 'a value it does not know');
      expect(ScreenOptions.decode('{"v":1,"sound":true}').sound, isNull);
      expect(const ScreenOptions(sound: true).copyWith(clearSound: true).sound, isNull);
    });
  });

  group('the panel', () {
    test('the switch is there for a host that plays sound, on as its person left it, and not in a window of its own',
        () {
      ScreenMenuState of({bool asked = true, bool here = true, bool on = true, bool covered = false, bool own = false}) =>
          ScreenMenuState.of(
              phone: false,
              fit: ScreenFit.fit,
              viewOnly: false,
              soundAsked: asked,
              soundHere: here,
              soundOn: on,
              covered: covered,
              inOwnWindow: own);
      expect(of(asked: false).offered, isNot(contains(ScreenAction.sound)));
      expect(of().enabled(ScreenAction.sound), isTrue);
      expect(of().isOn(ScreenAction.sound), isTrue);
      expect(of(on: false).isOn(ScreenAction.sound), isFalse);
      expect(of(own: true).offered, isNot(contains(ScreenAction.sound)), reason: "the session's, in its tab");
      expect(of(here: false).whyNot[ScreenAction.sound], ScreenWhyNot.soundHere);
      expect(of(here: false).isOn(ScreenAction.sound), isFalse, reason: 'nothing plays, so it is not shown as on');
      expect(of(covered: true).whyNot[ScreenAction.sound], ScreenWhyNot.covered);
      expect(of(covered: true, here: false).whyNot[ScreenAction.sound], ScreenWhyNot.soundHere,
          reason: 'what nothing here can change is the reason said');
      expect(ScreenAction.sound.group, ScreenActionGroup.video);
      expect(ScreenAction.sound.kind, ScreenActionKind.toggle);
    });
  });

  group('the controller', () {
    testWidgets('silent until the view says it may play; then as its person wants it; told only of changes',
        (tester) async {
      final (engine, c) = await _connect(tester, {'rate': 48000, 'channels': 2});
      expect(c.soundPlays, isTrue);
      expect(c.soundUnavailable, isNull);
      expect(engine.sounds, isEmpty, reason: 'nothing until a view lets it');
      c.soundAllowed = true;
      expect(engine.sounds, [true]);
      c.soundAllowed = true;
      expect(engine.sounds, [true], reason: 'told only of a change');
      c.soundWanted = false;
      expect(engine.sounds, [true, false]);
      // Covered, locked, a phone away: not allowed, and still off when wanted again.
      c.soundAllowed = false;
      c.soundWanted = true;
      expect(engine.sounds, [true, false]);
      c.soundAllowed = true;
      expect(engine.sounds, [true, false, true]);
      c.soundAllowed = false;
      expect(engine.sounds, [true, false, true, false]);
    });

    testWidgets('a session without sound, or that connected without it, is never told anything', (tester) async {
      final (engine, c) = await _connect(tester, {'unavailable': 'no output device'});
      expect(c.soundPlays, isFalse);
      expect(c.soundUnavailable, 'no output device');
      c.soundAllowed = true;
      c.soundWanted = false;
      c.soundWanted = true;
      expect(engine.sounds, isEmpty);
    });

    // The sound does not outlive the views of its screen.
    testWidgets('the view that goes silences the sound; of two views the last one does; a window of its own keeps '
        'it until it closes; the lock or recording mode silences it with no view left', (tester) async {
      final (engine, c) = await _connect(tester, {'rate': 48000, 'channels': 2});
      final session = c.session;
      c.soundAllowed = true;
      expect(engine.sounds, [true]);
      // A second view of the same session (a phone's and a computer's do not meet; a test can).
      final second = ScreenController(session, decodeTile: syncDecode);
      await tester.pump();
      second.soundAllowed = true;
      c.dispose();
      expect(engine.sounds, [true], reason: 'the other view still sees it');
      second.dispose();
      expect(engine.sounds, [true, false], reason: 'no view left: silent');

      // A view that goes while its screen is shown in a window of its own hands the sound to it.
      final third = ScreenController(session, decodeTile: syncDecode);
      await tester.pump();
      third.soundAllowed = true;
      expect(engine.sounds, [true, false, true]);
      third
        ..handSoundToOwnWindow('s1')
        ..dispose();
      expect(engine.sounds, [true, false, true], reason: 'the window of its own is seen');
      final gate = ScreenSoundGate.of(session);
      // Locked, or covered by recording mode, with no view left in the main window.
      gate.blocked = true;
      expect(engine.sounds, [true, false, true, false]);
      gate.blocked = false;
      expect(engine.sounds, [true, false, true, false, true]);
      // The window closes: nobody sees it.
      gate.release(ScreenSoundGate.ownWindow('s1'));
      expect(engine.sounds, [true, false, true, false, true, false]);
      expect(gate.playing, isFalse);
    });

    testWidgets('the session ended: nothing more is said', (tester) async {
      final (engine, c) = await _connect(tester, {'rate': 44100, 'channels': 1});
      engine.emitJson(ScreenEventKind.closed, {'reason': 'serverClosed', 'message': 'gone'});
      await tester.pump();
      c.soundAllowed = true;
      expect(engine.sounds, isEmpty);
    });
  });
}
