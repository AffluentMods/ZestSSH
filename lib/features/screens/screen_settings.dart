// Remote screens' settings (4.0): Settings, Remote
// screens. How a phone's finger drives the pointer when a screen opens
// (Touch by default; a host switched on this device keeps its own,
// screen_touch.*), the key that opens the screen menu on a computer (F8 by
// default, as in TigerVNC), the scaling a new screen is saved with, whether
// a screen of one's own space shares the clipboard by default, and whether
// recording mode covers a screen's picture (by default, until "Show
// for this session") or shows it. Each is a preference of the store
// (SharedPreferences), said in SettingsService to be put back by "Reset all
// settings", and to be the device's or the person's.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';

/// A phone's Touch or Mouse pointer when a screen opens (the device's: a
/// finger on this phone).
const String kScreenTouchDefaultKey = 'screen_default_touch';

/// The key that opens the screen menu on a computer (the device's: its
/// keyboard).
const String kScreenMenuKeyKey = 'screen_menu_key';

/// The scaling a new remote screen is saved with (the person's).
const String kScreenScalingDefaultKey = 'screen_default_scaling';

/// Whether recording mode covers a screen's picture (the device's, as
/// recording mode itself is).
const String kScreenRecordingKey = 'screen_recording';

/// Whether a remote screen of the person's own space shares the clipboard
/// when nothing else was chosen for it (`on`, the default, or `off`; the
/// person's). A host whose editor set its own, a device's choice for a host
/// (screen_clipboard.*) and a team's rules come first.
const String kScreenClipboardDefaultKey = 'screen_default_clipboard';

/// [kScreenClipboardDefaultKey] as [prefs] hold it: on unless turned off.
bool screenOwnClipboardDefault(SharedPreferences prefs) => prefs.getString(kScreenClipboardDefaultKey) != 'off';

/// The keys that may open the screen menu on a computer: F8 as TigerVNC has
/// it, or another function key a remote program may want for itself.
enum ScreenMenuKey {
  f8(8, LogicalKeyboardKey.f8),
  f9(9, LogicalKeyboardKey.f9),
  f10(10, LogicalKeyboardKey.f10),
  f11(11, LogicalKeyboardKey.f11),
  f12(12, LogicalKeyboardKey.f12);

  const ScreenMenuKey(this.number, this.logical);

  final int number;

  /// The key on this computer's keyboard.
  final LogicalKeyboardKey logical;

  /// The key as the remote takes it, for "Send F8" in the menu.
  ScreenKey get key => ScreenKey.f(number);

  /// As a keyboard prints it (the same in every language).
  String get label => 'F$number';
}

/// What recording mode does to a remote screen's picture.
enum ScreenRecordingBehaviour {
  /// Covered, paused, until "Show for this session" (the default: a screen
  /// may show anything).
  cover,

  /// Shown as when recording mode is off.
  show;

  String nameIn(AppLocalizations l10n) => switch (this) {
        cover => l10n.settingsScreenRecordingCover,
        show => l10n.settingsScreenRecordingShow,
      };
}

/// Touch or Mouse pointer, as Settings lists them.
String screenTouchModeNameIn(AppLocalizations l10n, ScreenTouchMode m) => switch (m) {
      ScreenTouchMode.touch => l10n.settingsScreenTouchModeTouch,
      ScreenTouchMode.mousePointer => l10n.settingsScreenTouchModeMouse,
    };

/// A scaling, as the host editor and Settings list them.
String screenScalingNameIn(AppLocalizations l10n, ScreenScaling s) => switch (s) {
      ScreenScaling.fit => l10n.connectionEditScreenScalingFit,
      ScreenScaling.oneToOne => l10n.connectionEditScreenScalingOneToOne,
      ScreenScaling.remoteResize => l10n.connectionEditScreenScalingRemote,
    };

T _named<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

final screenTouchDefaultProvider =
    NotifierProvider<ScreenTouchDefaultNotifier, ScreenTouchMode>(ScreenTouchDefaultNotifier.new);

class ScreenTouchDefaultNotifier extends Notifier<ScreenTouchMode> {
  @override
  ScreenTouchMode build() => ref.watch(sharedPreferencesProvider).getString(kScreenTouchDefaultKey) == 'mouse'
      ? ScreenTouchMode.mousePointer
      : ScreenTouchMode.touch;

  void set(ScreenTouchMode mode) {
    state = mode;
    unawaited(ref
        .read(sharedPreferencesProvider)
        .setString(kScreenTouchDefaultKey, mode == ScreenTouchMode.mousePointer ? 'mouse' : 'touch'));
  }
}

final screenMenuKeyProvider = NotifierProvider<ScreenMenuKeyNotifier, ScreenMenuKey>(ScreenMenuKeyNotifier.new);

class ScreenMenuKeyNotifier extends Notifier<ScreenMenuKey> {
  @override
  ScreenMenuKey build() =>
      _named(ScreenMenuKey.values, ref.watch(sharedPreferencesProvider).getString(kScreenMenuKeyKey), ScreenMenuKey.f8);

  void set(ScreenMenuKey key) {
    state = key;
    unawaited(ref.read(sharedPreferencesProvider).setString(kScreenMenuKeyKey, key.name));
  }
}

final screenScalingDefaultProvider =
    NotifierProvider<ScreenScalingDefaultNotifier, ScreenScaling>(ScreenScalingDefaultNotifier.new);

class ScreenScalingDefaultNotifier extends Notifier<ScreenScaling> {
  @override
  ScreenScaling build() => _named(
      ScreenScaling.values, ref.watch(sharedPreferencesProvider).getString(kScreenScalingDefaultKey), ScreenScaling.fit);

  void set(ScreenScaling scaling) {
    state = scaling;
    unawaited(ref.read(sharedPreferencesProvider).setString(kScreenScalingDefaultKey, scaling.name));
  }
}

final screenClipboardDefaultProvider =
    NotifierProvider<ScreenClipboardDefaultNotifier, bool>(ScreenClipboardDefaultNotifier.new);

class ScreenClipboardDefaultNotifier extends Notifier<bool> {
  @override
  bool build() => screenOwnClipboardDefault(ref.watch(sharedPreferencesProvider));

  void set(bool on) {
    state = on;
    unawaited(ref.read(sharedPreferencesProvider).setString(kScreenClipboardDefaultKey, on ? 'on' : 'off'));
  }
}

final screenRecordingBehaviourProvider =
    NotifierProvider<ScreenRecordingBehaviourNotifier, ScreenRecordingBehaviour>(ScreenRecordingBehaviourNotifier.new);

class ScreenRecordingBehaviourNotifier extends Notifier<ScreenRecordingBehaviour> {
  @override
  ScreenRecordingBehaviour build() => _named(ScreenRecordingBehaviour.values,
      ref.watch(sharedPreferencesProvider).getString(kScreenRecordingKey), ScreenRecordingBehaviour.cover);

  void set(ScreenRecordingBehaviour b) {
    state = b;
    unawaited(ref.read(sharedPreferencesProvider).setString(kScreenRecordingKey, b.name));
  }
}

/// The screen sessions whose picture is shown while recording mode is on
/// ("Show for this session"), one set for the desktop tab and the phone
/// screen: in memory only, for as long as the session is open, so a new
/// session, or the app started again, is covered again.
final screenShownWhileRecordingProvider = StateProvider<Set<String>>((ref) => const {});

/// Whether a screen's picture is covered now: recording mode on, Settings
/// saying to cover it, and not shown for this session.
bool screenCoveredWhileRecording({required bool recording, required ScreenRecordingBehaviour behaviour, required bool shown}) =>
    recording && behaviour == ScreenRecordingBehaviour.cover && !shown;

/// Whether a remote screen's picture is smoothed where it is not shown at
/// a whole number of this screen's pixels (4.0): per device, off
/// until its person turns it on in a session's panel.
const kScreenSmoothScalingKey = 'screen_smooth_scaling';

final screenSmoothScalingProvider =
    NotifierProvider<ScreenSmoothScalingNotifier, bool>(ScreenSmoothScalingNotifier.new);

class ScreenSmoothScalingNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(sharedPreferencesProvider).getString(kScreenSmoothScalingKey) == 'on';

  void set({required bool on}) {
    state = on;
    unawaited(ref.read(sharedPreferencesProvider).setString(kScreenSmoothScalingKey, on ? 'on' : 'off'));
  }
}

/// Whether a Mac's Command key goes to a remote screen as Ctrl (4.0, step
/// 4): per device, off until its person turns it on in a session's panel.
const kScreenCommandAsControlKey = 'screen_cmd_as_ctrl';

final screenCommandAsControlProvider =
    NotifierProvider<ScreenCommandAsControlNotifier, bool>(ScreenCommandAsControlNotifier.new);

class ScreenCommandAsControlNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(sharedPreferencesProvider).getString(kScreenCommandAsControlKey) == 'on';

  void set({required bool on}) {
    state = on;
    unawaited(ref.read(sharedPreferencesProvider).setString(kScreenCommandAsControlKey, on ? 'on' : 'off'));
  }
}

/// Whether a computer's strip of the remote's displays (the small live
/// pictures on the left, 4.0) is open: per device, open until its
/// person closes it. It is only drawn where there is more than one display.
const kScreenDisplayStripKey = 'screen_display_strip';

final screenDisplayStripOpenProvider =
    NotifierProvider<ScreenDisplayStripOpenNotifier, bool>(ScreenDisplayStripOpenNotifier.new);

class ScreenDisplayStripOpenNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(sharedPreferencesProvider).getString(kScreenDisplayStripKey) != 'closed';

  void set({required bool open}) {
    state = open;
    unawaited(ref.read(sharedPreferencesProvider).setString(kScreenDisplayStripKey, open ? 'open' : 'closed'));
  }
}
