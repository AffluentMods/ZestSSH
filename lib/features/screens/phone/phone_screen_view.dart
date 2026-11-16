// Remote screens (4.0): a phone's or a tablet's page for a screen session, in
// place of a terminal (terminal_screen.dart branches to it, so the route stays
// Routes.terminal).
//
// Connected, the picture takes the whole screen, immersive (the system bars
// hidden; entered as the screen connects, before its first picture, so that
// Android's one-time "Viewing full screen" hint, which takes the focus and
// kept the soft keyboard down in the spike, comes and goes before anyone
// types; the keyboard is asked for again once the app has the focus back).
// The picture fits inside the safe area and the system's gesture edges (the
// Dynamic Island, the home indicator, Android's back gesture), and goes under
// them only when zoomed. A floating bar hides itself; a tab at the top brings
// it back. The soft keyboard and a row of extra keys cover the bottom: the
// picture keeps its size and slides up so the pointer or the last tap stays
// above them, never shrunk to a strip.
//
// Not connected (connecting, dropped and reconnecting, failed), the page shows
// what the terminal shows then ([stateBody]), edge to edge again.
//
// Recording mode covers the picture until "Show for this session".
//
// The clipboard (screen_clipboard.dart): the remote's comes to this phone
// while it is shared and recording mode is off; the phone's goes to the remote
// only by "Paste to remote" in the menu, never read in the background.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/orchards/widgets/team_logged_indicator.dart';
import 'package:zestssh/features/screens/details/screen_session_details.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/menu/screen_text_size.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/hints/screen_hint.dart';
import 'package:zestssh/features/screens/phone/screen_bar_kept.dart';
import 'package:zestssh/features/screens/phone/screen_key_bar.dart';
import 'package:zestssh/features/screens/phone/screen_phone_toolbar.dart';
import 'package:zestssh/features/screens/phone/screen_send_text_bar.dart';
import 'package:zestssh/features/screens/session/screen_clipboard.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_privacy_cover.dart';
import 'package:zestssh/features/screens/view/screen_soft_keyboard.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/hit_area.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart' show RedactableDisplay;

/// The device-local preference that keeps a host's Touch or Mouse pointer on
/// this device (a phone's; Settings, Reset all settings puts it back).
String screenTouchPrefKey(String connectionId) => 'screen_touch.$connectionId';

/// The picture's scaling for a host's saved option. A phone has no "resize
/// the remote" yet (VNC servers that resize come in a later step): it fits.
ScreenFit screenFitFor(ScreenScaling scaling) => switch (scaling) {
      ScreenScaling.fit => ScreenFit.fit,
      ScreenScaling.oneToOne => ScreenFit.oneToOne,
      ScreenScaling.remoteResize => ScreenFit.fit,
    };

class PhoneScreenView extends ConsumerStatefulWidget {
  const PhoneScreenView({
    super.key,
    required this.sessionId,
    required this.connectionId,
    required this.label,
    required this.session,
    required this.onBack,
    required this.onDisconnect,
    this.options = ScreenOptions.defaults,
    this.inTeam = false,
    this.rdp = false,
    this.stateBody,
    this.background = AppColors.screenLetterbox,
    this.showDisconnect = true,
    this.wrapToolbar,
    this.decodeTile,
    this.clipboardIo,
    this.onFiles,
    this.measureRoundTrip,
  });

  final String sessionId;

  /// What measures the round trip for the session's details
  /// (screenRoundTripOf); null where nothing can.
  final Future<int?> Function()? measureRoundTrip;

  /// Opens the files of the SSH host the screen goes through (4.0:
  /// Files); null where it goes through none.
  final VoidCallback? onFiles;

  /// The host, for what is remembered of it on this device (Touch or Mouse
  /// pointer). Null for a session with no saved host.
  final String? connectionId;

  /// The host's name, masked while recording.
  final String label;

  /// The screen session while connected; null while it is not.
  final ScreenSession? session;

  /// The host's saved options: its scaling and view only, applied as it connects.
  final ScreenOptions options;

  /// Whether the host is a team's (its clipboard is off by default there).
  final bool inTeam;

  /// An RDP host's screen: the key bar's Super key is named Win.
  final bool rdp;

  /// What the page shows while the screen is not connected (connecting,
  /// dropped, failed): the terminal's own views. Null while connected.
  final Widget? stateBody;

  /// The page's colour while [stateBody] shows.
  final Color background;

  /// Back to the list; the screen stays connected.
  final VoidCallback onBack;

  /// Ends the session (asked first).
  final VoidCallback onDisconnect;

  /// Whether the page offers Disconnect while not connected (not for a
  /// connection that failed, whose view has its own Back).
  final bool showDisconnect;

  /// Wraps the floating bar (a phone's swipe to the next session); never the
  /// picture, where a finger drives the remote.
  final Widget Function(Widget toolbar)? wrapToolbar;

  /// Tests: tiles made images at once.
  final ScreenTileDecoder? decodeTile;

  /// Tests: the phone's clipboard.
  final ScreenClipboardIo? clipboardIo;

  /// How long the floating bar stays once it was last used (never while the
  /// soft keyboard is up).
  static const toolbarStays = Duration(seconds: 4);

  /// How long, once the bar hid itself, a finger on the picture is taken
  /// for a late tap meant for the bar and sent nowhere.
  static const lateTapGrace = Duration(milliseconds: 300);

  @override
  ConsumerState<PhoneScreenView> createState() => _PhoneScreenViewState();
}

class _PhoneScreenViewState extends ConsumerState<PhoneScreenView> with WidgetsBindingObserver {
  ScreenController? _c;
  ScreenClipboardLink? _clip;
  ScreenSoftKeyboard? _soft;
  ScreenSession? _for;
  final _focus = FocusNode(debugLabel: 'phone remote screen');

  bool _toolbarShown = true;
  Timer? _hideToolbar;

  /// Just after the bar hid itself ([PhoneScreenView.lateTapGrace]): a
  /// finger on the picture then reaches nobody.
  bool _justHidden = false;
  Timer? _justHiddenEnds;
  bool _keysShown = false;

  /// The Send text field is along the bottom (4.0).
  bool _sendText = false;

  /// The session's details sheet is open (4.0).
  bool _details = false;
  bool _immersive = false;
  double _lastKeyboardInset = 0;
  double _appliedObscured = 0;
  bool _covered = false;
  AppLifecycleState? _lifecycle;

  // The remote's sound for this session: its person's switch (kept across
  // a reconnect), and whether it may play now.
  bool _soundWanted = true;

  /// Sound plays only while the app is in front, not locked, and the
  /// picture is not covered.
  void _syncSound() {
    final away = _lifecycle == AppLifecycleState.hidden || _lifecycle == AppLifecycleState.paused;
    _c?.soundAllowed = !_covered && !away && !ref.read(isAppLockedProvider);
  }

  /// Paused because the app left the screen (resumed when it is back).
  bool _pausedAway = false;

  /// What the person made of the view (zoom, pan, scaling, mode), given to
  /// the view of the same screen once it is connected again (iOS closes a
  /// screen in the background; a dropped one comes back).
  ScreenControllerKept? _kept;
  String? _keptFor;

  /// The session id the controller was made for.
  String? _cSessionId;

  bool get _connected => widget.session != null && widget.stateBody == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync();
  }

  @override
  void didUpdateWidget(PhoneScreenView old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// The controller for the session connected now, made once for each
  /// session (a reconnect brings a new one), and immersive mode with it.
  void _sync() {
    final session = _connected ? widget.session : null;
    if (identical(session, _for)) return;
    _drop();
    _for = session;
    if (session == null) {
      _setImmersive(false);
      return;
    }
    final c = ScreenController(session, decodeTile: widget.decodeTile)
      ..measureRoundTrip = widget.measureRoundTrip
      ..soundWanted = _soundWanted;
    c.fit = screenFitFor(widget.options.scaling);
    c.displayCount = widget.rdp ? widget.options.displayCount : 1;
    c.maxDesktopPixels = ScreenOptions.maxDesktopPixelsOn(phone: true);
    c.textScale = widget.rdp ? widget.options.textScale : 0;
    c.frameLimit = widget.options.frameLimit;
    c.smoothScaling = ref.read(screenSmoothScalingProvider);
    c.viewOnly = widget.options.viewOnly;
    c.touchMode = _savedMode();
    final kept = _kept;
    if (kept != null && _keptFor == widget.sessionId) c.restore(kept);
    _c = c;
    _cSessionId = widget.sessionId;
    _clip = ScreenClipboardLink(
      session,
      on: screenClipboardOnFor(ref.read(sharedPreferencesProvider), widget.options,
          inTeam: widget.inTeam, connectionId: widget.connectionId),
      recording: () => mounted && ref.read(recordingModeProvider),
      // Seen: the app in front, nothing over the picture.
      shown: () =>
          mounted &&
          !_covered &&
          !_pausedAway &&
          (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed,
      onRemoteTooLarge: () {
        if (mounted) _tell(AppLocalizations.of(context)!.screenClipboardRemoteTooLarge);
      },
      io: widget.clipboardIo ?? const SystemScreenClipboardIo(),
    );
    _soft = ScreenSoftKeyboard(c.keyboard);
    // The whole picture again for a page opened on a session that ran
    // meanwhile (a new controller holds no tile): back from the pause the
    // page left it in, or a full update.
    if (session.isPaused) {
      session.resume();
    } else {
      session.fullRefresh();
    }
    _setImmersive(true);
    _showToolbar();
    _covered = false;
    _syncCover(ref.read(recordingModeProvider));
  }

  void _drop() {
    _clip?.dispose();
    _clip = null;
    _hideToolbar?.cancel();
    _justHiddenEnds?.cancel();
    _justHidden = false;
    _soft?.hide();
    _soft = null;
    _keysShown = false;
    _appliedObscured = 0;
    final c = _c;
    _c = null;
    _pausedAway = false;
    if (c != null) {
      if (c.viewport.hasRemote) {
        _kept = c.kept();
        _keptFor = _cSessionId;
      }
      // Nobody takes the frames once the page is gone: the server stops sending.
      if (!c.isClosed) c.pause();
      c.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _drop();
    _setImmersive(false);
    _focus.dispose();
    super.dispose();
  }

  // Immersive mode.

  void _setImmersive(bool on) {
    if (_immersive == on) return;
    _immersive = on;
    unawaited(SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final was = _lifecycle;
    _lifecycle = state;
    _syncSound();
    // Away from the screen: the server sends nothing meanwhile (and the
    // phone's data is spared). Back: the whole picture again.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      final c = _c;
      if (c != null && !c.isPaused) {
        c.pause();
        _pausedAway = true;
      }
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (_pausedAway) {
      _pausedAway = false;
      if (!_covered) _c?.resume();
    }
    if (was == null || was == AppLifecycleState.resumed) return;
    // Back from the system's one-time full screen hint (it takes the focus:
    // the app goes inactive) or from another app: immersive again, and the
    // soft keyboard asked for again if it was up (it did not come up under
    // the hint).
    if (_immersive) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    if (_keysShown && !_covered) _soft?.show(appearance: Theme.of(context).brightness);
  }

  // Touch or Mouse pointer, per host on this device.

  /// The host's own on this device where it was switched, else Settings'
  /// default (Touch unless Settings says Mouse pointer).
  ScreenTouchMode _savedMode() {
    final id = widget.connectionId;
    final saved = id == null ? null : ref.read(sharedPreferencesProvider).getString(screenTouchPrefKey(id));
    return switch (saved) {
      'mouse' => ScreenTouchMode.mousePointer,
      'touch' => ScreenTouchMode.touch,
      _ => ref.read(screenTouchDefaultProvider),
    };
  }

  void _toggleMode() {
    final c = _c;
    if (c == null) return;
    _setTouchMode(c.touchMode == ScreenTouchMode.touch ? ScreenTouchMode.mousePointer : ScreenTouchMode.touch);
  }

  /// Takes [next] as this host's touch mode on this device, and says so.
  void _setTouchMode(ScreenTouchMode next) {
    final c = _c;
    if (c == null || c.touchMode == next) return;
    setState(() => c.touchMode = next);
    final id = widget.connectionId;
    if (id != null) {
      unawaited(ref
          .read(sharedPreferencesProvider)
          .setString(screenTouchPrefKey(id), next == ScreenTouchMode.mousePointer ? 'mouse' : 'touch'));
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('screen-phone-mode-told'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        content: Text(next == ScreenTouchMode.touch ? l10n.screenPhoneModeTouch : l10n.screenPhoneModeMouse),
      ));
    _showToolbar();
  }

  // The floating bar.

  void _showToolbar() {
    _hideToolbar?.cancel();
    if (!_toolbarShown && mounted) setState(() => _toolbarShown = true);
    _toolbarShown = true;
    // It stays while the soft keyboard is up: its button is how it goes. And
    // while Keep the bar shown is on.
    if (_keysShown || ref.read(screenBarKeptProvider)) return;
    _hideToolbar = Timer(PhoneScreenView.toolbarStays, _hideByItself);
  }

  /// The bar's own time ran out: it hides, and a finger landing on the
  /// picture in the next moment, a slow tap meant for the bar, clicks
  /// nothing on the remote.
  void _hideByItself() {
    if (!mounted || _keysShown || ref.read(screenBarKeptProvider)) return;
    _justHiddenEnds?.cancel();
    setState(() {
      _toolbarShown = false;
      _justHidden = true;
    });
    _justHiddenEnds = Timer(PhoneScreenView.lateTapGrace, () {
      if (mounted) setState(() => _justHidden = false);
    });
  }

  void _hideToolbarNow() {
    _hideToolbar?.cancel();
    if (_toolbarShown) setState(() => _toolbarShown = false);
  }

  /// About how tall the Send text bar is, for what of the picture it covers.
  static const _sendTextHeight = 56.0;

  // The soft keyboard and the key bar.

  void _toggleKeyboard() {
    final soft = _soft;
    if (soft == null) return;
    setState(() {
      _keysShown = !_keysShown;
      // One keyboard at a time: the Send text field goes when keys are asked for.
      if (_keysShown) _sendText = false;
    });
    if (_keysShown) {
      soft.show(appearance: Theme.of(context).brightness);
    } else {
      soft.hide();
    }
    _showToolbar();
  }

  void _menu(ScreenPhoneMenu item) => _act(item.action);

  /// What this session offers now, for whatever draws its menu.
  ScreenMenuState _menuState(ScreenController c) => ScreenMenuState.of(
        phone: true,
        fit: c.fit,
        viewOnly: c.viewOnly,
        clipboardTogglable: _clipboardTogglable,
        clipboardOn: _clip?.on.value ?? false,
        touchMode: c.touchMode,
        sendTextShown: _sendText,
        detailsShown: _details,
        barKept: ref.read(screenBarKeptProvider),
        filesOffered: widget.onFiles != null,
        textSizeOffered: widget.rdp,
        // Relative mouse (4.0): in Mouse pointer mode a finger's
        // movement goes as movement. A phone holds no pointer for it.
        relativeAsked: widget.rdp && widget.options.relativeMouse,
        relativeTaken: c.relativeTaken,
        relativeHere: true,
        relativeOn: c.relativeMouse,
        smoothScaling: ref.read(screenSmoothScalingProvider),
        covered: _covered,
        soundAsked: widget.rdp && widget.options.soundOn(phone: true),
        soundHere: c.soundUnavailable == null,
        soundOn: _soundWanted,
      );

  /// Does [a] (4.0: one list of actions for a phone and a computer;
  /// model/screen_action.dart). An action this session does not offer now,
  /// or cannot do now, does nothing: a menu drawn a moment ago may still
  /// show it.
  void _act(ScreenAction a) {
    final c = _c;
    if (c == null || !_menuState(c).enabled(a)) return;
    if (a == ScreenAction.disconnect) {
      widget.onDisconnect();
      return;
    }
    if (a.touchMode != null) {
      _setTouchMode(a.touchMode!);
      _showToolbar();
      return;
    }
    if (a == ScreenAction.frameLimit) {
      unawaited(showScreenFrameLimitQuestion(context, current: c.frameLimit).then((picked) {
        if (picked != null && mounted) _c?.frameLimit = picked;
      }));
      return;
    }
    if (a == ScreenAction.textSize) {
      // Asked in a question of its own; the remote is told at once.
      unawaited(showScreenTextSizeQuestion(context, current: c.textScale).then((picked) {
        if (picked != null && mounted) _c?.setTextScale(picked);
      }));
      return;
    }
    if (a == ScreenAction.sessionDetails) {
      // The sheet says when it is gone, however it went.
      if (_details) return;
      setState(() => _details = true);
      c.detailsShown = true;
      unawaited(showScreenSessionDetailsSheet(
        context,
        details: c.details,
        onClosed: () {
          // Sampled only while it is open.
          _c?.detailsShown = false;
          if (mounted) setState(() => _details = false);
        },
      ));
      return;
    }
    setState(() {
      if (a.sendsKeys) {
        // Alone, whatever the key bar holds: with Ctrl or Alt it is another key.
        c.keyboard.sendChord(a.keysWith(ref.read(screenMenuKeyProvider)));
      } else if (a.fitMode != null) {
        c.fit = a.fitMode!;
      } else {
        switch (a) {
          case ScreenAction.viewOnly:
            c.viewOnly = !c.viewOnly;
            if (c.viewOnly && _keysShown) {
              _keysShown = false;
              _soft?.hide();
            }
          case ScreenAction.refresh:
            if (_connected) widget.session?.fullRefresh();
          case ScreenAction.sendText:
            _sendText = !_sendText;
            // One keyboard at a time: the field has its own.
            if (_sendText && _keysShown) {
              _keysShown = false;
              _soft?.hide();
            }
          case ScreenAction.relativeMouse:
            c.relativeMouse = !c.relativeMouse;
          case ScreenAction.sound:
            setState(() => _soundWanted = !_soundWanted);
            c.soundWanted = _soundWanted;
          case ScreenAction.smoothScaling:
            // This device's choice, for every screen it shows.
            final smooth = !ref.read(screenSmoothScalingProvider);
            ref.read(screenSmoothScalingProvider.notifier).set(on: smooth);
            c.smoothScaling = smooth;
          case ScreenAction.files:
            widget.onFiles?.call();
          case ScreenAction.keepBar:
            final notifier = ref.read(screenBarKeptProvider.notifier);
            notifier.set(kept: !ref.read(screenBarKeptProvider));
          case ScreenAction.clipboard:
            unawaited(_toggleClipboard());
          case ScreenAction.pasteToRemote:
            unawaited(_pasteToRemote());
          default:
        }
      }
    });
    _showToolbar();
  }

  // The clipboard.

  bool get _clipboardTogglable => widget.options.clipboardTogglable(inTeam: widget.inTeam);

  void _tell(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('screen-phone-clipboard-told'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        content: Text(text),
      ));
  }

  /// The menu's switch: this phone's choice for the host, said in the team's
  /// log where its vault logs sessions.
  Future<void> _toggleClipboard() async {
    final clip = _clip;
    if (clip == null || !_clipboardTogglable) return;
    final on = !clip.on.value;
    clip.on.value = on;
    final l10n = AppLocalizations.of(context)!;
    _tell(on ? l10n.screenClipboardOn : l10n.screenClipboardOff);
    await saveScreenClipboardChoice(ref.read(sharedPreferencesProvider),
        connectionId: widget.connectionId, sessionId: widget.sessionId, on: on);
    if (mounted) setState(() {});
  }

  /// "Paste to remote": what this phone's clipboard holds now goes to the
  /// remote's (read only now, as its person asked).
  Future<void> _pasteToRemote() async {
    final clip = _clip;
    final c = _c;
    if (clip == null || c == null || c.viewOnly) return;
    final l10n = AppLocalizations.of(context)!;
    final sent = await clip.sendLocal(onlyIfChanged: false);
    switch (sent) {
      case ScreenClipboardSend.sent || ScreenClipboardSend.unchanged:
        _tell(l10n.screenPastedToRemote);
      case ScreenClipboardSend.empty:
        _tell(l10n.screenClipboardEmpty);
      case ScreenClipboardSend.tooLarge:
        _tell(l10n.screenClipboardTooLarge);
      case ScreenClipboardSend.off:
        break;
    }
  }

  // Recording mode.

  void _syncCover(bool recording) {
    final c = _c;
    final covered = screenCoveredWhileRecording(
      recording: recording,
      behaviour: ref.read(screenRecordingBehaviourProvider),
      shown: ref.read(screenShownWhileRecordingProvider).contains(widget.sessionId),
    );
    if (covered == _covered && c != null && c.isPaused == covered) return;
    _covered = covered;
    _syncSound();
    if (c == null) return;
    if (covered) {
      if (_keysShown) {
        _keysShown = false;
        _soft?.hide();
      }
      c.pause();
    } else {
      c.resume();
    }
  }

  void _showWhileRecording() {
    final shown = ref.read(screenShownWhileRecordingProvider);
    ref.read(screenShownWhileRecordingProvider.notifier).state = {...shown, widget.sessionId};
  }

  /// What the picture keeps clear at fit: the safe area and the system's
  /// gesture edges, whichever is wider on each side.
  static EdgeInsets _fitInsets(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final gestures = MediaQuery.systemGestureInsetsOf(context);
    return EdgeInsets.fromLTRB(
      math.max(pad.left, gestures.left),
      math.max(pad.top, gestures.top),
      math.max(pad.right, gestures.right),
      math.max(pad.bottom, gestures.bottom),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(recordingModeProvider, (_, on) => setState(() => _syncCover(on)));
    ref.listen<bool>(isAppLockedProvider, (_, _) => _syncSound());
    ref.listen<Set<String>>(screenShownWhileRecordingProvider,
        (_, _) => setState(() => _syncCover(ref.read(recordingModeProvider))));
    ref.listen<ScreenRecordingBehaviour>(screenRecordingBehaviourProvider,
        (_, _) => setState(() => _syncCover(ref.read(recordingModeProvider))));
    final c = _c;
    if (c == null || !_connected) return _notConnected(context);
    return _connectedPage(context, c);
  }

  Widget _notConnected(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: widget.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('screen-phone-back'),
                    tooltip: l10n.screenPhoneBack,
                    onPressed: widget.onBack,
                    icon: const Icon(LucideIcons.chevronLeft),
                  ),
                  Expanded(
                    child: Text(
                      Redactable.host(widget.label).displayIn(ref),
                      key: const ValueKey('screen-phone-label'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (widget.showDisconnect)
                    IconButton(
                      key: const ValueKey('screen-phone-disconnect'),
                      tooltip: l10n.terminalDisconnect,
                      onPressed: widget.onDisconnect,
                      icon: Icon(LucideIcons.power, color: AppColors.error),
                    ),
                ],
              ),
            ),
            Expanded(child: widget.stateBody ?? const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }

  Widget _connectedPage(BuildContext context, ScreenController c) {
    final l10n = AppLocalizations.of(context)!;
    final media = MediaQuery.of(context);
    final pad = media.padding;
    final keyboardInset = media.viewInsets.bottom;
    final landscape = media.orientation == Orientation.landscape;
    final keySize = ref.watch(softKeyboardKeySizeProvider);
    final barHeight = ScreenKeyBar.heightFor(keySize, landscape: landscape);
    final showBar = _keysShown && !_covered;
    final showSendText = _sendText && !_covered && !showBar;

    // The soft keyboard went away by itself (Back, its own button): the key
    // bar goes with it.
    if (_keysShown && _lastKeyboardInset > 0 && keyboardInset == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_keysShown) return;
        setState(() => _keysShown = false);
        _soft?.hide();
        if (_toolbarShown) _showToolbar();
      });
    }
    _lastKeyboardInset = keyboardInset;

    // The part of the picture the keyboard and the bar cover: it slides up
    // by this much (after the layout: it repaints).
    final obscured = keyboardInset +
        (showBar
            ? barHeight + (keyboardInset == 0 ? pad.bottom : 0)
            : (showSendText ? _sendTextHeight + (keyboardInset == 0 ? pad.bottom : 0) : 0));
    if ((obscured - _appliedObscured).abs() >= 0.5) {
      _appliedObscured = obscured;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_c, c)) c.setObscuredBottom(_appliedObscured);
      });
    }

    Widget toolbar = ScreenPhoneToolbar(
      label: widget.label,
      touchMode: c.touchMode,
      fit: c.fit,
      zoomed: c.viewport.isZoomed,
      viewOnly: c.viewOnly,
      keyboardShown: _keysShown,
      onBack: widget.onBack,
      onToggleMode: _toggleMode,
      onToggleKeyboard: _toggleKeyboard,
      onWholeScreen: () {
        c.resetZoom();
        setState(() {});
        _showToolbar();
      },
      onMenu: _menu,
      onDisconnect: widget.onDisconnect,
      clipboardOn: _clip?.on.value ?? false,
      clipboardTogglable: _clipboardTogglable,
      menu: _menuState(c),
      onAction: _act,
      // The remote's displays (4.0): the bar's button, the panel's group.
      displays: c.displays,
      onDisplay: c.showDisplay,
    );
    final wrap = widget.wrapToolbar;
    if (wrap != null) toolbar = wrap(toolbar);

    return Scaffold(
      backgroundColor: AppColors.screenLetterbox,
      // The keyboard covers the picture; the picture never shrinks for it.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              // A finger on the picture: the bar gets out of the way.
              onPointerDown: (_) {
                if (_toolbarShown && !ref.read(screenBarKeptProvider)) _hideToolbarNow();
              },
              behavior: HitTestBehavior.translucent,
              child: ScreenView(
                key: const ValueKey('phone-screen-view'),
                controller: c,
                focusNode: _focus,
                insets: _fitInsets(context),
              ),
            ),
          ),
          if (_covered) Positioned.fill(child: _cover(l10n)),
          // The first time: three fingers for the displays, a hold for a
          // right click (4.0), under the bar.
          if (!_covered)
            Positioned(
              top: pad.top + 64,
              left: pad.left,
              right: pad.right,
              child: ScreenHintOverlay(offer: [
                if (c.displays.value.several) ScreenHintKind.threeFingers,
                if (c.touchMode == ScreenTouchMode.touch && !c.viewOnly) ScreenHintKind.holdForRightClick,
              ]),
            ),
          // The app switcher's snapshot: the picture covered as the app leaves.
          const ScreenPrivacyCover(),
          // A late tap meant for the bar that just hid: it reaches nobody
          // (the tab that brings the bar back, above, still takes it).
          if (_justHidden)
            const Positioned.fill(
              child: Listener(
                key: ValueKey('screen-phone-late-tap-guard'),
                behavior: HitTestBehavior.opaque,
              ),
            ),
          // The bar, or the tab that brings it back, kept inside the safe
          // area (off the Dynamic Island's side).
          Positioned(
            top: pad.top + 6,
            left: pad.left + 8,
            right: pad.right + 8,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: _toolbarShown
                  ? KeyedSubtree(key: const ValueKey('bar-shown'), child: toolbar)
                  : Align(
                      key: const ValueKey('bar-hidden'),
                      alignment: Alignment.topCenter,
                      child: HitArea(
                       grow: const EdgeInsets.symmetric(vertical: 13),
                       child: Semantics(
                        button: true,
                        label: l10n.screenPhoneShowToolbar,
                        // (Its tap is left out with what is under it: said here,
                        // or a screen reader could never bring the bar back.)
                        onTap: _showToolbar,
                        excludeSemantics: true,
                        child: Tooltip(
                          message: l10n.screenPhoneShowToolbar,
                          // Drawn 22 high; a finger's 48 with what is taken
                          // above and below it.
                          child: InkWell(
                            key: const ValueKey('screen-phone-show-toolbar'),
                            borderRadius: BorderRadius.circular(12),
                            onTap: _showToolbar,
                            child: Container(
                              width: 72,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0x99151412),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(LucideIcons.chevronDown, size: 16, color: Color(0xFFEDEBE6)),
                            ),
                          ),
                        ),
                       ),
                      ),
                    ),
            ),
          ),
          // Logged for its team: said for as long as it is, as on a terminal's
          // page. In the corner beside the tab while the bar is hidden, under
          // the bar while it is shown; what the log holds is a tap away. Never
          // wider than the room left of the tab (72 wide, in the middle), which
          // is the one thing that brings the bar back: a chip over it would
          // take its taps.
          Positioned(
            top: pad.top + (_toolbarShown ? 62 : 6),
            left: pad.left + 8,
            width: math.max(0, (MediaQuery.sizeOf(context).width - 72) / 2 - pad.left - 16),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              heightFactor: 1,
              child: TeamLoggedChip(
                sessionId: widget.sessionId,
                screen: widget.rdp ? LoggedScreen.rdp : LoggedScreen.vnc,
                overPicture: true,
              ),
            ),
          ),
          if (showBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: keyboardInset,
              child: Padding(
                padding: EdgeInsets.only(
                  left: pad.left,
                  right: pad.right,
                  bottom: keyboardInset == 0 ? pad.bottom : 0,
                ),
                child: ScreenKeyBar(keyboard: c.keyboard, windowsKey: widget.rdp),
              ),
            ),
          // Send text: a field along the bottom, above its own keyboard.
          if (showSendText)
            Positioned(
              left: 0,
              right: 0,
              bottom: keyboardInset,
              child: Padding(
                padding: EdgeInsets.only(
                  left: pad.left,
                  right: pad.right,
                  bottom: keyboardInset == 0 ? pad.bottom : 0,
                ),
                child: ScreenSendTextBar(
                  key: const ValueKey('screen-phone-send-text'),
                  keyboard: c.keyboard,
                  usScancodes: widget.rdp,
                  enabled: !c.viewOnly,
                  autofocus: true,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cover(AppLocalizations l10n) => ColoredBox(
        key: const ValueKey('screen-recording-cover'),
        color: AppColors.screenLetterbox,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LucideIcons.eyeOff, size: 36, color: AppColors.screenLetterboxInk),
                const SizedBox(height: 12),
                Text(
                  l10n.screenRecordingHidden,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.screenLetterboxInk, fontSize: 13.5, height: 1.4),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('screen-recording-show'),
                  onPressed: _showWhileRecording,
                  style: FilledButton.styleFrom(backgroundColor: AppColors.brandOrange),
                  child: Text(l10n.screenRecordingShow),
                ),
              ],
            ),
          ),
        ),
      );
}

/// What a phone's screen page shows for a remote screen that iOS's background
/// closed (ScreenBackgroundKeeper): paused, and connected again when the app
/// is back ([reconnecting] once it is).
class ScreenParkedView extends StatelessWidget {
  const ScreenParkedView({super.key, this.reconnecting = false});

  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      key: const ValueKey('screen-parked'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reconnecting)
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.brandOrange),
              )
            else
              const Icon(LucideIcons.pauseCircle, size: 36, color: AppColors.screenLetterboxInk),
            const SizedBox(height: 14),
            Text(
              reconnecting ? l10n.screenBackgroundReconnecting : l10n.screenBackgroundParked,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.screenLetterboxInk, fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
