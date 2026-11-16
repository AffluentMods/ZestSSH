// The remote's sound in an RDP session (4.0), on the Dart side over a fake engine: what
// the start request says, the switch, what a reader may do, and what the engine says of it.
import 'package:test/test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';

Future<void> settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('the request asks for sound only where the host says so: on from the start, or silent until said', () {
    expect(const ScreenConnectOptions.rdp().toRequest().containsKey('rdp_sound'), isFalse,
        reason: 'the server is told there is no sound here');
    expect(const ScreenConnectOptions.rdp(sound: true).toRequest()['rdp_sound'], 'on');
    expect(const ScreenConnectOptions.rdp(sound: true, soundOn: false).toRequest()['rdp_sound'], 'off');
    expect(const ScreenConnectOptions.rdp(soundOn: false).toRequest().containsKey('rdp_sound'), isFalse);
    expect(const ScreenConnectOptions.vnc().toRequest().containsKey('rdp_sound'), isFalse);
    // A new certificate pin keeps it.
    final o = const ScreenConnectOptions.rdp(sound: true, soundOn: false).copyWith(tlsPin: 'ab' * 32);
    expect(o.toRequest()['rdp_sound'], 'off');
  });

  test('the switch reaches the engine; a closed session and a reader send nothing', () async {
    final native = FakeScreenNative();
    final s = ScreenSession.open(const ScreenConnectOptions.rdp(sound: true), native: native);
    final engine = native.sessions.single;
    engine.connect(width: 800, height: 500);
    await settle();
    s.playSound(on: false);
    s.playSound(on: true);
    expect(engine.sounds, [false, true]);

    final reader = ScreenSession.reader(s.handle, protocol: ScreenProtocol.rdp, native: native);
    reader.playSound(on: false);
    expect(engine.sounds, [false, true], reason: 'sound is the owner\'s');
    reader.close();

    s.close();
    s.playSound(on: false);
    expect(engine.sounds, [false, true]);
  });

  test('what the engine says of the sound when connected: its format, or why there is none, cleaned', () {
    expect(const ScreenConnected({'sound': {'rate': 48000, 'channels': 2}}).sound, (rate: 48000, channels: 2));
    expect(const ScreenConnected({'sound': null}).sound, isNull);
    expect(const ScreenConnected({}).sound, isNull);
    for (final bad in <Object?>[
      {'rate': 0, 'channels': 2},
      {'rate': 48000},
      {'rate': '48000', 'channels': 2},
      'loud',
    ]) {
      expect(ScreenConnected({'sound': bad}).sound, isNull, reason: '$bad');
    }
    expect(const ScreenConnected({'sound': {'unavailable': 'no output device'}}).soundUnavailable, 'no output device');
    expect(const ScreenConnected({'sound': {'rate': 48000, 'channels': 2}}).soundUnavailable, isNull);
    final hostile = ScreenConnected({
      'sound': {'unavailable': 'no${String.fromCharCode(0x202e)}output${String.fromCharCode(10)}${'x' * 500}'},
    }).soundUnavailable!;
    expect(hostile.length, lessThanOrEqualTo(201));
    expect(hostile.contains(String.fromCharCode(0x202e)), isFalse);
    expect(const ScreenConnected({'sound': {'unavailable': 7}}).soundUnavailable, isNull);
    expect(const ScreenConnected({}).soundUnavailable, isNull);
  });
}
