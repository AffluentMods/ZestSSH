// A remote screen's clipboard (4.0), both ways, by these rules:
// on by default for a host of the person's own space, off for a team's host,
// and off for good on a team host whose editor turned "Members may turn the
// clipboard on" off. Whether it is on is this device's choice for each host
// (the device-local preference [screenClipboardPrefKey]), so a session never
// edits the host's record.
//
// The remote's clipboard comes as text the engine took (the extended
// clipboard's UTF-8, or Latin-1), at most [kScreenClipboardMaxBytes]: written
// to this device's clipboard while it is on, recording mode is off and the
// picture is seen (not paused, not behind another tab, the app in front),
// and never into the app's own clipboard history (ClipboardManager), a log or
// the screen. What comes while the picture is not seen is dropped, not kept
// for later: a server cannot swap what the person copied elsewhere just
// before they paste it (found in a security review). This device's goes to the remote only when asked: on a computer
// when the picture takes the keyboard and the clipboard changed since it last
// went, on a phone by "Paste to remote" (a phone never reads its clipboard in
// the background: iOS shows a banner each time an app reads it).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show ScreenSessionLogLines;
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart' show TeamSessionLogs;
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/screen_settings.dart' show screenOwnClipboardDefault;

/// The device-local preference that keeps whether this device shares its
/// clipboard with a host's screen (`on` or `off`; none: the host's default).
/// Settings, Reset all settings clears it.
String screenClipboardPrefKey(String connectionId) => 'screen_clipboard.$connectionId';

/// The most clipboard text taken from a screen or sent to it, in UTF-8
/// bytes: the engine's own cap (packages/zest_native/rust/src/vnc/engine/limits.rs MAX_TEXT).
const int kScreenClipboardMaxBytes = 1024 * 1024;

/// Whether the clipboard is shared with a host's screen on this device: off
/// for good on a team host that is locked; else this device's choice for the
/// host ([deviceChoice], the preference's value), or the host's default
/// ([ScreenOptions.clipboardOnByDefault]: in the person's own space
/// [ownDefault], Settings' "Clipboard on your own hosts", on unless turned
/// off; off in a team; unless its editor set it).
bool screenClipboardOn(ScreenOptions options, {required bool inTeam, String? deviceChoice, bool ownDefault = true}) {
  if (!options.clipboardTogglable(inTeam: inTeam)) return false;
  return switch (deviceChoice) {
    'on' => true,
    'off' => false,
    _ => options.clipboardOnByDefault(inTeam: inTeam, ownDefault: ownDefault),
  };
}

/// [screenClipboardOn] for [connectionId] as this device's preferences hold it.
bool screenClipboardOnFor(SharedPreferences prefs, ScreenOptions options,
        {required bool inTeam, required String? connectionId}) =>
    screenClipboardOn(options,
        inTeam: inTeam,
        deviceChoice: connectionId == null ? null : prefs.getString(screenClipboardPrefKey(connectionId)),
        ownDefault: screenOwnClipboardDefault(prefs));

/// Turns the clipboard on or off for [connectionId] on this device, as its
/// person chose in a screen's tab, and writes it into the team's log of
/// [sessionId] where its vault logs sessions (only that it was turned on or
/// off, never what it held).
Future<void> saveScreenClipboardChoice(SharedPreferences prefs,
    {required String? connectionId, required String sessionId, required bool on}) async {
  TeamSessionLogs.append(sessionId, '${ScreenSessionLogLines.clipboard(on: on)}\n');
  if (connectionId != null) await prefs.setString(screenClipboardPrefKey(connectionId), on ? 'on' : 'off');
}

/// Reads and writes this device's clipboard (tests give their own).
abstract interface class ScreenClipboardIo {
  Future<String?> read();
  Future<void> write(String text);
}

/// The system's clipboard, text only.
class SystemScreenClipboardIo implements ScreenClipboardIo {
  const SystemScreenClipboardIo();

  @override
  Future<String?> read() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<void> write(String text) => Clipboard.setData(ClipboardData(text: text));
}

/// What sending this device's clipboard to the remote did.
enum ScreenClipboardSend {
  /// Sent.
  sent,

  /// Not sent: the same text went (or came) last.
  unchanged,

  /// Nothing to send: the clipboard holds no text.
  empty,

  /// Not sent: over [kScreenClipboardMaxBytes].
  tooLarge,

  /// Not sent: the clipboard is off for this screen (or the view only).
  off,
}

/// The clipboard between this device and one screen session, while a view of
/// it is open.
class ScreenClipboardLink {
  ScreenClipboardLink(
    this.session, {
    required bool on,
    required this.recording,
    this.shown,
    this.onRemoteTooLarge,
    this.io = const SystemScreenClipboardIo(),
  }) : on = ValueNotifier(on) {
    _sub = session.events.listen((e) {
      if (e is ScreenClipboard) unawaited(_fromRemote(e.text));
      // RDP: the remote's text was more than the engine takes and went by.
      if (e is ScreenInfo && e.info['clipboard_too_long'] is num && this.on.value && !_disposed) {
        onRemoteTooLarge?.call();
      }
    });
    // The engine is told too (RDP's clipboard channel asks for the remote's
    // text and offers this device's only while shared; VNC has nothing to do).
    session.shareClipboard(on: on);
    this.on.addListener(_share);
  }

  void _share() {
    if (!_disposed) session.shareClipboard(on: on.value);
  }

  final ScreenSession session;

  /// Whether the clipboard is shared now.
  final ValueNotifier<bool> on;

  /// Whether recording mode is on: the remote's clipboard is not taken then.
  final bool Function() recording;

  /// Whether the picture is seen now (its tab in front, its window shown,
  /// the app in front, nothing covering it); null: whenever the session is
  /// not paused. The remote's clipboard is taken only while it is, and never
  /// while the session is paused.
  final bool Function()? shown;

  /// The remote's clipboard text was too long to take (over
  /// [kScreenClipboardMaxBytes]), while the clipboard is shared: for the view
  /// to say so. (RDP; a VNC engine cuts the text instead.)
  final void Function()? onRemoteTooLarge;

  /// Whether text from the remote may be written into this device's
  /// clipboard now.
  bool get _takesRemote => !session.isPaused && (shown?.call() ?? true);
  final ScreenClipboardIo io;

  late final StreamSubscription<ScreenEvent> _sub;

  /// The text that last went either way, so what came from the remote is not
  /// sent back to it, and the same text not sent twice.
  String? _last;
  bool _disposed = false;

  /// Text the remote's clipboard took.
  Future<void> _fromRemote(String text) async {
    if (_disposed || !on.value || recording() || text.isEmpty || !_takesRemote) return;
    if (utf8.encode(text).length > kScreenClipboardMaxBytes) return;
    _last = text;
    try {
      await io.write(text);
    } catch (_) {
      // A clipboard the system would not take: nothing else to do (and what
      // it held is never logged).
    }
  }

  /// Sends this device's clipboard to the remote: on a computer as the
  /// picture takes the keyboard ([onlyIfChanged]: not the text that last went
  /// either way), on a phone when its person asks.
  Future<ScreenClipboardSend> sendLocal({bool onlyIfChanged = true}) async {
    if (_disposed || !on.value || session.isClosed) return ScreenClipboardSend.off;
    final String? text;
    try {
      text = await io.read();
    } catch (_) {
      return ScreenClipboardSend.empty;
    }
    if (_disposed || !on.value) return ScreenClipboardSend.off;
    if (text == null || text.isEmpty) return ScreenClipboardSend.empty;
    if (utf8.encode(text).length > kScreenClipboardMaxBytes) return ScreenClipboardSend.tooLarge;
    if (onlyIfChanged && text == _last) return ScreenClipboardSend.unchanged;
    _last = text;
    session.sendClipboard(text);
    return ScreenClipboardSend.sent;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _last = null;
    unawaited(_sub.cancel());
    // No view of the screen: nothing is shared (the engine wipes this
    // device's text) until one opens again.
    on.removeListener(_share);
    session.shareClipboard(on: false);
    on.dispose();
  }
}
