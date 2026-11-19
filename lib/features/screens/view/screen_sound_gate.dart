// Remote screens (4.0): whether an RDP session's sound plays, decided for
// the session and not by any one view of it.
//
// A view that is seen holds the gate open while its person wants sound
// (ScreenController); a screen shown in a window of its own is held by that
// window while it is shown. The app's lock and recording mode's cover close
// it for every session at once (screen_sound_guard.dart), whether a view of
// the session is left or not. So the sound stops when the last view of it
// goes (the terminals' area left for Hosts, Keys or Settings; Back on a
// phone with the session kept), and nothing outlives the views that let it
// play.
import 'package:zest_native/screen.dart';

/// Whether [ScreenSession]'s sound plays: some holder wants it and nothing
/// blocks it. The engine is told only of changes.
class ScreenSoundGate {
  ScreenSoundGate._(this.session);

  static final _gates = Expando<ScreenSoundGate>('screen sound gate');

  /// The gate of [session] (one for each session; a reconnect's new session
  /// has a new one, silent as the session starts).
  static ScreenSoundGate of(ScreenSession session) => _gates[session] ??= ScreenSoundGate._(session);

  /// What a screen shown in a window of its own holds the gate with, while
  /// the window shows it.
  static Object ownWindow(String sessionId) => ('screen own window', sessionId);

  final ScreenSession session;
  final _holders = <Object>{};
  bool _blocked = false;

  /// What the engine was last told: sessions start silent.
  bool _sent = false;

  /// Whether the sound plays now.
  bool get playing => _sent;

  /// Whether the app's lock or recording mode's cover keeps it silent.
  bool get blocked => _blocked;
  set blocked(bool on) {
    if (on == _blocked) return;
    _blocked = on;
    _apply();
  }

  /// [who] wants the sound to play ([on]) or not.
  void hold(Object who, {required bool on}) {
    final changed = on ? _holders.add(who) : _holders.remove(who);
    if (changed) _apply();
  }

  /// [who] lets go: it no longer counts.
  void release(Object who) => hold(who, on: false);

  /// What [from] held passes to [to] (a view that goes while its screen is
  /// shown in a window of its own).
  void handOver(Object from, Object to) {
    if (!_holders.contains(from)) return;
    _holders.add(to);
    _holders.remove(from);
  }

  bool holds(Object who) => _holders.contains(who);

  void _apply() {
    final on = _holders.isNotEmpty && !_blocked;
    if (on == _sent || session.isClosed) return;
    _sent = on;
    session.playSound(on: on);
  }
}
