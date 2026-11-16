// Remote screens (4.0): a screen in a window of its own, the window's
// side. Another engine of the process, with its own memory: it reads the
// session's picture and drives it by the session's number
// (ScreenSession.reader), is handed what only the owner is told
// (screen_window_protocol.dart), and never ends the session. Its bar names no
// host. The menu key opens the session panel here too, with what a window
// can do by itself (the scaling, view only, the keys to send, text size, the
// frame rate limit, smooth scaling, the remote's displays, full screen on
// the monitor the window is on). The clipboard, the files, relative mouse,
// the session's details and ending the session stay with the tab in the
// main window.
import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart' show WindowController;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/hints/screen_held_line.dart';
import 'package:zestssh/features/screens/menu/screen_session_panel.dart';
import 'package:zestssh/features/screens/menu/screen_text_size.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart' show EditorWindowBackend, kMainWindowId;
import 'package:zestssh/ui/widgets/pop_out_window_guard.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart';

/// What answers the main window's calls in a screen's window
/// ([ScreenWindowHome] registers itself here), by window id.
final Map<int, Future<Object?> Function(String method, Object? arguments)> screenWindowHandlers = {};

/// A call from the main window to screen window [windowId]; null where it
/// shows no screen (yet).
Future<Object?> answerScreenWindowCall(
  int windowId,
  String method,
  Object? arguments, {
  int from = kMainWindowId,
}) async =>
    // Only the main window speaks for a session: what another window of
    // the app sends under this name is not heard.
    from == kMainWindowId ? screenWindowHandlers[windowId]?.call(method, arguments) : null;

/// The app of a screen's window, from what the main window handed it
/// ([payload], with [raw] holding the language and the theme), reaching the
/// main window through [backend].
Widget screenWindowApp({
  required int windowId,
  required ScreenWindowPayload payload,
  required Map<String, dynamic> raw,
  required EditorWindowBackend backend,
  required ValueListenable<bool> locked,
  required VoidCallback onActivity,
  ScreenNative? native,
  ScreenTileDecoder? decodeTile,
  Future<void> Function(bool fullScreen)? setFullScreen,
}) =>
    ProviderScope(
      overrides: [
        // The panel keeps its folded groups in the profile's settings; this
        // window has no settings store, so here they are kept in memory,
        // starting as the main window has them.
        screenPanelFoldedProvider.overrideWith(() => ScreenWindowPanelFolds(payload.panelFolded)),
      ],
      child: secondaryWindowApp(
        title: ScreenWindows.title,
        localeName: raw['locale'] as String?,
        theme: raw['theme'],
        accent: raw['accent'] as int?,
        // The app lock covers all of the window: its picture, and the
        // session panel or a question open over it, which act on the
        // session and were still within reach under a cover that lay
        // beneath them.
        over: (context, child) => PopOutWindowGuard(locked: locked, onActivity: onActivity, child: child),
        home: ScreenWindowHome(
          windowId: windowId,
          payload: payload,
          backend: backend,
          locked: locked,
          onActivity: onActivity,
          native: native,
          decodeTile: decodeTile,
          setFullScreen: setFullScreen,
        ),
      ),
    );

/// The session panel's folded groups in a screen's window: as the main
/// window handed them, changed in memory only.
class ScreenWindowPanelFolds extends ScreenPanelFoldedNotifier {
  ScreenWindowPanelFolds(this.names);

  final List<String> names;

  @override
  Set<ScreenActionGroup> build() => {
        for (final g in ScreenActionGroup.values)
          if (names.contains(g.name)) g,
      };

  @override
  void toggle(ScreenActionGroup g) => state = state.contains(g) ? ({...state}..remove(g)) : {...state, g};
}

class ScreenWindowHome extends StatefulWidget {
  const ScreenWindowHome({
    super.key,
    required this.windowId,
    required this.payload,
    required this.backend,
    required this.locked,
    required this.onActivity,
    this.native,
    this.decodeTile,
    this.setFullScreen,
  });

  final int windowId;
  final ScreenWindowPayload payload;
  final EditorWindowBackend backend;
  final ValueListenable<bool> locked;
  final VoidCallback onActivity;

  /// The engine, for tests.
  final ScreenNative? native;
  final ScreenTileDecoder? decodeTile;

  /// Makes this window fill its monitor or a window again (the window
  /// plugin's call unless a test gives another).
  final Future<void> Function(bool fullScreen)? setFullScreen;

  @override
  State<ScreenWindowHome> createState() => _ScreenWindowHomeState();
}

class _ScreenWindowHomeState extends State<ScreenWindowHome> {
  late final ScreenSession _session;
  late final ScreenController _c;
  late final ScreenMenuKey _menuKey;
  StreamSubscription<ScreenEvent>? _events;
  bool _backAsked = false;

  // The picture's keyboard focus: taking it is said to the main window,
  // which sends this computer's clipboard to the remote where it is shared.
  final _focus = FocusNode(debugLabel: 'screen-window');
  bool _hadFocus = false;

  void _onFocus() {
    final has = _focus.hasFocus;
    if (has && !_hadFocus && !_c.viewOnly && !_session.isClosed) {
      unawaited(widget.backend
          .invoke(kMainWindowId, kScreenWindowFocusMethod, widget.payload.sessionId)
          .catchError((Object _) => null));
    }
    _hadFocus = has;
  }

  // The app locked: the keys and buttons held are let go and nothing of
  // the picture is read here until it is unlocked, then the whole picture
  // first. (Whether the server sends meanwhile is the main window's to
  // say. The cover itself is over everything the window shows:
  // screenWindowApp.)
  void _onLock() {
    if (widget.locked.value) {
      _c.pause();
    } else {
      _c.resume();
    }
  }

  // Whether this window is in front (its engine resumed), said to the main
  // window at the start and at every change: the clipboard is shared for
  // this screen only while it is.
  AppLifecycleListener? _life;
  bool? _saidFront;

  void _tellFront(AppLifecycleState? state) {
    final front = state == AppLifecycleState.resumed;
    if (front == _saidFront) return;
    _saidFront = front;
    unawaited(widget.backend.invoke(kMainWindowId, kScreenWindowFrontMethod, front).catchError((Object _) => null));
  }

  // Full screen on the monitor the window is on: the bar is hidden then, and
  // a line says for a few seconds which key opens the menu.
  bool _fullScreen = false;
  bool _fullScreenHint = false;
  Timer? _hintTimer;

  /// How long the line about the menu key stays.
  static const _hintStays = Duration(seconds: 5);

  Future<void> _setFullScreen(bool on) async {
    if (on == _fullScreen) return;
    final set = widget.setFullScreen ?? WindowController.fromWindowId(widget.windowId).setFullScreen;
    try {
      await set(on);
    } catch (_) {
      // The window could not change: it stays as it is, bar and all.
      return;
    }
    if (!mounted) return;
    _hintTimer?.cancel();
    setState(() {
      _fullScreen = on;
      _fullScreenHint = on;
    });
    if (on) {
      _hintTimer = Timer(_hintStays, () {
        if (mounted) setState(() => _fullScreenHint = false);
      });
    }
    if (_menuOpen) _menu.value = _menuState();
  }

  // The session panel of this window.
  final _menu = ValueNotifier<ScreenMenuState>(const ScreenMenuState(offered: {}));
  bool _menuOpen = false;

  bool get _rdp => widget.payload.protocol == ScreenProtocol.rdp;
  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  ScreenMenuState _menuState() => ScreenMenuState.of(
        phone: false,
        fit: _c.fit,
        viewOnly: _c.viewOnly,
        fullScreen: _fullScreen,
        // Every key is the remote's here: there is no keyboard to give back.
        keyboardHeld: false,
        canResizeRemote: _rdp,
        resizingRemote: _c.followViewSize,
        textSizeOffered: _rdp,
        smoothScaling: _c.smoothScaling,
        commandKeyOffered: _mac,
        commandAsControl: _c.keyboard.commandAsControl,
        inOwnWindow: true,
      );

  void _onController() {
    if (_menuOpen) _menu.value = _menuState();
  }

  Future<void> _openMenu() async {
    if (_menuOpen || !mounted || _session.isClosed) return;
    _menuOpen = true;
    _menu.value = _menuState();
    await showScreenPanel(
      context,
      state: _menu,
      onAction: (a) => unawaited(_act(a)),
      menuKey: _menuKey,
      displays: _c.displays,
      onDisplay: _c.showDisplay,
    );
    _menuOpen = false;
  }

  /// Does [a] for this window's view of the session. What it does not
  /// offer does nothing (a menu drawn a moment ago may still show it).
  Future<void> _act(ScreenAction a) async {
    if (!_menuState().enabled(a)) return;
    if (a.sendsKeys) {
      _c.keyboard.sendChord(a.keysWith(_menuKey));
    } else if (a.fitMode != null) {
      _c
        ..fit = a.fitMode!
        ..followViewSize = false;
    } else {
      switch (a) {
        case ScreenAction.remoteResize:
          _c
            ..fit = ScreenFit.fit
            ..followViewSize = true;
        case ScreenAction.viewOnly:
          _c.viewOnly = !_c.viewOnly;
          // The bar has Ctrl+Alt+Del only while keys are sent.
          if (mounted) setState(() {});
        case ScreenAction.fullScreen:
          await _setFullScreen(!_fullScreen);
        case ScreenAction.refresh:
          _session.fullRefresh();
        case ScreenAction.smoothScaling:
          // For this window while it is open; the device's choice is the tab's.
          _c.smoothScaling = !_c.smoothScaling;
        case ScreenAction.commandAsControl:
          _c.keyboard.commandAsControl = !_c.keyboard.commandAsControl;
        case ScreenAction.textSize:
          final picked = await showScreenTextSizeQuestion(context, current: _c.textScale);
          if (picked != null && mounted) _c.setTextScale(picked);
        case ScreenAction.frameLimit:
          final picked = await showScreenFrameLimitQuestion(context, current: _c.frameLimit);
          if (picked != null && mounted) _c.frameLimit = picked;
        default:
      }
    }
    if (_menuOpen) _menu.value = _menuState();
  }

  @override
  void initState() {
    super.initState();
    final p = widget.payload;
    _menuKey = ScreenMenuKey.values.where((k) => k.name == p.menuKey).firstOrNull ?? ScreenMenuKey.f8;
    _session = ScreenSession.reader(p.handle, protocol: p.protocol, info: p.info, native: widget.native);
    _c = ScreenController(_session, decodeTile: widget.decodeTile)
      ..fit = ScreenFit.values.where((f) => f.name == p.fit).firstOrNull ?? ScreenFit.fit
      ..displayCount = p.displayCount
      ..textScale = p.textScale
      ..frameLimit = p.frameLimit
      ..smoothScaling = p.smoothScaling
      ..followViewSize = p.followViewSize
      ..viewOnly = p.viewOnly;
    _c.keyboard.commandAsControl = p.commandAsControl;
    _c.addListener(_onController);
    // (Said before the picture can take the keyboard, so the two arrive in order.)
    widget.locked.addListener(_onLock);
    if (widget.locked.value) _c.pause();
    _tellFront(WidgetsBinding.instance.lifecycleState);
    _life = AppLifecycleListener(onStateChange: _tellFront);
    _focus.addListener(_onFocus);
    // The session ended (the main window said why, or it is simply gone):
    // nothing to show here, the tab in the main window says how it ended.
    _events = _session.events.listen((e) {
      if (e is ScreenClosed) _back();
    });
    if (_session.isClosed) scheduleMicrotask(_back);
    screenWindowHandlers[widget.windowId] = _onCall;
  }

  @override
  void dispose() {
    if (screenWindowHandlers[widget.windowId] == _onCall) screenWindowHandlers.remove(widget.windowId);
    unawaited(_events?.cancel());
    _hintTimer?.cancel();
    widget.locked.removeListener(_onLock);
    _life?.dispose();
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _c.removeListener(_onController);
    _c.dispose();
    _menu.dispose();
    // Its view goes; the session is the main window's.
    _session.close();
    super.dispose();
  }

  Future<Object?> _onCall(String method, Object? arguments) async {
    if (method == kScreenWindowEventMethod) {
      final event = decodeScreenWindowEvent(arguments);
      if (event != null) _session.relayed(event);
    }
    return '';
  }

  /// Asks the main window to take the screen back into its tab; it closes
  /// this window.
  void _back() {
    if (_backAsked) return;
    _backAsked = true;
    unawaited(widget.backend
        .invoke(kMainWindowId, kScreenWindowBackMethod, widget.payload.sessionId)
        .catchError((Object _) => null));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
        backgroundColor: AppColors.screenLetterbox,
        body: Column(
          children: [
            // Full screen: the picture alone. The menu key is the way to everything.
            if (!_fullScreen)
            _ScreenWindowBar(
              onBack: _back,
              onFullScreen: () => unawaited(_setFullScreen(true)),
              onMenu: () => unawaited(_openMenu()),
              menuLabel: l10n.screenMenuTooltipKey(_menuKey.label),
              fullScreenLabel: l10n.screenFullScreen,
              onCtrlAltDel: _c.viewOnly
                  ? null
                  : () => _c.keyboard.sendChord(ScreenAction.sendCtrlAltDel.keysWith(_menuKey)),
              backLabel: l10n.screenBringBack,
              ctrlAltDelLabel: l10n.screenSendCtrlAltDel,
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ScreenView(
                    key: const ValueKey('screen-window-view'),
                    controller: _c,
                    focusNode: _focus,
                    onMenuKey: () => unawaited(_openMenu()),
                    menuKey: _menuKey.logical,
                  ),
                  if (_fullScreenHint)
                    ScreenHeldLine(
                      key: const ValueKey('screen-window-full-screen-hint'),
                      text: l10n.screenWindowFullScreenHint(_menuKey.label),
                      keyLabel: _menuKey.label,
                    ),
                ],
              ),
            ),
          ],
        ),
    );
  }
}

/// The window's bar: the way back to the tab on the left; on the right the
/// one key combination a computer keeps for itself, full screen, and the
/// screen options (as the menu key opens them), as the tab's toolbar has them.
class _ScreenWindowBar extends StatelessWidget {
  const _ScreenWindowBar({
    required this.onBack,
    required this.onCtrlAltDel,
    required this.onFullScreen,
    required this.onMenu,
    required this.backLabel,
    required this.ctrlAltDelLabel,
    required this.fullScreenLabel,
    required this.menuLabel,
  });

  final VoidCallback onBack;
  final VoidCallback? onCtrlAltDel;
  final VoidCallback onFullScreen;
  final VoidCallback onMenu;
  final String backLabel;
  final String ctrlAltDelLabel;
  final String fullScreenLabel;
  final String menuLabel;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      foregroundColor: ZestColors.textPrimary,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 30),
      textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12.5),
    );
    Widget icon(String key, IconData glyph, String tip, VoidCallback? onTap) => IconButton(
          key: ValueKey(key),
          tooltip: tip,
          onPressed: onTap,
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          padding: EdgeInsets.zero,
          color: ZestColors.textPrimary,
          disabledColor: ZestColors.textMuted,
          icon: Icon(glyph),
        );
    return Container(
      key: const ValueKey('screen-window-bar'),
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(bottom: BorderSide(color: ZestColors.borderDefault)),
      ),
      // The way back gives way in a narrow window (its words end in dots and
      // its tooltip says them whole) before the bar would overflow.
      child: Row(
        children: [
          Flexible(
            child: Tooltip(
              message: backLabel,
              child: TextButton.icon(
                key: const ValueKey('screen-window-back'),
                style: style,
                onPressed: onBack,
                icon: const Icon(LucideIcons.arrowLeftToLine, size: 15),
                label: Text(backLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          const Spacer(),
          if (onCtrlAltDel != null)
            icon('screen-window-ctrl-alt-del', ScreenAction.sendCtrlAltDel.icon, ctrlAltDelLabel, onCtrlAltDel),
          icon('screen-window-full-screen', LucideIcons.expand, fullScreenLabel, onFullScreen),
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: ZestColors.borderDefault,
          ),
          icon('screen-window-menu', LucideIcons.slidersHorizontal, menuLabel, onMenu),
        ],
      ),
    );
  }
}
