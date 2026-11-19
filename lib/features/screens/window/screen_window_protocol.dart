// Remote screens (4.0): a screen in a window of its own. That window
// is another engine of the process with its own memory, so everything it
// knows of the session is handed to it as text: what it starts with (the
// payload) and, while it is open, what only the session's owner is told (the
// remote's cursor, its displays, a new size, why it ended). The picture and
// the input do not go this way: the window reads and sends those itself, by
// the session's number (ScreenSession.reader).
//
// Never handed over: the clipboard's text, a password, the host's address or
// name (the window's title and bar name no host, so nothing here needs
// recording mode's masking).
import 'dart:convert';
import 'dart:typed_data';

import 'package:zest_native/screen.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';

/// The payload's `type`, as the editor's windows have "editor".
const kScreenWindowType = 'screen';

/// Main window to a screen's window: one event of the session, as
/// [encodeScreenWindowEvent] writes it.
const kScreenWindowEventMethod = 'screenWindowEvent';

/// A screen's window to the main window: bring the screen back to its tab
/// (its person asked, or the window is closing).
const kScreenWindowBackMethod = 'screenWindowBack';

/// A screen's window to the main window: its picture took the keyboard.
/// The main window, which shares the clipboard for the session, sends this
/// computer's clipboard to the remote then, as a tab does when its picture
/// takes the keyboard. Nothing of the clipboard goes through the window.
const kScreenWindowFocusMethod = 'screenWindowFocus';

/// A screen's window to the main window: its person pastes into the
/// picture (a host whose clipboard goes only then). The main window sends
/// this computer's clipboard to the remote and answers when it has, and the
/// window sends the key after. Nothing of the clipboard goes through the
/// window.
const kScreenWindowPasteMethod = 'screenWindowPaste';

/// A screen's window to the main window: whether it is in front now (true)
/// or not (anything else): its own engine's state, resumed or not. The main
/// window shares the clipboard for a screen in a window only while that
/// window said it is in front, as a tab's is shared only while the app is.
/// A window that never says so is never in front.
const kScreenWindowFrontMethod = 'screenWindowFront';

/// The largest remote cursor taken from the main window, a side.
const kScreenWindowMaxCursorSide = 512;

/// What a screen's window starts with.
class ScreenWindowPayload {
  const ScreenWindowPayload({
    required this.sessionId,
    required this.handle,
    required this.protocol,
    this.info = const {},
    this.menuKey = 'f8',
    this.viewOnly = false,
    this.fit = 'fit',
    this.followViewSize = false,
    this.textScale = 0,
    this.frameLimit = 0,
    this.displayCount = 1,
    this.smoothScaling = false,
    this.commandAsControl = false,
    this.clipboardOnPaste = false,
    this.panelFolded = const [],
    this.displayKeys = const [],
  });

  /// The tab's session in the main window (what "bring it back" names).
  final String sessionId;

  /// The engine's number for the session.
  final int handle;
  final ScreenProtocol protocol;

  /// What the session's ScreenConnected said (its size, its displays).
  final Map<String, Object?> info;

  /// The menu key's name (Settings, Remote screens).
  final String menuKey;

  /// As the tab had them when the window opened.
  final bool viewOnly;
  final String fit;
  final bool followViewSize;
  final int textScale;
  final int frameLimit;
  final int displayCount;
  final bool smoothScaling;
  final bool commandAsControl;

  /// This computer's clipboard goes to the remote only on a paste
  /// (ScreenOptions.clipboardOnPaste): the window asks the main window then.
  final bool clipboardOnPaste;

  /// The groups of the session panel that are folded on this device, by
  /// name: the window's panel opens as the tab's would. It has no settings
  /// store of its own; what is folded there holds while it is open.
  final List<String> panelFolded;

  /// The keys that show displays 1 to 4 as the main window has them (null:
  /// none set); the window has no settings store to read them from. Empty:
  /// the defaults.
  final List<ShortcutKey?> displayKeys;

  Map<String, Object?> toJson() => {
        'type': kScreenWindowType,
        'sessionId': sessionId,
        // Text: the number is 64 bits wide, and JSON's numbers are not.
        'handle': '$handle',
        'protocol': protocol.name,
        'info': info,
        'menuKey': menuKey,
        'viewOnly': viewOnly,
        'fit': fit,
        'followViewSize': followViewSize,
        'textScale': textScale,
        'frameLimit': frameLimit,
        'displayCount': displayCount,
        'smoothScaling': smoothScaling,
        'commandAsControl': commandAsControl,
        'clipboardOnPaste': clipboardOnPaste,
        'panelFolded': panelFolded,
        'displayKeys': [for (final k in displayKeys) k?.toJson()],
      };

  /// The payload [json] holds, or null where it is none of a screen's or
  /// names no session.
  static ScreenWindowPayload? fromJson(Map<String, dynamic> json) {
    if (json['type'] != kScreenWindowType) return null;
    final sessionId = json['sessionId'];
    final handle = int.tryParse('${json['handle']}');
    final protocol = switch (json['protocol']) {
      'rdp' => ScreenProtocol.rdp,
      'vnc' => ScreenProtocol.vnc,
      _ => null,
    };
    if (sessionId is! String || sessionId.isEmpty || handle == null || handle == 0 || protocol == null) return null;
    final info = json['info'];
    int count(Object? v, int min, int max, int otherwise) => v is int && v >= min && v <= max ? v : otherwise;
    return ScreenWindowPayload(
      sessionId: sessionId,
      handle: handle,
      protocol: protocol,
      info: info is Map ? info.cast<String, Object?>() : const {},
      menuKey: json['menuKey'] is String ? json['menuKey'] as String : 'f8',
      viewOnly: json['viewOnly'] == true,
      fit: json['fit'] is String ? json['fit'] as String : 'fit',
      followViewSize: json['followViewSize'] == true,
      textScale: count(json['textScale'], 0, 500, 0),
      frameLimit: count(json['frameLimit'], 0, 240, 0),
      displayCount: count(json['displayCount'], 1, 4, 1),
      smoothScaling: json['smoothScaling'] == true,
      commandAsControl: json['commandAsControl'] == true,
      clipboardOnPaste: json['clipboardOnPaste'] == true,
      panelFolded: [
        if (json['panelFolded'] case final List<dynamic> names)
          for (final n in names.take(16))
            if (n is String && n.length <= 32) n,
      ],
      displayKeys: [
        if (json['displayKeys'] case final List<dynamic> keys)
          for (final k in keys.take(4)) k is Map ? ShortcutKey.fromJson(k.cast<String, dynamic>()) : null,
      ],
    );
  }
}

/// [event] as the main window hands it to a screen's window, or null for
/// one that is not handed over: new pixels (the window finds them itself),
/// the clipboard's text (it stays with the main window), what the server
/// says for the log.
String? encodeScreenWindowEvent(ScreenEvent event) => switch (event) {
      ScreenCursor(:final system) when system => jsonEncode({'k': 'cursor', 'system': true}),
      ScreenCursor() => jsonEncode({
          'k': 'cursor',
          'w': event.width,
          'h': event.height,
          'x': event.hotX,
          'y': event.hotY,
          'rgba': base64Encode(event.rgba),
        }),
      ScreenDisplaysChanged(:final displays) => jsonEncode({
          'k': 'displays',
          'rects': [
            for (final d in displays) [d.x, d.y, d.width, d.height],
          ],
        }),
      ScreenResized(:final width, :final height) => jsonEncode({'k': 'resized', 'w': width, 'h': height}),
      ScreenClosed(:final reason, :final message) =>
        jsonEncode({'k': 'closed', 'reason': reason.name, 'message': message}),
      ScreenBell() => jsonEncode({'k': 'bell'}),
      _ => null,
    };

/// The event [arguments] holds ([encodeScreenWindowEvent]'s text), each
/// value checked; null for anything else.
ScreenEvent? decodeScreenWindowEvent(Object? arguments) {
  if (arguments is! String || arguments.length > 4 * 1024 * 1024) return null;
  final Object? json;
  try {
    json = jsonDecode(arguments);
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  int? whole(Object? v, int max) => v is int && v >= 0 && v <= max ? v : null;
  switch (json['k']) {
    case 'cursor':
      if (json['system'] == true) return ScreenCursor.systemPointer();
      final (w, h) = (whole(json['w'], kScreenWindowMaxCursorSide), whole(json['h'], kScreenWindowMaxCursorSide));
      final (x, y) = (whole(json['x'], 0xffff), whole(json['y'], 0xffff));
      final text = json['rgba'];
      if (w == null || h == null || x == null || y == null || text is! String) return null;
      final Uint8List rgba;
      try {
        rgba = base64Decode(text);
      } on FormatException {
        return null;
      }
      // A hidden cursor has no pixels; any other has exactly its own.
      if (rgba.length != w * h * 4) return null;
      return ScreenCursor(w, h, x, y, rgba);
    case 'displays':
      final rects = ScreenDisplayRect.listFrom(json['rects']);
      return rects.isEmpty ? null : ScreenDisplaysChanged(rects);
    case 'resized':
      final (w, h) = (whole(json['w'], 1 << 16), whole(json['h'], 1 << 16));
      return w == null || h == null || w == 0 || h == 0 ? null : ScreenResized(w, h);
    case 'closed':
      final name = json['reason'];
      final message = json['message'];
      final reason = ScreenCloseReason.values.where((r) => r.name == name).firstOrNull ?? ScreenCloseReason.internal;
      return ScreenClosed(reason, message is String ? message : '');
    case 'bell':
      return const ScreenBell();
    default:
      return null;
  }
}
