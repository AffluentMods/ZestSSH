// Remote screens (4.0): what can be done to a screen from its tab, the same
// list on a computer and on a phone. A menu, a sheet or a bar is drawn from
// this list and from what the session offers now ([ScreenMenuState]): it
// names no action itself, so an action added here (with its group, its kind
// and its words) appears wherever the list is drawn.
import 'package:flutter/widgets.dart' show IconData;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

export 'package:zestssh/features/screens/model/screen_displays.dart';
export 'package:zestssh/features/screens/model/screen_session_details.dart';

/// The groups a screen's menu has, in the order they are shown (4.0).
enum ScreenActionGroup {
  /// The scaling, view only, full screen, disconnecting.
  session,

  /// What the picture is drawn with, a refresh of it, the remote's sound.
  video,

  /// The keys to send, the touch mode, letting go of the keyboard.
  input,

  /// The remote's displays and which is shown.
  displays,

  /// The clipboard and the remote's files.
  clipboard,

  /// Numbers about the running session.
  details;

  String titleIn(AppLocalizations l10n) => switch (this) {
        session => l10n.screenGroupSession,
        video => l10n.screenGroupVideo,
        input => l10n.screenGroupInput,
        displays => l10n.screenGroupDisplays,
        clipboard => l10n.screenGroupClipboard,
        details => l10n.screenGroupDetails,
      };
}

/// How an action is drawn and what picking it does.
enum ScreenActionKind {
  /// Done once when picked (a key sent, a refresh, disconnecting).
  plain,

  /// A switch: on or off ([ScreenMenuState.isOn]).
  toggle,

  /// One of a set of which one is in use ([ScreenAction.choices]).
  choice,
}

/// The declaration order is the order inside a group.
enum ScreenAction {
  // Session.
  fit,
  fill,
  oneToOne,

  /// RDP: the remote's screen takes the tab's size (shown fitted meanwhile).
  remoteResize,
  viewOnly,
  fullScreen,

  /// A computer: the screen moves to a window of its own, which can sit on
  /// another monitor (4.0). The tab stays, to bring it back.
  ownWindow,

  /// A phone: its floating bar stays shown instead of hiding itself.
  keepBar,
  disconnect,

  // Video.
  refresh,

  /// RDP: how large the remote draws its text and windows, asked in a
  /// question of its own and changed in the running session (4.0).
  textSize,

  /// The most pictures a second this session draws, asked in a question of
  /// its own (4.0): it saves battery.
  frameLimit,

  /// The picture smoothed where it is shown larger or smaller than the
  /// remote draws it (4.0); this device's choice.
  smoothScaling,

  /// RDP: the remote's sound played on this device, for this session (4.0),
  /// where its host plays sound.
  sound,

  // Input.
  sendCtrlAltDel,
  sendSuper,
  sendAltTab,
  sendAltF4,
  sendPrintScreen,

  /// The key that opens the menu (F8 unless Settings says another), sent.
  sendMenuKey,

  /// A phone or tablet: a trackpad ([ScreenTouchMode.mousePointer]).
  touchPointer,

  /// A phone or tablet: taps click where the finger is ([ScreenTouchMode.touch]).
  touchTouch,

  /// A phone or tablet: the field along the bottom whose text is sent as text
  /// when its person says so (4.0).
  sendText,

  /// The mouse's movement goes to the remote as movement (4.0; RDP,
  /// where the host asks for it): on a computer with the pointer held in
  /// the picture, on a phone in Mouse pointer mode with a finger's movement.
  relativeMouse,

  /// A Mac: its Command key goes to the remote as Ctrl (4.0).
  commandAsControl,
  releaseKeyboard,

  // Clipboard and files.
  clipboard,
  pasteToRemote,

  /// The files of the SSH host the screen is reached through, in SFTP.
  files,

  // Details.

  /// The session's details shown (4.0): its speed, its frames, what
  /// draws the picture. A card over a computer's picture, a sheet on a phone.
  sessionDetails;

  ScreenActionGroup get group => switch (this) {
        fit || fill || oneToOne || remoteResize || viewOnly || fullScreen || ownWindow || keepBar || disconnect =>
          ScreenActionGroup.session,
        refresh || textSize || frameLimit || smoothScaling || sound => ScreenActionGroup.video,
        sendCtrlAltDel ||
        sendSuper ||
        sendAltTab ||
        sendAltF4 ||
        sendPrintScreen ||
        sendMenuKey ||
        touchPointer ||
        touchTouch ||
        sendText ||
        relativeMouse ||
        commandAsControl ||
        releaseKeyboard =>
          ScreenActionGroup.input,
        clipboard || pasteToRemote || files => ScreenActionGroup.clipboard,
        sessionDetails => ScreenActionGroup.details,
      };

  ScreenActionKind get kind => switch (this) {
        fit || fill || oneToOne || remoteResize || touchPointer || touchTouch => ScreenActionKind.choice,
        viewOnly ||
        fullScreen ||
        keepBar ||
        clipboard ||
        sendText ||
        relativeMouse ||
        commandAsControl ||
        smoothScaling ||
        sound ||
        sessionDetails =>
          ScreenActionKind.toggle,
        _ => ScreenActionKind.plain,
      };

  /// The set a [ScreenActionKind.choice] is one of (itself among them), in
  /// their order; empty for the other kinds.
  List<ScreenAction> get choices => switch (this) {
        fit || fill || oneToOne || remoteResize => const [fit, fill, oneToOne, remoteResize],
        touchPointer || touchTouch => const [touchPointer, touchTouch],
        _ => const [],
      };

  /// The keys a send action sends, pressed in order and let go in reverse
  /// ([menuKey]: the one that opens the menu); none for the others.
  List<ScreenKey> keysWith(ScreenMenuKey menuKey) => switch (this) {
        sendMenuKey => [menuKey.key],
        sendCtrlAltDel => const [ScreenKey.controlLeft, ScreenKey.altLeft, ScreenKey.delete],
        sendSuper => const [ScreenKey.superLeft],
        sendAltTab => const [ScreenKey.altLeft, ScreenKey.tab],
        sendAltF4 => [ScreenKey.altLeft, ScreenKey.f(4)],
        sendPrintScreen => const [ScreenKey.printScreen],
        _ => const [],
      };

  bool get sendsKeys => keysWith(ScreenMenuKey.f8).isNotEmpty;

  /// The scaling an action picks, or null.
  ScreenFit? get fitMode => switch (this) {
        fit => ScreenFit.fit,
        fill => ScreenFit.fill,
        oneToOne => ScreenFit.oneToOne,
        _ => null,
      };

  static ScreenAction ofFit(ScreenFit f) => switch (f) {
        ScreenFit.fit => fit,
        ScreenFit.fill => fill,
        ScreenFit.oneToOne => oneToOne,
      };

  /// The touch mode an action picks, or null.
  ScreenTouchMode? get touchMode => switch (this) {
        touchPointer => ScreenTouchMode.mousePointer,
        touchTouch => ScreenTouchMode.touch,
        _ => null,
      };

  static ScreenAction ofTouch(ScreenTouchMode m) => switch (m) {
        ScreenTouchMode.mousePointer => touchPointer,
        ScreenTouchMode.touch => touchTouch,
      };

  /// The send actions of the toolbar's Send keys list, in its order.
  static const sends = [sendCtrlAltDel, sendSuper, sendAltTab, sendAltF4, sendPrintScreen, sendMenuKey];
  static const fits = [fit, fill, oneToOne];

  String labelIn(AppLocalizations l10n, {ScreenMenuKey menuKey = ScreenMenuKey.f8}) => switch (this) {
        sendMenuKey => l10n.screenSendKey(menuKey.label),
        sendCtrlAltDel => l10n.screenSendCtrlAltDel,
        sendSuper => l10n.screenSendSuper,
        sendAltTab => l10n.screenSendAltTab,
        sendAltF4 => l10n.screenSendAltF4,
        sendPrintScreen => l10n.screenSendPrintScreen,
        fit => l10n.connectionEditScreenScalingFit,
        fill => l10n.screenFitFill,
        oneToOne => l10n.connectionEditScreenScalingOneToOne,
        remoteResize => l10n.connectionEditScreenScalingRemote,
        viewOnly => l10n.connectionEditScreenViewOnly,
        fullScreen => l10n.screenFullScreen,
        ownWindow => l10n.screenOwnWindow,
        refresh => l10n.screenRefresh,
        textSize => l10n.connectionEditRdpTextSize,
        frameLimit => l10n.connectionEditScreenFrameLimit,
        smoothScaling => l10n.screenSmoothScaling,
        sound => l10n.connectionEditRdpSound,
        touchPointer => l10n.settingsScreenTouchModeMouse,
        touchTouch => l10n.settingsScreenTouchModeTouch,
        sendText => l10n.screenSendTextHint,
        relativeMouse => l10n.connectionEditRdpRelativeMouse,
        commandAsControl => l10n.screenCommandAsControl,
        releaseKeyboard => l10n.screenReleaseKeyboard,
        clipboard => l10n.connectionEditScreenClipboard,
        pasteToRemote => l10n.screenPasteToRemote,
        keepBar => l10n.screenKeepBar,
        files => l10n.screenFiles,
        sessionDetails => l10n.screenDetailsTitle,
        disconnect => l10n.sessionInfoDisconnect,
      };

  IconData get icon => switch (this) {
        sendMenuKey || sendAltTab || sendAltF4 || sendSuper || sendPrintScreen => LucideIcons.keyboard,
        sendCtrlAltDel => LucideIcons.command,
        fit => LucideIcons.minimize2,
        fill => LucideIcons.maximize2,
        oneToOne => LucideIcons.scan,
        remoteResize => LucideIcons.monitor,
        viewOnly => LucideIcons.eye,
        fullScreen => LucideIcons.expand,
        ownWindow => LucideIcons.externalLink,
        refresh => LucideIcons.refreshCw,
        textSize => LucideIcons.type,
        frameLimit => LucideIcons.gauge,
        smoothScaling => LucideIcons.sparkles,
        sound => LucideIcons.volume2,
        touchPointer => LucideIcons.touchpad,
        touchTouch => LucideIcons.pointer,
        sendText => LucideIcons.textCursorInput,
        relativeMouse => LucideIcons.move,
        commandAsControl => LucideIcons.command,
        releaseKeyboard => LucideIcons.logOut,
        clipboard => LucideIcons.clipboardCheck,
        pasteToRemote => LucideIcons.clipboardPaste,
        keepBar => LucideIcons.pin,
        files => LucideIcons.folderOpen,
        sessionDetails => LucideIcons.activity,
        disconnect => LucideIcons.powerOff,
      };
}

/// Why an offered action cannot be picked now, to say under its greyed row.
enum ScreenWhyNot {
  /// Nothing is sent to a screen that is only looked at.
  viewOnly,

  /// The clipboard is not shared with this screen now.
  clipboardOff,

  /// The remote's server does not take relative mouse movement.
  relativeServer,

  /// This computer cannot hold the pointer (yet).
  relativeHere,

  /// The picture is covered (recording mode): nothing is sent to a remote
  /// computer nobody can see.
  covered,

  /// This device cannot play the remote's sound (no output, or a build
  /// without sound).
  soundHere;

  String textIn(AppLocalizations l10n) => switch (this) {
        viewOnly => l10n.screenWhyNotViewOnly,
        clipboardOff => l10n.screenWhyNotClipboardOff,
        relativeServer => l10n.screenWhyNotRelativeServer,
        relativeHere => l10n.screenWhyNotRelativeHere,
        covered => l10n.screenWhyNotCovered,
        soundHere => l10n.screenWhyNotSoundHere,
      };
}

/// What a screen's session offers at this moment, for whatever draws its
/// menu: which actions there are ([offered]), which are on or the choice in
/// use ([on]), and which are there but cannot be picked now, each with why
/// ([whyNot], [disabled]).
class ScreenMenuState {
  const ScreenMenuState({required this.offered, this.on = const {}, this.whyNot = const {}});

  final Set<ScreenAction> offered;
  final Set<ScreenAction> on;

  /// The offered actions that cannot be picked now, each with its reason.
  final Map<ScreenAction, ScreenWhyNot> whyNot;

  Set<ScreenAction> get disabled => whyNot.keys.toSet();

  /// Why [a] cannot be picked now, in words; null where it can, or is not
  /// offered at all.
  String? whyNotIn(AppLocalizations l10n, ScreenAction a) => whyNot[a]?.textIn(l10n);

  bool offers(ScreenAction a) => offered.contains(a);

  /// A toggle that is on, or the choice in use.
  bool isOn(ScreenAction a) => on.contains(a);

  /// Offered and to be picked now.
  bool enabled(ScreenAction a) => offered.contains(a) && !whyNot.containsKey(a);

  /// The offered actions of [g], in their order.
  List<ScreenAction> inGroup(ScreenActionGroup g) =>
      [for (final a in ScreenAction.values) if (a.group == g && offered.contains(a)) a];

  /// The groups with something offered, in their order.
  List<ScreenActionGroup> get groups =>
      [for (final g in ScreenActionGroup.values) if (offered.any((a) => a.group == g)) g];

  /// The state of a session as its view knows it.
  ///
  /// [phone]: a phone or tablet's view (no full screen, no menu key, no
  /// keyboard to let go of; the touch modes instead). [canResizeRemote]: an
  /// RDP screen, whose remote can take the view's size; [resizingRemote]:
  /// it does. [clipboardTogglable]: its person may turn the clipboard on or
  /// off here (not on a team host whose editor locked it off: no switch
  /// then, and no Paste to remote). [keyboardHeld]: the picture has the
  /// keyboard, so there is one to let go of. [sendTextShown]: a phone's
  /// Send text field is along the bottom. [detailsShown]: the session's
  /// details are shown. [barKept]: a phone's bar stays shown. [filesOffered]:
  /// the screen is reached through an SSH host, whose files can be opened.
  /// [relativeAsked]: the host's sessions ask for relative mouse, so its
  /// switch is there (a computer); it can be turned on where the server
  /// takes it ([relativeTaken]) and this computer can hold the pointer
  /// ([relativeHere]), and is on with [relativeOn]. [textSizeOffered]: an
  /// RDP screen, whose remote can be asked for another text size.
  /// [commandKeyOffered]: this computer is a Mac, whose Command key can go
  /// as Ctrl; it does with [commandAsControl]. [smoothScaling]: the picture
  /// is smoothed on this device. [ownWindowOffered]: this computer can show
  /// the screen in a window of its own, and nothing covers its picture.
  /// [covered]: recording mode covers the picture, so nothing that sends
  /// to the remote can be picked, and no sound plays.
  /// [soundAsked]: an RDP host that plays the remote's sound here, so the
  /// session's switch is there; [soundHere]: this device can ([ScreenWhyNot.soundHere]
  /// otherwise); it plays with [soundOn].
  /// [inOwnWindow]: this is that window's own menu. What belongs to the
  /// session's tab in the main window is not offered there: ending the
  /// session, the session's details (its bytes are counted in
  /// the main window), and with it everything the caller leaves out (the
  /// clipboard, the files, relative mouse, letting go of the keyboard).
  factory ScreenMenuState.of({
    required bool phone,
    required ScreenFit fit,
    required bool viewOnly,
    bool fullScreen = false,
    bool keyboardHeld = true,
    bool canResizeRemote = false,
    bool resizingRemote = false,
    bool clipboardTogglable = false,
    bool clipboardOn = false,
    ScreenTouchMode? touchMode,
    bool sendTextShown = false,
    bool detailsShown = false,
    bool barKept = false,
    bool filesOffered = false,
    bool relativeAsked = false,
    bool relativeTaken = false,
    bool relativeHere = false,
    bool relativeOn = false,
    bool textSizeOffered = false,
    bool commandKeyOffered = false,
    bool commandAsControl = false,
    bool smoothScaling = false,
    bool ownWindowOffered = false,
    bool inOwnWindow = false,
    bool covered = false,
    bool soundAsked = false,
    bool soundHere = true,
    bool soundOn = false,
  }) {
    final offered = <ScreenAction>{
      ...ScreenAction.fits,
      if (canResizeRemote) ScreenAction.remoteResize,
      ScreenAction.viewOnly,
      if (!phone) ScreenAction.fullScreen,
      if (!phone && ownWindowOffered) ScreenAction.ownWindow,
      if (phone) ScreenAction.keepBar,
      if (!inOwnWindow) ScreenAction.disconnect,
      ScreenAction.refresh,
      if (textSizeOffered) ScreenAction.textSize,
      ScreenAction.frameLimit,
      ScreenAction.smoothScaling,
      // The session's own: not in a window of its own.
      if (soundAsked && !inOwnWindow) ScreenAction.sound,
      for (final a in ScreenAction.sends)
        if (!phone || a != ScreenAction.sendMenuKey) a,
      if (phone) ...const [ScreenAction.touchPointer, ScreenAction.touchTouch, ScreenAction.sendText],
      // A computer holds the pointer for it; a phone has it in Mouse pointer mode.
      if (relativeAsked && (!phone || touchMode == ScreenTouchMode.mousePointer)) ScreenAction.relativeMouse,
      if (!phone && commandKeyOffered) ScreenAction.commandAsControl,
      if (!phone && keyboardHeld) ScreenAction.releaseKeyboard,
      if (clipboardTogglable) ScreenAction.clipboard,
      // A computer pastes with its own keys; a phone has a row for it.
      if (clipboardTogglable && phone) ScreenAction.pasteToRemote,
      if (filesOffered) ScreenAction.files,
      // (Named in the order they are listed, group after group.)
      if (!inOwnWindow) ScreenAction.sessionDetails,
    };
    final on = <ScreenAction>{
      canResizeRemote && resizingRemote ? ScreenAction.remoteResize : ScreenAction.ofFit(fit),
      if (viewOnly) ScreenAction.viewOnly,
      if (!phone && fullScreen) ScreenAction.fullScreen,
      if (phone && barKept) ScreenAction.keepBar,
      if (phone && touchMode != null) ScreenAction.ofTouch(touchMode),
      if (phone && sendTextShown) ScreenAction.sendText,
      if (detailsShown) ScreenAction.sessionDetails,
      if (relativeAsked && relativeOn && (!phone || touchMode == ScreenTouchMode.mousePointer))
        ScreenAction.relativeMouse,
      if (!phone && commandKeyOffered && commandAsControl) ScreenAction.commandAsControl,
      if (smoothScaling) ScreenAction.smoothScaling,
      if (soundAsked && soundHere && soundOn) ScreenAction.sound,
      if (clipboardTogglable && clipboardOn) ScreenAction.clipboard,
    };
    final whyNot = <ScreenAction, ScreenWhyNot>{
      // Nothing is sent to a screen that is only looked at.
      if (viewOnly)
        for (final a in ScreenAction.sends) a: ScreenWhyNot.viewOnly,
      // The first thing in its way that its person can do nothing about here,
      // then the one they can.
      if (!relativeHere)
        ScreenAction.relativeMouse: ScreenWhyNot.relativeHere
      else if (!relativeTaken)
        ScreenAction.relativeMouse: ScreenWhyNot.relativeServer
      else if (viewOnly)
        ScreenAction.relativeMouse: ScreenWhyNot.viewOnly,
      // Its field would send nothing; one that is open already can still be closed.
      if (viewOnly && !sendTextShown) ScreenAction.sendText: ScreenWhyNot.viewOnly,
      // The clipboard first: turning it on is what its person can do about it.
      if (!clipboardOn)
        ScreenAction.pasteToRemote: ScreenWhyNot.clipboardOff
      else if (viewOnly)
        ScreenAction.pasteToRemote: ScreenWhyNot.viewOnly,
      // The picture is covered: whatever would send something to the remote
      // is off, and this is the reason said, whatever else is in its way
      // (last, so it is the one kept). The view sends nothing then either
      // (ScreenController): this is what its person is told.
      if (!soundHere) ScreenAction.sound: ScreenWhyNot.soundHere,
      if (covered) ...{
        for (final a in ScreenAction.sends) a: ScreenWhyNot.covered,
        ScreenAction.relativeMouse: ScreenWhyNot.covered,
        ScreenAction.pasteToRemote: ScreenWhyNot.covered,
        if (!sendTextShown) ScreenAction.sendText: ScreenWhyNot.covered,
        if (soundHere) ScreenAction.sound: ScreenWhyNot.covered,
      },
    }..removeWhere((a, _) => !offered.contains(a));
    return ScreenMenuState(offered: offered, on: on, whyNot: whyNot);
  }
}
