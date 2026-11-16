import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// A settings section another surface can deep-link to.
enum SettingsJumpTarget {
  /// Settings > Keyboard and mouse (the Help menu's and the palette's
  /// "Keyboard shortcuts").
  keyboard,

  /// Settings > Security and privacy, as [security] (recording mode is there).
  privacy,

  /// Settings > Security and privacy (the Profile page's "Security settings"
  /// button, a team's notice about the app lock, a host key trusted on first
  /// use).
  security,

  /// Settings > Notifications (the bell's gear).
  notifications,

  /// Settings > Account (the rail's account button and every other way to the
  /// account on desktop).
  account,

  /// Settings > Appearance.
  appearance,

  /// Settings > Plan (4.0).
  plan,

  /// Settings > Terminal and SSH (4.0: the terminal Inspector's "More
  /// appearance settings", whose font and colours are there).
  terminal,

  /// Settings > Files (4.0).
  files,

  /// Settings > Backups and data (4.0).
  data,
}

/// A one-shot request to open a particular settings section: the Help menu's
/// "Keyboard shortcuts" lands on Keyboard (where the bindings live) instead of
/// a read-only cheat-sheet. The settings view consumes the request and clears
/// it, so it fires once.
final settingsJumpProvider = StateProvider<SettingsJumpTarget?>((_) => null);

/// Whether the desktop Settings pop-up is asked for, or open. Setting it to
/// true is how anything opens Settings on a computer: the desktop shell shows
/// the pop-up over whatever is on screen (a terminal stays where it is), and
/// sets this back to false when the pop-up closes.
final settingsPopupOpenProvider = StateProvider<bool>((_) => false);

/// Open the desktop Settings pop-up on [target]: the request is queued for
/// the settings view, then the pop-up is asked for. Whatever is on screen
/// stays there behind it. Returns false on phones and tablets, which have no
/// such pop-up, so the caller pushes its standalone screen instead.
bool jumpToDesktopSettings(WidgetRef ref, SettingsJumpTarget target) {
  if (!desktopShellInUse) return false;
  ref.read(settingsJumpProvider.notifier).state = target;
  ref.read(settingsPopupOpenProvider.notifier).state = true;
  return true;
}
