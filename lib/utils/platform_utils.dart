import 'dart:io' show Directory, Platform;

import 'package:flutter/widgets.dart' show BuildContext, MediaQuery, Size;

/// Whether the app is running on a desktop platform (Windows, macOS, Linux).
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Whether the app is running on a mobile platform (Android, iOS).
bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;

/// A test's stand-in for [isTouchLayout]: true draws the phone's and the
/// tablet's look on a computer, false a computer's. Null in the app.
bool? debugTouchLayout;

/// Whether the app's screens are the phone's and the tablet's (the 3.0 quick
/// wins: monospace for values only, chips only for filters and what needs
/// someone, no Delete on a list row, problems first). A computer keeps its
/// own look in every screen it shares with them.
bool get isTouchLayout => debugTouchLayout ?? !isDesktopPlatform;

/// The large screen's size (4.0):
/// a phone or a tablet whose shortest side is 600 or more and which is 840
/// or more wide has the computer's shell, at touch size; below that it has
/// the phone's tabs exactly, a small tablet held upright included.
const double kLargeScreenShortestSide = 600;

/// See [kLargeScreenShortestSide].
const double kLargeScreenWidth = 840;

/// Whether a phone's or a tablet's screen of [size] is a large screen.
bool isLargeScreen(Size size) =>
    size.shortestSide >= kLargeScreenShortestSide && size.width >= kLargeScreenWidth;

/// Whether Home is the computer's shell here: on a computer always; on a
/// phone or a tablet while its screen is a large screen ([isLargeScreen]).
/// Turning the device can change it.
bool usesDesktopShell(BuildContext context) => !isTouchLayout || isLargeScreen(MediaQuery.sizeOf(context));

/// How many of the computer's shells stand on a phone's or a tablet's screen
/// (0 or 1): DesktopShell counts itself there while it is up.
int touchDesktopShells = 0;

/// Whether the computer's shell is the one in use, for what has no screen to
/// ask ([usesDesktopShell]): on a computer always; on a phone or a tablet
/// while the shell stands there. A page opened, a session started, Settings
/// asked for, go where it shows them (a tab, its pop-up) and not to a
/// phone's page.
bool get desktopShellInUse => !isTouchLayout || touchDesktopShells > 0;

/// The directory a "import an SSH key / config / certificate" file picker
/// should open in: the user's `~/.ssh` if it exists, else their home
/// directory, else null (let the OS decide).
///
/// Keys almost always live in `~/.ssh`, so opening there saves the user from
/// navigating home -> reveal-hidden-files every time. Desktop only:
/// file_picker ignores `initialDirectory` on mobile, and mobile has no
/// user-facing `~/.ssh`. Never throws - a sandbox or permission error just
/// falls through to null.
String? defaultSshPickerDirectory() {
  if (!isDesktopPlatform) return null;
  final env = Platform.environment;
  var home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  if ((home == null || home.isEmpty) && Platform.isWindows) {
    final drive = env['HOMEDRIVE'];
    final rest = env['HOMEPATH'];
    if (drive != null && rest != null) home = '$drive$rest';
  }
  if (home == null || home.isEmpty) return null;
  final ssh = '$home${Platform.pathSeparator}.ssh';
  try {
    if (Directory(ssh).existsSync()) return ssh;
    if (Directory(home).existsSync()) return home;
  } catch (_) {/* sandbox / perms - let the OS pick */}
  return null;
}
