// Remote screens (4.0) on computers: a screen's tab (or its pane of a split).
// Its picture (ScreenView) under a slim toolbar; the host's saved scaling and
// view only applied as it opens. While the picture has the focus every key
// goes to the remote, the app's shortcuts too; F8 opens the screen menu and
// lets go of the keyboard. A tab not in front, a window hidden or minimized,
// the pane gone (another section shown), and recording mode's cover pause
// the screen: the server sends nothing until it is seen again, then the whole
// picture. Connecting, dropped and ended are the terminal's own views (the
// terminal area shows them before this pane).
//
// The clipboard (screen_clipboard.dart): the remote's comes to this computer
// while it is shared and recording mode is off; this computer's goes to the
// remote as the picture takes the keyboard, if it changed since it last went.
// The toolbar's switch keeps this computer's choice for the host.
import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zest_native/screen.dart' show ScreenProtocol, ScreenSession;
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/session/screen_clipboard.dart';
import 'package:zestssh/features/screens/session/screen_round_trip.dart';
import 'package:zestssh/features/screens/details/screen_session_details.dart';
import 'package:zestssh/features/screens/displays/screen_display_bars.dart';
import 'package:zestssh/features/screens/hints/screen_held_line.dart';
import 'package:zestssh/features/screens/hints/screen_hint.dart';
import 'package:zestssh/features/screens/menu/screen_text_size.dart';
import 'package:zestssh/features/screens/menu/screen_session_panel.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_display_preview.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_privacy_cover.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/window_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart' show confirmDisconnectSession;
import 'package:zestssh/ui/widgets/redacted_text.dart' show RedactableDisplay;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform;

import 'screen_menu.dart';
import 'screen_toolbar.dart';

/// The scaling a host's saved option starts the tab in. "Resize the remote"
/// fits until VNC servers that resize are supported (a later step).
ScreenFit screenFitOf(ScreenScaling s) => switch (s) {
      ScreenScaling.fit || ScreenScaling.remoteResize => ScreenFit.fit,
      ScreenScaling.oneToOne => ScreenFit.oneToOne,
    };

class ScreenPane extends ConsumerStatefulWidget {
  const ScreenPane({
    super.key,
    required this.sessionId,
    required this.sessionState,
    this.leafId,
    this.front = false,
    this.visible = true,
  });

  final String sessionId;
  final SessionState sessionState;

  /// The pane of the split it is in, if it is in one.
  final String? leafId;

  /// The keyboard's: the tab in front, or its pane in focus in a split.
  final bool front;

  /// On screen: the tab in front (in a split, the one its pane shows, with
  /// or without the focus). Kept behind another, it is paused.
  final bool visible;

  /// Turns tiles into images in widget tests (which have no engine thread).
  @visibleForTesting
  static ScreenTileDecoder? debugDecodeTile;

  /// This computer's clipboard, for widget tests.
  @visibleForTesting
  static ScreenClipboardIo? debugClipboard;

  @override
  ConsumerState<ScreenPane> createState() => _ScreenPaneState();
}

class _ScreenPaneState extends ConsumerState<ScreenPane> {
  final _focus = FocusNode(debugLabel: 'remote screen');
  late final AppLifecycleListener _life;
  bool _windowHidden = false;

  ScreenController? _c;
  ScreenSession? _session;
  ScreenClipboardLink? _clip;

  /// The person's choices in this tab, kept across a reconnect; the host's
  /// saved ones until they change them.
  ScreenFit? _fit;

  /// An RDP screen whose remote takes the tab's size ("Resize the remote",
  /// the host's saved scaling, or picked here); null until its session is
  /// there.
  bool? _resizeRemote;
  bool? _viewOnly;

  /// The zoom and pan of the view, given to the view of the same screen once
  /// it is connected again.
  ScreenControllerKept? _kept;

  bool _covered = false;

  // The remote's sound for this tab: its person's switch, kept across a
  // reconnect (the new session is told).
  bool _soundWanted = true;
  bool _menuOpen = false;

  /// The session's details are shown over the picture (4.0).
  bool _details = false;

  /// Whether this computer can hold the pointer for relative mouse (asked
  /// once of its own part; false until it has answered).
  bool _pointerHoldHere = false;

  /// The frame rate limit of this tab: the host's until one is picked here.
  int? _frameLimit;

  /// This computer is a Mac: its Command key can go to the remote as Ctrl.
  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  // What the session offers, for the panel while it is open (it is drawn
  // from this as it changes); whether the picture had the keyboard when the
  // panel opened; and the last thing picked in it.
  final _menuNotifier = ValueNotifier<ScreenMenuState>(const ScreenMenuState(offered: {}));
  bool _heldAtOpen = false;
  ScreenAction? _pickedInPanel;

  @override
  void initState() {
    super.initState();
    final now = WidgetsBinding.instance.lifecycleState;
    _windowHidden = now == AppLifecycleState.hidden || now == AppLifecycleState.paused;
    _life = AppLifecycleListener(
      onHide: () => _setWindowHidden(true),
      onShow: () => _setWindowHidden(false),
    );
    WindowService.fullscreen.addListener(_onFullscreen);
    _focus.addListener(_onFocus);
    ScreenWindows.instance.shown.addListener(_onOwnWindows);
    // The picture of its own window took the keyboard: this computer's
    // clipboard goes to the remote, as when the tab's picture takes it.
    ScreenWindows.instance.onWindowFocus(widget.sessionId, () {
      if (!mounted || !_inOwnWindow || _covered || (_viewOnly ?? false)) return;
      unawaited(_clip?.sendLocal());
    });
  }

  /// This screen is shown in a window of its own now (4.0): the
  /// tab says so in the picture's place and takes no frames.
  bool get _inOwnWindow => ScreenWindows.instance.isShown(widget.sessionId);

  void _onOwnWindows() {
    if (!mounted) return;
    final there = _inOwnWindow;
    if (_c?.idle == there) return;
    _c?.idle = there;
    setState(() {});
    if (!there && widget.front) _takeKeyboardSoon();
  }

  /// Moves the screen to a window of its own, with the choices it has here.
  Future<void> _openOwnWindow() async {
    final shell = _shell;
    final session = _session;
    final c = _c;
    if (shell == null || session == null || c == null || _covered) return;
    final several = c.displays.value.list;
    final opened = await ScreenWindows.instance.open(
      session,
      ScreenWindowPayload(
        sessionId: widget.sessionId,
        handle: session.handle,
        protocol: shell.protocol,
        // What the picture is now, not what the server said when it
        // connected; nothing of the server's name.
        info: {
          'protocol': shell.protocol.name,
          'width': c.desktopWidth > 0 ? c.desktopWidth : c.width,
          'height': c.desktopHeight > 0 ? c.desktopHeight : c.height,
          if (several.length > 1)
            'displays': [
              for (final d in several) [d.x, d.y, d.width, d.height],
            ],
        },
        menuKey: ref.read(screenMenuKeyProvider).name,
        viewOnly: c.viewOnly,
        fit: c.fit.name,
        followViewSize: c.followViewSize,
        textScale: c.textScale,
        frameLimit: c.frameLimit,
        displayCount: c.displayCount,
        smoothScaling: c.smoothScaling,
        commandAsControl: c.keyboard.commandAsControl,
        panelFolded: [for (final g in ref.read(screenPanelFoldedProvider)) g.name],
      ),
    );
    if (!opened && mounted) showTopSnackBar(context, AppLocalizations.of(context)!.screenOwnWindowFailed);
  }

  /// The picture took the keyboard: this computer's clipboard goes to the
  /// remote if it changed since it last went (not in view only, not under
  /// recording mode's cover, which takes the keyboard away anyway).
  void _onFocus() {
    if (!_focus.hasFocus || _covered || (_viewOnly ?? false)) return;
    unawaited(_clip?.sendLocal());
  }

  void _setWindowHidden(bool hidden) {
    _windowHidden = hidden;
    _sync();
  }

  void _onFullscreen() {
    if (mounted) setState(() {});
  }

  ScreenShellService? get _shell {
    final s = widget.sessionState.session?.shell;
    return s is ScreenShellService ? s : null;
  }

  /// A controller for the session the shell has now (a reconnect brings
  /// another one).
  void _attach() {
    final shell = _shell;
    final session = shell?.session;
    if (identical(session, _session)) return;
    _detach();
    _session = session;
    if (session == null || shell == null) return;
    final c = ScreenController(session, decodeTile: ScreenPane.debugDecodeTile)
      ..measureRoundTrip = screenRoundTripOf(shell)
      ..soundWanted = _soundWanted;
    _clip = ScreenClipboardLink(
      session,
      on: screenClipboardOnFor(ref.read(sharedPreferencesProvider), shell.options,
          inTeam: shell.inTeam, connectionId: shell.connectionId),
      recording: () => mounted && ref.read(recordingModeProvider),
      // Seen: this tab in front, the window shown and in front, nothing over
      // it; or its picture in a window of its own while that window is in
      // front by its own word, whatever the main window shows (recording
      // mode's cover brings it back here). A window behind another program,
      // or minimised, takes nothing from the remote's clipboard.
      shown: () =>
          mounted &&
          !_covered &&
          (_inOwnWindow
              ? ScreenWindows.instance.isFront(widget.sessionId)
              : (widget.visible &&
                  !_windowHidden &&
                  WidgetsBinding.instance.lifecycleState != AppLifecycleState.inactive)),
      onRemoteTooLarge: () {
        if (mounted) showTopSnackBar(context, AppLocalizations.of(context)!.screenClipboardRemoteTooLarge);
      },
      io: ScreenPane.debugClipboard ?? const SystemScreenClipboardIo(),
    );
    c.fit = _fit ??= screenFitOf(shell.options.scaling);
    // The details stay shown across a reconnect: the new session is sampled.
    c.detailsShown = _details;
    // Whether this computer can hold the pointer, for the panel's switch.
    unawaited(c.hold.capture.available().then((here) {
      if (mounted && here != _pointerHoldHere) setState(() => _pointerHoldHere = here);
    }));
    // RDP: how many displays the host asks for (4.0), so a view that
    // follows its size asks for that many at the new size.
    c.displayCount = shell.protocol == ScreenProtocol.rdp ? shell.options.displayCount : 1;
    c.textScale = shell.protocol == ScreenProtocol.rdp ? shell.options.textScale : 0;
    // The limit picked here before stays across a reconnect; else the host's.
    c.frameLimit = _frameLimit ??= shell.options.frameLimit;
    c.keyboard.commandAsControl = _mac && ref.read(screenCommandAsControlProvider);
    c.smoothScaling = ref.read(screenSmoothScalingProvider);
    // RDP: the remote's screen follows the tab's size where the host says so
    // (or it was picked here before), shown fitted until it has.
    c.followViewSize = _resizeRemote ??=
        shell.protocol == ScreenProtocol.rdp && shell.options.scaling == ScreenScaling.remoteResize;
    c.onResizeUnavailable = () {
      if (!mounted) return;
      setState(() => _resizeRemote = false);
      showTopSnackBar(context, AppLocalizations.of(context)!.screenResizeUnavailable);
    };
    c.viewOnly = _viewOnly ??= shell.options.viewOnly;
    // Shown in a window of its own (the area was left and come back to
    // meanwhile): this view takes nothing, and does not stop the server.
    c.idle = _inOwnWindow;
    final kept = _kept;
    if (kept != null) c.restore(kept);
    _c = c;
    // Paused by a view of it that went (the area left for another section
    // and come back to): its whole picture again.
    if (session.isPaused) session.resume();
    _sync();
    if (widget.front) _takeKeyboardSoon();
  }

  void _detach() {
    _clip?.dispose();
    _clip = null;
    final c = _c;
    if (c == null) return;
    if (c.viewport.hasRemote) _kept = c.kept();
    // Nobody sees it now: the server stops sending until a view comes back.
    c.pause();
    c.dispose();
    _c = null;
  }

  /// Paused unless it is seen.
  void _sync() {
    final c = _c;
    if (c == null) return;
    if (widget.visible && !_windowHidden && !_covered) {
      c.resume();
    } else {
      c.pause();
    }
  }

  @override
  void didUpdateWidget(ScreenPane old) {
    super.didUpdateWidget(old);
    _attach();
    if (old.visible != widget.visible) _sync();
    if (widget.front && !old.front) _takeKeyboardSoon();
  }

  /// The keyboard to the picture, once this frame is laid out: not under a
  /// dialog or the menu, not while it is covered.
  void _takeKeyboardSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.front || _covered || _menuOpen || _c == null) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    WindowService.fullscreen.removeListener(_onFullscreen);
    _focus.removeListener(_onFocus);
    ScreenWindows.instance.shown.removeListener(_onOwnWindows);
    ScreenWindows.instance.onWindowFocus(widget.sessionId, null);
    _life.dispose();
    _detach();
    _focus.dispose();
    _menuNotifier.dispose();
    super.dispose();
  }

  // The menu and the actions.

  /// Opens the session panel (4.0): on the menu key, which never
  /// reaches the remote, and from the bar's last button ([fromBar]). While it
  /// is open the keyboard is the panel's. A switch or a choice keeps it open
  /// and it shows the new state; an action done once closes it first.
  Future<void> _openMenu({bool fromBar = false}) async {
    if (_menuOpen || !mounted) return;
    // The picture had the keyboard (the menu key is only heard while it has):
    // it gets it back when the panel closes.
    final held = _focus.hasFocus || !fromBar;
    _heldAtOpen = held;
    _pickedInPanel = null;
    setState(() => _menuOpen = true);
    _menuNotifier.value = _menuState(keyboardHeld: held);
    final c = _c;
    await showScreenPanel(
      context,
      state: _menuNotifier,
      onAction: (a) {
        _pickedInPanel = a;
        unawaited(_act(a));
      },
      menuKey: ref.read(screenMenuKeyProvider),
      displays: c?.displays,
      onDisplay: c?.showDisplay,
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    // Closed: the keyboard back where it was, unless what was picked last let
    // go of it (Release the keyboard) or asks a question of its own
    // (Disconnect), which has the keyboard now.
    final last = _pickedInPanel;
    if (held && last != ScreenAction.releaseKeyboard && last != ScreenAction.disconnect) _takeKeyboardSoon();
  }

  /// Whether this screen's clipboard can be turned on or off here: not
  /// before it is connected, nor on a team host whose editor locked it off.
  bool get _clipboardTogglable =>
      _clip != null && (_shell?.options.clipboardTogglable(inTeam: _shell?.inTeam ?? false) ?? false);

  /// What this session offers now, for whatever draws its menu.
  ScreenMenuState _menuState({bool? keyboardHeld}) => ScreenMenuState.of(
        phone: false,
        fit: _fit ?? ScreenFit.fit,
        viewOnly: _viewOnly ?? false,
        fullScreen: WindowService.fullscreen.value,
        keyboardHeld: keyboardHeld ?? _focus.hasFocus,
        canResizeRemote: _shell?.protocol == ScreenProtocol.rdp,
        resizingRemote: _resizeRemote ?? false,
        clipboardTogglable: _clipboardTogglable,
        clipboardOn: _clip?.on.value ?? false,
        detailsShown: _details,
        filesOffered: _shell?.carrier != null,
        relativeAsked: _shell?.protocol == ScreenProtocol.rdp && (_shell?.options.relativeMouse ?? false),
        relativeTaken: _c?.relativeTaken ?? false,
        relativeHere: _pointerHoldHere,
        relativeOn: _c?.relativeMouse ?? false,
        textSizeOffered: _shell?.protocol == ScreenProtocol.rdp,
        commandKeyOffered: _mac,
        commandAsControl: _mac && ref.read(screenCommandAsControlProvider),
        smoothScaling: ref.read(screenSmoothScalingProvider),
        // Not while recording mode covers the picture: a window would show it.
        ownWindowOffered: isDesktopPlatform && !_covered,
        covered: _covered,
        soundAsked: _shell?.protocol == ScreenProtocol.rdp && (_shell?.options.soundOn(phone: false) ?? false),
        soundHere: _c?.soundUnavailable == null,
        soundOn: _soundWanted,
      );

  Future<void> _act(ScreenAction a) async {
    final c = _c;
    // Asked of the session as it is now, not as it was when the panel or
    // the bar drew the row: what is no longer offered does nothing.
    if (!mounted || !_menuState(keyboardHeld: true).enabled(a)) return;
    final l10n = AppLocalizations.of(context)!;
    if (a.sendsKeys) {
      c?.keyboard.sendChord(a.keysWith(ref.read(screenMenuKeyProvider)));
    } else if (a.fitMode != null) {
      // A scaling of the picture: the remote keeps the size it has.
      setState(() {
        _fit = a.fitMode;
        _resizeRemote = false;
      });
      c?.fit = a.fitMode!;
      c?.followViewSize = false;
    } else if (a == ScreenAction.remoteResize) {
      setState(() {
        _fit = ScreenFit.fit;
        _resizeRemote = true;
      });
      c?.fit = ScreenFit.fit;
      c?.followViewSize = true;
    } else {
      switch (a) {
        case ScreenAction.viewOnly:
          setState(() => _viewOnly = !(_viewOnly ?? false));
          c?.viewOnly = _viewOnly!;
        case ScreenAction.fullScreen:
          await WindowService.instance?.toggleFullscreen();
        case ScreenAction.refresh:
          _session?.fullRefresh();
        case ScreenAction.clipboard:
          if (_clipboardTogglable) await _toggleClipboard();
        case ScreenAction.files:
          // The SSH host's files, over the screen's own connection, in the
          // tab's SFTP dock (the desktop shell opens it).
          ref.read(screenFilesRequestProvider.notifier).state = widget.sessionId;
          return;
        case ScreenAction.relativeMouse:
          // On: the next click in the picture holds the pointer. Off: it is let go.
          if (c != null && _menuState().enabled(a)) setState(() => c.relativeMouse = !c.relativeMouse);
        case ScreenAction.ownWindow:
          await _openOwnWindow();
          return;
        case ScreenAction.sound:
          // This session's: kept for a reconnect, not for the host.
          setState(() => _soundWanted = !_soundWanted);
          c?.soundWanted = _soundWanted;
        case ScreenAction.smoothScaling:
          // This computer's choice, for every screen it shows (the listener in build tells the picture).
          ref.read(screenSmoothScalingProvider.notifier).set(on: !ref.read(screenSmoothScalingProvider));
          setState(() {});
        case ScreenAction.commandAsControl:
          // This Mac's choice, for every screen it opens (the listener in build tells the keyboard).
          if (_mac) {
            ref.read(screenCommandAsControlProvider.notifier).set(on: !ref.read(screenCommandAsControlProvider));
            setState(() {});
          }
        case ScreenAction.frameLimit:
          if (c != null) {
            final picked = await showScreenFrameLimitQuestion(context, current: c.frameLimit);
            if (picked != null && mounted) {
              _frameLimit = picked;
              c.frameLimit = picked;
            }
          }
        case ScreenAction.textSize:
          // Asked in a question of its own; the remote is told at once.
          if (c != null) {
            final picked = await showScreenTextSizeQuestion(context, current: c.textScale);
            if (picked != null && mounted) c.setTextScale(picked);
          }
        case ScreenAction.sessionDetails:
          // Sampled only while shown.
          setState(() => _details = !_details);
          c?.detailsShown = _details;
        case ScreenAction.releaseKeyboard:
          _focus.unfocus();
          showTopSnackBar(context, l10n.screenKeyboardReleased);
          return;
        case ScreenAction.disconnect:
          await confirmDisconnectSession(context, ref, widget.sessionId, widget.sessionState);
          return;
        default:
      }
    }
    // The keyboard back to the picture after what it was taken from it for.
    if (mounted) _takeKeyboardSoon();
  }

  /// The toolbar's clipboard switch: this computer's choice for the host,
  /// said in the team's log where its vault logs sessions.
  Future<void> _toggleClipboard() async {
    final clip = _clip;
    if (clip == null) return;
    final on = !clip.on.value;
    clip.on.value = on;
    setState(() {});
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(context, on ? l10n.screenClipboardOn : l10n.screenClipboardOff);
    await saveScreenClipboardChoice(ref.read(sharedPreferencesProvider),
        connectionId: _shell?.connectionId, sessionId: widget.sessionId, on: on);
    // Turned on with the picture holding the keyboard: what this computer
    // holds goes now.
    if (on && _focus.hasFocus && !(_viewOnly ?? false)) unawaited(clip.sendLocal());
    if (mounted) _takeKeyboardSoon();
  }

  /// How the screen is protected, for the lock's tooltip.
  String? _security(AppLocalizations l10n) {
    final shell = _shell;
    final info = shell?.connectedInfo;
    if (shell == null || info == null) return null;
    if (shell.viaCarrier) {
      return l10n.screenSecurityViaSsh(Redactable.host(shell.carrierLabel ?? '').displayIn(ref));
    }
    return info.tls != null ? l10n.screenSecurityTls : null;
  }

  void _focusPane() {
    // As a terminal's pane: the pane in focus, and the session the tab's
    // tools act on, one frame later (never mid-gesture).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final leaf = widget.leafId;
      if (leaf != null && ref.read(focusedPaneProvider) != leaf) {
        ref.read(focusedPaneProvider.notifier).state = leaf;
      }
      if (ref.read(v3ActiveSessionTabProvider) != widget.sessionId) {
        ref.read(v3ActiveSessionTabProvider.notifier).state = widget.sessionId;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final covered = screenCoveredWhileRecording(
      recording: ref.watch(recordingModeProvider),
      behaviour: ref.watch(screenRecordingBehaviourProvider),
      shown: ref.watch(screenShownWhileRecordingProvider).contains(widget.sessionId),
    );
    final menuKey = ref.watch(screenMenuKeyProvider);
    // The open panel follows the session (it redraws after this frame).
    if (_menuOpen) _menuNotifier.value = _menuState(keyboardHeld: _heldAtOpen);
    if (covered != _covered) {
      _covered = covered;
      if (covered) _focus.unfocus();
      // Recording mode covers the picture: not in a window that would show it.
      if (covered && _inOwnWindow) unawaited(ScreenWindows.instance.bringBack(widget.sessionId));
      // (Paused or resumed once this build is done: not mid-build.)
      scheduleMicrotask(() {
        if (!mounted) return;
        _sync();
        if (!covered && widget.front) _takeKeyboardSoon();
      });
    }
    // A tab picked (its pill, a key): the one in front takes the keyboard.
    ref.listen(screenSmoothScalingProvider, (_, on) => _c?.smoothScaling = on);
    ref.listen(screenCommandAsControlProvider, (_, on) {
      _c?.keyboard.commandAsControl = _mac && on;
    });
    ref.listen(terminalKeyboardAskProvider, (_, _) {
      if (widget.front) _takeKeyboardSoon();
    });
    _attach();
    final c = _c;
    // Sound plays only while the picture may be seen: no recording cover
    // over it and the app not locked. (A computer's tab behind another, or a
    // minimised window, still plays it, as another program's sound does.)
    c?.soundAllowed = !covered && !ref.watch(isAppLockedProvider);
    if (_inOwnWindow) {
      return _InOwnWindow(
        key: ValueKey('screen-pane-${widget.sessionId}'),
        onBack: () => unawaited(ScreenWindows.instance.bringBack(widget.sessionId)),
      );
    }
    return Column(
      key: ValueKey('screen-pane-${widget.sessionId}'),
      children: [
        ScreenToolbar(
          fit: _fit ?? ScreenFit.fit,
          viewOnly: _viewOnly ?? false,
          fullScreen: WindowService.fullscreen.value,
          canResizeRemote: _shell?.protocol == ScreenProtocol.rdp,
          resizingRemote: _resizeRemote ?? false,
          security: _security(l10n),
          onAction: (a) => unawaited(_act(a)),
          onMenu: (_) => unawaited(_openMenu(fromBar: true)),
          clipboardOn: _clip?.on.value ?? false,
          onToggleClipboard: _clipboardTogglable ? () => unawaited(_toggleClipboard()) : null,
          menuKey: menuKey,
          menu: _menuState(),
          // The remote's displays (4.0): the bar's segment.
          displays: c?.displays,
          onDisplay: c?.showDisplay,
        ),
        Expanded(
          child: c == null
              ? const ColoredBox(color: AppColors.screenLetterbox, child: SizedBox.expand())
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The strip of the remote's displays, left of the picture:
                    // nothing while there is one display. Open or closed is
                    // this computer's, kept until its person changes it.
                    ScreenDisplayStrip(
                      displays: c.displays,
                      onDisplay: c.showDisplay,
                      // A small live picture of each, read through a view of
                      // the session's picture; a plain box while recording
                      // mode covers the remote.
                      preview: (index, size) => ScreenDisplayPreview(
                        key: ValueKey('screen-display-preview-$index'),
                        controller: c,
                        index: index,
                        size: size,
                        covered: covered,
                        decodeTile: ScreenPane.debugDecodeTile,
                      ),
                      open: ref.watch(screenDisplayStripOpenProvider),
                      onOpenChanged: (open) => ref.read(screenDisplayStripOpenProvider.notifier).set(open: open),
                    ),
                    Expanded(
                      child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => _focusPane(),
                      child: ScreenView(
                        key: ValueKey('screen-view-${widget.sessionId}'),
                        controller: c,
                        focusNode: _focus,
                        autofocus: false,
                        insets: EdgeInsets.zero,
                        onMenuKey: () => unawaited(_openMenu()),
                        menuKey: menuKey.logical,
                      ),
                    ),
                    // The session's details, over the picture's top end corner.
                    // Not while recording mode covers the remote: its numbers
                    // are the session's own, but the card would sit on the cover.
                    if (_details && !covered)
                      PositionedDirectional(
                        top: 10,
                        end: 10,
                        child: ScreenSessionDetailsCard(
                          details: c.details,
                          onClose: () => unawaited(_act(ScreenAction.sessionDetails)),
                        ),
                      ),
                    if (covered)
                      _RecordingCover(
                        onShow: () {
                          final now = ref.read(screenShownWhileRecordingProvider);
                          ref.read(screenShownWhileRecordingProvider.notifier).state = {...now, widget.sessionId};
                        },
                      ),
                    // The first time on this computer: the key that gives the
                    // keyboard back and opens the panel (4.0).
                    if (!covered)
                      Positioned.fill(
                        child: ScreenHintOverlay(
                          offer: const [ScreenHintKind.releaseKey],
                          menuKey: menuKey.label,
                        ),
                      ),
                    // The pointer is held for the remote: said for as long as it
                    // is, with the key that gets it back. Last, so nothing of the
                    // remote's, no cover and no hint is over it.
                    ListenableBuilder(
                      listenable: c.hold,
                      builder: (context, _) => c.hold.held
                          ? ScreenHeldLine(
                              key: const ValueKey('screen-pointer-held'),
                              text: l10n.screenPointerHeld(menuKey.label),
                              keyLabel: menuKey.label,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
                    ),
                  ],
                ),
                    // A tablet's app switcher: the picture and the strip's small
                    // pictures of it covered as the app leaves.
                    const ScreenPrivacyCover(),
                  ],
                ),
        ),
      ],
    );
  }
}

/// In a tab whose screen is shown in a window of its own: that it is, and
/// the way back.
class _InOwnWindow extends StatelessWidget {
  const _InOwnWindow({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ColoredBox(
      color: ZestColors.surfacePanel,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Two windows, the screen in the one that stood out.
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.brandOrange.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(LucideIcons.appWindow, size: 26, color: AppColors.v3AccentInk),
                ),
                const SizedBox(height: 14),
                Text(
                  l10n.screenInOwnWindow,
                  key: const ValueKey('screen-in-own-window'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.screenInOwnWindowHelp,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.4, color: ZestColors.textMuted),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('screen-own-window-back'),
                  autofocus: true,
                  onPressed: onBack,
                  icon: const Icon(LucideIcons.arrowLeftToLine, size: 16),
                  label: Text(l10n.screenBringBack),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Over the picture while recording mode is on: the remote screen may show
/// anything, so it is hidden (and paused) until its person shows it for this
/// session.
class _RecordingCover extends StatelessWidget {
  const _RecordingCover({required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ColoredBox(
      key: const ValueKey('screen-recording-cover'),
      color: ZestColors.surfacePanel,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.eyeOff, size: 36, color: ZestColors.textTertiary),
              const SizedBox(height: 12),
              Text(
                l10n.screenRecordingCovered,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: ZestColors.textSecondary),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const ValueKey('screen-recording-show'),
                onPressed: onShow,
                icon: const Icon(LucideIcons.eye, size: 15),
                label: Text(l10n.screenRecordingShow),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
