import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView;
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/notifications/widgets/notification_toast_overlay.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/terminal/terminal_dictation.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart' show puttyImportHere;
import 'package:zestssh/ui/screens/security/lock_curtain.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_save_dialog.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_launch.dart';
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/providers/workspace_providers.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_open_dialog.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/router/link_pages.dart' show openShellSection;
import 'package:zestssh/ui/screens/desktop/maximized_panes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/tab_merge_undo.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/session_persistence_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart' show XProgramTarget;
import 'package:zestssh/services/session_ssh.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/tray_service.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart';
import 'package:zestssh/services/multi_window_service.dart';
import 'package:zestssh/services/window_service.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/screens/desktop/widgets/narrow_sidebar.dart';
import 'package:zestssh/ui/screens/desktop/widgets/host_slide_out_panel.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_editor_dock.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_status_bar.dart';
import 'package:zestssh/features/screens/view/screen_view.dart' show ScreenView;
import 'package:zestssh/features/screens/view/screen_full_screen.dart' show screenFullScreenSessionProvider;
import 'package:zestssh/ui/screens/desktop/widgets/automation_view.dart';
import 'package:zestssh/features/hosts/connect_link.dart' show quickConnectLinkText;
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/hosts/open_selected_hosts.dart' show openHostInSplit;
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/networks/pages/networks_page.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart' show layoutPresetLabel;
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/widgets/layout_preset_picker.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_failed_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/ui/screens/desktop/widgets/quick_connect_v3.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/update_banner.dart';
import 'package:zestssh/ui/widgets/update_dialog.dart' show showLastUpdateResult, showUpdateDialog;
import 'package:zestssh/services/update_check_service.dart' show UpdateInfo;
import 'package:zestssh/providers/update_providers.dart'
    show UpdateRestart, appBuildNumberProvider, autoUpdateStartProvider, inAppUpdateSupportedProvider, takeLastUpdate, updateOpenSessionCountProvider;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/command_palette_item.dart';
import 'package:zestssh/ui/widgets/command_palette.dart';
import 'package:zestssh/services/clipboard_manager.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart' show pasteClipboardIntoTerminal;
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/server_question_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/sign_in_link_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/passphrase_prompt_dialog.dart';
import 'package:zestssh/models/redactable.dart';
import 'dart:ui' as ui;
import 'package:pasteboard/pasteboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/ui/screens/desktop/dialogs/get_connected_dialogs.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/ui/screens/help/support_hub_page.dart';
import 'package:zestssh/ui/screens/desktop/widgets/triggers_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/history_view.dart';
import 'package:zestssh/utils/help_links.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/ui/screens/desktop/app_closing.dart';
import 'package:zestssh/providers/security_providers.dart' show isAppLockedProvider;
import 'package:zestssh/services/shortcut_service.dart';
import 'package:zestssh/ui/screens/home/app_icon_shortcuts.dart';
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout, touchDesktopShells;
import 'package:zestssh/features/orchards/setup/setup_command_host.dart' show restoresSavedTabsAtStart;
import 'package:zestssh/utils/after_next_frame.dart';

/// The main desktop shell with sidebar, tabbed terminals, and status bar.
///
/// Layout:
/// ```
/// ┌─────────┬────────────────────────────────┐
/// │         │  [Tab Bar]                     │
/// │ Sidebar │  ┌──────────────────────────┐  │
/// │         │  │                          │  │
/// │ Quick   │  │     Terminal Pane(s)     │  │
/// │ Connect │  │                          │  │
/// │         │  └──────────────────────────┘  │
/// │ Favs    ├────────────────────────────────┤
/// │ Conns   │  [Status Bar]                  │
/// │ Active  └────────────────────────────────┘
/// │ IDs     │
/// │ Settings│
/// └─────────┘
/// ```

/// How much larger the window's frame (its title bar, side rail and status
/// bar) draws its words as the system's text grows: their 48-pixel bar,
/// 44-pixel rail items and 28-pixel status bar hold them to there, and keep
/// their sizes. From 1.25 times a rail item's two lines were cut and the title
/// bar's tree selector ran over; at 1.5 the status bar cut its words. The
/// pages grow their words fully.
const double kDesktopFrameTextScale = 1.15;
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  /// Called in place of the window's full screen, where a test sets it (a
  /// test has no window).
  @visibleForTesting
  static VoidCallback? debugToggleFullscreen;

  /// Shows Settings in place of showSettingsPopup, where a test sets it (to
  /// see what a pop-up that cannot be shown leaves behind).
  @visibleForTesting
  static Future<void> Function(BuildContext context)? debugShowSettingsPopup;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  /// Wraps the shell for window captures: the redacted screenshot action and
  /// the report form's attachment (spec 7c/8b).
  final GlobalKey _shellCaptureKey = GlobalKey();

  /// The Support Hub has stepped aside for a picture of the app.
  bool _hubHiddenForCapture = false;

  // The shell's own node takes focus when nothing else has it (autofocus)
  // and receives the app-level chords. It is invisible and its rect is the
  // whole window, so it must never be a Tab destination: reading-order
  // traversal would list it first and land on it when a form wraps around.
  final _focusNode =
      FocusNode(debugLabel: 'DesktopShell', skipTraversal: true);

  /// Session id we should auto-open SFTP for as soon as it transitions to
  /// connected. Set when the user picks a host from the SFTP server picker
  /// (used when SFTP is invoked while no sessions are active).
  String? _pendingSftpAutoOpen;

  /// Captured in [initState] so [dispose] can clear clipboard history
  /// without touching `ref` - by the time `dispose` runs, the
  /// [ConsumerStatefulElement] is already deactivated and reading
  /// `ref` throws "Cannot use 'ref' after the widget was disposed".
  late final ClipboardManager _clipboardManager;

  /// Told when a broadcast stops by itself.
  StreamSubscription<String>? _broadcastStops;

  /// A Mac's Quit from outside the app (the Dock, logging out) ends it as
  /// the app's own Quit does ([_endTheApp]); null on other systems.
  AppLifecycleListener? _systemQuit;

  /// Whether this shell has the Settings pop-up on screen. The provider
  /// says Settings is asked for; this says whether it is shown, which the
  /// provider alone could not: it stayed true with nothing on screen (asked
  /// for before this shell was up, or the shell gone under the pop-up), and
  /// every click on the gear after that changed nothing.
  bool _settingsPopupShowing = false;

  @override
  void initState() {
    super.initState();
    // Activate pane tree persistence listener
    ref.read(paneTreePersistenceProvider);
    // Eagerly initialize the workTabs notifier so its paneTree/sessions
    // listeners are wired before any session is created.
    ref.read(workTabsProvider);
    // Capture the clipboard manager notifier for use in dispose() - see
    // [_clipboardManager] field doc.
    _clipboardManager = ref.read(clipboardManagerProvider.notifier);
    _setupCloseConfirmation();
    _setupTray();
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      _systemQuit = AppLifecycleListener(onExitRequested: _onSystemQuit);
    }
    // On a phone's or a tablet's large screen (4.0) this shell is
    // Home, at touch size: it counts itself, so that what opens a page or a
    // session puts it here (desktopShellInUse). Turning the device can take
    // it down and put it up again: a computer's saved sessions are not
    // restored there (a phone's and a tablet's never were, and each turn
    // would have opened them again), and no update is looked for (the
    // stores update the app).
    if (_onTouch) {
      touchDesktopShells++;
      // A host picked from the app icon's shortcuts, as the phone's Home.
      ShortcutService.pendingConnection.addListener(_appIconShortcutSoon);
      _appIconShortcutSoon();
    } else {
      _checkRestoredSessions();
    }
    _checkDeleteFailures();
    // "Update and restart" quits through here (update_dialog.dart).
    UpdateRestart.endApp = _endForUpdate;
    if (!_onTouch) _checkLastUpdate();
    // A report that could not be sent last time (spec 8d) is delivered by
    // the ticket poller, which the app starts once the database is open.
    // Register a hardware-level key handler so shortcuts like Ctrl+K work
    // even when the terminal (xterm) has focus. KeyboardListener only
    // receives events that propagate to its FocusNode, but the terminal
    // consumes them first. HardwareKeyboard intercepts at the platform
    // level before any Focus widget.
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    // A quick connect link's host, typed into Quick connect: one that comes
    // while the shell is up, and (below) one that came before.
    quickConnectLinkText.addListener(_quickConnectFromLink);
    // A broadcast that stops by itself (its tab came down to one terminal
    // on screen) is said.
    _broadcastStops = ref.read(broadcastModeProvider.notifier).stoppedByItself.listen((_) {
      if (!mounted) return;
      showTopSnackBar(context, AppLocalizations.of(context)!.broadcastStoppedOneTerminal, isInfo: true);
    });
    // A host-key verification can already be QUEUED when this shell mounts:
    // a workspace connected while the app sat on the lock screen, or the
    // shell was rebuilt (lock redirect) mid-drain with entries still pending.
    // The build-time listener fires only when the queue HEAD changes, so an
    // already-pending head would never be shown and that session would wait
    // forever (the old single-slot provider self-healed by overwriting; the
    // queue does not). Mirror the terminal screen's pending-prompt check.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // (On a phone's or a tablet's screen the app asks them: PhoneSignInQuestions.)
      if (!_onTouch) {
        if (ref.read(hostKeyVerificationProvider) != null &&
            !_hostKeyDialogShowing) {
          _showDesktopHostKeyDialog();
        }
        // The same for a server's sign-in question (a 2FA code).
        if (ref.read(serverQuestionProvider) != null) {
          _showDesktopServerQuestions();
        }
        // And for a login banner's link the sign-in waits on.
        if (ref.read(signInNoticeProvider) != null) _showDesktopSignInNotices();
      }
      // And for Settings, asked for while no shell was up to show it (a
      // zestssh:// link, a team's join, a jump to a setting, while the app
      // was locked): the listener below hears only a change.
      if (ref.read(settingsPopupOpenProvider)) _showSettingsPopup();
      _quickConnectFromLink();
    });
  }

  @override
  void dispose() {
    if (_onTouch) {
      touchDesktopShells--;
      ShortcutService.pendingConnection.removeListener(_appIconShortcutSoon);
    }
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    quickConnectLinkText.removeListener(_quickConnectFromLink);
    _broadcastStops?.cancel();
    _systemQuit?.dispose();
    if (UpdateRestart.endApp == _endForUpdate) UpdateRestart.endApp = null;
    // The app locked, as a rule: this screen goes, and can answer nothing more.
    // The window's close and the tray's Quit are the app's own from here
    // (closeWithoutShell); a close sent here did nothing, and a locked app could
    // only be force closed.
    final closeRequested = _closeRequested;
    if (closeRequested != null) WindowService.instance?.clearOnCloseRequested(closeRequested);
    TrayService.instance?.onQuit = null;
    _closingStep.dispose();
    // Security: clear clipboard history on shell disposal to prevent
    // sensitive terminal content from lingering in memory. Uses the
    // captured [_clipboardManager] rather than ref.read() because
    // dispose runs after the consumer element has been deactivated. When
    // the app's scope is gone first, the history went with it. A moment
    // later, once the tree is taken down: a provider is not changed while
    // it is, and where the app's scope stays up (the app locking) a debug
    // build refused it and ended this dispose halfway.
    final clipboard = _clipboardManager;
    scheduleMicrotask(() {
      if (clipboard.mounted) clipboard.clear();
    });
    _focusNode.dispose();
    super.dispose();
  }

  /// Whether this shell stands on a phone's or a tablet's screen (decided as
  /// it comes up: a device's kind does not change).
  final bool _onTouch = isTouchLayout;

  void _appIconShortcutSoon() => Future.microtask(() {
        if (mounted) connectAppIconShortcut(ref, _connectTo);
      });

  /// Hardware-level key handler that fires BEFORE any Focus widget.
  /// Returns true if the shortcut was handled (prevents propagation).
  bool _hardwareKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // Lock ZestSSH works from anywhere, to step away at once (4.0): Settings, a
    // dialog, the Support Hub or a terminal in front. The lock is drawn over the
    // app's navigator, so it covers whatever is open. Its default
    // (Ctrl/Cmd+Shift+L) is no terminal input, and bare Ctrl+L still clears a
    // terminal's screen. A remote screen's picture keeps every key, as below.
    if (_lockKey(event) && !_remoteScreenHasFocus()) {
      unawaited(LockCurtain.lockByYou(ref));
      return true;
    }
    // While Settings is open the keys are its own: no shortcut acts on the
    // shell behind the pop-up (a tab closed, a pane split, out of sight).
    if (ref.read(settingsPopupOpenProvider)) return false;
    // The same while the Support Hub is over the shell, but for its own key,
    // which goes back to the sessions, and the palette's, the way out from
    // everywhere (it comes back from the hub first).
    if (ref.read(supportHubOpenProvider)) {
      final bindings = ref.read(shortcutBindingsProvider);
      if (bindings.matches(event, ShortcutAction.supportHub) && _shellInFront) {
        _toggleSupportHub();
        return true;
      }
      if (_isPaletteKey(event, bindings) && _shellInFront) {
        _showCommandPalette();
        return true;
      }
      return false;
    }

    // Speech to text stops on Esc (4.0), from the terminal it types into too:
    // the one Esc is taken for that, and the next is the terminal's again.
    if (_dictationStopKey(event)) {
      unawaited(ref.read(dictationProvider.notifier).stop());
      return true;
    }

    // ── Remote screen focus gate (4.0) ───────────────────────────
    //
    // While a remote screen's picture has the keyboard, every key is the
    // remote computer's, the palette's and the app's other shortcuts too:
    // F8 (its menu, which also lets go of the keyboard) is the way out.
    if (_remoteScreenHasFocus()) return false;

    // ── Terminal focus gate ──────────────────────────────────────
    //
    // While the user is typing INSIDE a terminal, the app claims
    // essentially nothing. Terminal programs live on the full chord
    // space - bash readline on bare Ctrl+letters (Ctrl+K/T/W/...),
    // nvim/emacs/tmux/htop on Ctrl+anything, Alt+anything, and
    // F-keys - and any app shortcut firing instead reads as "the
    // terminal is broken". (We used to allowlist only ~15 bash
    // readline chords here, which is exactly why users kept finding
    // NEW stolen keys: every TUI uses a different set. Inverting the
    // rule fixes the whole class.)
    //
    // The single exception is the command-palette chord
    // (its key in Settings, Ctrl+Shift+K unless changed there, or the
    // legacy Ctrl+Shift+P alias: [_isPaletteKey]) - the
    // escape hatch back into app-land. Every other app action stays
    // reachable through the palette, so nothing is lost; it just
    // stops being one accidental keystroke away while in a shell.
    if (_terminalHasFocus()) {
      if (_isPaletteKey(event, ref.read(shortcutBindingsProvider))) {
        _showCommandPalette();
        return true;
      }
      // Close-tab is the one other app chord allowed to fire from inside a
      // terminal: its default (Ctrl/Cmd+Shift+W) is not a terminal input, so
      // catching it here lets the user close the tab without un-focusing,
      // while bare Ctrl+W still flows to the pty (readline delete-word,
      // nano's search). A user who rebinds it to a terminal key opts into
      // that themselves.
      if (ref.read(shortcutBindingsProvider).matches(
          event, ShortcutAction.closeTab)) {
        _closeCurrentTab();
        return true;
      }
      // Broadcast is stopped (or started) from where the typing is: while
      // it is on, every key goes to every terminal of the tab, so the way
      // out has to work from inside one. (Its default, Ctrl/Cmd+Shift+B, is
      // no terminal input; it reached the terminal as Ctrl+B before.)
      if (ref.read(shortcutBindingsProvider).matches(
          event, ShortcutAction.toggleBroadcast)) {
        _toggleBroadcast();
        return true;
      }
      // Find in terminal is for the terminal the typing is in: its default
      // (Ctrl/Cmd+Shift+F) is no terminal input either (a terminal sends
      // nothing for it), and from inside one it did nothing at all.
      if (ref.read(shortcutBindingsProvider).matches(
          event, ShortcutAction.findInTerminal)) {
        _findInTerminal();
        return true;
      }
      // Speech to text types into the terminal the typing is in (4.0): its
      // default (Ctrl+Shift+Space) is no terminal input either. Where
      // nothing listens (Linux) the key stays the terminal's.
      if (ref.read(voiceInputSupportedProvider) &&
          ref.read(shortcutBindingsProvider).matches(event, ShortcutAction.dictate)) {
        _toggleDictation();
        return true;
      }
      // Everything else flows untouched into TerminalView → pty.
      return false;
    }

    // A dialog keeps its keys: nothing here acts on the shell behind it (Find
    // opened under one, and its Esc gave the terminal the keyboard with the dialog
    // still open).
    if (!_shellInFront) return false;

    // ── Rebindable shortcut dispatch ───────────────────────────
    //
    // The user can rebind any of these via Settings → Keyboard
    // Shortcuts. We look up the current binding (override → default)
    // and fire the matching handler. Hardcoded fallbacks below
    // remain for shortcuts that aren't yet wired into the
    // dispatcher (mostly the deeper layout / pane management
    // ones which have their own complex handlers further down
    // this file).
    final bindings = ref.read(shortcutBindingsProvider);
    if (_isPaletteKey(event, bindings)) {
      _showCommandPalette();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.quickConnect)) {
      _showQuickConnect();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.supportHub) && _shellInFront) {
      _toggleSupportHub();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.closeTab)) {
      _closeCurrentTab();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.settings)) {
      // `sidebarSectionProvider` is write-only - nothing watches it - so
      // this used to do nothing AND swallow the event, preventing the
      // real handler further down from ever running. Drive the nav state
      // the v3 shell actually renders from.
      _openSettingsSection();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.toggleHostPanel)) {
      ref.read(desktopSettingsUpdaterProvider).toggleHostPanel();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.toggleSidebar)) {
      ref.read(desktopSettingsUpdaterProvider).toggleSidebarCollapsed();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.toggleRecordingMode)) {
      _toggleRecordingMode();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.openTmux)) {
      _openTmuxForSelectedTab();
      return true;
    }
    if (bindings.matches(event, ShortcutAction.findInTerminal)) {
      _findInTerminal();
      return true;
    }
    if (ref.read(voiceInputSupportedProvider) && bindings.matches(event, ShortcutAction.dictate)) {
      _toggleDictation();
      return true;
    }

    // Let all other keys propagate to the terminal
    return false;
  }

  /// Lock ZestSSH's key (4.0), only while the app lock is on: with it off there
  /// is no lock to go behind, and the key is left to what has the keyboard.
  bool _lockKey(KeyEvent event) =>
      ref.read(securityLockEnabledProvider) && ref.read(shortcutBindingsProvider).matches(event, ShortcutAction.lockApp);

  /// The command palette's keys: the one Settings binds it to (Ctrl+Shift+K
  /// unless changed there); Ctrl+Shift+P (Cmd+Shift+P too), kept for the
  /// hands that know it from other apps and offered nowhere to change, so it
  /// cannot be lost by accident; and Cmd+Shift+K, the Mac's twin of the
  /// default, while the palette keeps it. (Not bare Cmd+K: bash still uses it
  /// as 0x0B for kill-to-end-of-line on macOS, same as everywhere else.) A
  /// key the palette was moved away from goes on to the terminal.
  bool _isPaletteKey(KeyEvent event, ShortcutBindings bindings) {
    if (bindings.matches(event, ShortcutAction.commandPalette)) return true;
    final keys = HardwareKeyboard.instance;
    if (!keys.isShiftPressed ||
        !(keys.isControlPressed || keys.isMetaPressed)) {
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyP) return true;
    return key == LogicalKeyboardKey.keyK &&
        keys.isMetaPressed &&
        bindings.bindingFor(ShortcutAction.commandPalette) ==
            defaultShortcutBindings[ShortcutAction.commandPalette];
  }

  /// True when the keyboard is in a terminal: a pane, a tmux pane, a shared
  /// session's view. Used to skip app-level Ctrl+letter shortcuts that would
  /// otherwise shadow bash readline (Ctrl+K, Ctrl+T, Ctrl+W, Ctrl+B).
  ///
  /// A terminal is the [TerminalView] the focus is in (a tmux pane's focus,
  /// labelled `tmux %N`, and a shared view's were not taken for one by the
  /// pane's own label, so their Ctrl+T, Ctrl+B and Ctrl+, went to the app).
  bool _terminalHasFocus() {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.debugLabel == 'TerminalPane' ||
        focus?.context?.findAncestorWidgetOfExactType<TerminalView>() != null;
  }

  /// True when the keyboard is in a remote screen's picture (4.0): every key
  /// goes to the remote computer.
  bool _remoteScreenHasFocus() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<ScreenView>() != null;

  void _setupTray() {
    try {
      TrayService.instance?.onShowWindow = () {
        // Focus the main window
      };
      TrayService.instance?.onQuickConnect = () {
        afterNextFrame((_) {
          if (mounted) _showQuickConnect();
        });
      };
      TrayService.instance?.onConnectHost = (id) {
        afterNextFrame((_) {
          if (!mounted) return;
          final conns =
              ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
          for (final c in conns) {
            if (c.connection.id == id) {
              _connectTo(c);
              return;
            }
          }
        });
      };
      TrayService.instance?.onQuit = () async {
        await MultiWindowService.instance.closeAllWindows();
        await _commitPendingDeletes();
        ref.read(activeSessionsProvider.notifier).endAllSessions();
        await destroyAppWindow();
      };
    } catch (_) {
      // Tray may not be initialised (missing icon asset, etc.)
    }
  }

  /// The snapshot lives in the encrypted database (schema v36), so with the
  /// vault locked at start-up this waits for the database to open.
  void _checkRestoredSessions() {
    // A run for a command (zestssh admin) opens no saved tab and keeps them
    // for the next ordinary start (found in a code audit).
    if (!restoresSavedTabsAtStart()) return;
    if (ref.read(dbReadyProvider)) {
      unawaited(_restoreSavedSessions());
      return;
    }
    _dbReadyForRestore = ref.listenManual<bool>(dbReadyProvider, (_, ready) {
      if (!ready) return;
      _dbReadyForRestore?.close();
      _dbReadyForRestore = null;
      unawaited(_restoreSavedSessions());
    });
  }

  ProviderSubscription<bool>? _dbReadyForRestore;

  Future<void> _restoreSavedSessions() async {
    final prefs = ref.read(sharedPreferencesProvider);

    // Read saved pane layout preset (not the tree itself - session IDs change)
    final savedPreset = prefs.getInt('desktop_pane_layout_preset');

    final persistence =
        SessionPersistenceService(prefs, ref.read(localStateStoreProvider));
    final bool hasSaved;
    try {
      hasSaved = await persistence.hasSavedSessions();
    } catch (e) {
      AppLogger.warning('Session restore skipped: $e');
      return;
    }
    if (!mounted) return;
    if (!hasSaved) {
      // No sessions to restore - clear any stale pane layout
      prefs.remove('desktop_pane_layout');
      prefs.remove('desktop_pane_layout_preset');
      return;
    }

    // Group-aware snapshot is preferred; legacy flat list is the fallback
    // for users with old persisted data.
    final snapshot = await persistence.loadTabSnapshots();
    final savedSessions = await persistence.loadSavedSessions();
    if (!mounted) return;
    final hasSnapshots = snapshot.tabs.isNotEmpty;
    if (!hasSnapshots && savedSessions.isEmpty) return;

    final shouldRestore = ref.read(desktopRestoreSessionsProvider);
    if (!shouldRestore) {
      await persistence.clearSavedSessions();
      prefs.remove('desktop_pane_layout');
      prefs.remove('desktop_pane_layout_preset');
      return;
    }

    // Auto-restore on launch - no prompt. The user opted in via the settings
    // toggle (default true); we just bring everything back exactly how they
    // left it (groups, colors, custom names, splits, ratios, SFTP panes,
    // active tab, tab order - all captured in [TabSnapshot] / [PaneNode]).
    //
    // One thing is asked: a Telnet host among them, before anything connects
    // and once for the lot, as every other way of opening one asks. On Cancel
    // those tabs do not come back and the others do. (They came back with no
    // question: found in a security audit.)
    afterNextFrame((_) async {
      if (!mounted) return;

      final leaveOut = await telnetHostsNotToReopen(context, ref.read(connectionsDaoProvider), [
        if (hasSnapshots)
          for (final tab in snapshot.tabs)
            for (final leaf in tab.paneTreeOfConnIds.allLeaves) ...leaf.sessionIds
        else
          for (final saved in savedSessions) saved.connectionId,
      ]);
      if (!mounted) return;

      if (hasSnapshots) {
        final back = tabsWithoutHosts(snapshot.tabs, leaveOut, activeTabIndex: snapshot.activeTabIndex);
        await _restoreFromTabSnapshots(
          back.tabs,
          activeTabIndex: back.activeTabIndex,
        );
      } else {
        await _restoreFromFlatList([
          for (final saved in savedSessions)
            if (!leaveOut.contains(saved.connectionId)) saved,
        ]);
        if (savedPreset != null && savedPreset > 0) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!mounted) return;
            _applyLayoutPreset(savedPreset);
          });
        }
      }

      persistence.clearSavedSessions();
    });
  }

  /// Restore from group-aware tab snapshots. Each leaf in each tab's pane
  /// tree contains *connection ids*; we spawn a fresh session per occurrence
  /// (so 3 references to the same connection in one tab become 3 distinct
  /// sessions, all restored into the same group), then rebuild the pane tree
  /// with the new session ids and materialise the WorkTab.
  Future<void> _restoreFromTabSnapshots(
    List<TabSnapshot> snapshots, {
    int? activeTabIndex,
  }) async {
    final dao = ref.read(connectionsDaoProvider);
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final workTabsNotifier = ref.read(workTabsProvider.notifier);

    // Defensive: wipe any stale tabs/pane-tree before adding fresh ones, so
    // we never end up with phantom "Session not found" leaves alongside the
    // restored sessions. WorkTabsNotifier's constructor already clears the
    // persisted key, but this also resets the in-memory state in case
    // anything was created between construction and restore.
    workTabsNotifier.clearAllTabs();

    String? firstNewTabId;
    String? firstNewSessionId;
    String? activeTabIdToSelect;
    var freeCapHit = false;

    for (var i = 0; i < snapshots.length; i++) {
      final snap = snapshots[i];
      final liveTree = await _materialiseSnapshotTree(
        snap.paneTreeOfConnIds,
        dao: dao,
        sessionsNotifier: sessionsNotifier,
        workTabsNotifier: workTabsNotifier,
        panePaths: snap.panePaths,
      );
      if (liveTree == null) {
        // Out of session quota or every connection vanished - stop here.
        freeCapHit = true;
        break;
      }
      final firstSid = liveTree.allLeaves.first.sessionIds.first;
      final tabId = workTabsNotifier.createTab(firstSid);
      workTabsNotifier.replaceTabTree(tabId, liveTree);
      if (snap.customName != null) {
        workTabsNotifier.renameTab(tabId, snap.customName);
      }
      // Restore the user-picked tab color (group color chip).
      if (snap.colorIndex != null) {
        workTabsNotifier.setTabColor(tabId, snap.colorIndex);
      }
      firstNewTabId ??= tabId;
      firstNewSessionId ??= firstSid;
      if (activeTabIndex != null && i == activeTabIndex) {
        activeTabIdToSelect = tabId;
      }
    }

    // Select the previously-active tab (or the first restored one) so that
    // the SFTP / Split pills see an active session right away.
    final tabToActivate = activeTabIdToSelect ?? firstNewTabId;
    if (tabToActivate != null) {
      workTabsNotifier.setActiveTab(tabToActivate);
      // Sync the v3 active-session pointer so SFTP/split pills resolve to
      // the restored session instead of "no active SSH".
      final tab = ref.read(workTabsProvider).tabs.firstWhere(
            (t) => t.id == tabToActivate,
            orElse: () => WorkTab(paneTree: PaneLeaf.single(sessionId: '')),
          );
      final sidForActive = tab.sessionIds.firstOrNull ?? firstNewSessionId;
      if (sidForActive != null) {
        ref.read(v3ActiveSessionTabProvider.notifier).state = sidForActive;
      }
    }

    if (freeCapHit && mounted) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.desktopShellSomeSessionsNotRestored,
      );
    }
  }

  /// Walk a [paneTreeOfConnIds] and produce a fresh tree with newly spawned
  /// session ids. Returns null if any connection cannot be resolved or the
  /// session quota is exhausted (so the caller can stop early).
  Future<PaneNode?> _materialiseSnapshotTree(
    PaneNode tree, {
    required ConnectionsDao dao,
    required ActiveSessionsNotifier sessionsNotifier,
    required WorkTabsNotifier workTabsNotifier,
    Map<String, SftpPanePaths> panePaths = const {},
  }) async {
    if (tree is PaneLeaf) {
      final newSids = <String>[];
      for (final cid in tree.sessionIds) {
        final conn = await dao.getById(cid);
        if (conn == null) continue; // skip vanished connections
        // Suppress the auto-tab spawn for this session - we're routing it
        // into a tree we're building ourselves.
        workTabsNotifier.expectSplitSession();
        final sid = sessionsNotifier.startRestoredSession(conn);
        if (sid == null) return null; // free-tier cap hit
        newSids.add(sid);
      }
      if (newSids.isEmpty) return null;
      // An SFTP leaf gets its remembered folders back under its fresh session
      // id, before the leaf mounts (remember-last-folder spec, section 1).
      final restored = panePaths[tree.id];
      if (tree.type == 'sftp' && restored != null) {
        ref.read(sftpPanePathsProvider.notifier).seed(newSids.first, restored);
      }
      return PaneLeaf(
        sessionIds: newSids,
        activeIndex: tree.activeIndex.clamp(0, newSids.length - 1),
        type: tree.type,
      );
    }
    if (tree is PaneSplit) {
      final left = await _materialiseSnapshotTree(
        tree.first,
        dao: dao,
        sessionsNotifier: sessionsNotifier,
        workTabsNotifier: workTabsNotifier,
        panePaths: panePaths,
      );
      if (left == null) return null;
      final right = await _materialiseSnapshotTree(
        tree.second,
        dao: dao,
        sessionsNotifier: sessionsNotifier,
        workTabsNotifier: workTabsNotifier,
        panePaths: panePaths,
      );
      if (right == null) return null;
      return PaneSplit(
        first: left,
        second: right,
        axis: tree.axis,
        ratio: tree.ratio,
      );
    }
    return null;
  }

  /// Legacy flat-list restore (no group structure). Kept as a fallback for
  /// users with the pre-snapshot persistence format on disk.
  Future<void> _restoreFromFlatList(List<PersistedSession> savedSessions) async {
    // Same defensive wipe as the snapshot path - keeps the legacy fallback
    // from accumulating phantom panes alongside fresh sessions.
    ref.read(workTabsProvider.notifier).clearAllTabs();

    final connectionsAsync = ref.read(connectionsWithDetailsProvider);
    connectionsAsync.whenData((connections) {
      String? firstSid;
      for (final saved in savedSessions) {
        final match = connections
            .where((c) => c.connection.id == saved.connectionId)
            .firstOrNull;
        if (match == null) continue;
        final sid = ref
            .read(activeSessionsProvider.notifier)
            .startRestoredSession(match.connection);
        if (sid == null) {
          // Free-tier cap hit - stop trying to restore more.
          break;
        }
        ref.read(workTabsProvider.notifier).onSessionCreated(sid);
        firstSid ??= sid;
      }
      // Make the first restored session the active one so SFTP works.
      if (firstSid != null) {
        ref.read(v3ActiveSessionTabProvider.notifier).state = firstSid;
      }
    });
  }

  /// What the window's close does while this screen is there.
  VoidCallback? _closeRequested;

  void _setupCloseConfirmation() {
    WindowService.instance?.setOnCloseRequested(_closeRequested = () async {
      // ── Fast path: close-to-tray ─────────────────────────────────
      // When the user has "Minimize to tray on close" enabled we want
      // an INSTANT hide - no session teardown, no confirm dialog, no
      // pref writes. Sessions stay alive in the background. The user
      // brings the window back via the tray icon (single click) or
      // the "Show Window" menu item.
      //
      // Previously the close button always ran the full teardown
      // (save snapshots → close all windows → end all SSH sessions →
      // windowManager.destroy), which is why closing felt slow.
      final minimizeToTray = ref.read(desktopMinimizeToTrayProvider);
      if (minimizeToTray) {
        try {
          switch (closeToTrayAction(trayReady: TrayService.ready)) {
            case CloseToTray.hide:
              await windowManager.hide();
            case CloseToTray.minimize:
              AppLogger.info('No tray icon to bring the window back: minimised instead of hidden');
              await windowManager.minimize();
          }
        } catch (e) {
          AppLogger.warning('Hide-to-tray failed: $e');
          // Fall through to the normal teardown so the user can
          // still actually close if hide is broken on their setup.
        }
        return;
      }

      await _endTheApp();
    });
  }

  /// Set once the app is on its way out, so that the system's own ask that
  /// follows (on a Mac, the window going asks the app to quit) lets it go.
  bool _ending = false;

  /// The way out under way: a second Quit meanwhile (Cmd+Q twice, or the
  /// window's close and the Dock's Quit) waits for its answer.
  Future<bool>? _endingNow;

  /// Ends the app as closing its window does: the open sessions kept for
  /// the next start, a question first where sessions are open (unless that
  /// is turned off), the held remote deletes made, every session ended, and
  /// the window closed ([destroy]; the system's Quit ends the app itself).
  /// False where the question was answered no.
  ///
  /// [ask] false: the question was asked already (an update's restart asks
  /// it in its own words, with the same count).
  Future<bool> _endTheApp({bool destroy = true, bool ask = true}) {
    if (_ending) return Future.value(true);
    return _endingNow ??= _endOnce(destroy: destroy, ask: ask).whenComplete(() => _endingNow = null);
  }

  /// Quits for an update (UpdateRestart.endApp): the installer or its helper
  /// is started first, and only once it has started does the app quit as
  /// Quit does (tabs saved, sessions ended). Where it does not start, the
  /// error goes back to the update's dialog and nothing has been ended.
  Future<bool> _endForUpdate(Future<void> Function() launch) async {
    if (_ending || !mounted) return false;
    await launch();
    return _endTheApp(ask: false);
  }

  Future<bool> _endOnce({required bool destroy, required bool ask}) async {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.read(activeSessionsProvider);
    final activeCount = openSessionCount(sessions);

    // Update tray before closing
    try {
      TrayService.instance?.updateSessionCount(0);
    } catch (e) {
      AppLogger.debug('Tray update failed: $e');
    }

    final confirmClose = ref.read(desktopConfirmCloseWithSessionsProvider);
    if (ask && activeCount > 0 && confirmClose && mounted) {
      if (!await confirmCloseWithSessions(context, activeCount)) return false;
    }
    _ending = true;
    // Step by step, each said on screen while it runs, and none waited for
    // without end (app_closing.dart): closing took up to about ten seconds
    // with nothing on screen and looked like a freeze (19 October 2026).
    await runClosingSteps(_closingStep, [
      ClosingStep(l10n.desktopClosingSaving, () async {
        if (activeCount > 0) await saveOpenTabs(ref, sessions);
        await autoSaveLastSession(ref);
      }, limit: kClosingSaveLimit),
      ClosingStep(l10n.desktopClosingWindows, MultiWindowService.instance.closeAllWindows, limit: kClosingWindowsLimit),
      // Held remote deletes are made BEFORE the sessions are ended (a hold is
      // a delay, never a cancellation - delete safety spec §3), within their
      // own limit.
      ClosingStep(l10n.desktopClosingSessions, _commitPendingDeletes),
      // The sessions are told to end and not waited for: the window goes
      // while they end, as it always did (a server that does not answer
      // must not hold the close).
      ClosingStep(l10n.desktopClosingSessions, () async {
        unawaited(ref.read(activeSessionsProvider.notifier).endAllSessions());
      }),
    ]);
    if (destroy) await destroyAppWindow();
    return true;
  }

  /// The step the app is at as it closes, said on screen ([ClosingPanel]);
  /// null while it is not closing.
  final _closingStep = ValueNotifier<String?>(null);

  /// A Mac's Quit from outside the app (the Dock, logging out): it ends as
  /// the app's own Quit ends it, or stays where the question was answered no.
  Future<ui.AppExitResponse> _onSystemQuit() async =>
      await _endTheApp(destroy: false) ? ui.AppExitResponse.exit : ui.AppExitResponse.cancel;

  /// App quit with delete holds outstanding: commit them before the sessions
  /// close, with a hard 5s timeout so a stalled server can never hang the quit
  /// (delete safety spec §3). A brief "Finishing N deletes" blocks meanwhile.
  /// Anything that times out or fails is recorded for a next-launch notice -
  /// NEVER retried silently at startup with the user not present.
  Future<void> _commitPendingDeletes() async {
    final manager = ref.read(sftpDeleteHoldProvider);
    final n = manager.holdCount;
    if (n == 0) return;

    final finishingText = AppLocalizations.of(context)!.sftpDeleteFinishing(n);
    // Work under way, in the app's dialog (it was a spinner in a plain one);
    // closed as the deletes end, and nothing closes it before.
    final close = mounted ? showZestBusy(context, label: finishingText) : null;

    await commitHeldDeletes(ref);

    close?.call();
  }

  /// At startup, surface any deletes that did NOT complete on the previous quit
  /// (delete safety spec §3). This ONLY informs - it never re-issues the deletes
  /// (deleting files with the user not present is worse than the original miss).
  void _checkDeleteFailures() {
    final prefs = ref.read(sharedPreferencesProvider);
    final list = prefs.getStringList('sftp_delete_failures');
    if (list == null || list.isEmpty) return;
    unawaited(prefs.remove('sftp_delete_failures'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      for (final entry in list) {
        final i = entry.indexOf('|');
        if (i <= 0) continue;
        final count = int.tryParse(entry.substring(0, i)) ?? 1;
        final host = entry.substring(i + 1);
        showTopSnackBar(
          context,
          l10n.sftpDeleteFailedNotification(count, host),
          isError: true,
        );
      }
    });
  }

  /// At startup, after an update the app quit for: says it went in, or,
  /// where the app opened again on the old version, that it did not, with
  /// the installer's log behind Copy details (update_dialog.dart).
  void _checkLastUpdate() {
    unawaited(() async {
      final running = await ref.read(appVersionProvider.future).catchError((_) => '');
      if (running.isEmpty || !mounted) return;
      final runningBuild = await ref.read(appBuildNumberProvider.future);
      if (!mounted) return;
      final last = await takeLastUpdate(ref.read(sharedPreferencesProvider), running, runningBuild: runningBuild);
      if (last == null || !mounted) return;
      afterNextFrame((_) {
        if (mounted) showLastUpdateResult(context, last);
      });
    }());
  }

  // ── Desktop prompt dialog handlers ─────────────────────────────
  // On desktop, TerminalScreen is NOT used - _TerminalPane renders
  // terminals directly. So prompt dialogs must be shown from HERE.

  bool _passwordDialogShowing = false;
  bool _passphraseDialogShowing = false;
  bool _hostKeyDialogShowing = false;
  bool _connectionErrorDialogShowing = false;
  bool _serverQuestionsShowing = false;
  bool _signInNoticesShowing = false;

  /// Login banners with a link the sign-in waits on, one dialog at a time.
  Future<void> _showDesktopSignInNotices() async {
    if (_signInNoticesShowing || !mounted) return;
    _signInNoticesShowing = true;
    try {
      await showSignInNotices(context, ref, isMounted: () => mounted);
    } finally {
      _signInNoticesShowing = false;
    }
  }

  /// Server sign-in questions (a 2FA code), one dialog at a time.
  Future<void> _showDesktopServerQuestions() async {
    if (_serverQuestionsShowing || !mounted) return;
    _serverQuestionsShowing = true;
    try {
      await showServerQuestions(context, ref, isMounted: () => mounted);
    } finally {
      _serverQuestionsShowing = false;
    }
  }

  Future<void> _showDesktopPasswordDialog(PasswordPromptRequest request) async {
    if (_passwordDialogShowing || !mounted) return;
    _passwordDialogShowing = true;
    try {
      await showPasswordPrompt(context, request);
    } finally {
      _passwordDialogShowing = false;
    }
  }

  Future<void> _showDesktopPassphraseDialog(
      PassphrasePromptRequest request) async {
    if (_passphraseDialogShowing || !mounted) return;
    _passphraseDialogShowing = true;
    try {
      await showPassphrasePrompt(context, request);
    } finally {
      _passphraseDialogShowing = false;
    }
  }

  /// Drain the host-key queue: show one prompt at a time and advance to the
  /// next pending verification after each answer, so every untrusted host in
  /// a multi-session connect (a workspace) gets its own prompt.
  ///
  /// One drain loop runs at a time. A verification that arrives while this
  /// loop is open is already sitting in the queue and is shown as soon as the
  /// current one is answered, so the early return below never drops a prompt
  /// (the old single-slot version did exactly that - "only one host asks").
  Future<void> _showDesktopHostKeyDialog() async {
    if (_hostKeyDialogShowing || !mounted) return;
    _hostKeyDialogShowing = true;
    try {
      final queue = ref.read(hostKeyVerificationQueueProvider.notifier);
      HostKeyVerification? verification = queue.current;
      while (verification != null && mounted) {
        final accepted = await _askDesktopHostKey(verification);
        if (accepted == null) {
          // The dialog was TORN DOWN without an answer (the page under it was
          // replaced, e.g. by the lock-screen redirect), not answered: every
          // button pops an explicit bool and the barrier is not dismissible.
          // Leave the entry queued for the mount-time pending check instead of
          // resolving it, so no prompt is lost, nothing is trusted without an
          // explicit answer, and the NEXT prompt is not pushed on top of the
          // lock screen where a bystander could answer it.
          break;
        }
        queue.resolve(verification, accepted);
        verification = queue.current;
      }
    } finally {
      _hostKeyDialogShowing = false;
    }
  }

  /// Post a security notification when a trusted server's host key changes,
  /// gated by the user's "Security alerts" notification toggle.
  void _notifyHostKeyChanged(HostKeyVerification verification) {
    if (!ref.read(notifySecurityAlertsProvider)) return;
    // Recording mode: the host:port is masked at the source, since a bare
    // label is nothing the notification centre's scan can catch.
    final target =
        Redactable.address(hostWithPort(verification.host, verification.port))
            .display;
    final l10n = AppLocalizations.of(context)!;
    ref.read(notificationCenterProvider.notifier).warning(
          l10n.desktopShellHostKeyChanged,
          body: l10n.desktopShellHostKeyChangedBody(target),
        );
  }

  /// Show ONE host-key prompt and return the user's answer, or null when the
  /// dialog was torn down before an answer (its page was replaced).
  Future<bool?> _askDesktopHostKey(HostKeyVerification verification) async {
    // A CHANGED key on an already-trusted host: the dedicated security
    // warning (both fingerprints, trust date, verify command, inverted
    // actions), told to the notification centre as well. A new host's key:
    // the first-connection question. Both the app's dialogs, one on a
    // computer as on a phone ([askHostKeyTrust]).
    if (verification.isChanged) _notifyHostKeyChanged(verification);
    return askHostKeyTrust(context, verification);
  }

  /// Connects again to [connectionId] after a failed connection: a new
  /// session for it (the failed one was ended when the dialog opened), which
  /// the tabs give a tab of its own as they do every new session.
  void _retryConnection(String connectionId) {
    ref.read(connectionsWithDetailsProvider).whenData((connections) {
      final match = connections.where((c) => c.connection.id == connectionId).firstOrNull;
      if (match == null) return;
      ref.read(activeSessionsProvider.notifier).startSession(match.connection);
    });
  }

  Future<void> _showConnectionErrorDialog(ConnectionError error) async {
    if (_connectionErrorDialogShowing || !mounted) return;
    _connectionErrorDialogShowing = true;
    try {
      // Close the failed tab BEFORE the dialog is shown. The dialog
      // already carries a snapshot of the error data, and the
      // "Connection Lost" tab UI is functionally identical to the home
      // screen - keeping the red tab around just clutters the tab bar
      // and lets multiple failed attempts pile up. We also sweep any
      // *other* error-state tabs for the same host:port so prior
      // failures the user dismissed are cleaned up too.
      final sessionsMap = ref.read(activeSessionsProvider);
      final toEnd = <String>{
        if (error.sessionId != null &&
            sessionsMap.containsKey(error.sessionId))
          error.sessionId!,
        for (final entry in sessionsMap.entries)
          if (entry.value.status == SessionStatus.error &&
              entry.value.host == error.host &&
              entry.value.port == error.port)
            entry.key,
      };
      for (final id in toEnd) {
        ref.read(activeSessionsProvider.notifier).endSession(id);
      }

      // What went wrong and what to try, in the app's language, with the
      // report of it to copy (3.0: a plain dialog that said
      // "Could not connect to host:port" in English).
      final cid = error.connectionId;
      await showZestModal<void>(
        context: context,
        size: ZestModalSize.standard,
        child: ConnectionFailedDialog(
          error: error,
          onRetry: cid == null ? null : () => _retryConnection(cid),
        ),
      );
    } finally {
      _connectionErrorDialogShowing = false;
      // Clear the provider after dialog is dismissed
      ref.read(connectionErrorProvider.notifier).state = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Update window title and tray based on session count
    _updateWindowTitle();
    _updateTrayCount();
    if (_onTouch) {
      // The app icon's shortcuts follow the hosts, as on the phone's Home; a
      // picked one waits for the hosts and for the app to open.
      keepAppIconShortcuts(ref);
      ref.listen(connectionsWithDetailsProvider, (_, next) {
        if (next.hasValue) _appIconShortcutSoon();
      });
      ref.listen<bool>(isAppLockedProvider, (_, locked) {
        if (!locked) _appIconShortcutSoon();
      });
    }

    // Live monitor health -> tray icon / tooltip / menu. Seeded here and kept
    // fresh via listens (which do NOT rebuild the shell), so a monitor poll
    // updates the tray without re-running this whole build.
    _pushTrayHealth();
    ref.listen(monitoredConnectionsProvider, (_, _) => _pushTrayHealth());
    ref.listen(serverStatsProvider, (_, _) => _pushTrayHealth());
    ref.listen(agentlessMonitorPollerProvider, (_, _) => _pushTrayHealth());
    ref.listen(connectionHealthProvider, (_, _) => _pushTrayHealth());
    // Updates installed by themselves: the release found as the app started
    // is installed now, in the update's dialog, which shows it under way and
    // can stop it. Not where a session is open already (the restart would
    // end it): the status bar's version offers it then.
    ref.listen<UpdateInfo?>(autoUpdateStartProvider, (_, info) {
      if (info == null) return;
      ref.read(autoUpdateStartProvider.notifier).set(null);
      if (!ref.read(inAppUpdateSupportedProvider) || ref.read(updateOpenSessionCountProvider) > 0) return;
      afterNextFrame((_) {
        if (mounted) showUpdateDialog(context, info, autoStart: true);
      });
    });
    // A remote screen's Files: its SSH connection's files in the tab's dock.
    ref.listen<String?>(screenFilesRequestProvider, (_, sid) {
      if (sid == null) return;
      ref.read(screenFilesRequestProvider.notifier).state = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSftpForSession(sid);
      });
    });
    ref.listen(monitorThresholdsProvider, (_, _) => _pushTrayHealth());
    // Keeps count of which host's session was last in front, for what lists
    // hosts with their last used first.
    ref.listen(hostUseProvider, (_, _) {});
    // Recording mode is part of the screen for the tray too: re-push the moment
    // it toggles so the masked host names appear at once, not on the next poll.
    ref.listen(recordingModeProvider, (_, _) => _pushTrayHealth());

    // ── Desktop prompt dialogs ──────────────────────────────────
    // Settings is a pop-up over whatever is shown (3.0 UI).
    ref.listen<bool>(settingsPopupOpenProvider, (prev, next) {
      if (next && prev != true) _showSettingsPopup();
    });
    // No page of the shell is Settings: whatever still asks for that
    // section is given the pop-up, and the page that was shown stays.
    ref.listen<NavSection>(activeSidebarNavProvider, (prev, next) {
      if (next != NavSection.settings) return;
      final back = (prev == null || prev == NavSection.settings) ? NavSection.hosts : prev;
      Future.microtask(() {
        if (!mounted) return;
        ref.read(activeSidebarNavProvider.notifier).state = back;
        _openSettingsSection();
      });
    });

    // A sign-in's questions on a phone's or a tablet's screen are the app's
    // to ask (PhoneSignInQuestions, over whatever is on screen), this shell's
    // too: asked here as well, each would have come twice.
    if (!_onTouch) _listenForSignInQuestions();

    // Show error dialog when a connection fails
    ref.listen<ConnectionError?>(connectionErrorProvider, (prev, next) {
      if (next != null && mounted) {
        _showConnectionErrorDialog(next);
      }
    });

    // When a session marked for SFTP auto-open transitions to connected,
    // open the SFTP pane for it. Used by the SFTP empty-state server picker.
    ref.listen<Map<String, SessionState>>(activeSessionsProvider, (prev, next) {
      final pending = _pendingSftpAutoOpen;
      if (pending == null) return;
      final state = next[pending];
      if (state == null) {
        // Session removed before connecting - clear pending.
        _pendingSftpAutoOpen = null;
        return;
      }
      if (state.status == SessionStatus.connected) {
        // Clear pending on ANY connected state (not only SshService) so a
        // worker-isolate session, which has no in-process SSH client, does not
        // wedge the pending slot. _openSftpForSession itself opens the pane for
        // a real SshService or shows "SFTP requires an SSH connection" for a
        // session that cannot do SFTP.
        _pendingSftpAutoOpen = null;
        // Defer until after frame so pane tree state is settled.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _openSftpForSession(pending);
        });
      } else if (state.status == SessionStatus.error ||
          state.status == SessionStatus.disconnected) {
        _pendingSftpAutoOpen = null;
      }
    });

    // A panel asked for from anywhere opens where it can be seen: not behind
    // the Support Hub.
    ref.listen<HelpPage?>(helpDockProvider, (_, next) {
      if (next != null) _closeSupportHub();
    });

    // Speech to text stops when its session leaves the screen (another tab in
    // front, its tab closed, its pane showing another session): its words
    // would go where they are not seen.
    ref.listen<WorkTabsState>(workTabsProvider, (_, tabs) {
      final dictation = ref.read(dictationProvider);
      final id = dictation.sessionId;
      if (dictation.listening && id != null && !dictationSessionShown(tabs.activeTab, id)) {
        unawaited(ref.read(dictationProvider.notifier).stop());
      }
    });

    // Speech to text starting and stopping, said to a screen reader.
    return DictationAnnouncer(child: _buildShell());
  }

  /// A sign-in's questions (a password, a key's passphrase, a server's
  /// questions and its banner's link, a host key to trust), and what is said
  /// of a host key trusted without asking: asked by this shell on a computer.
  void _listenForSignInQuestions() {
    ref.listen<PasswordPromptRequest?>(passwordPromptProvider, (prev, next) {
      if (next != null && mounted) {
        _showDesktopPasswordDialog(next);
      }
    });
    ref.listen<PassphrasePromptRequest?>(passphrasePromptProvider,
        (prev, next) {
      if (next != null && mounted) {
        _showDesktopPassphraseDialog(next);
      }
    });
    ref.listen<ServerQuestionRequest?>(serverQuestionProvider, (prev, next) {
      if (next != null && mounted) {
        _showDesktopServerQuestions();
      }
    });
    ref.listen<SignInNoticeRequest?>(signInNoticeProvider, (prev, next) {
      if (next != null && mounted) _showDesktopSignInNotices();
    });
    ref.listen<HostKeyVerification?>(hostKeyVerificationProvider,
        (prev, next) {
      if (next != null && mounted) {
        _showDesktopHostKeyDialog();
      }
    });

    // Show a brief toast when a new host key is auto-accepted (TOFU off)
    ref.listen<HostKeyAutoAcceptEvent?>(hostKeyAutoAcceptProvider,
        (prev, next) {
      if (next != null && mounted) {
        // Recording mode: the toast is free text the notification centre's
        // scan does not recognise a fingerprint in, so both are masked here.
        final l10n = AppLocalizations.of(context)!;
        final target =
            Redactable.address(hostWithPort(next.host, next.port)).display;
        final fingerprint = Redactable.fingerprint(next.fingerprint).display;
        showTopSnackBar(
          context,
          l10n.desktopShellHostKeyAutoAccepted(
              target, next.keyType, fingerprint),
          duration: const Duration(seconds: 6),
          width: 500,
          actionLabel: l10n.settingsTitle,
          onAction: () {
            // Settings, on the page where host keys are asked about (Security
            // and privacy), so the user can enable host-key prompts.
            ref.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.security;
            _openSettingsSection();
          },
        );
        // Clear so subsequent connections re-trigger
        ref.read(hostKeyAutoAcceptProvider.notifier).state = null;
      }
    });

    // First-time confirmation of a host key adopted from cloud sync: name the
    // device + date it was recorded so a synced fingerprint is never trusted
    // silently (the connection has already proceeded - this only informs).
    ref.listen<HostKeyProvenanceEvent?>(hostKeyProvenanceProvider,
        (prev, next) {
      if (next != null && mounted) {
        final d = next.recordedAt;
        final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        final target =
            Redactable.address(hostWithPort(next.host, next.port)).display;
        final device = Redactable.host(next.device).display;
        final l10n = AppLocalizations.of(context)!;
        showTopSnackBar(
          context,
          next.certificate
              ? l10n.ftpsCertificateProvenance(target, device, date)
              : l10n.desktopShellHostKeyProvenance(target, device, date),
          isWarning: true,
          duration: const Duration(seconds: 8),
          width: 500,
        );
        ref.read(hostKeyProvenanceProvider.notifier).state = null;
      }
    });
  }

  Widget _buildShell() {
    return _buildWithMenuBar(
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        // NotificationToastOverlay wraps the entire shell so toasts
        // can float above any layout mode. Bell history popover lives
        // in the pill bar; toasts dock to the top-right corner under
        // the chrome.
        // The boundary is what "Copy redacted screenshot" and the report
        // form's attachment render (spec 7c/8b): the whole shell, without any
        // dialog floating above it.
        child: RepaintBoundary(
          key: _shellCaptureKey,
          child: NotificationToastOverlay(
            child: Stack(
              children: [
                Scaffold(
                  // On a phone's or a tablet's screen the system's bars (the
                  // status bar, the navigation bar, a camera's cut-out) keep
                  // their room: the bars' colour runs under them.
                  backgroundColor: _onTouch ? AppColors.v3ChromeBg : AppColors.v3Background,
                  body: _onTouch ? SafeArea(child: _buildV3Layout()) : _buildV3Layout(),
                ),
                // While the app closes: that it is closing, and the step.
                Positioned.fill(child: ClosingPanel(step: _closingStep)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── V3 layout (pill bar + narrow sidebar + content) ─────────────
  //
  // Persistent shell architecture (v1.5):
  //   Layer 1 - Pill bar:    fixed top, 48px, AppColors.v3ChromeBg (black)
  //   Layer 2 - Sidebar:     fixed left, 200px, AppColors.v3Background (charcoal)
  //   Layer 3 - Status bar:  fixed bottom, 28px, AppColors.v3ChromeBg (black)
  //   Layer 4 - Content:     fills remainder, IndexedStack (swaps on nav)
  //
  // Clicking sidebar items ONLY changes which IndexedStack child is visible.
  // The pill bar, sidebar, and status bar are mounted ONCE and never rebuild
  // during navigation. Active sessions stay alive in memory.

  /// Convert the WorkTab list into entries shaped like
  /// `MapEntry<String, SessionState>` so the existing PillBar API works
  /// unchanged. Each entry's key is the *tab id* (not a session id), and
  /// the value is a synthesized SessionState whose label/status/colorIndex
  /// reflect the tab's contents (e.g. "web-01, web-02" or "web-01 +2").
  ///
  /// **Sort order**: pinned tabs come first (in their original relative
  /// order), then unpinned tabs. This matches how every browser /
  /// IDE renders tab pinning.
  ///
  /// Returns the sorted entries plus a `groupSizes` map (members count
  /// per tab id) and a `pinnedIds` set so the pill bar can paint a pin
  /// glyph without needing to re-walk the WorkTab list.
  ({
    List<MapEntry<String, SessionState>> entries,
    Map<String, int> groupSizes,
    Map<String, List<Color>> identityColors,
    Set<String> pinnedIds,
  }) _workTabsToEntries(
    List<WorkTab> tabs,
    Map<String, SessionState> sessions,
    Map<String, ConnectionWithDetails> connById,
  ) {
    // Stable two-bucket sort: pinned first, then unpinned, preserving
    // each bucket's existing relative order. `pendingClose` tabs are
    // filtered out - they're in their 5-second undo window and need
    // to vanish from the strip immediately so X feels responsive. (The
    // keyboard's tab keys go by the same order: tabsInStripOrder.)
    final ordered = tabsInStripOrder(tabs, sessions);
    final result = <MapEntry<String, SessionState>>[];
    final groupSizes = <String, int>{};
    final identityColors = <String, List<Color>>{};
    final pinnedIds = <String>{};
    for (final tab in ordered) {
      // Gather valid sessions belonging to this tab. Hidden sessions
      // are excluded - once the user closes a session from the
      // in-terminal tab bar, its WorkTab pill should disappear too,
      // otherwise clicking the pill silently fails to switch view
      // (the render dispatch's `activeSessions` also excludes hidden,
      // so the terminal area would be empty even with activeTabId set).
      final members = <SessionState>[];
      // The terminals name the tab; the SFTP dock's session is one of them
      // already, so counting it again read "db-primary, db-primary".
      final memberIds = tab.terminalSessionIds.isNotEmpty
          ? tab.terminalSessionIds
          : tab.sessionIds;
      for (final sid in memberIds) {
        final s = sessions[sid];
        if (s != null && !s.isHidden) members.add(s);
      }
      // (A tab with none is not in the strip: tabsInStripOrder.)

      // Aggregate status: connecting > error > connected > disconnected.
      SessionStatus status = SessionStatus.connected;
      if (members.any((m) => m.status == SessionStatus.connecting)) {
        status = SessionStatus.connecting;
      } else if (members.any((m) => m.status == SessionStatus.error)) {
        status = SessionStatus.error;
      } else if (members.any((m) => m.status == SessionStatus.disconnected)) {
        status = SessionStatus.disconnected;
      }

      // Combined label. Each piece is masked on its own while recording mode
      // is on, so a "+2" count and the shape of a custom name survive; the
      // pill masks again at render, which is a no-op on a masked value.
      String label;
      if (tab.customName != null) {
        label = Redactable.freeText(tab.customName!).display;
      } else if (members.length == 1) {
        label = Redactable.host(members.first.connectionLabel).display;
      } else if (members.length == 2) {
        label =
            '${Redactable.host(members[0].connectionLabel)}, ${Redactable.host(members[1].connectionLabel)}';
      } else {
        label =
            '${Redactable.host(members.first.connectionLabel)} +${members.length - 1}';
      }

      final synthesized = SessionState(
        status: status,
        connectionId: members.first.connectionId,
        connectionLabel: label,
        host: members.first.host,
        port: members.first.port,
        username: members.first.username,
        colorIndex: tab.colorIndex ?? members.first.colorIndex,
      );
      result.add(MapEntry(tab.id, synthesized));
      groupSizes[tab.id] = members.length;
      // Identity colours in pane order (§3). A manual per-tab colour override
      // (legacy tabs) wins as a single solid bar; otherwise each pane resolves
      // host → group → neutral, live from the connections list so a host or
      // group recolour repaints the open tab with no reconnect.
      if (tab.colorIndex != null) {
        identityColors[tab.id] = [AppColors.labelColorFor(null, tab.colorIndex!)];
      } else {
        identityColors[tab.id] = [
          for (final m in members) _memberIdentityColor(m, connById),
        ];
      }
      if (tab.pinned) pinnedIds.add(tab.id);
    }
    return (
      entries: result,
      groupSizes: groupSizes,
      identityColors: identityColors,
      pinnedIds: pinnedIds,
    );
  }

  /// Resolve one session's identity colour under the v1.6 channel model:
  /// the host's own colour label → its group's colour → neutral grey (§3).
  /// Prefers the LIVE connection record so recolouring a host or its group
  /// updates open tabs immediately; falls back to the session's captured
  /// colour for quick-connects with no saved connection (no group to inherit).
  Color _memberIdentityColor(
    SessionState m,
    Map<String, ConnectionWithDetails> connById,
  ) {
    final cwd = m.connectionId != null ? connById[m.connectionId] : null;
    int? connColorValue;
    int connColorIndex;
    Color? groupColor;
    if (cwd != null) {
      connColorValue = cwd.connection.colorValue;
      connColorIndex = cwd.connection.colorIndex;
      final g = cwd.group;
      if (g != null) {
        groupColor = resolveGroupColor(
          colorValue: g.colorValue,
          colorIndex: g.colorIndex,
          name: g.name,
        );
      }
    } else {
      connColorValue = m.colorValue;
      connColorIndex = m.colorIndex;
    }
    return AppColors.resolveConnectionLabelColorOrNull(
          connColorValue: connColorValue,
          connColorIndex: connColorIndex,
          inheritedGroupColor: groupColor,
        ) ??
        AppColors.neutralLabelColor;
  }

  Widget _buildV3Layout() {
    final activeNav = ref.watch(activeSidebarNavProvider);
    final sessions = ref.watch(activeSessionsProvider);
    final detachedIds = ref.watch(detachedSessionsProvider);
    final activeSessions = sessions.entries
        .where((e) =>
            (e.value.status == SessionStatus.connected ||
                e.value.status == SessionStatus.connecting) &&
            !detachedIds.contains(e.key) &&
            !e.value.isHidden)
        .toList();
    // A tab whose only session dropped still shows the terminal area, where
    // that session says why, with Reconnect (3.0: the Hosts page
    // came up instead).
    final terminalShown = activeSessions.isNotEmpty ||
        sessions.entries.any((e) => shownAsDropped(e.value, e.key, detachedIds));

    // Tab strip is now driven by WorkTabs (each tab owns a pane tree).
    // We synthesize MapEntry<String, SessionState> entries keyed by tab id,
    // so PillBar's existing API continues to work without modification -
    // it just receives "tabs" instead of "sessions".
    final workTabs = ref.watch(workTabsProvider);
    final activeWorkTabId = workTabs.activeTabId;
    final activeSessionId = activeWorkTabId; // alias for legacy code below
    // The Hosts drawer and the icon-only rail answer to this one check, so the
    // rail comes back out whenever the drawer is not actually on screen (the
    // Hosts page hides the drawer: it already shows every host).
    final hostsDrawerIsShown = hostsDrawerShown(
      panelOn: ref.watch(hostPanelVisibleProvider),
      terminalShown: activeSessionId != null && terminalShown,
      activeNav: activeNav,
      openedOnHostsPage: ref.watch(hostsDrawerOnHostsPageProvider),
    );
    // Watch connections + groups so the tab identity bars recolour live when a
    // host's colour label or its group's colour changes - no reconnect (§3).
    final connsList = ref.watch(connectionsWithDetailsProvider).valueOrNull ??
        const <ConnectionWithDetails>[];
    final connById = {for (final c in connsList) c.connection.id: c};
    // The composed pill labels are plain strings by the time the pill bar
    // sees them, so the shell itself must rebuild when recording mode flips
    // for them to re-mask.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    final tabsResult = _workTabsToEntries(workTabs.tabs, sessions, connById);
    final tabEntries = tabsResult.entries;
    final tabGroupSizes = tabsResult.groupSizes;
    final tabIdentityColors = tabsResult.identityColors;
    final pinnedTabIds = tabsResult.pinnedIds;

    // Map NavSection enum to IndexedStack index
    final activeNavIndex = NavSection.values.indexOf(activeNav);

    // On a phone's or a tablet's large screen (4.0): an app bar
    // with the page's name in place of a computer's title bar; held upright,
    // the session tabs in a strip of their own under it, while sessions are
    // open, and a slim rail of icons with their names in place of the
    // sidebar; held sideways, the tabs in the bar and the full sidebar.
    final shellSize = MediaQuery.sizeOf(context);
    final upright = _onTouch && shellSize.height > shellSize.width;
    final terminalInFront = activeSessionId != null && terminalShown;
    final l10n = AppLocalizations.of(context)!;

    Widget pillBar({bool stripOnly = false}) => PillBar(
            touch: _onTouch,
            tabsInBar: !upright,
            stripOnly: stripOnly,
            // The Hosts page's name, which has no title line of its own;
            // every other page says its name under the bar, and the
            // bar has the Hosts pill there, as a computer's.
            pageTitle: _onTouch && !terminalInFront && activeNav == NavSection.hosts ? l10n.narrowSidebarHosts : null,
            activeNav: activeNav,
            activeSessionId: activeWorkTabId,
            terminalShown: activeSessionId != null && terminalShown,
            sessions: tabEntries,
            tabGroupSizes: tabGroupSizes,
            tabIdentityColors: tabIdentityColors,
            pinnedTabIds: pinnedTabIds,
            onNavChanged: (section) {
              if (section == NavSection.settings) return _openSettingsSection();
              _closeSupportHub();
              ref.read(activeSidebarNavProvider.notifier).state = section;
              // Deselect the active tab so the sidebar page is visible.
              // The tab strip stays - clicking a tab swaps back to its terminal.
              ref.read(workTabsProvider.notifier).clearActiveTab();
            },
            onSessionSelected: _selectTab,
            onSessionClosed: (tabId) async {
              // Soft-close with 5s Undo window: the tab vanishes from
              // the strip immediately, sessions stay alive until the
              // snackbar dismisses. Pinned tabs are ignored (users have
              // to Unpin first), groups get a hard confirmation
              // dialog before the soft-close even starts.
              final tab = ref.read(workTabsProvider).tabs.firstWhere(
                    (t) => t.id == tabId,
                    orElse: () => WorkTab(
                      paneTree: PaneLeaf.single(sessionId: ''),
                    ),
                  );
              if (tab.pinned) return;
              if (!await _confirmCloseTabsIfGroups([tab])) return;
              await _closeTabsWithUndo([tab]);
            },
            // What the bar does to a tab, or opens, happens on the shell, which
            // has to be in sight: each of these comes back from the Support Hub
            // first (a session it brought would stand behind it).
            onNewSession: () => _showQuickConnect(),
            onCommandPalette: _showCommandPalette,
            onHelp: _openHelp,
            onOpenTmux: (id) {
              _closeSupportHub();
              _openTmuxForSession(id);
            },
            onTabAction: (tabId, action) async {
              if (ref.read(supportHubOpenProvider)) {
                await _leaveSupportHub();
                if (!mounted) return;
              }
              // tabId here is the WorkTab id (we synthesized entries keyed
              // by tab id). Operations target the tab's primary (first) session.
              final wtState = ref.read(workTabsProvider);
              final tab = wtState.tabs.firstWhere(
                (t) => t.id == tabId,
                orElse: () => WorkTab(paneTree: PaneLeaf.single(sessionId: '')),
              );
              final primarySid = tab.sessionIds.firstOrNull;
              switch (action) {
                case 'reconnect':
                  if (primarySid == null) break;
                  // Signed in as it was (its account), the host read from its
                  // own space.
                  ref.read(activeSessionsProvider.notifier).openAgain(primarySid).then((newId) {
                    if (newId != null) ref.read(workTabsProvider.notifier).onSessionCreated(newId);
                  });
                case 'duplicate':
                  if (primarySid == null) break;
                  ref.read(activeSessionsProvider.notifier).openLike(primarySid).then((newId) {
                    if (newId != null) ref.read(workTabsProvider.notifier).onSessionCreated(newId);
                  });
                case 'pin':
                case 'unpin':
                  ref.read(workTabsProvider.notifier).togglePin(tabId);
                case 'closeOthers':
                  // Pinned tabs survive Close Others - that's the whole
                  // point of pinning. Mirrors browser behaviour. Group
                  // tabs get a hard confirm; everything else goes
                  // through the 5s undo flow.
                  final targets = wtState.tabs
                      .where((t) =>
                          t.id != tabId && !t.pinned && !t.pendingClose)
                      .toList();
                  if (!await _confirmCloseTabsIfGroups(targets)) break;
                  await _closeTabsWithUndo(targets);
                case 'closeAll':
                  // Pinned tabs also survive Close All. The user can
                  // unpin first if they really want everything gone.
                  final targets = wtState.tabs
                      .where((t) => !t.pinned && !t.pendingClose)
                      .toList();
                  if (!await _confirmCloseTabsIfGroups(targets)) break;
                  await _closeTabsWithUndo(targets);
                case 'rename':
                  final current = tab.customName ?? '';
                  final l10n = AppLocalizations.of(context)!;
                  final newName = await showZestInputDialog(
                    context: context,
                    title: l10n.desktopShellRenameTab,
                    icon: LucideIcons.pencil,
                    fieldLabel: l10n.desktopShellTabName,
                    hintText: l10n.desktopShellTabName,
                    initialValue: current,
                    confirmLabel: l10n.commonRename,
                  );
                  if (newName != null && mounted) {
                    final trimmed = newName.trim();
                    ref
                        .read(workTabsProvider.notifier)
                        .renameTab(tabId, trimmed.isEmpty ? null : trimmed);
                  }
                case 'splitRight':
                case 'splitDown':
                  _activateTabForAction(tabId, tab);
                  _splitPane(action == 'splitRight'
                      ? SplitDirection.horizontal
                      : SplitDirection.vertical);
                case 'saveWorkspace':
                  // Make the right-clicked tab active so the dialog previews and
                  // saves THAT layout, then hand off to the workspace agent's
                  // save dialog (previews the panes, blocks duplicate names -
                  // §5/§6).
                  if (ref.read(workTabsProvider).activeTabId != tabId) {
                    ref.read(workTabsProvider.notifier).setActiveTab(tabId);
                  }
                  WorkspaceSaveDialog.show(context);
                case 'addToWorkspace':
                  showAddTabToWorkspaceDialog(context, ref, tabId);
                case 'openSftp':
                  if (ref.read(workTabsProvider).activeTabId != tabId) {
                    ref.read(workTabsProvider.notifier).setActiveTab(tabId);
                  }
                  final sshSid = sshToolsSessionOf(
                    tab,
                    ref.read(activeSessionsProvider),
                    lastInFront: ref.read(lastSshSessionOfTabProvider)[tab.id],
                  );
                  if (sshSid != null) _openSftpForSession(sshSid);
                case 'mergeGroup':
                  _mergeColorGroupInto(tabId);
                case 'clearColor':
                  ref.read(workTabsProvider.notifier).setTabColor(tabId, null);
                default:
                  if (action.startsWith('color:')) {
                    final idx = int.tryParse(action.substring(6));
                    if (idx != null) {
                      ref
                          .read(workTabsProvider.notifier)
                          .setTabColor(tabId, idx);
                    }
                  }
              }
            },
            // The strip names the tabs by their ids. (It passed places in the
            // strip, which were used as places in the list of tabs: the strip
            // shows pinned tabs first and leaves out a tab being closed, so
            // another tab than the one dragged was moved or merged.)
            onTabMove: (tabId, besideTabId, after) {
              ref
                  .read(workTabsProvider.notifier)
                  .moveTabBeside(tabId, besideTabId, after: after);
            },
            onTabMerge: (sourceTabId, destTabId) {
              final undo = ref
                  .read(workTabsProvider.notifier)
                  .mergeTabs(sourceTabId, destTabId);
              // Undo for a few seconds, as a closed tab has.
              if (undo != null) offerTabMergeUndo(context, ref, [undo]);
            },
            // A terminal pane dragged from the terminal area onto a header pill:
            // resolve the leaf to its active session and move it into that group.
            onLeafMoveToTab: (leafId, destTabId) {
              final sid =
                  ref.read(paneTreeProvider)?.findLeaf(leafId)?.sessionIdOrNull;
              if (sid != null) {
                ref
                    .read(workTabsProvider.notifier)
                    .moveSessionToTab(sid, destTabId);
              }
            },
            // Dropped on a tab's edge or on empty header space: pop the pane out
            // into a tab of its own, beside that tab or at the end.
            onLeafPopOut: (leafId, besideTabId, after) {
              final sid =
                  ref.read(paneTreeProvider)?.findLeaf(leafId)?.sessionIdOrNull;
              if (sid != null) {
                ref.read(workTabsProvider.notifier).splitSessionToNewTab(
                      sid,
                      besideTabId: besideTabId,
                      after: after,
                    );
              }
            },
          );

    // A remote screen in full screen lies over the whole window: what the
    // window shows under it is neither read out nor reached by the keyboard.
    final underScreen = ref.watch(screenFullScreenSessionProvider) != null;
    Widget chrome(Widget child) =>
        ExcludeSemantics(excluding: underScreen, child: ExcludeFocus(excluding: underScreen, child: child));
    return Column(
      children: [
        // ── Layer 1: Pill bar (persistent, 48px, pure black) ───
        chrome(MediaQuery.withClampedTextScaling(
          maxScaleFactor: kDesktopFrameTextScale,
          child: pillBar(),
        )),
        // Upright on a touch screen: the session tabs under the app bar,
        // while there are any.
        if (upright && tabEntries.isNotEmpty)
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: kDesktopFrameTextScale,
            child: pillBar(stripOnly: true),
          ),

        // Update-available banner - renders nothing unless a newer release
        // is offered and not dismissed. Sits below the pill bar, above the
        // sidebar + content.
        const UpdateBanner(),

        // ── Layer 2 + 4: Sidebar (persistent) + Content area ──
        // The Support Hub lies over them: everything under it stays mounted,
        // so the sessions go on running and every panel is as it was left.
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Nothing under the hub takes the keyboard or the pointer: a
              // terminal asks for the keyboard when it comes to the front, when
              // its session connects, when the one in front ends, and a key that
              // reached it from the form would run on a live host. (The pointer
              // for the frames the hub steps aside for a picture.) The keyboard
              // comes back through terminalKeyboardAskProvider as the hub goes.
              ExcludeFocus(
                excluding: ref.watch(supportHubOpenProvider),
                child: IgnorePointer(
                  ignoring: ref.watch(supportHubOpenProvider),
                  child: Row(
            children: [
              // Layer 2: Narrow sidebar (200px, or a 56px icon-only rail when
              // the user pushes it in or the Hosts drawer is on screen - see
              // A1).
              FocusTraversalGroup(
                child: chrome(MediaQuery.withClampedTextScaling(
                  maxScaleFactor: kDesktopFrameTextScale,
                  child: NarrowSidebar(
                    hostsPanelShown: hostsDrawerIsShown,
                    // Upright on a touch screen: the slim rail, each icon
                    // with its name
                    // under it.
                    labelledRail: upright,
                    // When a terminal tab is active the content area shows the
                    // terminal (not a section page), so highlight NO sidebar
                    // item - otherwise the last-visited section (e.g. Hosts)
                    // reads as "you're here" while you're actually in a
                    // terminal. Same condition the content area uses below to
                    // pick the terminal.
                    // While Settings is open its gear is the item that is lit.
                    activeSection: ref.watch(settingsPopupOpenProvider)
                        ? NavSection.settings
                        : (activeSessionId != null && terminalShown)
                            ? null
                            : activeNav,
                    onSectionChanged: (section) {
                      if (section == NavSection.settings) {
                        return _openSettingsSection();
                      }
                      ref.read(activeSidebarNavProvider.notifier).state =
                          section;
                      // Deselect the active tab so the sidebar page is visible.
                      // The tab strip stays - clicking a tab swaps back to its
                      // terminal.
                      ref.read(workTabsProvider.notifier).clearActiveTab();
                    },
                  ),
                )),
              ),

              // A1: persistent, resizable Hosts fast-connect panel. Sits
              // between the icon-only rail and the content while toggled on.
              //
              // §7e - suppress the drawer while the Hosts PAGE is the active
              // view. Otherwise the same hosts render twice at once (drawer
              // tree on the left, page grid on the right). The drawer's whole
              // purpose is reaching hosts WITHOUT leaving a session, so hiding
              // it on the Hosts page loses nothing.
              if (hostsDrawerIsShown)
                FocusTraversalGroup(
                  child: HostSlideOutPanel(
                    onConnectTo: _connectTo,
                    onManageHosts: () {
                      ref.read(activeSidebarNavProvider.notifier).state =
                          NavSection.hosts;
                      ref.read(workTabsProvider.notifier).clearActiveTab();
                    },
                    onClose: () => ref
                        .read(desktopSettingsUpdaterProvider)
                        .setHostPanelVisible(false),
                  ),
                ),

              // Layer 4: Main content area (dynamic)
              // When a session tab is active, show terminal.
              // Otherwise, show the IndexedStack keyed off sidebar nav.
              //
              // The content is its own traversal unit (as are the sidebar,
              // the hosts drawer and the docks): reading-order traversal
              // runs over the whole window, and without the groups a Tab
              // inside a form here would land on a sidebar row that shares
              // its horizontal band.
              Expanded(
                child: Builder(
                  builder: (context) => _besideEditor(
                    activeSessionId: activeSessionId,
                    terminalShown: terminalShown,
                    activeNav: activeNav,
                    content: FocusTraversalGroup(
                  child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent &&
                        HardwareKeyboard.instance.isControlPressed) {
                      if (event.scrollDelta.dy < 0) {
                        _adjustFontSize(1);
                      } else {
                        _adjustFontSize(-1);
                      }
                    }
                  },
                  child: activeSessionId != null && terminalShown
                      // Session tab selected → terminal area
                      ? DesktopTerminalArea(
                          onConnectTo: _connectTo,
                          onToggleSftp: _openSftpForSession,
                          onApplyLayout: (preset) => preset == null
                              ? _arrangeAutomatically()
                              : _applyLayoutPreset(preset.number),
                        )
                      // No session tab → IndexedStack of sidebar sections
                      : IndexedStack(
                          index: activeNavIndex,
                          children: [
                            // 0: NavSection.hosts
                            HostsHomePage(
                              onConnectTo: _connectTo,
                              onConnectAs: (item, account) => _connectTo(item, asAccount: account),
                              onOpenXProgram: (item, program) => _connectTo(item, xProgram: program),
                              onOpenConsole: (item) => _connectTo(item, console: true),
                              onOpenTmux: _openTmuxForConnection,
                              onOpenSftp: _openSftpForHost,
                              onSwitchToSession: _selectSessionTab,
                              onQuickConnect: _showQuickConnect,
                            ),
                            // 1: NavSection.keys
                            const KeysView(),
                            // 2: NavSection.networks
                            const NetworksPage(),
                            // 3: NavSection.portForwarding
                            const PortForwardListView(),
                            // 4: NavSection.snippets
                            const SnippetsLibraryView(),
                            // 5: NavSection.automation
                            const AutomationView(),
                            // 6: NavSection.monitor
                            const MonitorTableView(),
                            // 7: NavSection.settings is no page: Settings is a
                            // pop-up (showSettingsPopup). The place is kept so
                            // that every section's index stays its own.
                            const SizedBox.shrink(),
                            // 8: NavSection.triggers
                            const TriggersView(),
                            // 9: NavSection.commandHistory
                            const HistoryView(),
                            // 10: NavSection.team (while an Orchard is open)
                            const TeamView(),
                          ],
                        ),
                  ),
                ),
                  ),
                ),
              ),

              // The docked Help panel (help/feedback/support spec, section
              // 2). Unlike the editor it is not tied to a section: it stays
              // beside whatever the user is looking at, so a bug can be
              // reproduced on screen while the form is open.
              _helpDockIfOpen(),
              // The setup guide docks on the right while you work. It was only
              // ever mounted in the retired Modern layout, so the "Setup guide"
              // buttons on Automation, Server Monitor and Snippets did nothing.
              const SetupGuideDock(),
            ],
          ),
                ),
              ),
              if (ref.watch(supportHubOpenProvider))
                Offstage(
                  offstage: _hubHiddenForCapture,
                  child: SupportHubPage(
                    captureScreenshot: _captureBehindHub,
                    onClose: _closeSupportHub,
                  ),
                ),
            ],
          ),
        ),

        // ── Layer 3: Status bar (persistent, 28px, pure black) ─
        chrome(_buildStatusBar()),
      ],
    );
  }

  /// The content area with the docked New/Edit connection editor at its right
  /// while one is open ([connectionEditorTargetProvider], set by
  /// ConnectionEditScreen.showAdaptive). Beside the page, which narrows to make
  /// room, the panel drag-resizable from its left edge; the page keeps
  /// [kHostsPageMinWidth], the panel narrowing for it, and where even the
  /// panel's least width leaves the page less than that, the panel lies over
  /// the page instead, a shadow along its edge (the device run of 13 November
  /// 2026: a 1200 wide window left the Hosts page 290, its toolbar on three
  /// rows). Decided as it is laid out ([_EditorBesidePage]), so nothing is
  /// built during layout.
  ///
  /// The editor lives on the HOSTS view: it stays MOUNTED (so an in-progress
  /// draft is never lost) but is tucked away with Offstage whenever the user is
  /// looking at a terminal or a different section, and reappears, with its
  /// boxes intact, when they return to Hosts. It is dismissed for real (target
  /// cleared, state discarded) only via Cancel / Save / Close. One tree for
  /// both ways it stands, so a window resized across the line keeps the draft.
  Widget _besideEditor({
    required String? activeSessionId,
    required bool terminalShown,
    required NavSection activeNav,
    required Widget content,
  }) {
    final target = ref.watch(connectionEditorTargetProvider);
    final shown = target != null && (activeSessionId == null || !terminalShown) && activeNav == NavSection.hosts;
    return CustomMultiChildLayout(
      delegate: _EditorBesidePage(wanted: ref.watch(connectionEditorWidthProvider), shown: shown),
      children: [
        LayoutId(id: _EditorPart.page, child: content),
        if (target != null) ...[
          LayoutId(
            id: _EditorPart.shadow,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Theme.of(context).shadowColor.withValues(alpha: 0),
                    Theme.of(context).shadowColor.withValues(alpha: 0.3),
                  ]),
                ),
              ),
            ),
          ),
          LayoutId(
            id: _EditorPart.editor,
            child: Offstage(offstage: !shown, child: ConnectionEditorDock(target: target, fill: true)),
          ),
        ],
      ],
    );
  }

  /// The status bar under every screen.
  Widget _buildStatusBar() => MediaQuery.withClampedTextScaling(
        maxScaleFactor: kDesktopFrameTextScale,
        child: const DesktopStatusBar(),
      );

  // ── Native menu bar ──────────────────────────────────────────────

  Widget _buildWithMenuBar({required Widget child}) {
    // PlatformMenuBar is only supported on macOS (a test can build the shell
    // as on a Mac, which Platform.isMacOS would not let it).
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;

    final l10n = AppLocalizations.of(context)!;
    return PlatformMenuBar(
      menus: [
        // ── The application's own menu (a Mac shows the first menu under
        //    the app's name; it was File, with no Quit, so Cmd+Q did
        //    nothing): About, Settings, the system's Services and Hide, and
        //    Quit, which ends the app as closing its window does.
        PlatformMenu(
          label: 'ZestSSH',
          menus: [
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.desktopMenuAboutZestssh,
                onSelected: () => _showAboutDialog(),
              ),
            ]),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.settingsTitle,
                shortcut: const SingleActivator(LogicalKeyboardKey.comma,
                    meta: true),
                onSelected: _openSettingsSection,
              ),
            ]),
            if (PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.servicesSubmenu))
              const PlatformMenuItemGroup(members: [
                PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.servicesSubmenu),
              ]),
            PlatformMenuItemGroup(members: [
              for (final type in const [
                PlatformProvidedMenuItemType.hide,
                PlatformProvidedMenuItemType.hideOtherApplications,
                PlatformProvidedMenuItemType.showAllApplications,
              ])
                if (PlatformProvidedMenuItem.hasMenu(type))
                  PlatformProvidedMenuItem(type: type),
            ]),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.trayQuit,
                shortcut:
                    const SingleActivator(LogicalKeyboardKey.keyQ, meta: true),
                onSelected: () => unawaited(_endTheApp()),
              ),
            ]),
          ],
        ),

        // ── File ──
        PlatformMenu(
          label: l10n.desktopMenuFile,
          menus: [
            PlatformMenuItem(
              label: l10n.desktopQuickConnect,
              shortcut:
                  const SingleActivator(LogicalKeyboardKey.keyT, meta: true),
              onSelected: _showQuickConnect,
            ),
            PlatformMenuItem(
              label: l10n.hostsNewHost,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyN,
                  meta: true, shift: true),
              onSelected: _outOfHub(() => ConnectionEditScreen.showAdaptive(context)),
            ),
            PlatformMenuItem(
              label: l10n.cloudImpTitle,
              onSelected: _outOfHub(() => openImportHosts(context)),
            ),
            PlatformMenuItem(
              label: l10n.desktopMenuImportSshConfig,
              onSelected: _outOfHub(() => _importSshConfig()),
            ),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.desktopShortcutCloseTab,
                shortcut:
                    const SingleActivator(LogicalKeyboardKey.keyW, meta: true),
                onSelected: _hubFirst(_closeCurrentTab),
              ),
              PlatformMenuItem(
                label: l10n.desktopMenuReopenClosedTab,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyT,
                    meta: true, shift: true),
                onSelected: _outOfHub(_reopenLastClosedTab),
              ),
            ]),
          ],
        ),

        // ── Edit ──
        PlatformMenu(
          label: l10n.desktopMenuEdit,
          menus: [
            PlatformMenuItem(
              label: l10n.copy,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC,
                  meta: true, shift: true),
              onSelected: _copySelection,
            ),
            PlatformMenuItem(
              label: l10n.terminalPaste,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyV,
                  meta: true, shift: true),
              onSelected: _pasteToTerminal,
            ),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.desktopShortcutFindInTerminal,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyF,
                    meta: true, shift: true),
                onSelected: _outOfHub(_findInTerminal),
              ),
            ]),
          ],
        ),

        // ── View ──
        PlatformMenu(
          label: l10n.desktopMenuView,
          menus: [
            PlatformMenuItem(
              label: l10n.desktopCommandPalette,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyK,
                  meta: true),
              onSelected: _showCommandPalette,
            ),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.desktopShortcutZoomIn,
                shortcut: const SingleActivator(LogicalKeyboardKey.equal,
                    meta: true),
                onSelected: _outOfHub(() => _zoomFont(1)),
              ),
              PlatformMenuItem(
                label: l10n.desktopShortcutZoomOut,
                shortcut: const SingleActivator(LogicalKeyboardKey.minus,
                    meta: true),
                onSelected: _outOfHub(() => _zoomFont(-1)),
              ),
              PlatformMenuItem(
                label: l10n.desktopShortcutResetZoom,
                shortcut: const SingleActivator(LogicalKeyboardKey.digit0,
                    meta: true),
                onSelected: _outOfHub(() => _adjustFontSize(0, resetTo: 14.0)),
              ),
            ]),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.desktopShortcutToggleFullscreen,
                // The macOS convention (and the one way out of native
                // fullscreen the system itself teaches): Ctrl+Cmd+F. F11 stays
                // the in-app binding on every platform.
                shortcut: const SingleActivator(LogicalKeyboardKey.keyF,
                    control: true, meta: true),
                onSelected: _toggleFullscreen,
              ),
              PlatformMenuItem(
                label: l10n.desktopMenuToggleAlwaysOnTop,
                onSelected: _toggleAlwaysOnTop,
              ),
            ]),
          ],
        ),

        // ── Terminal ──
        PlatformMenu(
          label: l10n.desktopShortcutTerminal,
          menus: [
            PlatformMenuItem(
              label: l10n.desktopShortcutSplitRight,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyD,
                  meta: true, shift: true),
              onSelected: _outOfHub(() => _splitPane(SplitDirection.horizontal)),
            ),
            PlatformMenuItem(
              label: l10n.desktopShortcutSplitDown,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyE,
                  meta: true, shift: true),
              onSelected: _outOfHub(() => _splitPane(SplitDirection.vertical)),
            ),
            PlatformMenuItem(
              label: l10n.desktopShortcutCloseSplit,
              onSelected: _hubFirst(_closeFocusedPane),
            ),
            PlatformMenuItem(
              label: l10n.desktopToggleSftpPanel,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyS,
                  meta: true, shift: true),
              onSelected: _outOfHub(_toggleSftp),
            ),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.desktopMenuToggleBroadcastMode,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyB,
                    meta: true, shift: true),
                onSelected: _outOfHub(_toggleBroadcast),
              ),
            ]),
          ],
        ),

        // ── Window ──
        PlatformMenu(
          label: l10n.desktopShellMenuWindow,
          menus: [
            PlatformMenuItem(
              label: l10n.desktopShellMenuMinimize,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyM,
                  meta: true),
              onSelected: () => windowManager.minimize(),
            ),
            PlatformMenuItem(
              label: l10n.desktopShellMenuZoom,
              onSelected: () async {
                final isMaximized = await windowManager.isMaximized();
                if (isMaximized) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
            ),
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.desktopShellMenuBringAllToFront,
                onSelected: () => windowManager.show(),
              ),
            ]),
          ],
        ),

        // ── Help ──
        PlatformMenu(
          label: l10n.desktopMenuHelp,
          menus: [
            // Mirrors the `?` menu (spec 7b) so macOS users get the same
            // rows from the native menu bar. (The Support Hub, reports and
            // tickets are the account service's: not in a build with none.)
            if (zestHasCloud) ...[
              PlatformMenuItem(
                label: l10n.supportHubOpen,
                onSelected: _toggleSupportHub,
              ),
              PlatformMenuItem(
                label: l10n.helpReportBug,
                onSelected: () => _openReportForm(FeedbackType.bug),
              ),
              PlatformMenuItem(
                label: l10n.helpSuggest,
                onSelected: () => _openReportForm(FeedbackType.suggestion),
              ),
              PlatformMenuItem(
                label: l10n.helpSupport,
                onSelected: () => _openHelp(HelpPage.support),
              ),
              PlatformMenuItem(
                label: l10n.ticketsTitle,
                onSelected: () => _openHelp(HelpPage.tickets),
              ),
            ],
            PlatformMenuItemGroup(members: [
              PlatformMenuItem(
                label: l10n.recModeName,
                onSelected: _toggleRecordingMode,
              ),
              PlatformMenuItem(
                label: l10n.recModeCopyScreenshot,
                onSelected: _copyRedactedScreenshot,
              ),
            ]),
            PlatformMenuItemGroup(members: [
              if (kZestDocsUrl != '')
                PlatformMenuItem(
                  label: l10n.helpDocs,
                  onSelected: () => _openUrl(kZestDocsUrl),
                ),
              if (kZestFaqUrl != '')
                PlatformMenuItem(
                  label: l10n.helpFaq,
                  onSelected: () => _openUrl(kZestFaqUrl),
                ),
              PlatformMenuItem(
                label: l10n.helpShortcuts,
                onSelected: _openShortcutsSettings,
              ),
              if (kZestDiscordUrl != '')
                PlatformMenuItem(
                  label: l10n.helpDiscord,
                  onSelected: () => _openUrl(kZestDiscordUrl),
                ),
              PlatformMenuItem(
                label: l10n.helpWhatsNew,
                onSelected: () => showWhatsNewDialog(context),
              ),
            ]),
          ],
        ),
      ],
      child: child,
    );
  }

  /// A menu item for something the Support Hub lies over. A Mac's keys for the
  /// menu arrive whatever has the keyboard (the hub's own keys never see them),
  /// and a tab split or a font changed out of sight is no answer to them: back
  /// to the sessions first.
  VoidCallback _outOfHub(VoidCallback action) => () async {
        // (A dialog keeps its keys, and the menu's have no way of knowing of it.)
        if (!_shellInFront) return;
        if (ref.read(supportHubOpenProvider)) {
          await _leaveSupportHub();
          if (!mounted) return;
        }
        action();
      };

  /// A menu item that closes something: with the Support Hub open, the hub is
  /// what is in front, and it is the one to close. A live tab the person cannot
  /// see is not closed by a Cmd+W meant for the page.
  VoidCallback _hubFirst(VoidCallback close) => () {
        if (!_shellInFront) return;
        if (ref.read(supportHubOpenProvider)) {
          _closeSupportHub();
        } else {
          close();
        }
      };

  // ── Find in terminal ─────────────────────────────────────────────

  /// Find in terminal, for the terminal the keyboard is in (a pane's own, or
  /// a tmux pane of one), else for the session in front: its bar opens in
  /// that pane, or takes the keyboard again where it is open; its close
  /// button or Escape closes it. With no terminal to search, the person is
  /// told so. (A bar of the shell's own searched the first session of the
  /// strip's, wherever the keyboard was, and never brought a match into
  /// view.)
  void _findInTerminal() {
    final at = FocusManager.instance.primaryFocus?.context;
    // In the bar already: the keyboard is where Find would put it.
    if (at?.findAncestorWidgetOfExactType<TerminalSearchBar>() != null) return;
    final String? sid;
    final view = at?.findAncestorWidgetOfExactType<TerminalView>();
    if (view != null) {
      // A terminal that is no session's own (a shared session's view, a
      // replay) has no Find of the shell's: its keys are its own.
      sid = at!.findAncestorWidgetOfExactType<TmuxSessionView>()?.host.sessionId ??
          ref
              .read(activeSessionsProvider)
              .entries
              .where((e) => identical(e.value.session?.terminal, view.terminal))
              .map((e) => e.key)
              .firstOrNull;
      if (sid == null) return;
    } else {
      sid = _sessionShownInFront();
    }
    if (sid == null) {
      showTopSnackBar(context, AppLocalizations.of(context)!.desktopShellOpenTerminalToSearch);
      return;
    }
    // A remote screen (4.0) has no text to find in.
    if (ref.read(activeSessionsProvider.notifier).isScreen(sid)) {
      showTopSnackBar(context, AppLocalizations.of(context)!.hostScreenNoTerminal, isWarning: true);
      return;
    }
    final find = ref.read(terminalFindProvider.notifier);
    final was = find.state;
    find.state = (sessionId: sid, ask: was?.sessionId == sid ? was!.ask + 1 : 0);
  }

  /// The session in front whose terminal is on screen, in the tab in front:
  /// the focused pane's (as SFTP's shortcut finds it), else the one last
  /// clicked into, else the tab's first. A pane shows one session of its
  /// own tabs, the one in front.
  /// Esc alone, while speech to text listens and nothing (a dialog) is over
  /// the shell.
  bool _dictationStopKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isShiftPressed || keys.isAltPressed || keys.isMetaPressed) return false;
    return _shellInFront && ref.read(dictationProvider).listening;
  }

  /// Speech to text (4.0), from its key or the palette: started for the
  /// terminal the typing is in, else the one in front; stopped where it
  /// listens. Never for a remote screen or a session that is files only:
  /// there is no prompt to type at.
  void _toggleDictation() {
    if (!ref.read(voiceInputSupportedProvider)) return;
    final at = FocusManager.instance.primaryFocus?.context;
    final view = at?.findAncestorWidgetOfExactType<TerminalView>();
    String? sid;
    if (view != null) {
      // (A terminal that is no session's own, a shared session's view, is
      // not typed into by it.)
      sid = at!.findAncestorWidgetOfExactType<TmuxSessionView>()?.host.sessionId ??
          ref
              .read(activeSessionsProvider)
              .entries
              .where((e) => identical(e.value.session?.terminal, view.terminal))
              .map((e) => e.key)
              .firstOrNull;
    } else {
      sid = _sessionShownInFront();
    }
    final sessions = ref.read(activeSessionsProvider.notifier);
    if (sid != null && (sessions.isScreen(sid) || sessions.isFilesOnly(sid))) sid = null;
    unawaited(toggleDictation(context, ref, sid));
  }

  String? _sessionShownInFront() {
    final tab = ref.read(workTabsProvider).activeTab;
    if (tab == null) return null;
    final shown = [
      for (final leaf in tab.paneTree.allLeaves)
        if (leaf.type != 'sftp' && leaf.sessionIdOrNull != null) leaf.sessionIdOrNull!,
    ];
    final sessions = ref.read(activeSessionsProvider);
    final focused = ref.read(focusedPaneProvider);
    final leaf = focused == null ? null : tab.paneTree.findLeaf(focused);
    for (final sid in [leaf?.sessionIdOrNull, ref.read(v3ActiveSessionTabProvider), ...shown]) {
      if (sid != null && shown.contains(sid) && sessions[sid]?.session != null) return sid;
    }
    return null;
  }

  // ── Window title ──────────────────────────────────────────────────

  void _updateWindowTitle() {
    // Security: never expose connection details (host, user) in the window
    // title - screen-sharing, screenshots, and task-bar previews would leak
    // server info. Always use the generic app name.
    const title = 'ZestSSH';

    // Defer to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WindowService.instance?.setTitle(title);
    });
  }

  void _updateTrayCount() {
    final sessions = ref.watch(activeSessionsProvider);
    final activeCount = sessions.values
        .where((s) =>
            s.status == SessionStatus.connected ||
            s.status == SessionStatus.connecting)
        .length;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        TrayService.instance?.updateSessionCount(activeCount);
      } catch (_) {
        // Tray may not be initialised
      }
    });
  }

  /// Resolve every monitored host's bucket (the exact same inputs the monitor
  /// screens + alert engine feed [resolveMonitorHost]) and push the critical /
  /// warning tally + per-host list to the tray. Reads (never watches) so it can
  /// run from a `ref.listen` callback without rebuilding the shell.
  void _pushTrayHealth() {
    final monitored =
        ref.read(monitoredConnectionsProvider).valueOrNull ?? const [];
    final config = ref.read(monitorThresholdsProvider);
    final sessions = ref.read(activeSessionsProvider);
    final statsNotifier = ref.read(serverStatsProvider.notifier);
    final stats = ref.read(serverStatsProvider);
    final health = ref.read(connectionHealthProvider);
    final monitor = ref.read(agentlessMonitorPollerProvider);
    final now = DateTime.now();

    var critical = 0;
    var warning = 0;
    final entries = <TrayHostEntry>[];
    for (final c in monitored) {
      final hasActiveSession = sessions.values.any(
        (s) => s.connectionId == c.id && s.status == SessionStatus.connected,
      );
      final view = resolveMonitorHost(
        history: statsNotifier.historyFor(c.id),
        stats: stats[c.id],
        health: health[c.id],
        monitor: monitor[c.id],
        hasActiveSession: hasActiveSession,
        thresholds: config.resolveFor(c.id),
        // The host's own alert choices (its panel's Alert menu).
        silenced: ref.read(hostAlertPrefsProvider)[c.id]?.silencedAt(now) ?? const {},
        countArcAsFree: ref.read(hostAlertPrefsProvider)[c.id]?.countArcAsFree ?? false,
        debounceReadings: config.global.debounceReadings,
        staleAfter: monitorStaleAfter(
            checkIntervalMinutes: config.global.checkIntervalMinutes,
            refreshIntervalSeconds: statsNotifier.refreshIntervalSeconds),
        now: now,
      );
      if (view.bucket == MonitorBucket.critical) {
        critical++;
      } else if (view.bucket == MonitorBucket.warning) {
        warning++;
      }
      // Recording mode: the OS tray menu is part of the screen too. A toggle
      // re-pushes immediately (the recordingModeProvider listener above), and
      // every stats refresh rebuilds these entries, so the mask never lags.
      final name = c.label.isNotEmpty
          ? Redactable.host(c.label).display
          : Redactable.address(c.host).display;
      entries.add(TrayHostEntry(id: c.id, label: '${_trayGlyph(view.bucket)} $name'));
    }

    afterNextFrame((_) {
      try {
        TrayService.instance?.updateMonitorState(
          critical: critical,
          warning: warning,
          hosts: entries,
        );
      } catch (_) {
        // Tray may not be initialised
      }
    });
  }

  String _trayGlyph(MonitorBucket b) {
    if (b == MonitorBucket.critical) return '\u{1F534}'; // red circle
    if (b == MonitorBucket.warning) return '\u{1F7E0}'; // orange circle
    if (b == MonitorBucket.healthy) return '\u{1F7E2}'; // green circle
    return '\u{26AA}'; // white circle - can't check
  }

  // ── Connections ──────────────────────────────────────────────────

  /// [asAccount]: signed in with that one of the host's other accounts
  /// (3.0, accounts per host: "Connect as"); its default where null.
  /// [usernameOverride]: the user typed for a host that is not saved.
  Future<void> _connectTo(ConnectionWithDetails item,
      {String? asAccount, String? usernameOverride, XProgramTarget? xProgram, bool console = false}) async {
    // Asked for from the tray, a link or Quick connect: the session is what the
    // person wants to see, not a page over it.
    if (ref.read(supportHubOpenProvider)) {
      await _leaveSupportHub();
      if (!mounted) return;
    }
    final l10n = AppLocalizations.of(context)!;
    // Warn before cleartext Telnet connections.
    if (item.connection.protocol == 'telnet') {
      if (!await confirmUnencryptedConnection(context)) return;
      if (!mounted) return;
    }

    // An X program (4.0): a screen tab of its own on this SSH host.
    final sessions = ref.read(activeSessionsProvider.notifier);
    // A Proxmox guest's console (4.0): a screen tab of its own too.
    final sessionId = xProgram != null
        ? sessions.startXProgram(item.connection, xProgram)
        : console
            ? sessions.startConsole(item.connection)
            : sessions.startSession(item.connection, asAccount: asAccount, usernameOverride: usernameOverride);
    if (sessionId == null) {
      if (context.mounted) {
        showTopSnackBar(context,
            l10n.desktopShellFreeTierLimit(freeSessionLimit),
            isError: true);
      }
      return;
    }
    ref.read(workTabsProvider.notifier).onSessionCreated(sessionId);

    // Switch to sessions view
    ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;

    // If we're in split mode, add the new session as a tab in the focused pane
    final paneTree = ref.read(paneTreeProvider);
    if (paneTree != null && paneTree is PaneSplit) {
      final focusedLeafId = ref.read(focusedPaneProvider);
      if (focusedLeafId != null) {
        ref.read(paneTreeProvider.notifier).addSessionToPane(
              focusedLeafId, sessionId);
        // Switch to the newly added tab in that pane
        final leaf = ref.read(paneTreeProvider)?.findLeaf(focusedLeafId);
        if (leaf != null) {
          ref.read(paneTreeProvider.notifier).setActiveTab(
                focusedLeafId, leaf.sessionIds.length - 1);
        }
        return;
      }
    }

    // Single mode - select the new tab
    _selectSessionTab(sessionId);
  }

  void _selectSessionTab(String sessionId) {
    afterNextFrame((_) {
      if (!mounted) return;
      // The work tab that holds the session, with its pane in front: the tab
      // strip is work tabs (3.0), and only this brings the session on screen.
      // "Switch to session" on the Hosts page changed the old index below
      // and nothing showed.
      final tabs = ref.read(workTabsProvider.notifier);
      final tab = tabs.tabContaining(sessionId);
      if (tab != null) {
        tabs.setActiveTab(tab.id);
        final leaf = tab.paneTree.allLeaves.where((l) => l.sessionIds.contains(sessionId)).firstOrNull;
        if (leaf != null) {
          ref.read(paneTreeProvider.notifier).setActiveTab(leaf.id, leaf.sessionIds.indexOf(sessionId));
          ref.read(focusedPaneProvider.notifier).state = leaf.id;
        }
      }
      final sessions = ref.read(activeSessionsProvider);
      final activeIds = sessions.entries
          .where((e) =>
              e.value.status == SessionStatus.connected ||
              e.value.status == SessionStatus.connecting)
          .map((e) => e.key)
          .toList();
      final index = activeIds.indexOf(sessionId);
      if (index >= 0) {
        ref.read(desktopSelectedTabProvider.notifier).state = index;
      }
      // V3 layout: also set the active session tab
      ref.read(v3ActiveSessionTabProvider.notifier).state = sessionId;
    });
  }

  /// Opens Quick connect, with [typed] in it where it is given.
  Future<void> _showQuickConnect({String? typed}) async {
    // What it switches to or opens would be behind the Support Hub.
    if (ref.read(supportHubOpenProvider)) {
      await _leaveSupportHub();
      if (!mounted) return;
    }
    QuickConnectV3.show(context,
        typed: typed,
        onSwitchTab: (id) => ref.read(workTabsProvider.notifier).setActiveTab(id),
        onOpenWorkspace: (id) => launchWorkspaceFromSurface(context, ref, id),
        onConnect: (uri) {
      // Try to find a saved connection by ID first
      final connections = ref.read(connectionsWithDetailsProvider).valueOrNull ?? [];
      final match = connections.where((c) => c.connection.id == uri).firstOrNull;
      if (match != null) {
        _connectTo(match);
      } else {
        // Parse as user@host:port for ephemeral connect
        _quickConnectUri(uri);
      }
    });
  }

  /// Connects to what was typed (user@host:port, read by [parseQuickTarget]),
  /// a host that is not saved, signed in as the user typed.
  void _quickConnectUri(String input) {
    final target = parseQuickTarget(input, defaultPort: ref.read(defaultPortProvider));
    if (target == null) return;
    _connectTo(ConnectionWithDetails(connection: quickConnectionOf(target)), usernameOverride: target.user);
  }

  /// Opens Quick connect with the host a quick connect link names typed in
  /// ([quickConnectLinkText]), for the person to connect or not.
  void _quickConnectFromLink() {
    final typed = quickConnectLinkText.value;
    if (typed == null || !mounted) return;
    quickConnectLinkText.value = null;
    _showQuickConnect(typed: typed);
  }

  // ── Command palette ──────────────────────────────────────────────

  /// Switch the shell to a sidebar section (v3) or push its route on the
  /// older layouts.
  ///
  /// The palette's "Navigate" actions and the Settings shortcut used to
  /// write `sidebarSectionProvider`, which no widget watches - so they were
  /// silently inert. This drives `activeSidebarNavProvider`, which is what
  /// the v3 shell actually renders from, and clears the active work tab so
  /// the section is visible instead of hidden behind a terminal.
  void _openNavSection(NavSection section) => openShellSection(ref, section);

  /// Opens Settings: a pop-up over whatever is shown, so a terminal stays
  /// where it is. Asked for through the provider, which every other way
  /// into Settings uses as well. Where the provider says it is asked for
  /// already and this shell shows nothing, it is shown now: setting the
  /// provider again would change nothing, and nothing would open.
  void _openSettingsSection() {
    final open = ref.read(settingsPopupOpenProvider.notifier);
    if (!open.state) {
      open.state = true;
    } else if (!_settingsPopupShowing) {
      _showSettingsPopup();
    }
  }

  /// Shows the pop-up that [settingsPopupOpenProvider] asked for, and says
  /// so there when it has closed: also where this shell has gone by then
  /// (the app locked under it, which takes the pop-up away too), and where
  /// it could not be shown at all, so the gear opens it the next time.
  Future<void> _showSettingsPopup() async {
    if (_settingsPopupShowing || !mounted) return;
    _settingsPopupShowing = true;
    // Taken now: after this shell has gone, its ref can read nothing.
    final open = ref.read(settingsPopupOpenProvider.notifier);
    try {
      await (DesktopShell.debugShowSettingsPopup ?? showSettingsPopup)(context);
    } catch (e) {
      AppLogger.warning('Settings pop-up not shown: ${errorKind(e)}');
    } finally {
      _settingsPopupShowing = false;
      // (The app's scope itself gone: there is nothing left to say it to.)
      if (open.mounted) open.state = false;
    }
  }

  Future<void> _showCommandPalette() async {
    // Whatever is chosen in it acts on the shell, which has to be in sight.
    if (ref.read(supportHubOpenProvider)) {
      await _leaveSupportHub();
      if (!mounted) return;
    }
    final sessions = ref.read(activeSessionsProvider);
    final activeIds = sessions.entries
        .where((e) =>
            e.value.status == SessionStatus.connected ||
            e.value.status == SessionStatus.connecting)
        .map((e) => e.key)
        .toList();

    final l10n = AppLocalizations.of(context)!;

    // The desktop shell owns the context-aware window / pane / layout /
    // session / navigation actions (they close over shell state and can't
    // be built inside the palette). We build them as CommandPaletteItems and
    // inject them into the ONE unified palette, which lists the hosts and
    // the snippets beside them, every action under Actions (4.0) with what
    // it does under its name (`desc`). `group` keeps them in families here.
    final actions = <CommandPaletteItem>[];
    var seq = 0;
    void add(
      String group,
      String title,
      IconData icon,
      VoidCallback onExecute, {
      String? shortcut,
      required String desc,
    }) {
      actions.add(CommandPaletteItem(
        id: 'act_${seq++}',
        category: CommandCategory.action,
        title: title,
        subtitle: desc,
        group: group,
        icon: icon,
        shortcut: shortcut,
        onSelect: onExecute,
      ));
    }

    // Accelerators come from the user's CURRENT bindings, never literals, so
    // a rebinding in Settings shows here at once and a cleared binding blanks
    // the column (spec 9). Fixed chords that are not rebindable (the layout
    // presets) are formatted through the same platform-aware formatter.
    final binds = ref.read(shortcutBindingsProvider);
    String? accel(ShortcutAction a) => binds.bindingFor(a)?.displayLabel;

    // ── Connections ──
    add(l10n.desktopConnections, l10n.desktopQuickConnect, LucideIcons.zap,
        _showQuickConnect,
        shortcut: accel(ShortcutAction.quickConnect), desc: l10n.paletteDescQuickConnect);
    add(l10n.desktopConnections, l10n.hostsNewHost, LucideIcons.plus,
        () => ConnectionEditScreen.showAdaptive(context),
        shortcut: accel(ShortcutAction.newConnection), desc: l10n.paletteDescNewHost);
    add(l10n.desktopConnections, l10n.cloudImpTitle, LucideIcons.downloadCloud,
        () => openImportHosts(context), desc: l10n.paletteDescImportHosts);
    add(l10n.desktopConnections, l10n.csvImpTitle, LucideIcons.table,
        () => openCsvImport(context), desc: l10n.cloudImpCsvDesc);
    add(l10n.desktopConnections, l10n.settingsImportSshConfig, LucideIcons.upload,
        () => _importSshConfig(), desc: l10n.cloudImpSshConfigDesc);
    if (puttyImportHere) {
      add(l10n.desktopConnections, l10n.commandPaletteSectionActionImportPutty,
          LucideIcons.download, () => context.push(Routes.puttyImport), desc: l10n.cloudImpPuttyDesc);
    }
    // Pick a host, connect, and SFTP opens once it is up (the title bar's SFTP
    // pill used to start this when no session was open).
    add(l10n.desktopConnections, l10n.sftpOpenPickerTitle, LucideIcons.folderOpen,
        _showSftpServerPicker, desc: l10n.paletteDescSftpPicker);

    // ── Sessions ──
    if (activeIds.isNotEmpty) {
      add(l10n.desktopCmdCategorySessions, l10n.desktopCmdCloseCurrentTab,
          LucideIcons.x, _closeCurrentTab, shortcut: accel(ShortcutAction.closeTab), desc: l10n.paletteDescCloseTab);
      add(l10n.desktopCmdCategorySessions, l10n.desktopCmdCloseAllTabs,
          LucideIcons.listX,
          () => ref.read(activeSessionsProvider.notifier).endAllSessions(), desc: l10n.paletteDescCloseAllTabs);
      add(l10n.desktopCmdCategorySessions, l10n.desktopMenuReopenClosedTab,
          LucideIcons.rotateCcw, _reopenLastClosedTab,
          shortcut: accel(ShortcutAction.reopenLastTab), desc: l10n.paletteDescReopenTab);
      add(l10n.desktopCmdCategorySessions, l10n.desktopShortcutFindInTerminal,
          LucideIcons.search, _findInTerminal,
          shortcut: accel(ShortcutAction.findInTerminal), desc: l10n.paletteDescFind);
      // Only with an SSH session in the tab in front: tmux control mode runs
      // over SSH, and offering it on a local shell led to a dead end.
      if (_sshSessionInFront() != null) {
        add(l10n.desktopCmdCategorySessions, l10n.desktopShellOpenTmux,
            LucideIcons.layoutDashboard, _openTmuxForSelectedTab,
            shortcut: accel(ShortcutAction.openTmux), desc: l10n.shortcutHelpOpenTmux);
      }
      // Speech to text (4.0), where something listens.
      if (ref.read(voiceInputSupportedProvider)) {
        add(l10n.desktopCmdCategorySessions, l10n.terminalSpeechToText, LucideIcons.mic, _toggleDictation,
            shortcut: accel(ShortcutAction.dictate), desc: l10n.shortcutHelpDictate);
      }
    }
    // Session sharing (3.0): what teammates share with this account.
    if (kOrchardsEnabled) {
      add(l10n.desktopCmdCategorySessions, l10n.shareInvitesTitle,
          LucideIcons.users, () => showShareInvitations(context), desc: l10n.paletteDescShareInvites);
    }

    // ── Layout & panes ──
    if (activeIds.length >= 2) {
      add(l10n.desktopShortcutLayout, l10n.desktopShortcutSplitRight,
          LucideIcons.columns, () => _splitPane(SplitDirection.horizontal),
          shortcut: accel(ShortcutAction.splitRight), desc: l10n.paletteDescSplitRight);
      add(l10n.desktopShortcutLayout, l10n.desktopShortcutSplitDown,
          LucideIcons.rows, () => _splitPane(SplitDirection.vertical),
          shortcut: accel(ShortcutAction.splitDown), desc: l10n.paletteDescSplitDown);
      add(l10n.desktopShortcutLayout, l10n.desktopShortcutCloseSplit,
          LucideIcons.minimize2, () => _closeFocusedPane(),
          shortcut: accel(ShortcutAction.closeSplit), desc: l10n.paletteDescCloseSplit);
    }
    if (ref.read(paneTreeProvider) is PaneSplit || _paneMaximized) {
      add(
          l10n.desktopShortcutLayout,
          _paneMaximized
              ? l10n.desktopShellRestorePaneLayout
              : l10n.desktopShellMaximizeFocusedPane,
          _paneMaximized ? LucideIcons.minimize2 : LucideIcons.maximize2,
          _toggleMaximizePane,
          shortcut: accel(ShortcutAction.maximizePane), desc: l10n.shortcutHelpMaximizePane);
    }
    // The arrangements that hold exactly the terminals of this tab, and
    // the automatic grid. (The ones with room for more are in the Layout
    // popover, where their pictures are.)
    final layoutTab = ref.read(workTabsProvider).activeTab;
    final layoutPanes = layoutTab == null
        ? 0
        : ref
            .read(workTabsProvider.notifier)
            .arrangeablePanes(layoutTab.id, shown: _shownHere)
            .length;
    for (final preset in paletteLayouts(layoutPanes)) {
      add(
          l10n.desktopShortcutLayout,
          preset == null ? l10n.layoutAutomatic : layoutPresetLabel(l10n, preset),
          preset == null ? LucideIcons.layoutDashboard : LucideIcons.layoutGrid,
          preset == null
              ? _arrangeAutomatically
              : () => _applyLayoutPreset(preset.number),
          desc: l10n.paletteDescLayout);
    }

    // ── Sessions: broadcast + disconnect ──
    // Broadcast is the tab's in front: it types to the terminals of that
    // tab. (It used to switch it on for every session of every tab.)
    if (layoutTab != null) {
      final broadcasts = ref.read(broadcastModeProvider).broadcasts(layoutTab.id);
      final terminals = terminalsOf(layoutTab, away: ref.read(broadcastAwayProvider));
      if (broadcasts || terminals.length >= kBroadcastFewest) {
        add(
            l10n.desktopCmdCategorySessions,
            broadcasts ? l10n.desktopCmdDisableBroadcast : l10n.desktopCmdEnableBroadcast,
            LucideIcons.radioTower,
            _toggleBroadcast,
            shortcut: accel(ShortcutAction.toggleBroadcast),
            desc: broadcasts ? l10n.paletteDescBroadcastOff : l10n.shortcutHelpToggleBroadcast);
      }
    }
    // Pick hosts, and they open together in one tab, typing to all.
    add(l10n.desktopCmdCategorySessions, l10n.desktopCmdBroadcastToHosts, LucideIcons.radioTower, () async {
      await broadcastToHostsFlow(context, ref);
      if (mounted) ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
    }, desc: l10n.paletteDescBroadcastHosts);
    // One command on many hosts, each with its result (3.0).
    add(l10n.desktopCmdCategorySessions, l10n.runOnHostsMenu, LucideIcons.listChecks, () => showRunOnHosts(context),
        desc: l10n.paletteDescRunOnHosts);
    // 'Disconnect current' / 'Disconnect all' removed: they called the
    // exact same endSession/endAllSessions as 'Close current tab' /
    // 'Close all tabs' above, so they were duplicate palette entries.

    // ── Window ──
    add(l10n.desktopCmdCategoryWindow, l10n.desktopShortcutToggleFullscreen,
        LucideIcons.maximize2, _toggleFullscreen,
        shortcut: accel(ShortcutAction.toggleFullscreen), desc: l10n.paletteDescFullscreen);
    add(l10n.desktopCmdCategoryWindow, l10n.desktopMenuToggleAlwaysOnTop,
        LucideIcons.pin, _toggleAlwaysOnTop, desc: l10n.paletteDescAlwaysOnTop);

    // ── Navigate ──
    add(l10n.desktopCmdCategoryNavigate, l10n.desktopConnections, LucideIcons.server,
        () => _openNavSection(NavSection.hosts), desc: l10n.paletteDescGoHosts);
    add(l10n.desktopCmdCategoryNavigate, l10n.desktopIdentities, LucideIcons.keyRound,
        () => _openNavSection(NavSection.keys), desc: l10n.paletteDescGoKeys);
    add(l10n.desktopCmdCategoryNavigate, l10n.snippetsTitle, LucideIcons.code,
        () => _openNavSection(NavSection.snippets), desc: l10n.paletteDescGoSnippets);
    add(l10n.desktopCmdCategoryNavigate, l10n.desktopServerMonitor,
        LucideIcons.activity, () => _openNavSection(NavSection.monitor), desc: l10n.paletteDescGoMonitor);
    // Settings and About as the rest of the shell opens them: the pop-up
    // its key opens, the About the menu and Help show. (They pushed a
    // phone's pages over the shell.)
    add(l10n.desktopCmdCategoryNavigate, l10n.settingsTitle, LucideIcons.settings,
        _openSettingsSection,
        shortcut: accel(ShortcutAction.settings), desc: l10n.paletteDescSettings);
    add(l10n.desktopCmdCategoryNavigate, l10n.settingsAbout, LucideIcons.info,
        _showAboutDialog, desc: l10n.paletteDescAbout);
    add(l10n.desktopCmdCategoryNavigate, l10n.desktopCmdProfileCloudSync,
        LucideIcons.cloudCog, () => ProfileScreen.openAccount(context, ref), desc: l10n.paletteDescAccount);

    // ── Automation ──
    add(l10n.desktopShellAutomation, l10n.desktopShellOpenAutomationWizard,
        LucideIcons.wand2, () => context.push(Routes.automationWizard), desc: l10n.paletteDescAutomationWizard);
    add(l10n.desktopShellAutomation, l10n.desktopShellOpenWorkflows,
        LucideIcons.gitFork, () => context.push(Routes.workflowList), desc: l10n.paletteDescWorkflows);
    add(l10n.desktopShellAutomation, l10n.desktopShellOpenAutomationHistory,
        LucideIcons.history, () => context.push(Routes.automationHistory), desc: l10n.paletteDescAutomationHistory);
    add(l10n.desktopShellAutomation, l10n.desktopShellOpenScheduledTasks,
        LucideIcons.clock, () => context.push(Routes.scheduledTasks), desc: l10n.paletteDescScheduledTasks);

    // ── Identity & Security ──
    // Lock ZestSSH (4.0): while the app lock is on.
    if (ref.read(securityLockEnabledProvider)) {
      add(l10n.desktopCmdCategoryIdentity, l10n.shortcutNameLockApp, LucideIcons.lock,
          () => unawaited(LockCurtain.lockByYou(ref)),
          shortcut: accel(ShortcutAction.lockApp), desc: l10n.shortcutHelpLockApp);
    }
    add(l10n.desktopCmdCategoryIdentity, l10n.identityNewTitle, LucideIcons.userPlus,
        () => IdentityEditScreen.showAdaptive(context), desc: l10n.paletteDescNewKey);
    add(l10n.desktopCmdCategoryIdentity, l10n.desktopGenerateSshKey,
        LucideIcons.keyRound,
        () => KeyGenerationScreen.showAdaptive(context), desc: l10n.paletteDescGenerateKey);

    // ── Snippets ──
    add(l10n.snippetsTitle, l10n.desktopCmdNewSnippet, LucideIcons.plusSquare,
        () {
      _openNavSection(NavSection.snippets);
    }, desc: l10n.paletteDescNewSnippet);

    // ── Workspace ──
    add(l10n.desktopShellWorkspace, l10n.desktopShellSaveWorkspace,
        LucideIcons.save, () => WorkspaceSaveDialog.show(context), desc: l10n.paletteDescSaveWorkspace);
    add(l10n.desktopShellWorkspace, l10n.desktopShellLoadWorkspace,
        LucideIcons.folderOpen, () => showWorkspaceOpenDialog(context, ref), desc: l10n.paletteDescLoadWorkspace);
    // (§7d) The standalone "Launch Tab Workspace…" browse modal has been
    // removed - workspaces now live in the Hosts drawer, the Hosts page, and
    // the Split-tab empty state. No command-palette entry re-opens it.

    // ── General ──
    add(l10n.desktopShortcutGeneral, l10n.helpShortcuts, LucideIcons.keyboard,
        _openShortcutsSettings, desc: l10n.paletteDescShortcuts);

    // ── Help (spec 7b/7c) ── (what is the account service's: where the build has one)
    if (zestHasCloud) {
    add(l10n.desktopMenuHelp, l10n.supportHubOpen, LucideIcons.lifeBuoy,
        _toggleSupportHub, shortcut: accel(ShortcutAction.supportHub), desc: l10n.shortcutHelpSupportHub);
    add(l10n.desktopMenuHelp, l10n.helpReportBug, LucideIcons.bug,
        () => _openReportForm(FeedbackType.bug), desc: l10n.paletteDescReportBug);
    add(l10n.desktopMenuHelp, l10n.helpSuggest, LucideIcons.lightbulb,
        () => _openReportForm(FeedbackType.suggestion), desc: l10n.paletteDescSuggest);
    add(l10n.desktopMenuHelp, l10n.helpSupport, LucideIcons.helpCircle,
        () => _openHelp(HelpPage.support), desc: l10n.paletteDescHelp);
    add(l10n.desktopMenuHelp, l10n.supportWrite, LucideIcons.pencil,
        () => _openHelp(HelpPage.contactSupport), desc: l10n.paletteDescWriteSupport);
    add(l10n.desktopMenuHelp, l10n.ticketsTitle, LucideIcons.inbox,
        () => _openHelp(HelpPage.tickets), desc: l10n.paletteDescTickets);
    add(l10n.desktopMenuHelp, l10n.astryxTitle, LucideIcons.sparkles,
        () => _openHelp(HelpPage.askAstryx), desc: l10n.astryxPaletteDesc);
    }
    add(
        l10n.desktopMenuHelp,
        ref.read(recordingModeProvider)
            ? l10n.recModeTurnOff
            : l10n.recModeTurnOn,
        LucideIcons.video,
        _toggleRecordingMode,
        shortcut: accel(ShortcutAction.toggleRecordingMode),
        desc: ref.read(recordingModeProvider) ? l10n.paletteDescRecordingOff : l10n.shortcutHelpToggleRecordingMode);
    add(l10n.desktopMenuHelp, l10n.recModeCopyScreenshot,
        LucideIcons.camera, _copyRedactedScreenshot, desc: l10n.paletteDescCopyScreenshot);
    if (kZestDocsUrl != '') {
      add(l10n.desktopMenuHelp, l10n.helpDocs, LucideIcons.bookOpen,
          () => _openUrl(kZestDocsUrl), desc: l10n.paletteDescDocs);
    }
    add(l10n.desktopMenuHelp, l10n.helpWhatsNew, LucideIcons.badgeAlert,
        () => showWhatsNewDialog(context), desc: l10n.paletteDescWhatsNew);
    if (zestHasPlans) {
      add(l10n.desktopShortcutGeneral, l10n.settingsUpgradePro, LucideIcons.star,
          () => context.push(Routes.upgrade), desc: l10n.paletteDescUpgrade);
    }

    showCommandPalette(
      context,
      ref,
      actions: actions,
      onConnect: _connectTo,
      // Ctrl+Enter (Cmd+Enter on a Mac) on a host: beside the panes of the
      // tab in front, as the host panel's Open in split.
      onOpenInSplit: (item) => unawaited(openHostInSplit(context, ref, item.connection)),
      // "Open web-01 in SFTP": as the Hosts panel's SFTP.
      onOpenSftp: _openSftpForHost,
      // "Broadcast to the Web group": Broadcast to hosts with its hosts
      // ticked, then the sessions in front, as the action above.
      onBroadcast: (ids) async {
        await broadcastToHostsFlow(context, ref, preselected: ids);
        if (mounted) ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
      },
    );
  }

  // ── Workspace save / load ──────────────────────────────────────
  //
  // The palette's Save workspace and Load workspace use the workspaces the
  // Hosts page shows (WorkspaceSaveDialog, showWorkspaceOpenDialog), kept in
  // the encrypted store. They kept a store of their own in plain
  // preferences, which nothing else showed; what it holds is brought into
  // the one store once (withPaletteWorkspaces). 3.0 docs check, 22 October
  // 2026.

  /// Fold every tab sharing [tabId]'s color override into a single tab.
  ///
  /// Designed for the Stage-1 spillover case: sorting a tab of 4 sessions
  /// to a 2-pane layout produces 2 tabs each with `colorIndex == X`. Right-
  /// clicking either tab and picking "Merge Group" recombines them into one
  /// tab whose tree is a horizontal split of the originals.
  ///
  /// Soft-close a list of WorkTabs with a 5-second Undo window.
  ///
  /// The tabs vanish from the pill strip immediately (filtered by
  /// `pendingClose`) but their SSH sessions stay alive. A snackbar
  /// pops at the bottom of the screen with an "Undo" action - clicking
  /// it cancels the close (sessions never disconnected, tabs reappear
  /// intact). Letting the snackbar dismiss runs the actual
  /// `endSession` + SFTP cleanup + `closeTab`.
  ///
  /// Skips pinned tabs (caller is expected to filter them too, but
  /// we double-check here as defence-in-depth).
  Future<void> _closeTabsWithUndo(List<WorkTab> tabs) async {
    final closing = tabs.where((t) => !t.pinned).toList();
    if (closing.isEmpty) return;

    // Capture session ids per tab BEFORE marking pendingClose. The
    // tab's own `sessionIds` getter walks the pane tree, so it stays
    // valid even after we mark pendingClose, but we want a stable
    // snapshot in case the tree mutates during the undo window.
    final captured = <String, List<String>>{
      for (final t in closing) t.id: List.of(t.sessionIds),
    };

    for (final t in closing) {
      ref.read(workTabsProvider.notifier).markPendingClose(t.id);
    }

    if (!mounted) {
      // Shell already gone - finalize immediately so we don't leak
      // sessions waiting for a snackbar that won't appear.
      _finalizePendingCloses(captured);
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final n = captured.values.fold<int>(
        0, (sum, ids) => sum + ids.toSet().length);
    final tabCount = closing.length;
    final label = tabCount == 1
        ? (n == 1
            ? l10n.desktopShellTabClosed
            : l10n.desktopShellTabClosedWithSessions(n))
        : l10n.desktopShellTabsClosedWithSessions(tabCount, n);

    var undone = false;
    // showTopSnackBar already calls clearSnackBars() so any prior undo
    // toast resolves its `closed` future and finalizes its tabs.
    final controller = showTopSnackBar(
      context,
      label,
      duration: const Duration(seconds: 5),
      actionLabel: l10n.desktopShellUndo,
      onAction: () {
        undone = true;
        for (final tabId in captured.keys) {
          ref.read(workTabsProvider.notifier).cancelPendingClose(tabId);
        }
      },
    );

    await controller.closed;
    // If the user clicked Undo, the cancelPendingClose calls already
    // restored the tabs and `undone` is true - skip finalization.
    if (undone) return;
    _finalizePendingCloses(captured);
  }

  /// For each captured tab still marked `pendingClose` (i.e. the user
  /// didn't undo), close registered SFTP services, end SSH sessions,
  /// and remove the WorkTab. Tabs the user undid are skipped because
  /// `cancelPendingClose` cleared their flag.
  void _finalizePendingCloses(Map<String, List<String>> captured) {
    final sftpNotifier = ref.read(sftpSessionsProvider.notifier);
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final state = ref.read(workTabsProvider);

    for (final entry in captured.entries) {
      final tab = state.tabs
          .where((t) => t.id == entry.key)
          .firstOrNull;
      if (tab == null) continue; // already closed via another path
      if (!tab.pendingClose) continue; // user clicked Undo

      // Each session once: its terminal and its SFTP pane share its id.
      for (final sid in entry.value.toSet()) {
        // Reopened one by one, the last closed first (Ctrl+Shift+T). (Only a
        // tab closed from the keyboard was remembered.)
        final connectionId = ref.read(activeSessionsProvider)[sid]?.connectionId;
        if (connectionId != null) ref.read(recentlyClosedTabsProvider.notifier).add(connectionId);
        final sftp = sftpNotifier.get(sid);
        if (sftp != null) {
          sftpNotifier.unregister(sid);
          // ignore: discarded_futures
          sftp.close();
        }
        // ignore: discarded_futures
        sessionsNotifier.endSession(sid);
      }
      ref.read(workTabsProvider.notifier).closeTab(tab.id);
    }
  }

  /// Show a destructive confirmation dialog if any of [tabs] is a
  /// "real group" - three or more *unique* sessions wired into the
  /// same WorkTab. A terminal + SFTP pane on the same session is NOT
  /// a group (one unique sessionId), so it doesn't trigger.
  ///
  /// Returns true when the user confirmed (or no confirmation was
  /// needed), false when they cancelled. Caller bails on false.
  Future<bool> _confirmCloseTabsIfGroups(List<WorkTab> tabs) async {
    // Count unique session ids per tab; sum up only the ones that
    // qualify as a group.
    var groupCount = 0;
    var totalSessions = 0;
    for (final t in tabs) {
      final unique = t.sessionIds.toSet().length;
      if (unique >= 3) {
        groupCount++;
        totalSessions += unique;
      }
    }
    if (groupCount == 0) return true; // no groups → close without prompt
    if (!mounted) return false;

    final l10n = AppLocalizations.of(context)!;
    // The app's own question (it was a plain dialog built here).
    final answer = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: groupCount == 1 ? l10n.desktopShellDisconnectGroup : l10n.desktopShellDisconnectGroups(groupCount),
      body: groupCount == 1
          ? l10n.desktopShellDisconnectGroupBody(totalSessions)
          : l10n.desktopShellDisconnectGroupsBody(totalSessions, groupCount),
      confirmLabel:
          groupCount == 1 ? l10n.desktopShellDisconnectAll : l10n.desktopShellDisconnectCount(totalSessions),
    );
    return answer == true;
  }

  /// No-op (with a snackbar) if the tab has no explicit colorIndex or no
  /// siblings share it - coincidental "same connection color" tabs aren't
  /// considered part of the same group.
  void _mergeColorGroupInto(String tabId) {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(workTabsProvider.notifier);
    final state = ref.read(workTabsProvider);
    final source =
        state.tabs.where((t) => t.id == tabId).firstOrNull;
    if (source == null) return;
    if (source.colorIndex == null) {
      showTopSnackBar(
        context,
        l10n.desktopShellNotInColorGroup,
      );
      return;
    }
    final siblings = state.tabs
        .where((t) =>
            t.id != tabId && t.colorIndex == source.colorIndex)
        .toList();
    if (siblings.isEmpty) {
      showTopSnackBar(
        context,
        l10n.desktopShellNoTabsShareColor,
      );
      return;
    }
    // Each sibling joins the source's tab (mergeTabs): tabs nobody arranged
    // become one grid, the room shared evenly.
    final undos = [
      for (final sibling in siblings) ?notifier.mergeTabs(sibling.id, tabId),
    ];
    notifier.setActiveTab(tabId);
    offerTabMergeUndo(context, ref, undos, message: l10n.desktopShellMergedTabs(siblings.length + 1));
  }

  // ── Active session resolution ───────────────────────────────────

  // ── SFTP helpers ────────────────────────────────────────────────

  /// Open (or toggle) an SFTP pane for the given session id.
  /// Initialises the pane tree if needed, and falls back to the first
  /// available leaf when no pane is focused.
  void _openSftpForSession(String sid) {
    final l10n = AppLocalizations.of(context)!;
    // A session that is files only shows its files in its own pane: its tab
    // is brought to the front, and no second browser is opened beside it.
    if (ref.read(activeSessionsProvider.notifier).isFilesOnly(sid)) {
      _selectSessionTab(sid);
      return;
    }
    final session = ref.read(activeSessionsProvider)[sid];
    // A screen's SSH connection too (4.0: a screen's Files).
    if (sshServiceOfShell(session?.session?.shell) == null) {
      showTopSnackBar(context, l10n.desktopShellSftpRequiresSsh);
      return;
    }
    // Switch the active WorkTab to the one containing this session so
    // the terminal-area render dispatch actually shows the SFTP pane -
    // setting v3ActiveSessionTabProvider alone is NOT enough because
    // the render check at desktop_shell.dart's V3 layout reads
    // `activeWorkTabId`. Without this, clicking SFTP from a sidebar
    // page (Hosts, Snippets, etc.) would silently mutate the pane tree
    // and the user would see nothing change.
    final tab = ref.read(workTabsProvider.notifier).tabContaining(sid);
    if (tab != null &&
        ref.read(workTabsProvider).activeTabId != tab.id) {
      ref.read(workTabsProvider.notifier).setActiveTab(tab.id);
    }
    // Make sure this session is the one displayed.
    if (ref.read(v3ActiveSessionTabProvider) != sid) {
      ref.read(v3ActiveSessionTabProvider.notifier).state = sid;
    }
    var tree = ref.read(paneTreeProvider);
    // If SFTP is already open for this session, close it (toggle).
    final existingSftp = tree?.allLeaves
        .where((l) => l.type == 'sftp' && l.sessionId == sid)
        .firstOrNull;
    if (existingSftp != null) {
      ref.read(paneTreeProvider.notifier).closePane(existingSftp.id);
      return;
    }
    // A tab has one SFTP dock: SFTP for another of its sessions replaces it.
    for (final other in tree?.allLeaves.where((l) => l.type == 'sftp').toList() ??
        const <PaneLeaf>[]) {
      ref.read(paneTreeProvider.notifier).closePane(other.id);
    }
    tree = ref.read(paneTreeProvider);
    if (tree == null) {
      ref.read(paneTreeProvider.notifier).initSinglePane(sid);
    }
    final updatedTree = ref.read(paneTreeProvider);

    // Validate the focused leaf is in THIS tree. If the user switched
    // tabs / sessions, focusedPaneProvider may point to a leaf from
    // a different tab's tree - using it would make splitPaneWithSftp
    // silently no-op (which is the original "SFTP didn't work" bug).
    final focused = ref.read(focusedPaneProvider);
    String? leafId;
    if (focused != null && updatedTree?.findLeaf(focused) != null) {
      leafId = focused;
    } else {
      leafId = updatedTree?.allLeaves.firstOrNull?.id;
    }
    if (leafId == null) {
      showTopSnackBar(context, l10n.desktopShellSftpNoActivePane,
          isError: true);
      return;
    }
    final ok = ref
        .read(paneTreeProvider.notifier)
        .splitPaneWithSftp(leafId, Axis.horizontal, sid);
    if (!ok) {
      showTopSnackBar(context, l10n.desktopShellSftpLayoutChanged,
          isError: true);
    }
  }

  /// Show a picker dialog listing saved connections so the user can open
  /// SFTP without first manually connecting. Once they pick a host, the
  /// session starts and SFTP opens automatically when it connects.
  ///
  /// Tiles mirror the home-screen host card style: a 3px coloured left
  /// edge (group colour or accent), a 32x32 OS icon coloured by the
  /// detected distro, label + host:port, and a chevron. Keeps the picker
  /// consistent with the rest of the app instead of looking like a
  /// stock list dialog.
  void _showSftpServerPicker() {
    // Route through the shared, filterable ConnectionPickerDialog (A2) so
    // the SFTP host picker gets an autofocus search box + consistent tiles
    // instead of a bespoke, filter-less list.
    ConnectionPickerDialog.show(
      context,
      title: AppLocalizations.of(context)!.sftpOpenPickerTitle,
    ).then((result) {
      final picked = result.connection;
      if (picked == null || !mounted) return;
      // Reuse a live SSH session for this host if one exists; otherwise
      // start a fresh connect and auto-open SFTP once it is ready.
      final sessions = ref.read(activeSessionsProvider);
      String? runningSid;
      for (final entry in sessions.entries) {
        final s = entry.value;
        if (s.status == SessionStatus.connected &&
            s.connectionId == picked.connection.id &&
            s.session?.shell is SshService &&
            !s.isHidden) {
          runningSid = entry.key;
          break;
        }
      }
      if (runningSid != null) {
        _openSftpForSession(runningSid);
      } else {
        _startSessionForSftp(picked);
      }
    });
  }

  /// Start a session for the given connection and remember to open SFTP
  /// for it when it transitions to connected. (See ref.listen in build()).
  /// SFTP for a host (the Hosts panel): in a session already open to it, or
  /// in a new one that opens SFTP once it connects.
  void _openSftpForHost(ConnectionWithDetails item) {
    final live = ref
        .read(activeSessionsProvider)
        .entries
        .where((e) =>
            e.value.connectionId == item.connection.id &&
            e.value.status == SessionStatus.connected)
        .firstOrNull;
    if (live == null) {
      _startSessionForSftp(item);
      return;
    }
    _selectSessionTab(live.key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openSftpForSession(live.key);
    });
  }

  void _startSessionForSftp(ConnectionWithDetails item) {
    // A Telnet host has no SFTP: said before anything connects, rather than
    // an unencrypted session opened unasked that cannot give it.
    if (isTelnetHost(item.connection)) {
      showTopSnackBar(context, AppLocalizations.of(context)!.desktopShellSftpRequiresSsh);
      return;
    }
    final sid = ref
        .read(activeSessionsProvider.notifier)
        .startSession(item.connection);
    if (sid == null) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.desktopShellFreeTierLimit(freeSessionLimit),
        isError: true,
      );
      return;
    }
    ref.read(workTabsProvider.notifier).onSessionCreated(sid);
    _pendingSftpAutoOpen = sid;
    // Switch to the new session tab so the user sees the connection progress.
    _selectSessionTab(sid);
    // The toast names the host, so it goes through the redaction toolkit
    // like every other painted identifier.
    final who = item.connection.label.isNotEmpty
        ? Redactable.host(item.connection.label).display
        : Redactable.address(item.connection.host).display;
    showTopSnackBar(
        context, AppLocalizations.of(context)!.sftpConnectingWillOpen(who));
  }

  // ── Window actions ──────────────────────────────────────────────

  void _toggleFullscreen() {
    final debug = DesktopShell.debugToggleFullscreen;
    if (debug != null) return debug();
    WindowService.instance?.toggleFullscreen();
  }

  void _toggleAlwaysOnTop() {
    WindowService.instance?.toggleAlwaysOnTop();
  }

  // ── Split pane ──────────────────────────────────────────────────

  /// Make [tab] the active WorkTab and sync the terminal-area selection, so a
  /// context-menu action (split / SFTP) triggered on a tab OTHER than the
  /// active one still lands in that tab's pane tree.
  void _activateTabForAction(String tabId, WorkTab tab) {
    if (ref.read(workTabsProvider).activeTabId != tabId) {
      ref.read(workTabsProvider.notifier).setActiveTab(tabId);
    }
    final sid = tab.sessionIds.firstOrNull;
    if (sid == null) return;
    ref.read(v3ActiveSessionTabProvider.notifier).state = sid;
    final activeEntries = ref
        .read(activeSessionsProvider)
        .entries
        .where((e) =>
            e.value.status == SessionStatus.connected ||
            e.value.status == SessionStatus.connecting)
        .toList();
    final idx = activeEntries.indexWhere((e) => e.key == sid);
    if (idx >= 0) {
      ref.read(desktopSelectedTabProvider.notifier).state = idx;
    }
  }

  /// Hard cap on the number of split panes a single tree can have.
  /// Beyond this each new pane becomes a slim sliver and is unreadable -
  /// users should switch tabs / use a layout preset instead.
  static const int _kMaxPanes = 8;

  void _splitPane(SplitDirection direction) {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.read(activeSessionsProvider);
    final activeEntries = sessions.entries
        .where((e) =>
            e.value.status == SessionStatus.connected ||
            e.value.status == SessionStatus.connecting)
        .toList();

    if (activeEntries.isEmpty) {
      showTopSnackBar(context, l10n.desktopShellConnectToServerFirst);
      return;
    }

    final axis = direction == SplitDirection.horizontal
        ? Axis.horizontal
        : Axis.vertical;

    final selectedTab = ref.read(desktopSelectedTabProvider);
    final clampedTab = selectedTab.clamp(0, activeEntries.length - 1);
    final primaryId = activeEntries[clampedTab].key;

    // If no session is currently selected (we're on Hosts/Keys/etc page),
    // promote the primary session so the terminal view mounts.
    if (ref.read(v3ActiveSessionTabProvider) == null) {
      ref.read(v3ActiveSessionTabProvider.notifier).state = primaryId;
    }

    // Ensure a pane tree exists for this session.
    var tree = ref.read(paneTreeProvider);
    if (tree == null) {
      ref.read(paneTreeProvider.notifier).initSinglePane(primaryId);
      tree = ref.read(paneTreeProvider);
    }

    // Don't allow runaway splitting - past 8 panes everything is unreadable.
    if ((tree?.allLeaves.length ?? 0) >= _kMaxPanes) {
      showTopSnackBar(
          context, l10n.desktopShellMaxPanesReached(_kMaxPanes));
      return;
    }

    // Resolve the leaf to split: prefer focused, otherwise the first
    // leaf. Validate the focused leaf actually exists in the CURRENT
    // tree - focusedPaneProvider can hold a stale id from a previous
    // tab's tree (we clear it on tab swap now, but old saved state
    // and races can still leave a phantom value).
    final focused = ref.read(focusedPaneProvider);
    String? leafIdOrNull;
    if (focused != null && tree?.findLeaf(focused) != null) {
      leafIdOrNull = focused;
    } else {
      leafIdOrNull = tree?.allLeaves.firstOrNull?.id;
    }
    if (leafIdOrNull == null) {
      showTopSnackBar(context, l10n.desktopShellCouldNotSplitPane);
      return;
    }
    // Promote to non-null so the .then() closure captures String, not
    // String? (Dart doesn't preserve flow promotion across closures).
    final String leafId = leafIdOrNull;

    // The session we're cloning lives in the leaf we're splitting - not
    // necessarily the top-bar selected tab. Look it up so the duplicate
    // is for the right host.
    final sourceLeaf = tree!.findLeaf(leafId);
    final sourceSessionId = sourceLeaf?.sessionId ?? primaryId;
    final sourceState = ref.read(activeSessionsProvider)[sourceSessionId];
    final sourceConnId = sourceState?.connectionId;

    // Each pane MUST own its own session - otherwise typing in one mirrors
    // into the other (they share the same xterm + ssh stream). When the
    // user clicks Split we always spawn a fresh duplicate of the source
    // connection and use that for the new pane.
    if (sourceConnId == null) {
      // Edge case: ephemeral session without a saved connection. Fall
      // back to picking another live session so we at least don't share.
      final other = activeEntries
          .where((e) => e.key != sourceSessionId)
          .firstOrNull
          ?.key;
      if (other != null) {
        ref.read(paneTreeProvider.notifier).splitPane(leafId, axis, other);
      } else {
        showTopSnackBar(context, l10n.desktopShellSessionCantDuplicate);
      }
      return;
    }

    // Start the duplicate asynchronously - startSession needs a
    // Connection record from the DAO. We split the tree only after the
    // new session id is known, so the new pane gets its own terminal.
    ref.read(connectionsDaoProvider).getById(sourceConnId).then((conn) {
      if (!mounted) return;
      if (conn == null) {
        showTopSnackBar(context, l10n.desktopShellConnectionRecordNotFound);
        return;
      }

      // RE-VALIDATE leafId against the *current* tree (it may have
      // changed during the DAO await - tab switch, close, etc.). If
      // the leaf is gone, fall back to the first leaf so the split
      // still lands somewhere visible instead of orphaning the new
      // session into a counted-but-invisible state.
      final currentTree = ref.read(paneTreeProvider);
      String? targetLeafId = leafId;
      if (currentTree?.findLeaf(targetLeafId) == null) {
        targetLeafId = currentTree?.allLeaves.firstOrNull?.id;
      }
      if (targetLeafId == null) {
        showTopSnackBar(context, l10n.desktopShellCouldNotSplitSourceGone,
            isError: true);
        return;
      }

      // The split-spawned session must NOT get its own tab - it lives in
      // the active tab's split tree.
      ref.read(workTabsProvider.notifier).expectSplitSession();
      // The split signs in as the session it is split from.
      final newSessionId = ref.read(activeSessionsProvider.notifier).startLike(sourceSessionId, conn);
      if (newSessionId == null) {
        showTopSnackBar(context,
            l10n.desktopShellFreeTierLimit(freeSessionLimit),
            isError: true);
        return;
      }
      // splitPane returns false if the leaf disappeared between the
      // re-validation above and the actual mutation (extremely tight
      // race, but possible). End the orphan session immediately so
      // we don't leave a phantom in the session count.
      final ok = ref
          .read(paneTreeProvider.notifier)
          .splitPane(targetLeafId, axis, newSessionId);
      if (!ok) {
        ref
            .read(activeSessionsProvider.notifier)
            .endSession(newSessionId);
        if (mounted) {
          showTopSnackBar(context, l10n.desktopShellSplitFailedLayoutChanged,
              isError: true);
        }
        return;
      }
    });
  }

  /// Close the currently focused pane in the tree.
  /// If it is the last pane, the tree becomes null (showing single terminal).
  void _closeFocusedPane() {
    final focusedLeaf = ref.read(focusedPaneProvider);
    if (focusedLeaf != null) {
      ref.read(paneTreeProvider.notifier).closePane(focusedLeaf);
    }
  }

  // ── Pane maximize toggle ──────────────────────────────────────
  // Each tab's own arrangement from before a pane was maximised (it was one
  // for the whole window, restored into whichever tab was in front).
  final _maximized = MaximizedPanes();

  /// Whether the tab in front has a pane maximised.
  bool get _paneMaximized => _maximized.isMaximized(ref.read(workTabsProvider).activeTab?.id);

  void _toggleMaximizePane() {
    final tabs = ref.read(workTabsProvider);
    final tabId = tabs.activeTab?.id;
    final focused = ref.read(focusedPaneProvider);
    if (focused == null || tabId == null) return;
    _maximized.keepOnly(tabs.tabs.map((t) => t.id));
    final restoring = _maximized.isMaximized(tabId);
    final next = _maximized.toggle(tabId, ref.read(paneTreeProvider), focused);
    if (next == null) return;
    ref.read(paneTreeProvider.notifier).setTree(next);
    // Restored: the same pane stays in front where it is still there.
    if (restoring && ref.read(paneTreeProvider)?.findLeaf(focused) != null) {
      ref.read(focusedPaneProvider.notifier).state = focused;
    }
  }

  // ── Layout presets ──────────────────────────────────────────────

  /// Whether the session [sessionId] is still shown in the main window:
  /// one that ended, or went to a window of its own, is no longer in its
  /// pane.
  bool _shownHere(String sessionId) =>
      ref.read(activeSessionsProvider).containsKey(sessionId) &&
      !ref.read(detachedSessionsProvider).contains(sessionId);

  /// Arranges the terminals of the **current tab** as the arrangement
  /// [number] stands for (WorkTabsNotifier.arrangeTab). One with fewer panes
  /// than the tab has terminals is not made, and the person is told why.
  /// (It used to move the terminals it had no pane for into new tabs, which
  /// read as terminals disappearing.)
  void _applyLayoutPreset(int number) {
    final preset = LayoutPreset.byNumber(number);
    final activeTab = ref.read(workTabsProvider).activeTab;
    if (preset == null || activeTab == null) return;
    final outcome = ref
        .read(workTabsProvider.notifier)
        .arrangeTab(activeTab.id, preset, shown: _shownHere);
    switch (outcome) {
      case ArrangeOutcome.nothing:
        return;
      case ArrangeOutcome.tooSmall:
        showTopSnackBar(context, AppLocalizations.of(context)!.layoutTooSmall,
            isWarning: true);
      case ArrangeOutcome.done:
        // Kept for the next launch.
        ref
            .read(sharedPreferencesProvider)
            .setInt('desktop_pane_layout_preset', number);
        _maximized.forget(activeTab.id);
    }
  }

  /// Puts the terminals of the current tab in the grid a tab nobody
  /// arranged stands in: up to three side by side, from four on in two
  /// rows. From then on the tab keeps to that grid as terminals join and
  /// leave it.
  void _arrangeAutomatically() {
    final activeTab = ref.read(workTabsProvider).activeTab;
    if (activeTab == null) return;
    final outcome = ref
        .read(workTabsProvider.notifier)
        .arrangeTab(activeTab.id, null, shown: _shownHere);
    if (outcome != ArrangeOutcome.done) return;
    ref.read(sharedPreferencesProvider).remove('desktop_pane_layout_preset');
    _maximized.forget(activeTab.id);
  }

  void _reopenLastClosedTab() {
    final connectionId = ref.read(recentlyClosedTabsProvider.notifier).pop();
    if (connectionId == null) return;

    final connectionsAsync = ref.read(connectionsWithDetailsProvider);
    connectionsAsync.whenData((connections) {
      final match = connections
          .where((c) => c.connection.id == connectionId)
          .firstOrNull;
      if (match != null) {
        _connectTo(match);
      }
    });
  }

  // ── Keyboard shortcuts ──────────────────────────────────────────

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    // Same terminal-focus gate as [_hardwareKeyHandler] - guard here
    // too because this root-Focus handler also fires for chords the
    // focused widget bubbles up unhandled (e.g. Ctrl+T reaching the
    // Quick Connect mapping below while a TUI expected it). While a
    // terminal is focused, this handler claims nothing at all - the
    // palette escape hatch is owned by _hardwareKeyHandler.
    if (_terminalHasFocus() || _remoteScreenHasFocus()) {
      return;
    }
    // Nor while the Support Hub is over the shell: what it leaves unhandled
    // comes up to here, and is nothing to act on what is behind it.
    if (ref.read(supportHubOpenProvider)) return;

    // (The command palette is _hardwareKeyHandler's alone, its Ctrl+Shift+P
    // as well: kept here too, one press opened the palette there and closed
    // it again here, both handlers being run for every key.)

    // (Quick connect is the rebindable dispatcher's alone: Ctrl+T here as well
    // opened it twice from one press, both handlers being run for every key,
    // and opened it on Ctrl+T after it was bound to another key.)

    // Every key below that Settings lets one change goes by what Settings
    // binds it to (Keyboard shortcuts; the keys of the comments unless
    // changed there). Their keys were fixed here: a key chosen in Settings
    // did nothing, though the palette named it, the old key went on working,
    // and so did a key cleared there.
    final bindings = ref.read(shortcutBindingsProvider);

    // Ctrl+Shift+N → New Connection
    if (bindings.matches(event, ShortcutAction.newConnection)) {
      ConnectionEditScreen.showAdaptive(context);
      return;
    }

    // Close-tab (default Ctrl+Shift+W) is owned by the rebindable dispatcher
    // in _hardwareKeyHandler; no hardcoded bare-Ctrl+W here, so that chord
    // reaches the terminal (readline delete-word, nano search) untouched.

    // Reopen the last closed tab, the next tab and the one before (Ctrl+Shift+T,
    // Ctrl+Tab and Ctrl+Shift+Tab).
    if (bindings.matches(event, ShortcutAction.reopenLastTab)) {
      _reopenLastClosedTab();
      return;
    }
    if (bindings.matches(event, ShortcutAction.nextTab)) {
      _stepTab(1);
      return;
    }
    if (bindings.matches(event, ShortcutAction.previousTab)) {
      _stepTab(-1);
      return;
    }

    // Ctrl+1-9 → Jump to tab. (Not with Alt held as well: on many keyboards
    // that is how a brace, a bracket or an at sign is typed.)
    if (isCtrl && !isShift && !isAlt) {
      final digit = _getDigitFromKey(event.logicalKey);
      if (digit != null && digit >= 1 && digit <= 9) {
        _jumpToTab(digit - 1);
        return;
      }
    }

    // Ctrl+Shift+D → Split right
    if (bindings.matches(event, ShortcutAction.splitRight)) {
      _splitPane(SplitDirection.horizontal);
      return;
    }

    // Ctrl+Shift+E → Split down
    if (bindings.matches(event, ShortcutAction.splitDown)) {
      _splitPane(SplitDirection.vertical);
      return;
    }

    // Ctrl and the backslash → Close split
    if (bindings.matches(event, ShortcutAction.closeSplit)) {
      _closeFocusedPane();
      return;
    }

    // Alt+Arrow keys → Navigate between panes
    if (isAlt && !isCtrl && !isShift) {
      final direction = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowLeft => AxisDirection.left,
        LogicalKeyboardKey.arrowRight => AxisDirection.right,
        LogicalKeyboardKey.arrowUp => AxisDirection.up,
        LogicalKeyboardKey.arrowDown => AxisDirection.down,
        _ => null,
      };
      if (direction != null) {
        ref.read(paneTreeProvider.notifier).moveFocus(direction);
        return;
      }
    }

    // Ctrl+Shift+M → Toggle maximize focused pane
    if (bindings.matches(event, ShortcutAction.maximizePane)) {
      _toggleMaximizePane();
      return;
    }

    // Ctrl+= → Increase font size, Ctrl+- → Decrease it, Ctrl+0 → Reset it to
    // the default (14px); each by the number pad's key as well
    // ([_matchesOrPadTwin]).
    if (_matchesOrPadTwin(bindings, event, ShortcutAction.zoomIn)) {
      _adjustFontSize(1);
      return;
    }
    if (_matchesOrPadTwin(bindings, event, ShortcutAction.zoomOut)) {
      _adjustFontSize(-1);
      return;
    }
    if (_matchesOrPadTwin(bindings, event, ShortcutAction.resetZoom)) {
      _adjustFontSize(0, resetTo: 14.0);
      return;
    }

    // (Arrangements have no key of their own. Ctrl+Alt and a digit was
    // meant to be one and never was: Ctrl and a digit, looked at first, took
    // it for a jump to a tab. They are chosen in the Layout popover and in
    // the command palette, which also opens from inside a terminal.)

    // Ctrl+Shift+B → Toggle broadcast mode (from inside a terminal it is
    // _hardwareKeyHandler's)
    if (bindings.matches(event, ShortcutAction.toggleBroadcast)) {
      _toggleBroadcast();
      return;
    }

    // Ctrl+Shift+I → Toggle session info slide panel
    if (bindings.matches(event, ShortcutAction.toggleSessionInfo)) {
      final current = ref.read(sessionSlidePanelVisibleProvider);
      ref.read(sessionSlidePanelVisibleProvider.notifier).state = !current;
      return;
    }

    // (Settings, Ctrl+comma, is _hardwareKeyHandler's alone. Ctrl+comma here
    // as well opened it where Settings had been bound to another key or to
    // none.)

    // Ctrl+Shift+S → Toggle SFTP panel
    if (bindings.matches(event, ShortcutAction.toggleSftpPanel)) {
      _toggleSftp();
      return;
    }

    // (Find in terminal is the shortcut Settings binds it to, taken in
    // [_hardwareKeyHandler], from inside a terminal too: kept here as well,
    // one key would open it twice. Its bar closes on its own Escape.)

    // Ctrl+Shift+C → Copy selection (inside a terminal its own keys copy and
    // paste: terminalKeys)
    if (bindings.matches(event, ShortcutAction.copySelection)) {
      _copySelection();
      return;
    }

    // Ctrl+Shift+V → Paste
    if (bindings.matches(event, ShortcutAction.paste)) {
      _pasteToTerminal();
      return;
    }

    // (Zoom in / out / reset are handled by the earlier _adjustFontSize
    // block above - this duplicate block used a different clamp (8-32 vs
    // 8-24) and a different persistence path, and was unreachable because
    // the earlier handlers already `return`. Removed to keep one zoom impl.)

    // F11 → Toggle fullscreen
    if (bindings.matches(event, ShortcutAction.toggleFullscreen)) {
      _toggleFullscreen();
      return;
    }
  }

  /// The number pad's twins of the keys zoom is bound to by default: Ctrl
  /// and the pad's +, - or 0 zoom as Ctrl and =, - or 0 do, while zoom is
  /// bound to those (with the same other keys held).
  static final Map<int, LogicalKeyboardKey> _padTwins = {
    LogicalKeyboardKey.equal.keyId: LogicalKeyboardKey.numpadAdd,
    LogicalKeyboardKey.minus.keyId: LogicalKeyboardKey.numpadSubtract,
    LogicalKeyboardKey.digit0.keyId: LogicalKeyboardKey.numpad0,
  };

  /// [action]'s key as Settings binds it, or that key's twin on the number
  /// pad ([_padTwins]).
  bool _matchesOrPadTwin(ShortcutBindings bindings, KeyEvent event, ShortcutAction action) {
    if (bindings.matches(event, action)) return true;
    final binding = bindings.bindingFor(action);
    final twin = _padTwins[binding?.keyId];
    if (binding == null || twin == null || event.logicalKey != twin) return false;
    return ShortcutKey(
      keyId: twin.keyId,
      ctrl: binding.ctrl,
      shift: binding.shift,
      alt: binding.alt,
      meta: binding.meta,
    ).matches(event);
  }

  // ── Tab actions ──────────────────────────────────────────────────

  void _adjustFontSize(int delta, {double? resetTo}) {
    final current = ref.read(terminalFontSizeProvider);
    final newSize = clampTerminalFontSize(resetTo ?? current + delta);
    ref.read(terminalFontSizeProvider.notifier).state = newSize;
    ref.read(settingsServiceProvider).setTerminalFontSize(newSize);
  }

  /// Shows the tab [tabId], as a click on its pill does.
  void _selectTab(String tabId) {
    _closeSupportHub();
    // Switch the active WorkTab - paneTreeProvider is automatically
    // swapped to that tab's tree by WorkTabsNotifier, which points the
    // terminal area at the tab's first session as well.
    ref.read(workTabsProvider.notifier).setActiveTab(tabId);
    // Its terminal takes the keyboard (DesktopTerminalArea).
    ref.read(terminalKeyboardAskProvider.notifier).state++;
    // The legacy single-pane index, counted as the IndexedStack-based
    // terminal area lists the sessions: connected or on their way, neither in
    // a window of its own nor hidden. (The tabs count every session that is
    // not hidden.)
    final firstSid = ref.read(workTabsProvider).activeTab?.sessionIds.firstOrNull;
    if (firstSid == null) return;
    final detached = ref.read(detachedSessionsProvider);
    final listed = [
      for (final e in ref.read(activeSessionsProvider).entries)
        if ((e.value.status == SessionStatus.connected || e.value.status == SessionStatus.connecting) &&
            !detached.contains(e.key) &&
            !e.value.isHidden)
          e.key,
    ];
    final idx = listed.indexOf(firstSid);
    if (idx >= 0) ref.read(desktopSelectedTabProvider.notifier).state = idx;
  }

  /// The tabs as the strip shows them.
  List<WorkTab> _stripTabs() =>
      tabsInStripOrder(ref.read(workTabsProvider).tabs, ref.read(activeSessionsProvider));

  /// Closes the tab in front the way its pill does: a group is asked about
  /// first, and there is a moment to take it back. A pinned tab, which its
  /// pill does not close, is not closed either. (This closed the session at
  /// an index kept from before tabs held groups: in a tab of several, not
  /// the one in front, or a session of another tab.)
  Future<void> _closeCurrentTab() async {
    // (The tab in front is never one being closed: marking it so puts
    // another in front.)
    final tab = ref.read(workTabsProvider).activeTab;
    if (tab == null || tab.pinned) return;
    if (!await _confirmCloseTabsIfGroups([tab])) return;
    await _closeTabsWithUndo([tab]);
  }

  /// The next tab ([direction] 1) or the one before it (-1): of the pane in
  /// focus when it holds several, or else of the strip.
  void _stepTab(int direction) {
    final tree = ref.read(paneTreeProvider);
    final focused = ref.read(focusedPaneProvider);
    final leaf = focused == null ? null : tree?.findLeaf(focused);
    if (leaf != null && leaf.sessionIds.length > 1) {
      final panes = ref.read(paneTreeProvider.notifier);
      direction > 0 ? panes.nextTabInPane() : panes.prevTabInPane();
      return;
    }
    _cycleTab(direction);
  }

  /// The next tab of the strip ([direction] 1) or the one before it (-1),
  /// round from the last to the first; with no tab in front, the first or
  /// the last.
  void _cycleTab(int direction) {
    final strip = _stripTabs();
    if (strip.isEmpty) return;
    final current = strip.indexWhere((t) => t.id == ref.read(workTabsProvider).activeTabId);
    final next = current < 0
        ? (direction > 0 ? 0 : strip.length - 1)
        : (current + direction) % strip.length;
    // (A strip of one has nowhere to go.)
    if (next != current) _selectTab(strip[next].id);
  }

  /// The tab at [index] of the strip (Ctrl and a digit: 0 is the first).
  void _jumpToTab(int index) {
    final strip = _stripTabs();
    if (index >= strip.length) return;
    _selectTab(strip[index].id);
  }

  /// Starts or stops the broadcast of the tab in front. One with fewer than
  /// two terminals has nobody to type to, and the person is told so. (This
  /// used to switch broadcast on for every session of every tab.)
  void _toggleBroadcast() {
    final tab = ref.read(workTabsProvider).activeTab;
    if (tab == null) return;
    final notifier = ref.read(broadcastModeProvider.notifier);
    if (ref.read(broadcastModeProvider).broadcasts(tab.id)) {
      notifier.stopTab(tab.id);
    } else if (!notifier.startTab(tab.id)) {
      showTopSnackBar(context, AppLocalizations.of(context)!.layoutBroadcastNeedsPanes);
    }
  }

  // ── SFTP Toggle ────────────────────────────────────────────────

  /// The SSH session the tab in front's tmux and SFTP act on, as its header's
  /// buttons do ([sshToolsSessionOf]): the focused pane's, else the one last in
  /// front, else its first. Null where the tab has none: a local shell's.
  String? _sshSessionInFront() {
    final tab = ref.read(workTabsProvider).activeTab;
    if (tab == null) return null;
    final tree = ref.read(paneTreeProvider);
    final focused = ref.read(focusedPaneProvider);
    final leaf = focused == null ? null : tree?.findLeaf(focused);
    return sshToolsSessionOf(
      tab,
      ref.read(activeSessionsProvider),
      focused: leaf != null && leaf.type != 'sftp' && leaf.sessionIds.isNotEmpty ? leaf.sessionId : null,
      lastInFront: ref.read(lastSshSessionOfTabProvider)[tab.id] ?? ref.read(v3ActiveSessionTabProvider),
    );
  }

  /// The SFTP shortcut: SFTP for the session the person is looking at (the
  /// focused pane's, else the active tab's), by the same path as the session
  /// header's SFTP button. In a tab with no SSH session it does nothing, as
  /// the tab offers no SFTP.
  void _toggleSftp() {
    final sid = _sshSessionInFront();
    if (sid == null) return;
    _openSftpForSession(sid);
  }

  /// A tmux badge was clicked for [item]: reuse a live session for that
  /// connection, or connect and open tmux once it is up.
  void _openTmuxForConnection(ConnectionWithDetails item) {
    final sessions = ref.read(activeSessionsProvider);
    final live = sessions.entries
        .where((e) =>
            e.value.connectionId == item.connection.id &&
            e.value.status == SessionStatus.connected)
        .map((e) => e.key)
        .firstOrNull;
    if (live != null) {
      _openTmuxForSession(live);
      return;
    }
    ref.read(tmuxPendingConnectionProvider.notifier).state = item.connection.id;
    _connectTo(item);
  }

  /// Bring [sessionId]'s tab to the front and open tmux in it.
  void _openTmuxForSession(String sessionId) {
    ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
    _selectSessionTab(sessionId);
    final host = ref.read(tmuxHostProvider(sessionId));
    if (!host.active) host.begin();
  }

  /// Import from SSH config as a desktop modal (menu, palette, home tab).
  Future<void> _importSshConfig() async {
    final outcome = await showDesktopSshConfigImport(context);
    if (outcome != null && mounted) {
      toastImportOutcome(context,
          added: outcome.imported, failedLimit: outcome.failedLimit);
    }
  }

  /// tmux mode renders inside the selected session's own tab. In a tab with no
  /// SSH session it does nothing, as the tab offers no tmux.
  void _openTmuxForSelectedTab() {
    final sid = _sshSessionInFront();
    if (sid == null) return;
    final host = ref.read(tmuxHostProvider(sid));
    if (!host.active) host.begin();
  }

  // ── Clipboard ──────────────────────────────────────────────────

  /// Copies the selection where the keyboard is: a terminal's (a pane of a
  /// split, a tmux pane, a shared view) or a text field's, as their own Copy
  /// does (this did nothing, so a Mac's Edit > Copy copied nothing).
  void _copySelection() {
    final at = FocusManager.instance.primaryFocus?.context;
    if (at != null) {
      Actions.maybeInvoke<CopySelectionTextIntent>(at, CopySelectionTextIntent.copy);
    }
  }

  /// Pastes where the keyboard is: into the terminal it is in (a pane of a
  /// split, a tmux pane, a shared view), asked about first where the text
  /// looks dangerous, or into a text field (its own paste). Where it is in
  /// neither, into the session in front ([_terminalInFront]), unless the Support
  /// Hub or a dialog lies over it: the clipboard never goes to a live host the
  /// person cannot see, however the page is left.
  void _pasteToTerminal() async {
    final at = FocusManager.instance.primaryFocus?.context;
    final inTerminal = at?.findAncestorWidgetOfExactType<TerminalView>()?.terminal;
    if (inTerminal == null && at != null && Actions.maybeFind<PasteTextIntent>(at) != null) {
      Actions.maybeInvoke<PasteTextIntent>(at, const PasteTextIntent(SelectionChangedCause.keyboard));
      return;
    }
    if (ref.read(supportHubOpenProvider) || !_shellInFront) return;
    final terminal = inTerminal ?? _terminalInFront();
    // The one paste of every terminal: the dangerous-command question where
    // that is on, then xterm's paste() (bracketed where the shell takes it).
    if (terminal != null) await pasteClipboardIntoTerminal(context, ref, terminal);
  }

  /// The terminal of the session in front, where it is connected: in tmux
  /// mode the focused tmux pane, not the hidden main terminal behind the
  /// workspace.
  Terminal? _terminalInFront() {
    final id = ref.read(v3ActiveSessionTabProvider);
    final session = id == null ? null : ref.read(activeSessionsProvider)[id];
    if (session == null || session.status != SessionStatus.connected) return null;
    // A remote screen's (4.0) terminal is none: nothing typed goes anywhere.
    if (ref.read(activeSessionsProvider.notifier).isScreen(id!)) return null;
    final tmuxHost = ref.read(tmuxHostProvider(id));
    final tmuxPane = tmuxHost.live
        ? tmuxHost.controller?.activeWindow?.activeTerminal
        : null;
    return tmuxPane ?? session.session?.terminal;
  }

  // Single zoom implementation - delegate to _adjustFontSize so the
  // macOS menu path shares the keyboard path's clamp and persistence
  // instead of drifting (was clamp 8-32 + a different setter).
  void _zoomFont(int direction) => _adjustFontSize(direction);

  int? _getDigitFromKey(LogicalKeyboardKey key) {
    final digitKeys = {
      LogicalKeyboardKey.digit1: 1,
      LogicalKeyboardKey.digit2: 2,
      LogicalKeyboardKey.digit3: 3,
      LogicalKeyboardKey.digit4: 4,
      LogicalKeyboardKey.digit5: 5,
      LogicalKeyboardKey.digit6: 6,
      LogicalKeyboardKey.digit7: 7,
      LogicalKeyboardKey.digit8: 8,
      LogicalKeyboardKey.digit9: 9,
    };
    return digitKeys[key];
  }

  // ── Help dialogs ──────────────────────────────────────────────

  // ── Help menu, recording mode, window capture (spec 7b, 7c) ──────

  /// The `?` button (help/feedback/support spec, section 2): toggles the
  /// docked Help panel. A [page] opens it straight on that level, for the
  /// palette and the macOS menu. With the Support Hub open, the button goes
  /// back to the sessions.
  void _openHelp([HelpPage page = HelpPage.home]) {
    if (ref.read(supportHubOpenProvider)) {
      _closeSupportHub();
      if (page == HelpPage.home) return;
    }
    final open = ref.read(helpDockProvider) != null;
    ref.read(helpDockProvider.notifier).state =
        page == HelpPage.home && open ? null : page;
  }

  /// F1, the palette and the macOS menu: the Support Hub, or back to the
  /// sessions from it.
  void _toggleSupportHub() {
    // (The hub is the account service's: nothing to open in a build with none.)
    if (!_shellInFront || !zestHasCloud) return;
    if (ref.read(supportHubOpenProvider)) {
      _closeSupportHub();
    } else {
      ref.read(supportHubOpenProvider.notifier).state = true;
    }
  }

  /// Back to the sessions, for what opens over them next: done once the hub has
  /// gone. The keyboard it holds falls somewhere as it goes, and a dialog opened
  /// in that same frame lost it: the palette stood open with the keys going past
  /// it, and Esc did not close it.
  Future<void> _leaveSupportHub() {
    _closeSupportHub();
    return WidgetsBinding.instance.endOfFrame;
  }

  /// Nothing is open over the shell. A dialog keeps its keys: with it open the
  /// hub would come up under it and Esc would close what cannot be seen.
  bool get _shellInFront => ModalRoute.of(context)?.isCurrent ?? true;

  /// Back to the sessions, which went on running: the keyboard goes back to the
  /// terminal in front. What the hub was showing is kept for the next time.
  void _closeSupportHub() {
    if (!ref.read(supportHubOpenProvider)) return;
    ref.read(supportHubOpenProvider.notifier).state = false;
    ref.read(terminalKeyboardAskProvider.notifier).state++;
  }

  /// The hub's report form takes a picture of the app, not of the hub: the hub
  /// steps aside for two frames, keeping everything it holds.
  Future<Uint8List?> _captureBehindHub({required bool redacted}) async {
    setState(() => _hubHiddenForCapture = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return null;
      return await _captureShell(redacted: redacted);
    } finally {
      if (mounted) setState(() => _hubHiddenForCapture = false);
    }
  }

  /// The Help panel as a layout sibling of the content, in every layout, so
  /// the content shrinks instead of being covered. Nothing while closed.
  Widget _helpDockIfOpen() {
    if (ref.watch(helpDockProvider) == null) return const SizedBox.shrink();
    return HelpDock(
      captureScreenshot: _captureShell,
      onCopyRedactedScreenshot: _copyRedactedScreenshot,
      onOpenShortcuts: _openShortcutsSettings,
      onAbout: _showAboutDialog,
    );
  }

  void _toggleRecordingMode() {
    final on = ref.read(recordingModeProvider);
    // ignore: discarded_futures
    ref.read(settingsUpdaterProvider).setRecordingMode(!on);
  }

  void _openReportForm(FeedbackType type) => _openHelp(
      type == FeedbackType.bug ? HelpPage.reportBug : HelpPage.suggest);

  /// "Keyboard shortcuts" lands on the Keyboard section of Settings, where
  /// the bindings live and the fixed keys are documented (spec 7b, 9).
  void _openShortcutsSettings() {
    ref.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.keyboard;
    _openSettingsSection();
  }

  void _openUrl(String url) {
    if (url.isEmpty) return;
    // ignore: discarded_futures
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Render the shell to a PNG. With [redacted], recording-mode masking is
  /// applied for the capture even when the mode is off, without entering
  /// the mode (spec 7c): the flag is raised for two frames and restored.
  Future<Uint8List?> _captureShell({required bool redacted}) async {
    final wasOn = ref.read(recordingModeProvider);
    final forced = redacted && !wasOn;
    if (forced) {
      Redactor.instance.enabled = true;
      ref.read(recordingModeProvider.notifier).state = true;
    }
    try {
      if (forced) {
        await WidgetsBinding.instance.endOfFrame;
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted) return null;
      final boundary = _shellCaptureKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(
          pixelRatio: MediaQuery.devicePixelRatioOf(context));
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } catch (_) {
      return null;
    } finally {
      if (forced) {
        // Restore what the SETTING says now, not what it said before the
        // capture: a toggle during the two awaited frames must win.
        final persisted =
            ref.read(settingsServiceProvider).recordingModeEnabled;
        Redactor.instance.enabled = persisted;
        ref.read(recordingModeProvider.notifier).state = persisted;
      }
    }
  }

  /// Put a redacted PNG of the window on the clipboard without entering
  /// recording mode (spec 7c).
  Future<void> _copyRedactedScreenshot() async {
    final l10n = AppLocalizations.of(context)!;
    // From the Help panel: close it first so the image is the app, not
    // the panel. Two frames for the layout to settle.
    if (ref.read(helpDockProvider) != null) {
      ref.read(helpDockProvider.notifier).state = null;
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final png = await _captureShell(redacted: true);
    if (!mounted) return;
    if (png == null) {
      showTopSnackBar(context, l10n.recModeCopyScreenshotFailed,
          isError: true);
      return;
    }
    // The clipboard plugin has no image path on Linux (a silent no-op), so
    // there the PNG goes straight to a file; a clipboard failure anywhere
    // else falls back to the same file dialog rather than a dead end.
    var copied = false;
    if (!Platform.isLinux) {
      try {
        await Pasteboard.writeImage(png);
        copied = true;
      } catch (_) {
        copied = false;
      }
    }
    if (!mounted) return;
    if (!copied) {
      await _saveScreenshotPng(png);
      return;
    }
    // A clipboard image is invisible until pasted, so the toast says where
    // it went and offers a file for anyone who wants something to point at.
    showTopSnackBar(
      context,
      // Paste is Cmd+V on a Mac (it said Ctrl+V there too).
      defaultTargetPlatform == TargetPlatform.macOS
          ? l10n.docCheckScreenshotCopiedMac
          : l10n.recModeCopyScreenshotDone,
      isSuccess: true,
      duration: const Duration(seconds: 8),
      actionLabel: l10n.recModeSaveScreenshotAction,
      onAction: () => _saveScreenshotPng(png),
    );
  }

  /// Write a captured PNG wherever the user picks; the dialog opens in
  /// Downloads.
  Future<void> _saveScreenshotPng(Uint8List png) async {
    final l10n = AppLocalizations.of(context)!;
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    try {
      String? downloads;
      try {
        downloads = (await getDownloadsDirectory())?.path;
      } catch (_) {
        // No Downloads folder known: the dialog opens where the OS chooses.
      }
      if (!mounted) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: l10n.recModeSaveScreenshotTitle,
        initialDirectory: downloads,
        fileName: 'zestssh-redacted-${stamp.substring(0, 19)}.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (path == null) return; // cancelled
      await File(path).writeAsBytes(png, flush: true);
      if (!mounted) return;
      // The file name only: a full path carries the OS user name, which
      // recording mode does not mask.
      final shown = path.replaceAll('\\', '/').split('/').last;
      showTopSnackBar(context, l10n.recModeScreenshotSaved(shown),
          isSuccess: true);
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context, l10n.recModeScreenshotSaveFailed,
          isError: true, details: '$e');
    }
  }

  void _showAboutDialog() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAboutDialog(
      context: context,
      applicationName: l10n.desktopAboutAppName,
      applicationVersion:
          '${info.version}${info.buildNumber.isNotEmpty ? ' (${info.buildNumber})' : ''}',
      applicationLegalese: l10n.desktopAboutLegalese(DateTime.now().year),
      children: [
        const SizedBox(height: 16),
        Text(l10n.desktopAboutDescription),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Technical Details box - bounded scrollable region used in the
// Connection Failed dialog so a long stack trace doesn't push the
// dialog actions off-screen on a small / minimised window.
// ══════════════════════════════════════════════════════════════════

/// The parts of the content area while the connection editor is open.
enum _EditorPart { page, shadow, editor }

/// Lays out the content area and the connection editor at its right
/// ([connectionEditorFit]): beside the page, or over it with a shadow along its
/// edge where the page would be left too little. The page has the whole area
/// while the editor is not shown.
class _EditorBesidePage extends MultiChildLayoutDelegate {
  _EditorBesidePage({required this.wanted, required this.shown});

  /// The editor's width asked for ([connectionEditorWidthProvider]).
  final double wanted;

  /// Whether the editor is on screen (the Hosts page in front).
  final bool shown;

  /// How wide the shadow along the editor's edge is while it lies over the page.
  static const _shadow = 24.0;

  @override
  void performLayout(Size size) {
    final fit = connectionEditorFit(size.width, wanted);
    final editor = fit.width + kConnectionEditorHandleWidth;
    final docked = shown && fit.docked;
    layoutChild(_EditorPart.page, BoxConstraints.tight(Size(math.max(0, docked ? size.width - editor : size.width), size.height)));
    positionChild(_EditorPart.page, Offset.zero);
    if (hasChild(_EditorPart.editor)) {
      layoutChild(_EditorPart.editor, BoxConstraints.tight(Size(editor, size.height)));
      positionChild(_EditorPart.editor, Offset(size.width - editor, 0));
    }
    if (hasChild(_EditorPart.shadow)) {
      final w = shown && !fit.docked ? _shadow : 0.0;
      layoutChild(_EditorPart.shadow, BoxConstraints.tight(Size(w, size.height)));
      positionChild(_EditorPart.shadow, Offset(size.width - editor - w, 0));
    }
  }

  @override
  bool shouldRelayout(_EditorBesidePage oldDelegate) => oldDelegate.wanted != wanted || oldDelegate.shown != shown;
}
