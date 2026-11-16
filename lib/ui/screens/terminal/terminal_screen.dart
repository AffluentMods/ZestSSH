import 'dart:async';
import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/widgets/mosh_contact_mark.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/hosts/pending_files.dart';
import 'package:zestssh/features/shortcuts/tablet_shortcuts.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/widgets/team_logged_indicator.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/ui/screens/sharing/share_session_dialog.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/screens/sharing/watch_ui.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/clipboard_manager.dart';
import 'package:zestssh/features/terminal/session_announcer.dart';
import 'package:zestssh/features/terminal/terminal_reader.dart';
import 'package:zestssh/features/triggers/trigger_highlight_binder.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/session_ssh.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/ftps/ftps_pane_file_source.dart';
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';
import 'package:zestssh/ui/screens/tmux/tmux_start_question.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/features/snippets/save_snippet.dart';
import 'package:zestssh/ui/screens/port_forward/port_forward_screen.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/ui/screens/sftp/sftp_dual_pane_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart';
import 'package:zestssh/ui/screens/terminal/widgets/dropped_session_view.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_settings_sheet.dart';
import 'package:zestssh/ui/screens/terminal/widgets/copy_from_screen_view.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';
import 'package:zestssh/ui/screens/terminal/widgets/session_info_dialog.dart';
import 'package:zestssh/ui/screens/terminal/mobile_split_terminal.dart';
import 'package:zestssh/ui/screens/terminal/hardware_keyboard_use.dart';
import 'package:zestssh/ui/screens/terminal/soft_keyboard_return.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart' show quickConnectFocusWanted;
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';
import 'package:zestssh/ui/widgets/mobile_session_tabs.dart';
import 'package:zestssh/ui/widgets/paste_question.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/screens/terminal/session_swipe.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/features/screens/session/screen_round_trip.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';

// TODO: Decompose this 1300+ line file into smaller widgets:
// - terminal_gestures.dart (pinch/swipe/multi-finger logic)
// - terminal_speech.dart (speech-to-text)
// - terminal_context_menu.dart
// - terminal_clipboard.dart

/// URL regex pattern for detecting clickable links in terminal output.
/// Strips common trailing punctuation (period, comma, colon, semicolon,
/// closing paren/bracket) that is typically sentence punctuation, not URL.
final _urlPattern = RegExp(
  r'https?://[^\s<>\[\]{}()"' "'" r'`,;]+(?<![.,;:!?\)\]])' ,
  caseSensitive: false,
);

/// Whether a session that is disconnected as [now] stays on a phone's
/// terminal screen until its person closes it, for what it says to be
/// read: a session its host ended (with what the host said last), and a
/// session that was ended over its host's key when new keys were taken,
/// or over the key of a jump host on the way to it.
@visibleForTesting
bool staysToBeRead(SessionState? now) =>
    sessionEnded(now?.dropCause) != null || endReasonItself(now?.dropCause) == hostKeyFailedAtNewKeys;

/// Whether a phone's terminal screen closes by itself a moment after its
/// session went from [before] to [now]: the session was disconnected and
/// nothing connects it again by itself. Not a session that stays for its
/// person to read ([staysToBeRead]): that one closes when they close it.
@visibleForTesting
bool closesByItself(SessionState? before, SessionState? now) =>
    now?.status == SessionStatus.disconnected &&
    before?.status != SessionStatus.disconnected &&
    now?.isReconnecting != true &&
    !staysToBeRead(now);

/// What a phone's terminal screen keeps of a connection that failed, once it
/// has shown it: the failure while [now], the session as it is, is that
/// failure or gone (a failed connection is taken out of the list of
/// sessions a moment after it failed, and on a computer its dialog holds
/// what went wrong), and nothing once the session is anything else.
/// (The screen went back to the list as the failure was taken out: what
/// went wrong was on screen for two seconds.)
@visibleForTesting
SessionState? keptFailure(SessionState? now, SessionState? kept) {
  if (now == null) return kept;
  return now.status == SessionStatus.error ? now : null;
}

/// Whether the screen shows a phone's row of keys, as on a phone. Null in the
/// app (the system it runs on decides).
@visibleForTesting
bool? debugPhoneKeysRow;

/// Whether the screen is a phone's or a tablet's (its row of keys, its
/// on-screen keyboard), as [debugPhoneKeysRow] says in a test.
bool get _phoneScreen => debugPhoneKeysRow ?? !isDesktopPlatform;

/// Full-screen terminal emulator screen.
class TerminalScreen extends ConsumerStatefulWidget {
  final String sessionId;

  /// The split view's controls for this pane, in its toolbar in place of
  /// the split button (MobileSplitTerminal's lower or right pane).
  final Widget? paneControls;

  const TerminalScreen({super.key, required this.sessionId, this.paneControls});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  final _terminalController = TerminalController();
  final _terminalFocusNode = FocusNode();
  // The terminal's view, which a find scrolls to its current match.
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  // The find bar's field, which its key gives the keyboard back to where the
  // bar is open.
  final _findFocus = FocusNode();
  Timer? _autoCloseTimer;
  // The failed connection this screen showed, kept once it is taken out of
  // the list of sessions ([keptFailure]).
  SessionState? _failure;
  // The account the session was opened with where it is not its host's own
  // (Connect as), kept for Try again once the session is gone.
  String? _account;
  bool _showSearch = false;

  // A session that is files only: the connection its files were opened for
  // by themselves, once (connected again, it is another connection). Its
  // files are opened as it connects, and the screen stays under them.
  TerminalSession? _filesOpenedFor;

  // ── Speech-to-text state ──
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;

  // ── Session transcript recording ──
  // The recording is the session's, not this screen's: it goes on while the
  // screen is left and the session runs (it was thrown away as the screen
  // closed), and is saved as the session ends.
  bool get _isRecording => SessionTranscriptService.isRecording(widget.sessionId);

  // ── Text selection toolbar state ──
  bool _hasSelection = false;
  String _selectedText = '';

  // ── Data reception tracking (for toolbar pulse animation) ──
  bool _isReceivingData = false;
  Timer? _dataReceptionTimer;

  // ── Soft keyboard modifier state (Ctrl/Alt sticky keys) ──
  final _softKeyModifier = ValueNotifier<SoftKeyModifier>(SoftKeyModifier.none);

  /// Map cursor shape setting to xterm cursor type.
  TerminalCursorType _mapCursorType(TerminalCursorShape shape) {
    switch (shape) {
      case TerminalCursorShape.block:
        return TerminalCursorType.block;
      case TerminalCursorShape.underline:
        return TerminalCursorType.underline;
      case TerminalCursorShape.verticalBar:
        return TerminalCursorType.verticalBar;
    }
  }

  // ── Pinch-to-zoom state ──
  /// Active pointer positions (by pointer ID).
  final Map<int, Offset> _pointers = {};

  /// Font size when the pinch gesture started.
  double? _pinchBaseFontSize;

  /// Distance between the two fingers when the pinch started.
  double? _pinchBaseDistance;

  // ── Multi-finger tap detection ──
  /// Timestamp when pointers first went down (for tap detection).
  DateTime? _multiTouchStart;

  /// Whether the multi-touch gesture moved significantly (not a tap).
  bool _multiTouchMoved = false;

  /// Starting position for horizontal swipe detection.
  Offset? _swipeStart;

  // ── Long-press detection (raw pointer, bypasses gesture arena) ──
  Timer? _longPressTimer;
  Offset? _longPressPosition;
  int? _longPressPointer;

  // The one finger on the terminal, and the selection as it went down: a
  // selection it makes or grows opens the sheet as it is let go.
  ({int pointer, BufferRange? selection})? _touch;

  /// Whether the finger on the terminal made or changed the selection.
  bool get _touchSelected {
    final touch = _touch;
    final now = _terminalController.selection;
    return touch != null && now != null && now != touch.selection;
  }

  // ── Volume key mapping (Android) ──
  static const _volumeKeyChannel =
      MethodChannel('com.affluentlabs.zestssh/volume_keys');
  static const _volumeKeyEvents =
      EventChannel('com.affluentlabs.zestssh/volume_keys/events');
  StreamSubscription? _volumeKeySub;

  /// How often the keyboard was asked for while tmux shows in place of the
  /// terminal ([_showSoftKeyboard]): tmux's pane in front takes it.
  int _tmuxKeyboardAsk = 0;

  // The on-screen keyboard as the app is left and come back to: up again
  // where it was up (SoftKeyboardReturn).
  late final _keyboardReturn = SoftKeyboardReturn(
    inset: () => mounted ? View.of(context).viewInsets.bottom : 0,
    terminalFocused: () => _terminalFocusNode.hasFocus,
    mayShow: () =>
        mounted &&
        !ref.read(isAppLockedProvider) &&
        ref.read(hardwareKeyboardUseProvider).keyboardOnTap &&
        (ModalRoute.of(context)?.isCurrent ?? true),
    show: () => _terminalViewKey.currentState?.requestKeyboard(),
    ready: () async {
      try {
        await ref.read(isAppLockedProvider.notifier).resumeChecked;
      } catch (_) {/* a lock with no such check (a test's): at once */}
    },
  );

  @override
  void didChangeMetrics() {
    if (_phoneScreen) _keyboardReturn.metricsChanged();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminalController.addListener(_onSelectionChanged);
    _setupVolumeKeys();
    // A key from a keyboard (an arrow, Home, F5) is the terminal's own to
    // take, which it does while it has the focus, in the form the program at
    // the other end asked for. This screen took the same keys a second time,
    // whatever had the focus, and sent a fixed code for each: one press was
    // sent twice (one arrow up went two commands back), and to the session
    // of a screen that was not the one in front.

    // Sync soft keyboard modifier to the global provider so the
    // terminal's onOutput handler can apply Ctrl/Alt to system keyboard input.
    _softKeyModifier.addListener(() {
      if (mounted) {
        ref.read(mobileSoftKeyModifierProvider.notifier).state =
            _softKeyModifier.value;
      }
    });

    // Reverse sync: when the provider is reset (e.g. after Ctrl+key is consumed
    // by terminal_providers), push the reset back to the ValueNotifier so the
    // soft keyboard widget visually deactivates the Ctrl/Alt button.
    ref.listenManual(mobileSoftKeyModifierProvider, (prev, next) {
      if (_softKeyModifier.value != next) {
        _softKeyModifier.value = next;
      }
    });

    // (A sign-in's questions are the app's to ask, wherever they come from:
    // PhoneSignInQuestions, lib/ui/screens/terminal/phone_sign_in_questions.dart.)
  }

  /// Called whenever the terminal controller notifies (selection, highlights).
  void _onSelectionChanged() {
    final sel = _terminalController.selection;
    final hasNow = sel != null;

    if (hasNow != _hasSelection) {
      setState(() {
        _hasSelection = hasNow;
        if (hasNow) {
          // Read selected text from the terminal buffer
          final sessionState =
              ref.read(sessionStateProvider(widget.sessionId));
          final terminal = sessionState?.session?.terminal;
          if (terminal != null) {
            _selectedText = terminal.buffer.getText(sel);
          }
        } else {
          _selectedText = '';
        }
      });
    } else if (hasNow) {
      // Selection changed but still active - update the text
      final sessionState =
          ref.read(sessionStateProvider(widget.sessionId));
      final terminal = sessionState?.session?.terminal;
      if (terminal != null) {
        _selectedText = terminal.buffer.getText(sel);
      }
    }
  }

  /// Enable volume key interception on Android when the setting is on.
  void _setupVolumeKeys() {
    if (!Platform.isAndroid) return;
    final enabled = ref.read(volumeKeysEnabledProvider);
    if (!enabled) return;

    _volumeKeyChannel.invokeMethod('setEnabled', {'enabled': true});
    _volumeKeySub = _volumeKeyEvents.receiveBroadcastStream().listen((event) {
      if (event is! String) return;
      final sessions = ref.read(activeSessionsProvider.notifier);

      // Send ANSI escape sequences for Page Up / Page Down
      if (event == 'volume_up') {
        sessions.sendInput(widget.sessionId, Uint8List.fromList('\x1b[5~'.codeUnits)); // Page Up
      } else if (event == 'volume_down') {
        sessions.sendInput(widget.sessionId, Uint8List.fromList('\x1b[6~'.codeUnits)); // Page Down
      }
    });
  }

  @override
  void dispose() {
    _keyboardReturn.dispose();
    _softKeyModifier.dispose();
    _longPressTimer?.cancel();
    _autoCloseTimer?.cancel();
    _dataReceptionTimer?.cancel();
    // Disable volume key interception
    if (Platform.isAndroid) {
      _volumeKeyChannel.invokeMethod('setEnabled', {'enabled': false});
    }
    _volumeKeySub?.cancel();
    _terminalController.removeListener(_onSelectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _terminalFocusNode.dispose();
    _findFocus.dispose();
    _terminalController.dispose();
    _speech.stop();
    super.dispose();
  }

  /// Keep sessions alive when app goes to background.
  /// Only disconnect on explicit user action (red button) - NOT on
  /// app lifecycle changes. On a phone and a tablet the on-screen keyboard
  /// that was up as the app was left comes up again as it is back
  /// (SoftKeyboardReturn).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The connection is kept alive when the app goes to background. The OS
    // may still kill the socket eventually, but we don't proactively
    // disconnect.
    if (_phoneScreen) _keyboardReturn.lifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
    // What went wrong stays until its person leaves, tries again or copies
    // it, after the failed connection is taken out of the list ([keptFailure]).
    final live = ref.watch(sessionStateProvider(widget.sessionId));
    // Connected, and dropped, said to a screen reader (4.0 accessibility).
    listenSessionChanges(ref, context, widget.sessionId);
    _failure = keptFailure(live, _failure);
    if (live != null) _account ??= ref.read(activeSessionsProvider.notifier).accountOf(widget.sessionId);
    final sessionState = live ?? _failure;
    // The host's own theme where it has one, else the app's.
    final terminalTheme = ref.watch(hostTerminalThemeProvider(sessionState?.connectionId));

    final terminalStyle = ref.watch(terminalStyleProvider);
    final cursorShape = ref.watch(cursorStyleProvider);
    final terminalTitle = ref.watch(terminalTitleProvider(widget.sessionId));

    // ── Data reception tracking for pulse animation ──
    ref.listen<int>(sessionDataActivityProvider(widget.sessionId),
        (prev, next) {
      if (!mounted) return;
      if (!_isReceivingData) {
        setState(() => _isReceivingData = true);
      }
      _dataReceptionTimer?.cancel();
      _dataReceptionTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _isReceivingData = false);
      });
    });

    // Detected OS for this session
    final detectedOs = sessionState?.connectionId != null
        ? ref.watch(detectedOsProvider(sessionState!.connectionId!))
        : null;
    // ── Auto-close after disconnect (only when NOT auto-reconnecting) ──
    // When the session transitions to disconnected, check if auto-reconnect
    // is handling it. If not, start a timer to pop.
    ref.listen<SessionState?>(sessionStateProvider(widget.sessionId),
        (prev, next) {
      // (Not while it is being connected again, and not a session that
      // stays for its person to read: closesByItself.)
      if (closesByItself(prev, next)) {
        _autoCloseTimer?.cancel();
        _autoCloseTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) context.pop();
        });
      } else if (staysToBeRead(next)) {
        // Why a connection dropped is said a moment after it did, when the
        // screen has begun to close: it stays after all.
        _autoCloseTimer?.cancel();
      }
    });

    // Files asked for from a phone's host sheet before it was connected
    // (sftpPendingConnectionProvider): opened once its session is up.
    if (sessionState != null &&
        sessionState.status == SessionStatus.connected &&
        ref.watch(sftpPendingConnectionProvider) == sessionState.connectionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(sftpPendingConnectionProvider) != sessionState.connectionId) return;
        ref.read(sftpPendingConnectionProvider.notifier).state = null;
        _openSftp(sessionState);
      });
    }

    // A session that is files only (an SFTP-only host): its files open by
    // themselves as it connects, once for each connection. Under them this
    // screen says it has no terminal, with Files to open them again.
    final filesOnly = ref.read(activeSessionsProvider.notifier).isFilesOnly(widget.sessionId);
    final filesSession = sessionState?.session;
    if (filesOnly &&
        sessionState != null &&
        sessionState.status == SessionStatus.connected &&
        filesSession != null &&
        !identical(_filesOpenedFor, filesSession)) {
      _filesOpenedFor = filesSession;
      // (Where a host sheet's Files asked for them, that opens them, above.)
      if (ref.read(sftpPendingConnectionProvider) != sessionState.connectionId) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final now = ref.read(sessionStateProvider(widget.sessionId));
          if (now?.status == SessionStatus.connected) _openSftp(now!);
        });
      }
    }

    if (sessionState == null) {
      // Session was removed (e.g. user cancelled password prompt).
      // Auto-navigate back to home instead of showing a dead-end screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          // Use go instead of pop to guarantee we reach home even if
          // the route stack was replaced (e.g. after a retry via context.go).
          context.go(Routes.home);
        }
      });
      // Show a brief loading state while navigating away
      return const Scaffold(
        backgroundColor: Color(0xFF0A0A0A),
        body: SizedBox.shrink(),
      );
    }

    // A remote screen (4.0): its own page, with no terminal
    // (lib/features/screens/phone/phone_screen_view.dart); while it is not
    // connected, what a terminal's page shows then (connecting, dropped and
    // reconnecting, failed).
    if (ref.read(activeSessionsProvider.notifier).isScreen(widget.sessionId)) {
      final shell = sessionState.session?.shell;
      final screenShell = shell is ScreenShellService ? shell : null;
      final screenSession = sessionState.status == SessionStatus.connected ? screenShell?.session : null;
      return PhoneScreenView(
        sessionId: widget.sessionId,
        connectionId: sessionState.connectionId,
        label: sessionState.connectionLabel,
        session: screenSession,
        options: screenShell?.options ?? ScreenOptions.defaults,
        inTeam: screenShell?.inTeam ?? false,
        rdp: ref.read(activeSessionsProvider.notifier).isRdpScreen(widget.sessionId),
        // Files: the SSH host's, over the screen's own connection.
        onFiles: screenShell?.carrier == null ? null : () => unawaited(_openSftp(sessionState)),
        measureRoundTrip: screenShell == null ? null : screenRoundTripOf(screenShell),
        stateBody: screenSession != null
            ? null
            : sessionState.status == SessionStatus.connected
                ? const SizedBox.shrink()
                // Closed by iOS's background, and connected again on return.
                : ref.read(activeSessionsProvider.notifier).isParkedScreen(widget.sessionId) &&
                        sessionState.status != SessionStatus.error
                    ? ScreenParkedView(reconnecting: sessionState.status == SessionStatus.connecting)
                    : _buildTerminalBody(sessionState, terminalTheme, terminalStyle, cursorShape),
        background: terminalTheme.background,
        showDisconnect: sessionState.status != SessionStatus.error,
        onBack: () {
          // The screen stays connected, as a terminal does.
          if (mounted) context.go(Routes.home);
        },
        onDisconnect: _disconnect,
        wrapToolbar: _swipeable,
      );
    }

    // The row of keys above a phone's keyboard (mobile only), where Settings
    // has it: above the keyboard, or above the terminal (Keyboard row
    // position, which nothing read); none while its switch is off, or its
    // position is Disabled. Off, the terminal takes its room (e.g. for a
    // keyboard of its own).
    //
    // With a hardware keyboard (Automatic, unless Settings keeps it: Always)
    // the row hides once one is typed on and comes back as HardwareKeyboardUse
    // says (lib/ui/screens/terminal/hardware_keyboard_use.dart): the
    // on-screen keyboard typing, or a tap after 20 seconds without a hardware
    // key. Its switch off is Never. While a tap brings no on-screen keyboard
    // up, the row ends with a key that does.
    //
    // While a hardware keyboard is typed on, Settings can keep only the keys
    // it lacks instead (the default on a tablet, 3.2.1).
    final keysRowAt = ref.watch(extraKeyboardPositionProvider);
    final hardware = ref.watch(hardwareKeyboardUseProvider);
    final hardwareRow = ref.watch(keysRowHardwareProvider) ??
        HardwareKeysRow.defaultFor(tablet: MediaQuery.sizeOf(context).shortestSide >= 600);
    // (None for a session that is files only: there is nothing to type into.)
    final keysRow = sessionState.status == SessionStatus.connected &&
            !filesOnly &&
            (debugPhoneKeysRow ?? !isDesktopPlatform) &&
            ref.watch(showExtraKeyboardRowProvider) &&
            keysRowAt != 'disabled' &&
            !(hardwareRow == HardwareKeysRow.hide && hardware.rowHidden)
        // A key of the row used: taps bring the on-screen keyboard up again
        // (at the release, after the key's own tap).
        ? Listener(
            onPointerUp: (_) => ref.read(hardwareKeyboardUseProvider.notifier).wantSoftKeyboard(),
            child: TerminalSoftKeyboard(
              onKey: (key) {
                final terminal = _typingTarget(sessionState);
                if (terminal != null) typeSoftKey(terminal, key);
              },
              modifierNotifier: _softKeyModifier,
              onMicPressed: () => _handleMic(sessionState),
              isListening: _isListening,
              onShowKeyboard: hardware.keyboardOnTap ? null : _showSoftKeyboard,
              onlyMissingKeys: hardwareRow == HardwareKeysRow.missingOnly && hardware.rowHidden,
            ),
          )
        : null;

    // Hide system overlays for immersive terminal experience
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.surfaceDark,
      ),
      // The app's keys from a keyboard (TabletShortcut) where the keyboard is
      // on this screen but not in its terminal (a button of the toolbar has
      // it); in the terminal, its view's own onKeyEvent takes them first.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (_terminalFocusNode.hasFocus || textFieldHasKeyboard()) return KeyEventResult.ignored;
          return _onAppKey(event, sessionState, inTerminal: false);
        },
        child: Scaffold(
        backgroundColor: terminalTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              // Toolbar: on a phone, swiped sideways to the previous or the
              // next session (3.1); never the terminal under it.
              _swipeable(TerminalToolbar(
                sessionId: widget.sessionId,
                status: sessionState.status,
                // Where a terminal says what its shell calls it, a session
                // that is files only says SFTP (FTPS for an FTPS host's).
                terminalTitle: filesOnly
                    ? (ref.read(activeSessionsProvider.notifier).isFtps(widget.sessionId)
                        ? ConnectionProtocol.ftps.nameIn(AppLocalizations.of(context)!)
                        : AppLocalizations.of(context)!.pillSftp)
                    : terminalTitle,
                connectionLabel: sessionState.connectionLabel,
                host: sessionState.host,
                port: sessionState.port,
                username: sessionState.username,
                isRecording: _isRecording,
                isReconnecting: sessionState.isReconnecting,
                isReceivingData: _isReceivingData,
                connectedAt: sessionState.session?.startedAt,
                detectedOs: detectedOs,
                splitButton: isDesktopPlatform || widget.paneControls != null
                    ? null
                    : MobileSplitTerminal.buildSplitButton(context, ref),
                paneControls: widget.paneControls,
                onSplit: !isDesktopPlatform
                    ? () {
                        final isActive = ref.read(mobileSplitActiveProvider);
                        ref.read(mobileSplitActiveProvider.notifier).state =
                            !isActive;
                      }
                    : null,
                onDisconnect: () => _disconnect(),
                onBack: () {
                  // Background the session - keep it alive, just navigate away.
                  // Only the disconnect/power button in toolbar kills the session.
                  if (mounted) context.go(Routes.home);
                },
                onReconnect: sessionState.status == SessionStatus.disconnected &&
                        !sessionState.isReconnecting &&
                        sessionState.connectionId != null
                    ? () => _manualReconnect(sessionState)
                    : null,
                onSearch: sessionState.status == SessionStatus.connected && !filesOnly
                    ? () {
                        final wasShowing = _showSearch;
                        setState(() => _showSearch = !_showSearch);
                        // If closing search via toolbar button, re-focus terminal
                        if (wasShowing) {
                          _terminalFocusNode.requestFocus();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _terminalFocusNode.requestFocus();
                          });
                        }
                      }
                    : null,
                onSftp: _isSshSession(sessionState)
                    ? () => _openSftp(sessionState)
                    : null,
                // What runs on the host or is typed into its terminal: not
                // for a session that is files only.
                onPortForward: _isSshSession(sessionState) && !filesOnly
                    ? () => _openPortForward(sessionState)
                    : null,
                onTmux: _isSshSession(sessionState) &&
                        !filesOnly &&
                        sessionState.status == SessionStatus.connected
                    ? () {
                        final host =
                            ref.read(tmuxHostProvider(widget.sessionId));
                        if (!host.active) host.begin();
                      }
                    : null,
                onSnippets: filesOnly ? null : () => _openSnippets(sessionState),
                onSettings: () => TerminalSettingsSheet.show(context),
                isBroadcasting: ref.watch(broadcastModeProvider).enabled,
                broadcastTargetCount:
                    ref.watch(broadcastModeProvider).targetSessionIds.length,
                onBroadcastConfig: _hasMultipleSessions(ref) && !filesOnly
                    ? () => _showBroadcastPanel(ref)
                    : null,
                onSessionInfo: sessionState.status == SessionStatus.connected
                    ? () => SessionInfoDialog.show(
                          context,
                          host: sessionState.host,
                          username: sessionState.username,
                          port: sessionState.port,
                          connectedAt: sessionState.session?.startedAt,
                          detectedOs: detectedOs,
                          connectionLabel: sessionState.connectionLabel,
                        )
                    : null,
                // Open the connection editor for this session's
                // backing connection. Quick connects auto-save with a
                // raw "user@host:port" label - this is the path to
                // rename / attach an identity / configure forwards
                // without losing the active session.
                onEditConnection: sessionState.connectionId != null
                    ? () {
                        // Docked adaptive editor (same as everywhere), not a
                        // route push. Quick connects are ephemeral (`quick_`
                        // id, never saved), so open a NEW connection pre-filled
                        // from the session instead of trying to load a blank.
                        final cid = sessionState.connectionId;
                        final ephemeral =
                            cid == null || cid.startsWith('quick_');
                        ConnectionEditScreen.showModal(
                          context,
                          connectionId: ephemeral ? null : cid,
                          initialHost: ephemeral ? sessionState.host : null,
                          initialPort: ephemeral ? sessionState.port : null,
                          initialLabel: ephemeral &&
                                  sessionState.connectionLabel.isNotEmpty
                              ? sessionState.connectionLabel
                              : null,
                        );
                      }
                    : null,
              )),
              // Logged for its team: said for as long as it is.
              TeamLoggedStrip(sessionId: widget.sessionId),
              // Shared with teammates (3.0): said for as long as it is, with
              // who has the keyboard; a tap opens who is there.
              SessionShareStrip(sessionId: widget.sessionId, always: true),
              // A watched session nobody is watching (3.0).
              WatchHeldBanner(sessionId: widget.sessionId),
              // Output that asks for tmux control mode with nobody having
              // asked for tmux: whether to start it.
              TmuxStartQuestion(sessionId: widget.sessionId),

              // Mobile session tabs (shown when 2+ sessions are active)
              if (!isDesktopPlatform)
                MobileSessionTabs(
                  currentSessionId: widget.sessionId,
                  onSessionSelected: (sessionId) {
                    if (sessionId != widget.sessionId) {
                      haptic(ref, Haptic.light);
                      context.pushReplacement('/terminal/$sessionId');
                    }
                  },
                  onSessionClose: (sessionId) {
                    ref
                        .read(activeSessionsProvider.notifier)
                        .endSession(sessionId);
                  },
                ),

              // Search overlay (above terminal)
              if (_showSearch &&
                  sessionState.session != null &&
                  !ref.watch(tmuxHostProvider(widget.sessionId)).active)
                TerminalSearchBar(
                  terminal: sessionState.session!.terminal,
                  controller: _terminalController,
                  theme: terminalTheme,
                  focusNode: _findFocus,
                  onShowLine: (line) => _terminalViewKey.currentState?.scrollToLine(line),
                  onClose: () {
                    setState(() => _showSearch = false);
                    // Re-focus terminal after search closes so cursor
                    // reverts from the unfocused outline to the proper
                    // block/underline/bar set in settings.
                    _terminalFocusNode.requestFocus();
                    // Belt-and-suspenders: also request after the frame
                    // in case the widget tree hasn't settled yet.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _terminalFocusNode.requestFocus();
                    });
                  },
                ),

              // Broadcast banner
              if (ref.watch(broadcastModeProvider).enabled)
                GestureDetector(
                  onTap: () => _showBroadcastPanel(ref),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    color: AppColors.brandOrange.withValues(alpha: 0.15),
                    child: Row(
                      children: [
                        Icon(LucideIcons.radioTower,
                            size: 14, color: AppColors.accentInk),
                        const SizedBox(width: 6),
                        Text(
                          AppLocalizations.of(context)!
                              .terminalBroadcastingCount(ref
                                  .watch(broadcastModeProvider)
                                  .targetSessionIds
                                  .length),
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.accentInk,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        Icon(LucideIcons.slidersHorizontal,
                            size: 14, color: AppColors.accentInk),
                      ],
                    ),
                  ),
                ),

              // The keys row, above the terminal where Settings puts it
              // there (Keyboard row position, which nothing read).
              if (keysRow != null && keysRowAt == 'aboveTerminal') keysRow,

              // Terminal view
              Expanded(
                child: _buildTerminalBody(
                  sessionState,
                  terminalTheme,
                  terminalStyle,
                  cursorShape,
                ),
              ),

              if (keysRow != null && keysRowAt != 'aboveTerminal') keysRow,
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// The on-screen keyboard, asked for by the row's key for it: taps bring
  /// it up from now on as well. In tmux mode, for tmux's pane in front (it
  /// asked the terminal hidden behind tmux, and nothing came up).
  void _showSoftKeyboard() {
    ref.read(hardwareKeyboardUseProvider.notifier).wantSoftKeyboard();
    if (ref.read(tmuxHostProvider(widget.sessionId)).active) {
      setState(() => _tmuxKeyboardAsk++);
      return;
    }
    _terminalViewKey.currentState?.requestKeyboard();
  }

  /// Where what is typed from this screen around the terminal goes (the row
  /// of keys, a snippet, voice, a paste): in tmux mode, tmux's pane in front,
  /// and nowhere while tmux is not attached yet; else the session's own
  /// terminal. (In tmux mode it all went into the session's shell hidden
  /// behind tmux, so in tmux mode on a phone the keyboard seemed
  /// not to work at all.)
  Terminal? _typingTarget(SessionState? sessionState) {
    final tmux = ref.read(tmuxHostProvider(widget.sessionId));
    if (tmux.active) return tmux.live ? tmux.controller?.activeWindow?.activePane?.terminal : null;
    return sessionState?.session?.terminal;
  }

  /// A key from a keyboard that reached the terminal, or this screen around
  /// it ([inTerminal] false): a hardware keyboard's is noted
  /// (HardwareKeyboardUse), and an app shortcut's key runs it
  /// ([TabletShortcut]; Cmd on an iPad, Ctrl on Android). In the terminal,
  /// a key the terminal types something for (Ctrl and a letter) stays its
  /// own.
  KeyEventResult _onAppKey(KeyEvent event, SessionState sessionState, {required bool inTerminal}) {
    if (inTerminal) {
      ref.read(hardwareKeyboardUseProvider.notifier).key(event,
          softKeyboardOpen: defaultTargetPlatform == TargetPlatform.android && _keyboardReturn.open);
    }
    final shortcut = tabletShortcutFor(event);
    if (shortcut == null || (inTerminal && shortcut.typedByTerminalOn())) return KeyEventResult.ignored;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return KeyEventResult.ignored;
    switch (shortcut) {
      case TabletShortcut.nextSession:
        _switchSession(1);
      case TabletShortcut.previousSession:
        _switchSession(-1);
      case TabletShortcut.find:
        if (sessionState.status != SessionStatus.connected) return KeyEventResult.ignored;
        if (_showSearch) {
          _findFocus.requestFocus();
        } else {
          setState(() => _showSearch = true);
        }
      case TabletShortcut.zoomIn:
        _zoom(1);
      case TabletShortcut.zoomOut:
        _zoom(-1);
      case TabletShortcut.resetZoom:
        _zoom(0, resetTo: 14);
      case TabletShortcut.closeSession:
        // Asked first, as the toolbar's power button asks.
        _disconnect();
      case TabletShortcut.newConnection:
        context.push(Routes.connectionEdit);
      case TabletShortcut.quickConnect:
        // Home's list of hosts, its quick connect field with the keyboard.
        quickConnectFocusWanted.value = true;
        context.go(Routes.home);
      case TabletShortcut.settings:
        context.push(Routes.settings);
    }
    return KeyEventResult.handled;
  }

  /// The terminal's text a size larger ([delta] 1), smaller (-1), or back to
  /// [resetTo]; kept, as a pinch keeps it.
  void _zoom(int delta, {double? resetTo}) {
    final size = clampTerminalFontSize(resetTo ?? ref.read(terminalFontSizeProvider) + delta);
    ref.read(terminalFontSizeProvider.notifier).state = size;
    ref.read(settingsUpdaterProvider).setTerminalFontSize(size);
  }

  // ─── Pinch-to-zoom helpers ──────────────────────────────────────

  final _copyOnRelease = CopyOnRelease();

  /// A finger (or a click) on the terminal, as it went down: let go soon and
  /// where it went down, it was a tap (HardwareKeyboardUse.tapped).
  ({int pointer, Offset at, DateTime when})? _tap;

  /// Calculate the distance between two active pointers.
  double _pointerDistance() {
    final positions = _pointers.values.toList();
    if (positions.length < 2) return 0;
    return (positions[0] - positions[1]).distance;
  }

  /// Wraps a child widget with raw pointer tracking for gestures that
  /// must bypass xterm's internal gesture arena:
  ///
  /// - **Long-press** (mobile): hold finger ~400ms → context menu
  /// - **Pinch-to-zoom**: 2-finger scale → adjust font size
  /// - **Two-finger tap**: < 300ms → send Ctrl+C
  /// - **Three-finger tap**: < 400ms → paste clipboard
  /// - **Two-finger swipe**: horizontal → switch sessions
  Widget _pinchToZoomWrapper({
    required Widget child,
    required double currentFontSize,
    required SessionState sessionState,
  }) {
    return Listener(
      onPointerDown: (event) {
        _pointers[event.pointer] = event.position;
        _copyOnRelease.down(event);
        _tap = _pointers.length == 1 ? (pointer: event.pointer, at: event.position, when: DateTime.now()) : null;

        // (A right click is the terminal view's own, as on a computer: its
        // onSecondaryTapUp. A listener here pasted at every right click,
        // whatever Settings said and whatever the program in the terminal
        // asked for, and never opened the menu.)
        if (event.buttons == kSecondaryMouseButton || event.buttons == kMiddleMouseButton) return;

        // ── Single-finger long-press detection ──
        if (_pointers.length == 1 &&
            event.kind != PointerDeviceKind.mouse) {
          _longPressTimer?.cancel();
          _longPressPosition = event.position;
          _longPressPointer = event.pointer;
          _touch = (pointer: event.pointer, selection: _terminalController.selection);
          _longPressTimer = Timer(const Duration(milliseconds: 800), () {
            if (_pointers.length == 1 &&
                _longPressPointer != null &&
                _longPressPosition != null) {
              // A selection this touch made (a long press selects a word) is
              // the finger's to grow: the sheet waits for it to be let go.
              // Opened now, it took the touch, and the selection stopped
              // growing.
              if (_touchSelected) return;
              _showTerminalContextMenu(
                  _longPressPosition!, sessionState);
              _touch = null;
              _longPressPointer = null;
              _longPressPosition = null;
            }
          });
        } else {
          // Multi-touch started - cancel any pending long-press
          _longPressTimer?.cancel();
          _longPressPointer = null;
          _longPressPosition = null;
          _touch = null;
        }

        if (_pointers.length == 2) {
          _pinchBaseFontSize = currentFontSize;
          _pinchBaseDistance = _pointerDistance();
          _multiTouchStart = DateTime.now();
          _multiTouchMoved = false;
          _swipeStart = event.position;
        } else if (_pointers.length == 3) {
          _multiTouchStart = DateTime.now();
          _multiTouchMoved = false;
        }
      },
      onPointerMove: (event) {
        final oldPos = _pointers[event.pointer];
        _pointers[event.pointer] = event.position;

        // Detect significant movement (not a tap)
        if (oldPos != null &&
            (event.position - oldPos).distance > 10) {
          _multiTouchMoved = true;
        }

        // A finger that has moved from where it went down is no long press,
        // however slowly it moves (measured from one move to the next, a
        // slow drag never moved, and the sheet opened under it), and a few
        // pixels are enough: a scroll that starts slowly and then stops is
        // no press (the sheet used to jump up
        // under a finger that had begun to scroll).
        if (event.pointer == _longPressPointer &&
            _longPressPosition != null &&
            (event.position - _longPressPosition!).distance > kTerminalPressSlop) {
          _longPressTimer?.cancel();
          _longPressPointer = null;
          _longPressPosition = null;
        }

        if (_pointers.length == 2 &&
            _pinchBaseFontSize != null &&
            _pinchBaseDistance != null &&
            _pinchBaseDistance! > 0) {
          final currentDistance = _pointerDistance();
          final scale = currentDistance / _pinchBaseDistance!;
          final newSize = clampTerminalFontSize(_pinchBaseFontSize! * scale);
          final rounded = newSize.roundToDouble();
          ref.read(terminalFontSizeProvider.notifier).state = rounded;
        }
      },
      onPointerUp: (event) {
        final fingerCount = _pointers.length;
        _pointers.remove(event.pointer);

        // A selection made with a mouse (a tablet's, a phone's) is copied as
        // its button is let go, where copy on select is on, as on a computer
        // (it never was here); one made by touch keeps the bar's Copy.
        if (_copyOnRelease.up(event)) {
          final terminal = sessionState.session?.terminal;
          if (terminal != null) copySelectionIfEnabled(ref, terminal, _terminalController);
        }

        // A tap: where a hardware keyboard was used, the keys row may come
        // back (HardwareKeyboardUse).
        final tap = _tap;
        if (tap != null && tap.pointer == event.pointer) {
          _tap = null;
          if ((event.position - tap.at).distance <= kTouchSlop &&
              DateTime.now().difference(tap.when) < const Duration(milliseconds: 400)) {
            ref.read(hardwareKeyboardUseProvider.notifier).tapped();
          }
        }

        // Cancel long-press timer on finger lift
        if (event.pointer == _longPressPointer) {
          _longPressTimer?.cancel();
          _longPressPointer = null;
          _longPressPosition = null;
        }

        // The finger that made or grew a selection, let go: the sheet, with
        // the selection's own actions.
        if (event.pointer == _touch?.pointer) {
          if (_pointers.isEmpty && _touchSelected) {
            _showTerminalContextMenu(event.position, sessionState);
          }
          _touch = null;
        }

        if (_pointers.isEmpty && _multiTouchStart != null) {
          final elapsed =
              DateTime.now().difference(_multiTouchStart!).inMilliseconds;

          // Two-finger tap (< 300ms, no movement) → send Ctrl+C
          if (fingerCount == 2 &&
              elapsed < 300 &&
              !_multiTouchMoved) {
            haptic(ref, Haptic.light);
            sessionState.session?.terminal.textInput('\x03');
          }

          // Three-finger tap → paste from clipboard
          if (fingerCount == 3 &&
              elapsed < 400 &&
              !_multiTouchMoved) {
            final terminal = sessionState.session?.terminal;
            if (terminal != null) {
              haptic(ref, Haptic.medium);
              _pasteToTerminal(terminal);
            }
          }

          _multiTouchStart = null;
          _multiTouchMoved = false;
        }

        if (_pointers.length < 2) {
          // Check for horizontal swipe between sessions
          if (_swipeStart != null &&
              _multiTouchMoved &&
              fingerCount == 2) {
            final dx = event.position.dx - _swipeStart!.dx;
            if (dx.abs() > 100) {
              _switchSession(dx < 0 ? 1 : -1);
            }
          }

          if (_pinchBaseFontSize != null) {
            final size = ref.read(terminalFontSizeProvider);
            ref.read(settingsUpdaterProvider).setTerminalFontSize(size);
          }
          _pinchBaseFontSize = null;
          _pinchBaseDistance = null;
          _swipeStart = null;
        }
      },
      onPointerCancel: (event) {
        _pointers.remove(event.pointer);
        if (_tap?.pointer == event.pointer) _tap = null;

        if (event.pointer == _longPressPointer) {
          _longPressTimer?.cancel();
          _longPressPointer = null;
          _longPressPosition = null;
        }
        if (event.pointer == _touch?.pointer) _touch = null;

        if (_pointers.length < 2) {
          _pinchBaseFontSize = null;
          _pinchBaseDistance = null;
          _swipeStart = null;
          _multiTouchStart = null;
        }
      },
      child: child,
    );
  }

  /// The top bar [toolbar], swiped sideways between sessions on a phone (3.1;
  /// a split's panes keep their bars as they were).
  Widget _swipeable(Widget toolbar) {
    if (widget.paneControls != null || ref.watch(mobileSplitActiveProvider) || !sessionSwipeOn(context)) {
      return toolbar;
    }
    return SessionSwipeHeader(sessionId: widget.sessionId, child: toolbar);
  }

  /// Switch to the next/previous active session.
  /// [direction]: 1 = next, -1 = previous.
  void _switchSession(int direction) {
    final sessions = ref.read(activeSessionsProvider);
    final activeIds = sessions.entries
        .where((e) =>
            e.value.status == SessionStatus.connected ||
            e.value.status == SessionStatus.connecting)
        .map((e) => e.key)
        .toList();

    if (activeIds.length < 2) return;

    final currentIndex = activeIds.indexOf(widget.sessionId);
    if (currentIndex == -1) return;

    final nextIndex =
        (currentIndex + direction) % activeIds.length;
    final nextId = activeIds[nextIndex];

    haptic(ref, Haptic.light);
    context.pushReplacement('/terminal/$nextId');
  }

  Widget _buildTerminalBody(
    SessionState sessionState,
    TerminalTheme theme,
    TerminalStyle style,
    TerminalCursorShape cursorShape,
  ) {
    switch (sessionState.status) {
      case SessionStatus.connecting:
        return _buildConnectingScreen(sessionState, theme);

      case SessionStatus.connected:
        // A session that is files only has no terminal: its place says so,
        // with its files to open (they open by themselves as it connects).
        // No terminal view, which would bring a keyboard up for nothing.
        if (ref.read(activeSessionsProvider.notifier).isFilesOnly(widget.sessionId)) {
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.folderOpen, size: 44, color: theme.foreground.withValues(alpha: 0.5)),
                  const SizedBox(height: 14),
                  Text(
                    ref.read(activeSessionsProvider.notifier).isFtps(widget.sessionId)
                        ? AppLocalizations.of(context)!.sessionFilesOnlyLineFtps
                        : AppLocalizations.of(context)!.sessionFilesOnlyLine,
                    key: const ValueKey('terminal-files-only'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.foreground.withValues(alpha: 0.6), fontSize: 13.5, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    key: const ValueKey('terminal-files-only-open'),
                    onPressed: () => _openSftp(sessionState),
                    icon: const Icon(LucideIcons.folderOpen, size: 18),
                    label: Text(AppLocalizations.of(context)!.sftpOnlyOpenFiles),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.brandOrange),
                  ),
                ],
              ),
            ),
          );
        }
        // tmux mode takes the terminal's place; the toolbar, tabs and the
        // extra-keys row stay (keys are routed to the focused tmux pane).
        final tmuxHost = ref.watch(tmuxHostProvider(widget.sessionId));
        if (tmuxHost.active) {
          // Find searches the tmux pane in front, its bar above the panes.
          return TmuxSessionView(
            host: tmuxHost,
            onLeave: tmuxHost.stop,
            findOpen: _showSearch,
            onFindClose: () => setState(() => _showSearch = false),
            keyboardAsk: _tmuxKeyboardAsk,
          );
        }
        return Stack(
          children: [
            // Terminal view with gestures
            // Long-press & right-click detection is handled by raw
            // pointer events inside _pinchToZoomWrapper so it bypasses
            // xterm's internal gesture arena.
            _pinchToZoomWrapper(
              currentFontSize: style.fontSize,
              sessionState: sessionState,
              child: Padding(
                padding: EdgeInsets.all(
                  ref.watch(terminalMarginProvider),
                ),
                child: RepaintBoundary(
                  // To a screen reader: one node with the session's name,
                  // its new lines read out, and Read the screen (4.0
                  // accessibility).
                  child: TerminalReadAloud(
                    terminal: sessionState.session!.terminal,
                    name: sessionState.connectionLabel,
                    onActivate: () => _terminalViewKey.currentState?.requestKeyboard(),
                    child: TriggerHighlightBinder(
                    terminal: sessionState.session!.terminal,
                    controller: _terminalController,
                    connectionId: sessionState.session!.connectionId,
                    child: TerminalView(
                      sessionState.session!.terminal,
                      key: _terminalViewKey,
                      controller: _terminalController,
                      focusNode: _terminalFocusNode,
                      theme: theme,
                      textStyle: style,
                      padding: const EdgeInsets.all(4),
                      autofocus: true,
                      cursorType: _mapCursorType(cursorShape),
                      cursorBlink: ref.watch(cursorBlinkProvider),
                      // A program's own hide request is obeyed (it was drawn
                      // whatever it asked), and the person's choice of when
                      // the cursor is drawn (4.0).
                      alwaysShowCursor: false,
                      hideCursor: ref.watch(cursorVisibilityProvider) == TerminalCursorVisibility.never,
                      hideCursorWhileOutput:
                          ref.watch(cursorVisibilityProvider) == TerminalCursorVisibility.notDuringOutput,
                      deleteDetection: true,
                      // The keyboard without suggestions where its person
                      // chose the compact one (Settings): on many keyboards
                      // a smaller row above the keys.
                      keyboardType: ref.watch(compactKeyboardProvider)
                          ? TextInputType.visiblePassword
                          : TextInputType.text,
                      // The keyboard is asked not to learn from the terminal
                      // unless its person turned that off (Settings).
                      personalizedLearning: !ref.watch(keyboardIncognitoProvider),
                      enableUrlDetection: true,
                      // A terminal's own keys from a keyboard, as every
                      // terminal has them (terminalKeys): the widget's own
                      // took Ctrl+A and Ctrl+V from the shell on Android.
                      shortcuts: terminalKeys(
                        paste: () => pasteClipboardIntoTerminal(context, ref, sessionState.session!.terminal),
                      ),
                      // What the keyboard commits from its clipboard is a
                      // paste too, with its questions.
                      onKeyboardPaste: (text) => pasteTextIntoTerminal(context, ref, sessionState.session!.terminal, text),
                      // The app's keys first (and a hardware keyboard noted).
                      onKeyEvent: (node, event) => _onAppKey(event, sessionState, inTerminal: true),
                      // Option (Alt) as Meta, as Settings has it (an iPad's
                      // and an iPhone's on until changed).
                      altIsMeta: ref.watch(optionAsMetaProvider),
                      // While a hardware keyboard is typed on, a tap gives
                      // the terminal its input and no on-screen keyboard.
                      keyboardOnTap: ref.watch(hardwareKeyboardUseProvider).keyboardOnTap,
                      onKeyboardInput: () => ref.read(hardwareKeyboardUseProvider.notifier).softText(),
                      // A right click, as a computer has it: a paste where
                      // Settings says so and nothing is selected, otherwise
                      // the terminal's menu where the pointer is. A program
                      // that takes the mouse is sent the click instead (the
                      // view does not call this then).
                      onSecondaryTapUp: (details, offset) {
                        if (ref.read(desktopRightClickPasteProvider) && _terminalController.selection == null) {
                          _quickPasteFromClipboard(sessionState);
                        } else {
                          _showTerminalContextMenu(details.globalPosition, sessionState, atPointer: true);
                        }
                      },
                      // A middle click pastes, where Settings says so (as on
                      // a computer; a phone and a tablet had none).
                      onTertiaryTapUp: (details, offset) {
                        if (ref.read(desktopMiddleClickPasteProvider)) _quickPasteFromClipboard(sessionState);
                      },
                      onUrlTap: (url) => _openUrl(url),
                      onTapUp: (details, cellOffset) {
                        _handleTerminalTap(
                          sessionState.session!.terminal,
                          cellOffset,
                        );
                      },
                    ),
                  ),
                  ),
                ),
              ),
            ),
            // (The old floating Copy/Share/Snippet toolbar was removed - its
            // actions now live in the single long-press action sheet, which
            // is selection-aware. Avoids two menus stacking on long-press.)
            // A built-in Mosh session's "last contact" while its host is
            // quiet (4.0).
            Positioned(
              top: 0,
              right: 0,
              child: IgnorePointer(child: MoshContactMark(shell: sessionState.session?.shell)),
            ),
          ],
        );

      case SessionStatus.error:
        // A failed connection that was taken out of the list of sessions
        // has nothing left to end: ending it would put it back for a moment,
        // as a disconnected session.
        void endIfStillListed() {
          if (ref.read(sessionStateProvider(widget.sessionId)) == null) return;
          ref.read(activeSessionsProvider.notifier).endSession(widget.sessionId);
        }
        return ConnectionErrorView(
          errorMessage: sessionState.errorMessage,
          connectionLabel: sessionState.connectionLabel,
          connectionId: sessionState.connectionId,
          connectionLog: sessionState.connectionLog,
          host: sessionState.host,
          port: sessionState.port,
          username: sessionState.username,
          onRetry: () async {
            // Again, signed in as it was (its account) and in the space it
            // worked in, as a computer's Try again does. (The host was read
            // from the space on screen and signed in to as its own account:
            // a session opened with Connect as tried again as another, and
            // one of a host of another space did not open.)
            final connId = sessionState.connectionId;
            if (connId == null) return;
            final sessions = ref.read(activeSessionsProvider.notifier);
            final newId = ref.read(sessionStateProvider(widget.sessionId)) != null
                ? await sessions.openAgain(widget.sessionId)
                : await sessions.openHostAgain(connId, account: _account);
            // Use pushReplacement so home is still underneath for back navigation
            if (newId != null && mounted) context.pushReplacement('/terminal/$newId');
          },
          onEditConnection: () {
            final cid = sessionState.connectionId;
            if (cid == null) return;
            // Docked adaptive editor; pre-fill from the session for an
            // ephemeral quick-connect (`quick_` id) instead of loading a blank.
            final ephemeral = cid.startsWith('quick_');
            ConnectionEditScreen.showModal(
              context,
              connectionId: ephemeral ? null : cid,
              initialHost: ephemeral ? sessionState.host : null,
              initialPort: ephemeral ? sessionState.port : null,
              initialLabel: ephemeral && sessionState.connectionLabel.isNotEmpty
                  ? sessionState.connectionLabel
                  : null,
            );
          },
          onGoBack: () {
            // End the failed session and navigate home.
            // Use go(home) instead of pop() because if the user
            // retried (which uses pushReplacement), pop may not have
            // a destination. go(home) always works.
            try {
              endIfStillListed();
            } catch (_) {
              // Don't let cleanup errors block navigation
            }
            if (mounted) context.go(Routes.home);
          },
        );

      case SessionStatus.disconnected:
        return _buildDisconnectedView(sessionState, theme);
    }
  }

  // ─── JuiceSSH-style connecting screen ─────────────────────────

  Widget _buildConnectingScreen(
    SessionState sessionState,
    TerminalTheme theme,
  ) {
    final log = sessionState.connectionLog;
    final label = sessionState.connectionLabel;
    // The log lines below are masked by a plain function, so this screen
    // must rebuild itself when recording mode flips.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);

    return Column(
      children: [
        // ── Logo + status (centered in remaining space) ──
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ZestSSH logo - large and prominent
                Image.asset(
                  'assets/icon.png',
                  width: 96,
                  height: 96,
                  errorBuilder: (_, _, _) => Icon(
                    LucideIcons.terminal,
                    size: 96,
                    color: AppColors.accentInk,
                  ),
                ),
                const SizedBox(height: 28),

                // "Connecting..." title
                Text(
                  AppLocalizations.of(context)!.terminalConnecting,
                  style: TextStyle(
                    color: theme.foreground,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 12),

                // Connection name + spinner
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: theme.foreground.withValues(alpha: 0.5),
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: RedactedText(
                        Redactable.host(label),
                        style: TextStyle(
                          color: theme.foreground.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                // A session to a watched Crate's host waits here for
                // someone to watch it (3.0).
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: WatchWaitingPanel(sessionId: widget.sessionId),
                ),
              ],
            ),
          ),
        ),

        // ── Live connection log at the bottom ──
        if (log.isNotEmpty)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.background.withValues(alpha: 0.0),
                  theme.background,
                ],
                stops: const [0.0, 0.15],
              ),
            ),
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              itemCount: log.length,
              itemBuilder: (context, index) {
                // Show newest at bottom (reversed list, so index 0 is newest)
                final msg = log[log.length - 1 - index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  // Recording mode: a log line names the host, the user or
                  // both, so it goes through the connection-line mask.
                  child: Text(
                    maskConnectionLine(msg,
                        host: sessionState.host,
                        username: sessionState.username),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: theme.foreground.withValues(alpha: 0.45),
                      height: 1.4,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  // ─── Disconnected / Reconnecting view ─────────────────────────

  Widget _buildDisconnectedView(
    SessionState sessionState,
    TerminalTheme theme,
  ) =>
      DroppedSessionView(
        sessionId: widget.sessionId,
        sessionState: sessionState,
        theme: theme,
        closing: _autoCloseTimer?.isActive ?? false,
        onReconnect: sessionState.connectionId == null ? null : () => _manualReconnect(sessionState),
      );

  /// Manually reconnect a disconnected session: signed in as it was, in the
  /// space it worked in ([ActiveSessionsNotifier.openAgain]).
  Future<void> _manualReconnect(SessionState sessionState) async {
    if (sessionState.connectionId == null) return;
    final newId = await ref.read(activeSessionsProvider.notifier).openAgain(widget.sessionId);
    // Use pushReplacement so home is still underneath for back navigation
    if (newId != null && mounted) context.pushReplacement('/terminal/$newId');
  }

  /// Check if the current session is an SSH connection (not telnet/local shell).
  bool _isSshSession(SessionState? state) {
    return state?.session?.shell is SshService;
  }

  /// Whether there are 2+ active sessions (broadcast needs at least 2).
  bool _hasMultipleSessions(WidgetRef ref) {
    final sessions = ref.read(activeSessionsProvider);
    return sessions.entries
            .where((e) => e.value.status == SessionStatus.connected)
            .length >=
        2;
  }

  /// Show the broadcast control panel - toggle + session picker in one sheet.
  void _showBroadcastPanel(WidgetRef ref) {
    final sessions = ref.read(activeSessionsProvider);
    final connectedEntries = sessions.entries
        .where((e) => e.value.status == SessionStatus.connected)
        .toList();

    if (connectedEntries.length < 2) return;

    // The app's dialog (3.4), a phone's sheet: broadcasting on or off and the
    // sessions it types into, each taking effect at once; Select all the
    // footer's side link and Done its main button. (A sheet of its own
    // before, its on and off a pill in its header, its rows tinted orange.)
    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: StatefulBuilder(
        builder: (context, setSheetState) {
          final l10n = AppLocalizations.of(context)!;
          final broadcast = ref.read(broadcastModeProvider);
          final isEnabled = broadcast.enabled;
          final targetCount = broadcast.targetSessionIds.length;
          final totalCount = connectedEntries.length;

          void turn(bool on) {
            if (on) {
              ref.read(broadcastModeProvider.notifier).enable(connectedEntries.map((e) => e.key).toSet());
            } else {
              ref.read(broadcastModeProvider.notifier).disable();
            }
            setSheetState(() {});
          }

          void toggle(String id) {
            ref.read(broadcastModeProvider.notifier).toggleTarget(id);
            setSheetState(() {});
          }

          return ZestDialogShell(
            size: ZestModalSize.compact,
            tone: ZestDialogTone.neutral,
            icon: LucideIcons.radioTower,
            title: l10n.terminalBroadcast,
            subtitle: isEnabled
                ? l10n.terminalBroadcastSessionCount(targetCount, totalCount)
                : l10n.terminalBroadcastSubtitle,
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // On or off: a switch, as every setting that takes effect at
                // once.
                MergeSemantics(
                  child: ListTile(
                    key: const ValueKey('broadcast-sheet-on'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      isEnabled ? l10n.terminalBroadcastOn : l10n.terminalBroadcastOff,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    trailing: ZestSwitch(value: isEnabled, onChanged: turn),
                    onTap: () => turn(!isEnabled),
                  ),
                ),
                if (isEnabled) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.terminalSessionsHeader,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: AppColors.v3TextSecondary,
                    ),
                  ),
                  for (final entry in connectedEntries)
                    ListTile(
                      key: ValueKey('broadcast-sheet-session-${entry.key}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(LucideIcons.terminal, size: 16, color: AppColors.v3TextSecondary),
                      title: RedactedText(
                        Redactable.host(entry.value.connectionLabel.isNotEmpty
                            ? entry.value.connectionLabel
                            : (entry.value.host ?? entry.key)),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: entry.key == widget.sessionId ? FontWeight.w600 : null,
                        ),
                      ),
                      subtitle: entry.key == widget.sessionId
                          ? Text(l10n.terminalCurrent,
                              style: TextStyle(fontSize: 11, color: AppColors.v3TextSecondary))
                          : null,
                      trailing: ZestSwitch(
                        value: broadcast.targetSessionIds.contains(entry.key),
                        onChanged: (_) => toggle(entry.key),
                      ),
                      onTap: () => toggle(entry.key),
                    ),
                ],
              ],
            ),
            tertiaryKey: const ValueKey('broadcast-sheet-all'),
            tertiaryAction: isEnabled
                ? (
                    label: targetCount == totalCount ? l10n.terminalDeselectAll : l10n.terminalSelectAll,
                    onPressed: () {
                      if (targetCount == totalCount) {
                        // All but this one off.
                        ref.read(broadcastModeProvider.notifier).enable({widget.sessionId});
                      } else {
                        ref
                            .read(broadcastModeProvider.notifier)
                            .enable(connectedEntries.map((e) => e.key).toSet());
                      }
                      setSheetState(() {});
                    },
                  )
                : null,
            primaryKey: const ValueKey('broadcast-sheet-done'),
            primaryAction: (label: l10n.done, icon: null, onPressed: () => Navigator.of(context).pop()),
          );
        },
      ),
    );
  }

  /// Show upgrade dialog for Pro-gated features.
  Future<void> _showProGate(String featureName) async {
    final shouldUpgrade = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.sparkles,
      title: AppLocalizations.of(context)!.terminalProGateTitle(featureName),
      body: AppLocalizations.of(context)!.terminalProGateMsg(featureName),
      confirmLabel: AppLocalizations.of(context)!.upgrade,
      cancelLabel: AppLocalizations.of(context)!.notNow,
    );

    if (shouldUpgrade == true && mounted) {
      context.push(Routes.upgrade);
    }
  }

  /// Open SFTP file browser.
  Future<void> _openSftp(SessionState sessionState) async {
    final shell = sessionState.session?.shell;
    // The host's Crate must allow SFTP: its switch is the
    // vault's for browsing files, an FTPS host's too (3.4), as a computer's
    // file manager asks it of every host.
    if ((sshServiceOfShell(shell) != null || shell is FtpsShellService) &&
        !await ref.read(activeSessionsProvider.notifier).hostAllows(sessionState.connectionId, CrateSwitches.sftp)) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showTopSnackBar(context, shell is FtpsShellService ? l10n.orchardFtpsNotAllowed : l10n.orchardSftpNotAllowed,
            isWarning: true);
      }
      return;
    }
    // An FTPS host (3.4): its files in the two-pane browser, on a phone too
    // (the phone's own browser speaks SFTP alone so far).
    if (shell is FtpsShellService) {
      final client = shell.client;
      if (client == null || !mounted) return;
      final files = FtpsPaneFileSource(client: client, sourceId: widget.sessionId, reconnect: shell.reconnect);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SftpDualPaneScreen(
            ftps: files,
            connectionLabel: sessionState.connectionLabel,
            initialSessionId: widget.sessionId,
          ),
        ),
      );
      await files.close();
      return;
    }
    // An SSH session's own connection, or the one a screen goes through
    // (4.0: a screen's Files).
    final ssh = sshServiceOfShell(shell);
    if (ssh == null) return;

    try {
      final sftp = SftpService(ssh.client);
      await sftp.open();

      if (mounted) {
        final isDesktop = isDesktopPlatform;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => isDesktop
                ? SftpDualPaneScreen(
                    sftp: sftp,
                    connectionLabel: sessionState.connectionLabel,
                    initialSessionId: widget.sessionId,
                  )
                : SftpBrowserScreen(
                    sftp: sftp,
                    connectionLabel: sessionState.connectionLabel,
                    connectionId: sessionState.connectionId,
                    username: sessionState.username,
                    sessionId: widget.sessionId,
                  ),
          ),
        );
        // Its held deletes made first (closed under them, they failed).
        await (isDesktop ? sftp.close() : closePhoneSftp(ref.read(sftpDeleteHoldProvider), sftp));
      }
    } catch (e) {
      if (mounted) {
        // Why, in the app's language, with what was thrown in its report
        // (it said "SFTP error:" and the raw error).
        showTopSnackBar(context, sftpStartFailure(e), isError: true, details: '$e');
      }
    }
  }

  /// Open port forwarding screen (free on every tier).
  Future<void> _openPortForward(SessionState sessionState) async {
    final sessions = ref.read(activeSessionsProvider.notifier);
    // The host's Crate must allow port forwarding.
    if (!await sessions.hostAllows(sessionState.connectionId, CrateSwitches.forward)) {
      if (mounted) {
        showTopSnackBar(context, AppLocalizations.of(context)!.orchardForwardNotAllowed, isWarning: true);
      }
      return;
    }
    if (!mounted) return;
    final portForwardService = sessions.getPortForwardService(widget.sessionId);
    if (portForwardService == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PortForwardScreen(
          portForwardService: portForwardService,
          connectionLabel: sessionState.connectionLabel,
          connectionId: sessionState.connectionId,
        ),
      ),
    );
  }

  /// Open snippets as a bottom sheet drawer for quick access.
  void _openSnippets(SessionState? sessionState) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      builder: (sheetContext) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Icon(LucideIcons.code, size: 18, color: AppColors.accentInk),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.of(context)!.terminalSnippets,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SnippetsScreen(
              onExecute: (command, shown, secrets) async {
                Navigator.pop(sheetContext);
                // Check for dangerous commands before execution
                if (ref.read(dangerousCommandProtectionProvider)) {
                  final dangers = DangerousCommandService.checkFilled(command);
                  if (dangers.isNotEmpty && mounted) {
                    final result = await showDangerousCommandDialog(
                      context,
                      command: shown,
                      runs: command,
                      matches: dangers,
                    );
                    if (result.dontAskAgain) {
                      await ref
                          .read(settingsUpdaterProvider)
                          .setDangerousCommandProtection(false);
                    }
                    if (!result.proceed) return;
                  }
                }
                // Send the command to the terminal (tmux's pane in front in
                // tmux mode).
                final terminal = _typingTarget(sessionState);
                if (terminal != null) {
                  typePickedSnippet(ref.read, terminal, command, secrets: secrets);
                }
              },
              executeCommand: listOptionsFrom(sessionState),
            ),
          ),
        ],
      ),
    );
  }

  /// Saves the currently selected terminal text as a new snippet.
  ///
  /// Opens the snippet editor pre-filled with the selected text as the
  /// command. The user can set a label, category, etc. before saving.
  Future<void> _saveSelectionAsSnippet(String text) async {
    if (text.isEmpty) return;

    // snippetCategoriesProvider is now a synchronous derived Provider
    // (live off snippetsProvider) - read it directly, no `.future`.
    final categories = ref.read(snippetCategoriesProvider);

    final result = await showSnippetEditDialog(
      context: context,
      existingCategories: categories,
      initialCommand: text.trim(),
    );

    if (result != null && mounted) {
      final crud = ref.read(snippetCrudProvider);
      final saved = await saveSnippetSaying(
        context,
        name: result.label,
        added: true,
        write: () => crud.create(
          label: result.label,
          command: result.command,
          category: result.category,
          confirmBeforeRun: result.confirmBeforeRun,
          metadata: result.metadata,
        ),
      );
      if (saved && mounted) _terminalController.clearSelection();
    }
  }

  // ─── Terminal context menu ──────────────────────────────────────

  /// Extract all text from the terminal buffer.
  ///
  /// Honours each row's `isWrapped` flag: a row flagged wrapped is a
  /// SOFT-WRAP continuation of the row above (the terminal folded a long
  /// line to fit the width), so we must NOT put a newline before it - that
  /// would split a single logical line (a long command, URL, or crontab
  /// entry) into pieces on copy. Only genuine line breaks get a `\n`.
  String _getTerminalText(Terminal terminal) {
    final buffer = terminal.buffer;
    final out = StringBuffer();
    for (var i = 0; i < buffer.lines.length; i++) {
      final line = buffer.lines[i];
      if (i != 0 && !line.isWrapped) out.write('\n');
      out.write(line.toString());
    }
    return out.toString().trimRight();
  }

  /// The terminal's actions: a sheet from the bottom for a finger (a long
  /// press), and a menu where the pointer is for a mouse ([atPointer]: a
  /// right click), with the same actions in the same order.
  void _showTerminalContextMenu(
    Offset position,
    SessionState sessionState, {
    bool atPointer = false,
  }) {
    final terminal = sessionState.session?.terminal;
    if (terminal == null) return;

    if (!atPointer) haptic(ref, Haptic.medium);

    final hasSelection = _hasSelection && _selectedText.isNotEmpty;
    final groups = _terminalActionGroups(
      AppLocalizations.of(context)!,
      hasSelection: hasSelection,
      isRecording: _isRecording,
      keysRow: debugPhoneKeysRow ?? !isDesktopPlatform,
    );

    final Future<String?> picked;
    if (atPointer) {
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
      final at = overlay.globalToLocal(position);
      picked = showMenu<String>(
        context: context,
        color: ZestTokens.surfaceRaisedAlt,
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ZestTokens.borderStrong),
        ),
        position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
        items: [
          for (final (i, group) in groups.indexed) ...[
            if (i > 0) const PopupMenuDivider(),
            for (final action in group.actions)
              PopupMenuItem<String>(
                key: ValueKey('terminal-menu-${action.value}'),
                value: action.value,
                height: 36,
                child: Row(
                  children: [
                    Icon(
                      action.icon,
                      size: 16,
                      color: action.destructive ? ZestTokens.statusCritical : ZestTokens.textTertiary,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        action.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: action.destructive ? ZestTokens.statusCritical : ZestTokens.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      );
    } else {
      picked = showModalBottomSheet<String>(
        context: context,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.5),
        builder: (ctx) => _TerminalActionSheet(groups: groups),
      );
    }
    picked.then((value) {
      if (value == null || !mounted) return;
      haptic(ref, Haptic.selection);
      switch (value) {
        // ── Selection actions ──
        case 'copySel':
          _copySelection(terminal);
          _terminalController.clearSelection();
        case 'shareSel':
          Share.share(_selectedText);
          _terminalController.clearSelection();
        case 'snippetSel':
          _saveSelectionAsSnippet(_selectedText);
        // ── Terminal actions ──
        case 'find':
          setState(() => _showSearch = true);
        case 'copyAll':
          _copySession(terminal);
        case 'readScreen':
          showTerminalReader(context, terminal: terminal, name: sessionState.connectionLabel);
        case 'paste':
          _pasteToTerminal(terminal);
        case 'clipboard':
          _showClipboardHistory(terminal);
        case 'record':
          _toggleRecording(sessionState);
        case 'export':
          _exportTranscript(terminal, sessionState.connectionLabel);
        case 'share':
          _shareTranscript(terminal);
        case 'shareSession':
          if (SessionShares.of(widget.sessionId) != null) {
            showShareParticipants(context, widget.sessionId);
          } else {
            showShareSession(context, widget.sessionId);
          }
        case 'clear':
          _confirmClearTerminal(terminal);
        case 'keysRow':
          context.push(Routes.keyboardRow);
      }
    });
  }

  /// Confirm before wiping the scrollback - clearing is destructive and has
  /// no undo, so a stray tap shouldn't discard the whole session history.
  Future<void> _confirmClearTerminal(Terminal terminal) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.terminalClearTitle,
      body: l10n.terminalClearBody,
      confirmLabel: l10n.terminalClear,
    );
    if (ok == true) {
      terminal.buffer.clear();
    }
  }

  /// Select all text in the terminal buffer.
  // ignore: unused_element
  void _selectAll(Terminal terminal) {
    final buffer = terminal.buffer;
    final lineCount = buffer.lines.length;
    if (lineCount == 0) return;

    final lastCol = buffer.lines[lineCount - 1].toString().length;

    _terminalController.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(lastCol, lineCount - 1),
    );
  }

  void _copySelection(Terminal terminal) {
    final selection = _terminalController.selection;
    if (selection == null) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.terminalNoSelection,
      );
      return;
    }
    final text = terminal.buffer.getText(selection);
    Clipboard.setData(ClipboardData(text: text));
    ref.read(clipboardManagerProvider.notifier).add(text);
    if (mounted) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.terminalSelectionCopied,
      );
    }
  }

  void _copySession(Terminal terminal) {
    showDialog(
      context: context,
      builder: (ctx) => CopyFromScreenView(
        text: _getTerminalText(terminal),
        onCopy: (toCopy, hasRange) {
          Clipboard.setData(ClipboardData(text: toCopy));
          ref.read(clipboardManagerProvider.notifier).add(toCopy);
          Navigator.pop(ctx);
          if (mounted) {
            showTopSnackBar(
              context,
              hasRange
                  ? AppLocalizations.of(context)!.terminalSelectionCopiedClipboard
                  : AppLocalizations.of(context)!.terminalAllTextCopied,
            );
          }
        },
      ),
    );
  }

  Future<void> _pasteToTerminal(Terminal terminal) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) return;

    // As a paste may type it: no control character but a tab and a line
    // break.
    final text = Terminal.pasteable(data!.text!);
    if (text.isEmpty) return;
    // Every line break counts, a CR alone as well (only LFs were counted: a
    // text of CRs was one line here, and pasted unasked).
    final lineCount = pasteLineBreaks(text) + 1;

    // Confirm multi-line or large pastes to prevent accidental command execution.
    // Any paste containing newlines can trigger command execution in the shell,
    // so even small multi-line pastes need confirmation; where the shell runs
    // each line as it arrives, the question says so.
    if ((lineCount > 1 || text.length > 500) && mounted) {
      final confirmed = await showPasteQuestion(context, text, runs: lineCount > 1 && !terminal.bracketedPasteMode);
      if (!confirmed) return;
    }
    if (!mounted) return;

    // Check for dangerous commands before pasting
    if (ref.read(dangerousCommandProtectionProvider)) {
      final dangerMatches = DangerousCommandService.checkFilled(text);
      if (dangerMatches.isNotEmpty && mounted) {
        final result = await showDangerousCommandDialog(
          context,
          command: text,
          matches: dangerMatches,
          isPaste: true,
        );
        if (result.dontAskAgain) {
          await ref
              .read(settingsUpdaterProvider)
              .setDangerousCommandProtection(false);
        }
        if (!result.proceed) return;
      }
    }

    // Use terminal.paste() for bracketed paste mode support.
    // If the shell has enabled bracketed paste, xterm wraps the text
    // in escape sequences so the shell knows it's a paste (prevents
    // accidental command execution on multi-line pastes).
    terminal.paste(text);
  }

  /// Quick paste fired by right-click (desktop / desktop-on-tablet): the
  /// app's one paste of a terminal ([pasteClipboardIntoTerminal]), which
  /// asks first where the shell would run each line as it arrives (it has
  /// not asked for bracketed paste) and where the text looks dangerous. (It
  /// was a copy of that paste, which said a line break never ran a line,
  /// whatever the shell.) Mobile long-press continues to surface the full
  /// context menu via [_showTerminalContextMenu].
  Future<void> _quickPasteFromClipboard(SessionState sessionState) async {
    final terminal = _typingTarget(sessionState);
    if (terminal == null) return;
    await pasteClipboardIntoTerminal(context, ref, terminal);
  }

  void _showClipboardHistory(Terminal terminal) {
    final entries = ref.read(clipboardManagerProvider);
    if (entries.isEmpty) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.terminalClipboardHistoryEmpty,
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(LucideIcons.clipboardPaste,
                    size: 18, color: AppColors.accentInk),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.of(context)!.terminalClipboardHistory,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    ref.read(clipboardManagerProvider.notifier).clear();
                    Navigator.pop(sheetContext);
                  },
                  child: Text(AppLocalizations.of(context)!.terminalClearAll),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: entries.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 16),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final preview = entry.text.length > 100
                    ? '${entry.text.substring(0, 100)}...'
                    : entry.text;
                return ListTile(
                  dense: true,
                  title: Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    // As a paste may type it, and asked first where the shell
                    // would run its lines as they arrive.
                    final text = Terminal.pasteable(entry.text);
                    if (text.isEmpty || !mounted) return;
                    // (The screen's own context: the sheet's is gone with it.)
                    if (!await askBeforeLinesRun(this.context, terminal, text) || !mounted) return;
                    // Check for dangerous commands
                    if (ref.read(dangerousCommandProtectionProvider)) {
                      final dangers = DangerousCommandService.checkFilled(text);
                      if (dangers.isNotEmpty && mounted) {
                        final result = await showDangerousCommandDialog(
                          this.context,
                          command: text,
                          matches: dangers,
                          isPaste: true,
                        );
                        if (result.dontAskAgain) {
                          await ref
                              .read(settingsUpdaterProvider)
                              .setDangerousCommandProtection(false);
                        }
                        if (!result.proceed) return;
                      }
                    }
                    // Use paste() for bracketed paste mode support
                    terminal.paste(text);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Toggle session transcript recording on/off. Stopping SAVES the
  /// recording (to the transcripts folder) before it is discarded, and says
  /// where it went; it used to be thrown away silently.
  Future<void> _toggleRecording(SessionState sessionState) async {
    final sessionId = widget.sessionId;
    final label = sessionState.connectionLabel;

    if (_isRecording) {
      final path = await SessionTranscriptService.saveToFile(sessionId);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      if (path == null) {
        // Not saved: the recording goes on, so nothing is lost, as on a
        // computer (it was stopped and thrown away, said as "Recording
        // stopped").
        showTopSnackBar(context, l10n.desktopTerminalAreaSaveTranscriptError,
            isError: true, details: '${SessionTranscriptService.lastSaveError ?? 'Not saved'}');
        return;
      }
      SessionTranscriptService.stopRecording(sessionId);
      setState(() {});
      // The file name embeds the (masked) host label; the free-text rule
      // masks any address in the rest of the path.
      // With the way to read it (nothing in the app opened one).
      showTopSnackBar(context, l10n.terminalTranscriptSaved(Redactable.freeText(path).display),
          isSuccess: true,
          actionLabel: l10n.transcriptsOpen,
          onAction: () => context.push(Routes.transcriptView, extra: path));
    } else {
      SessionTranscriptService.startRecording(sessionId, label);
      setState(() {});
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.terminalRecordingSession,
      );
    }
  }

  Future<void> _exportTranscript(Terminal terminal, String connectionLabel) async {
    // Use transcript service if we have a recording, otherwise raw buffer
    if (SessionTranscriptService.isRecording(widget.sessionId)) {
      final path =
          await SessionTranscriptService.saveToFile(widget.sessionId);
      if (path == null && mounted) {
        // Said, with what stopped it (it said nothing).
        showTopSnackBar(context, AppLocalizations.of(context)!.desktopTerminalAreaSaveTranscriptError,
            isError: true, details: '${SessionTranscriptService.lastSaveError ?? 'Not saved'}');
      }
      if (path != null && mounted) {
        // Recording mode: the saved path embeds the (already masked) file name
        // and may name a host, so the free-text rule masks any address or
        // registered name in it, matching the desktop export toast.
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!
              .terminalTranscriptSaved(Redactable.freeText(path).display),
        );
      }
      return;
    }

    // Not recording: what the terminal holds now, saved as a recording is
    // (encrypted, framed with the same header and warning, in the transcripts
    // folder where the Transcripts page lists it). It was written as plain
    // text to terminal_<time>.txt in the documents folder, which nothing in
    // the app listed or opened.
    final l10n = AppLocalizations.of(context)!;
    if (SessionTranscriptService.getBufferText(terminal).trim().isEmpty) {
      showTopSnackBar(context, l10n.transcriptNothingToSave);
      return;
    }
    final path = await SessionTranscriptService.saveSnapshot(terminal, connectionLabel: connectionLabel);
    if (!mounted) return;
    if (path == null) {
      // In the app's words, with what stopped it to copy.
      showTopSnackBar(context, l10n.desktopTerminalAreaSaveTranscriptError,
          isError: true, details: '${SessionTranscriptService.lastSaveError ?? 'Not saved'}');
      return;
    }
    showTopSnackBar(context, l10n.terminalTranscriptSaved(Redactable.freeText(path).display),
        isSuccess: true,
        actionLabel: l10n.transcriptsOpen,
        onAction: () => context.push(Routes.transcriptView, extra: path));
  }

  Future<void> _shareTranscript(Terminal terminal) async {
    final text = _getTerminalText(terminal);
    await Share.share(text);
  }

  // ─── Speech-to-text ────────────────────────────────────────────

  Future<void> _handleMic(SessionState sessionState) async {
    final isPro = ref.read(isProProvider);
    if (!isPro) {
      await _showProGate(AppLocalizations.of(context)!.terminalSpeechToText);
      return;
    }

    final terminal = _typingTarget(sessionState);
    if (terminal == null) return;

    if (_isListening) {
      await _speech.stop();
      if (!mounted) return;
      setState(() => _isListening = false);
      return;
    }

    final available = await _speech.initialize();
    if (!available) {
      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.terminalSpeechUnavailable,
          isError: true,
        );
      }
      return;
    }

    setState(() => _isListening = true);

    _speech.listen(
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          // Security: strip control characters from speech recognition
          // output before sending to the terminal/remote shell.
          final sanitized = CommandText.withoutControlCharacters(result.recognizedWords);
          if (sanitized.isNotEmpty) {
            terminal.textInput(sanitized);
          }
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        // Privacy: force on-device recognition so spoken commands are never
        // relayed to a cloud speech service. On platforms/devices without an
        // on-device recognizer this makes dictation unavailable rather than
        // silently sending audio off-device - the correct trade-off for an
        // SSH client with a no-tracking stance.
        onDevice: true,
      ),
    );

    // Auto-stop after speech ends
    _speech.statusListener = (status) {
      if (status == 'done' || status == 'notListening') {
        if (mounted) setState(() => _isListening = false);
      }
    };
  }

  // ─── URL detection & tap ───────────────────────────────────────

  /// Handle a tap on a terminal cell - detect and open URLs.
  void _handleTerminalTap(Terminal terminal, CellOffset cellOffset) {
    final buffer = terminal.buffer;
    if (cellOffset.y >= buffer.lines.length) return;

    final lineText = buffer.lines[cellOffset.y].toString();

    // Find all URLs in this line and check if tap is within one
    for (final match in _urlPattern.allMatches(lineText)) {
      if (cellOffset.x >= match.start && cellOffset.x <= match.end) {
        final url = match.group(0)!;
        _openUrl(url);
        return;
      }
    }
  }

  /// URL schemes safe to hand to the OS from untrusted terminal output.
  /// Blocks javascript:, data:, file:, blob:, vbscript:, etc. Enforced at the
  /// sink here (mirrors the desktop path) so the check never depends on every
  /// URL producer staying narrow.
  static const _allowedUrlSchemes = {'http', 'https', 'ssh', 'sftp', 'ftp'};

  /// Open a URL in the system browser after user confirmation.
  /// Security: terminal output is untrusted (from remote server), so always
  /// confirm before opening URLs to prevent drive-by navigation attacks.
  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // Reject dangerous schemes (javascript:, data:, file:, …) before the
    // dialog is even shown.
    if (!_allowedUrlSchemes.contains(uri.scheme.toLowerCase())) return;

    // Ask for confirmation before opening URLs from terminal output
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: AppLocalizations.of(context)!.terminalOpenUrlTitle,
      // The address itself, whole: what is opened is what is read here. (A
      // direction override in it drew it as another address.)
      body: withHiddenCharactersShown(url),
      confirmLabel: AppLocalizations.of(context)!.terminalOpen,
    );
    if (confirmed != true) return;

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.terminalCouldNotOpenUrl(withHiddenCharactersShown(url)),
        );
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.terminalOpenUrlFailed,
          isError: true, details: '$e'
        );
      }
    }
  }

  // ─── Disconnect ────────────────────────────────────────────────

  Future<void> _disconnect() async {
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: AppLocalizations.of(context)!.terminalDisconnect,
      body: AppLocalizations.of(context)!.terminalDisconnectConfirm,
      confirmLabel: AppLocalizations.of(context)!.terminalDisconnect,
    );

    if (confirmed == true) {
      await ref
          .read(activeSessionsProvider.notifier)
          .endSession(widget.sessionId);
    }
  }
}

/// One of the terminal's actions, in its sheet and in its menu at the pointer.
class _TerminalAction {
  const _TerminalAction(this.value, this.icon, this.label, {this.iconColor, this.destructive = false});

  /// What the sheet or the menu gives back when it is picked.
  final String value;
  final IconData icon;
  final String label;
  final Color? iconColor;
  final bool destructive;
}

/// A group of the terminal's actions, under [label] in the sheet (none for
/// the last, Clear).
typedef _TerminalActionGroup = ({String? label, List<_TerminalAction> actions});

/// The terminal's actions, in their groups: what is selected first where
/// something is ([hasSelection]), then the terminal's own, then Clear. A
/// phone's and a tablet's have the row of keys among them ([keysRow]).
List<_TerminalActionGroup> _terminalActionGroups(
  AppLocalizations l10n, {
  required bool hasSelection,
  required bool isRecording,
  bool keysRow = false,
}) =>
    [
      if (hasSelection)
        (
          label: l10n.terminalSelectionHeader,
          actions: [
            _TerminalAction('copySel', LucideIcons.copy, l10n.terminalCopySelection),
            _TerminalAction('shareSel', LucideIcons.share, l10n.terminalShareSelection),
            _TerminalAction('snippetSel', LucideIcons.bookmarkPlus, l10n.terminalSaveAsSnippet),
          ],
        ),
      (
        label: l10n.terminalTerminalHeader,
        actions: [
          _TerminalAction('copyAll', LucideIcons.boxSelect, l10n.terminalCopyFromScreen),
          _TerminalAction('readScreen', LucideIcons.scrollText, l10n.terminalReadScreen),
          _TerminalAction('paste', LucideIcons.clipboardPaste, l10n.terminalPaste),
          _TerminalAction('find', LucideIcons.search, l10n.terminalFind),
          _TerminalAction('clipboard', LucideIcons.clipboardList, l10n.terminalClipboardHistory),
          _TerminalAction(
            'record',
            isRecording ? LucideIcons.stopCircle : LucideIcons.circle,
            isRecording ? l10n.terminalStopRecording : l10n.terminalRecordSession,
            iconColor: isRecording ? AppColors.error : AppColors.brandOrange,
          ),
          _TerminalAction('export', LucideIcons.download, l10n.terminalExportTranscript),
          _TerminalAction('share', LucideIcons.share2, l10n.terminalShareTranscript),
          if (kOrchardsEnabled) _TerminalAction('shareSession', LucideIcons.users, l10n.shareMenuItem),
          if (keysRow) _TerminalAction('keysRow', LucideIcons.keyboard, l10n.settingsExtraKeyboardRow),
        ],
      ),
      (
        label: null,
        actions: [_TerminalAction('clear', LucideIcons.trash, l10n.terminalClear, destructive: true)],
      ),
    ];

/// The single long-press action sheet for the terminal. Replaces both the
/// old plain popup menu AND the floating Copy/Share/Snippet toolbar with one
/// grouped, icon-led sheet. When there's an active selection it leads with
/// selection actions; otherwise it goes straight to terminal-wide actions.
class _TerminalActionSheet extends StatelessWidget {
  const _TerminalActionSheet({required this.groups});

  /// What it offers ([_terminalActionGroups]).
  final List<_TerminalActionGroup> groups;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: AppColors.divider, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        // Scrolls where it is taller than a sheet may be (at most 9/16 of the
        // screen): on a phone held sideways its last rows were cut off, Paste
        // among them.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, group) in groups.indexed) ...[
                if (i > 0) const _SheetDivider(),
                if (group.label != null) _label(group.label!),
                for (final action in group.actions)
                  _row(context,
                      icon: action.icon,
                      iconColor: action.iconColor,
                      label: action.label,
                      value: action.value,
                      destructive: action.destructive),
              ],
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  // A group's name is a heading to a screen reader (4.0 accessibility pass).
  Widget _label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            header: true,
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: AppColors.accentInk.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
      );

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    Color? iconColor,
    bool destructive = false,
  }) {
    final fg = destructive ? AppColors.error : AppColors.onSurface;
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      // 52 high at least, taller where the text is larger (it was 52 always,
      // and a long name ran off the sheet at twice the text size).
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
          child: Row(
            children: [
              Icon(
                icon,
                size: 21,
                color: destructive
                    ? AppColors.error
                    : (iconColor ?? AppColors.onSurface.withValues(alpha: 0.75)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetDivider extends StatelessWidget {
  const _SheetDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 6),
        child: Divider(
          height: 1,
          color: AppColors.onSurface.withValues(alpha: 0.08),
        ),
      );
}
