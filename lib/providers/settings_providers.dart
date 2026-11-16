import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/session_log_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes;
import 'package:zestssh/theme/terminal_fonts.dart';

// ── Terminal theme ───────────────────────────────────────────────

/// Current terminal theme ID (persisted).
final terminalThemeIdProvider = StateProvider<String>((ref) {
  return ref.read(settingsServiceProvider).terminalThemeId;
});

/// The terminal theme shown: the one kept, except that with "Match terminal
/// to app theme" on and a matched pair kept, it is the pair of the app theme
/// in use. So with "Follow system theme" on, Daylight's light terminal comes
/// with Daylight, where the dark one kept from before stayed black.
///
/// It stands in only for a kept terminal theme that is the pair of ANOTHER
/// app theme than the one in use: a terminal theme tied to no app theme
/// (Cyberpunk, a custom one), or tied to the app theme in use (Ember's own
/// "dark"), is shown as it was picked.
final shownTerminalThemeIdProvider = Provider<String>((ref) {
  final id = ref.watch(terminalThemeIdProvider);
  if (!ref.watch(themesSyncedProvider)) return id;
  final pairedApp = kTerminalToAppThemeId[id];
  if (pairedApp == null) return id;
  final appId = ref.watch(appThemeProvider).id;
  final appPair = kAppToTerminalThemeId[appId];
  // Tied to the app theme in use, or already that theme's own pair (two app
  // themes may share one terminal theme): it is what was picked.
  if (pairedApp == appId || appPair == id) return id;
  return appPair ?? id;
});

/// Resolved [TerminalTheme] from the current ID.
///
/// When "themes synced" is on, the user's PRIMARY accent flows into the
/// terminal: the cursor + selection of the BRAND terminal themes (the ones
/// whose cursor is the legacy brand orange - Dark / Light / AMOLED / Citrus)
/// are retinted to the active app primary. Presets with their own designed
/// cursor (Dracula, Nord, Solarized, …) are left untouched so we never clobber
/// a hand-tuned palette. With the default primary (`#E8600A`) the retint is a
/// no-op, so the default terminal is byte-identical. Per-connection theme
/// overrides bypass this (they resolve the raw preset in terminal_screen).
final terminalThemeProvider = Provider<TerminalTheme>((ref) {
  final id = ref.watch(shownTerminalThemeIdProvider);
  final base = app_themes.TerminalThemes.all[id] ??
      app_themes.TerminalThemes.all[app_themes.TerminalThemes.defaultId]!;

  if (!ref.watch(themesSyncedProvider)) return base;

  // Only the brand-accent terminal themes carry a brand cursor: the legacy
  // orange on Dark / Light / AMOLED / Citrus, the current one on Zest Night.
  const brandCursors = {0xFFE8600A, 0xFFFF7A1A};
  if (!brandCursors.contains(base.cursor.toARGB32())) return base;

  // Resolved primary == AppColors.v3AccentPrimary (applyTheme sets it to
  // cs.primary). Read it from the scheme so this provider re-runs on theme
  // change.
  final primary = ref.watch(appThemeProvider).colorScheme.primary;
  if (primary.toARGB32() == base.cursor.toARGB32()) return base; // no-op for default

  // Preserve each field's original alpha so selection stays translucent.
  final selAlpha = ((base.selection.toARGB32() >> 24) & 0xFF) / 255.0;
  return TerminalTheme(
    cursor: primary,
    selection: primary.withValues(alpha: selAlpha),
    foreground: base.foreground,
    background: base.background,
    black: base.black,
    red: base.red,
    green: base.green,
    yellow: base.yellow,
    blue: base.blue,
    magenta: base.magenta,
    cyan: base.cyan,
    white: base.white,
    brightBlack: base.brightBlack,
    brightRed: base.brightRed,
    brightGreen: base.brightGreen,
    brightYellow: base.brightYellow,
    brightBlue: base.brightBlue,
    brightMagenta: base.brightMagenta,
    brightCyan: base.brightCyan,
    brightWhite: base.brightWhite,
    searchHitBackground: base.searchHitBackground,
    searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
    searchHitForeground: base.searchHitForeground,
  );
});

// ── Terminal font ────────────────────────────────────────────────

/// Current terminal font family (persisted).
final terminalFontFamilyProvider = StateProvider<TerminalFontFamily>((ref) {
  return ref.read(settingsServiceProvider).terminalFontFamily;
});

/// The smallest and largest terminal font size every control offers (the
/// settings pages, the Inspector, the status bar, the zoom keys, a pinch).
const double kTerminalFontSizeMin = 8;
const double kTerminalFontSizeMax = 28;

/// [size] held between [kTerminalFontSizeMin] and [kTerminalFontSizeMax], so
/// a size kept by an older version or synced from another device (synced
/// sizes may be 6 to 48) never goes past a slider's ends.
double clampTerminalFontSize(double size) =>
    size.clamp(kTerminalFontSizeMin, kTerminalFontSizeMax).toDouble();

/// Current terminal font size (persisted).
final terminalFontSizeProvider = StateProvider<double>((ref) {
  return clampTerminalFontSize(ref.read(settingsServiceProvider).terminalFontSize);
});

// ── Terminal behaviour ───────────────────────────────────────────

/// Scrollback buffer size.
final scrollbackLinesProvider = StateProvider<int>((ref) {
  return ref.read(settingsServiceProvider).scrollbackLines;
});

/// Whether the terminal bell is enabled.
final bellEnabledProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).bellEnabled;
});

/// Whether programming ligatures are rendered in the terminal.
final terminalLigaturesProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).terminalLigatures;
});

/// Whether Server Monitor alerts (host went Critical / Warning / offline) fire.
final monitorAlertsEnabledProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).monitorAlertsEnabled;
});

/// Whether haptic feedback is enabled.
final hapticFeedbackProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).hapticFeedback;
});

/// Keep screen awake during terminal sessions.
final keepScreenAwakeProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).keepScreenAwake;
});

/// Recording (presenter) mode: when on, the app chrome masks host addresses,
/// usernames and key fingerprints so a screen recording leaks nothing real.
/// Device-local, defaults off. See [Redactor].
final recordingModeProvider = StateProvider<bool>((ref) {
  // The Redactor singleton is what every `Redactable.display` consults, so it
  // must mirror this provider exactly: seeded at startup (the mode persists
  // across restarts, so a crash mid-recording never silently starts leaking)
  // and updated on every toggle.
  final settings = ref.read(settingsServiceProvider);
  final on = settings.recordingModeEnabled;
  Redactor.instance
    ..salt = settings.recordingMaskSalt
    ..enabled = on;
  // Instantiate the fleet registrar here (every recording-mode surface reads
  // this provider at startup), so the collision table is populated before
  // the first masked name renders and stays current for the container's life.
  ref.read(redactionFleetRegistrar);
  return on;
});

/// The recording-mode level (spec section 4): Layout keeps the shape of a
/// name, Strict replaces it with an unrelated word. Persisted and seeded into
/// the Redactor the same way the mode flag is.
final recordingRedactLevelProvider = StateProvider<RedactLevel>((ref) {
  final raw = ref.read(settingsServiceProvider).recordingRedactLevel;
  final level = raw == 'strict' ? RedactLevel.strict : RedactLevel.layout;
  Redactor.instance.level = level;
  return level;
});

// ── Resolved TerminalStyle ───────────────────────────────────────

/// Resolved [TerminalStyle] combining font family and size.
final terminalStyleProvider = Provider<TerminalStyle>((ref) {
  final fontFamily = ref.watch(terminalFontFamilyProvider);
  final fontSize = ref.watch(terminalFontSizeProvider);
  final ligatures = ref.watch(terminalLigaturesProvider);

  return TerminalStyle(
    fontSize: fontSize,
    fontFamily: fontFamily.fontFamily,
    enableLigatures: ligatures,
    // Ends with the bundled Nerd Font symbols (4.0): powerline prompts and
    // file icons draw in every terminal font.
    fontFamilyFallback: kTerminalFontFallback,
  );
});

// ── Cursor settings ──────────────────────────────────────────────

/// Current cursor style (persisted).
final cursorStyleProvider = StateProvider<TerminalCursorShape>((ref) {
  return ref.read(settingsServiceProvider).cursorStyle;
});

/// Whether the cursor blinks (persisted).
final cursorBlinkProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).cursorBlink;
});

/// When the terminal draws its cursor (persisted, 4.0).
final cursorVisibilityProvider = StateProvider<TerminalCursorVisibility>((ref) {
  return ref.read(settingsServiceProvider).cursorVisibility;
});

// ── Snippet execution ──────────────────────────────────────────

/// Whether snippets auto-execute (send Enter) when tapped in terminal.
/// Default: false (paste only - user presses Enter manually).
final autoExecuteSnippetsProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).autoExecuteSnippets;
});

// ── Volume key mapping ──────────────────────────────────────────

/// Whether volume keys act as Page Up / Page Down in terminal.
final volumeKeysEnabledProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).volumeKeysEnabled;
});

// ── Security ────────────────────────────────────────────────────

/// Whether the app lock is enabled (reactive, survives PIN setup navigation).
final securityLockEnabledProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).securityLockEnabled;
});

/// "Show open sessions on the lock screen" (4.0): a count of the sessions still
/// connected under the lock screen's title, never their names. Off by default.
final lockShowSessionsProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).lockShowSessions;
});

// ── Auto Backup ─────────────────────────────────────────────────

/// Current auto-backup interval ('off', 'daily', 'weekly').
final autoBackupIntervalProvider = StateProvider<String>((ref) {
  return ref.read(settingsServiceProvider).autoBackupInterval;
});

// ── Cloud Sync Mode ─────────────────────────────────────────────

/// Current sync mode ('auto', 'manual', 'off').
final syncModeProvider = StateProvider<String>((ref) {
  return ref.read(settingsServiceProvider).syncMode;
});

/// Sync interval in minutes (used when sync mode is 'auto').
final syncIntervalProvider = StateProvider<int>((ref) {
  return ref.read(settingsServiceProvider).syncIntervalMinutes;
});

// ── Connection defaults ─────────────────────────────────────────

/// Default SSH port for new connections.
final defaultPortProvider = StateProvider<int>((ref) {
  return ref.read(settingsServiceProvider).defaultPort;
});

/// Default username for new connections.
final defaultUsernameProvider = StateProvider<String>((ref) {
  return ref.read(settingsServiceProvider).defaultUsername;
});

/// Connection timeout in seconds.
final connectionTimeoutProvider = StateProvider<int>((ref) {
  return ref.read(settingsServiceProvider).connectionTimeout;
});

// ── Terminal margin ──────────────────────────────────────────────

/// Terminal margin/padding in pixels around the terminal content.
final terminalMarginProvider = StateProvider<double>((ref) {
  return ref.read(settingsServiceProvider).terminalMargin;
});

// ── Extra keyboard position ──────────────────────────────────────

/// Position of the extra keyboard row: 'aboveKeyboard', 'aboveTerminal',
/// or 'disabled'.
final extraKeyboardPositionProvider = StateProvider<String>((ref) {
  return ref.read(settingsServiceProvider).extraKeyboardPosition;
});

// ── Terminal behaviour (extended) ───────────────────────────────

/// Automatically copy text when selected.
final copyOnSelectProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).copyOnSelect;
});

/// Detect `tmux -CC` started inside a terminal and switch that tab to the
/// native tmux workspace.
final tmuxAutoDetectProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).tmuxAutoDetect;
});

/// Mosh hosts open with the mosh program installed on this computer instead
/// of the built-in client (4.0; offered on a Mac and Linux only).
final moshSystemClientProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).moshSystemClient;
});

/// Let remote programs copy to the local clipboard (OSC 52). Off by default;
/// the read-back form is refused even when this is on.
final osc52ClipboardProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).osc52Clipboard;
});

// ── Session log (device-local) ──────────────────────────────────

/// Log every session's output to a plain-text file as it happens.
final sessionLogEnabledProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).sessionLogEnabled;
});

/// Folder for session logs; empty means the app's default folder.
final sessionLogDirectoryProvider = StateProvider<String>((ref) {
  return ref.read(settingsServiceProvider).sessionLogDirectory;
});

/// Prefix each logged line with the time it arrived.
final sessionLogTimestampsProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).sessionLogTimestamps;
});

/// The folder session logs actually land in: the configured one when it is
/// usable, else the app default. For display in Settings.
final sessionLogEffectiveDirProvider = FutureProvider<String>((ref) async {
  final configured = ref.watch(sessionLogDirectoryProvider);
  return (await SessionLogService.resolveDirectory(configured)).path;
});

/// Whether the terminal asks the on-screen keyboard not to learn from what
/// is typed there (Android): on until its person turns it off.
final keyboardIncognitoProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).keyboardIncognito;
});

/// Whether the terminal asks the on-screen keyboard for its layout without
/// suggestions, as for a password typed in the open (Android): off until its
/// person turns it on.
final compactKeyboardProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).compactKeyboard;
});

/// Whether a terminal's new lines are read out while a screen reader is on
/// (TerminalReadAloud): on until its person turns it off.
final terminalReadAloudProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).terminalReadAloud;
});

/// Whether Option (Alt) is Meta in the terminal: ESC and the key's character
/// (on an iPad and an iPhone until changed; off on a Mac).
final optionAsMetaProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).optionAsMeta;
});

/// What the row of keys does while a hardware keyboard is typed on; null
/// until chosen, which is the device's default (HardwareKeysRow.defaultFor).
final keysRowHardwareProvider = StateProvider<HardwareKeysRow?>((ref) {
  return HardwareKeysRow.fromId(ref.read(settingsServiceProvider).keysRowHardware);
});

/// Show the extra keyboard row above the terminal.
final showExtraKeyboardRowProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).showExtraKeyboardRow;
});

/// When true the extra keyboard row is a single horizontally-scrollable
/// strip with every key directly tappable. When false the legacy
/// two-row + FN-toggle layout is used.
final softKeyboardScrollableModeProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).softKeyboardScrollableMode;
});

/// How the key row looks: Grouped or Flat (3.1's Compact reads as Grouped).
final softKeyboardStyleProvider = StateProvider<SoftKeyRowStyle>((ref) {
  return SoftKeyRowStyle.fromId(ref.read(settingsServiceProvider).softKeyboardStyle);
});

/// How big the key row's keys are, in either layout (3.2.1).
final softKeyboardKeySizeProvider = StateProvider<SoftKeySize>((ref) {
  return SoftKeySize.fromId(ref.read(settingsServiceProvider).softKeyboardKeySize);
});

/// Stable ids of soft-keyboard keys the user has disabled.
final softKeyboardDisabledKeysProvider = StateProvider<Set<String>>((ref) {
  return ref.read(settingsServiceProvider).softKeyboardDisabledKeys;
});

/// User-defined key order for the scrollable soft-keyboard's rows. Seeded
/// from prefs (or the catalog default when unset), then reconciled against
/// the current catalog so the two rows never drop or duplicate a key.
final softKeyboardRow1OrderProvider = StateProvider<List<String>>((ref) {
  final s = ref.read(settingsServiceProvider);
  final saved1 =
      s.softKeyboardRow1Order.isEmpty ? defaultSoftRow1 : s.softKeyboardRow1Order;
  final saved2 =
      s.softKeyboardRow2Order.isEmpty ? defaultSoftRow2 : s.softKeyboardRow2Order;
  return reconcileSoftRows(saved1, saved2).row1;
});

final softKeyboardRow2OrderProvider = StateProvider<List<String>>((ref) {
  final s = ref.read(settingsServiceProvider);
  final saved1 =
      s.softKeyboardRow1Order.isEmpty ? defaultSoftRow1 : s.softKeyboardRow1Order;
  final saved2 =
      s.softKeyboardRow2Order.isEmpty ? defaultSoftRow2 : s.softKeyboardRow2Order;
  return reconcileSoftRows(saved1, saved2).row2;
});

/// Show confirmation when closing an active session.
final closeConfirmationProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).closeConfirmation;
});

/// SSH keepalive interval in seconds (0 = disabled).
final keepaliveIntervalProvider = StateProvider<int>((ref) {
  return ref.read(settingsServiceProvider).keepaliveIntervalSeconds;
});

// ── Connection defaults (extended) ────────────────────────────

/// Default auth method ('password', 'publicKey', 'ask').
final defaultAuthMethodProvider = StateProvider<String>((ref) {
  return ref.read(settingsServiceProvider).defaultAuthMethod;
});

/// Default identity ID for new connections (nullable).
final defaultIdentityIdProvider = StateProvider<String?>((ref) {
  return ref.read(settingsServiceProvider).defaultIdentityId;
});

// ── Snippet settings ──────────────────────────────────────────

/// Require confirmation before running destructive commands.
final snippetDestructiveConfirmProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).snippetDestructiveConfirmation;
});

/// Default category for newly created snippets.
final defaultSnippetCategoryProvider = StateProvider<String?>((ref) {
  return ref.read(settingsServiceProvider).defaultSnippetCategory;
});

// ── Notifications ──────────────────────────────────────────────

/// Notify when a connection is lost.
final notifyConnectionLostProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).notifyConnectionLost;
});

/// Notify when a file transfer completes.
final notifyTransferCompleteProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).notifyTransferComplete;
});

/// Notify when a file transfer fails.
final notifyTransferFailedProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).notifyTransferFailed;
});

/// Notify on security-relevant events (a server's host key changed).
final notifySecurityAlertsProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).notifySecurityAlerts;
});

/// Notify when a newer ZestSSH version is available (desktop update check).
final notifyUpdateAvailableProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).notifyUpdateAvailable;
});

/// A computer's "Also show as system notifications" (4.0, off at first):
/// the app's notices go to the system's notifications as well while the
/// window is not in front (NotificationService.onComputer).
final desktopSystemNotificationsProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).desktopSystemNotifications;
});

// ── Server health checks ──────────────────────────────────────

/// Whether server health check pings are enabled.
final healthChecksEnabledProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).serverHealthChecksEnabled;
});

/// Health check ping interval in seconds.
final healthCheckIntervalProvider = StateProvider<int>((ref) {
  return ref.read(settingsServiceProvider).healthCheckIntervalSeconds;
});

// ── Auto Reconnect ──────────────────────────────────────────

/// Whether sessions automatically reconnect after unexpected disconnect.
final autoReconnectEnabledProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).autoReconnectEnabled;
});

// ── Dangerous Command Protection ─────────────────────────────

/// Whether to warn before executing or pasting dangerous commands.
final dangerousCommandProtectionProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).dangerousCommandProtection;
});

// ── Host key settings ─────────────────────────────────────────

/// Whether to prompt before trusting new (unknown) host keys.
final askBeforeTrustingKeysProvider = StateProvider<bool>((ref) {
  return ref.read(settingsServiceProvider).askBeforeTrustingNewKeys;
});

// ── Setting persistence helpers ──────────────────────────────────

/// Helper that persists a settings change and updates the provider.
class SettingsUpdater {
  final Ref _ref;

  SettingsUpdater(this._ref);

  /// Nudge the sync engine after an allowlisted setting changes so it pushes
  /// to the user's other devices (debounced; a no-op when [key] isn't synced
  /// or Cloud Sync isn't configured). Device-local toggles skip this and never
  /// trigger a cycle.
  void _nudgeSync(String key) {
    if (!SettingsService.isSyncedSettingKey(key)) return;
    // Best-effort: the setting is already persisted by the caller. The sync
    // engine reaches the encrypted DB, which may be closed (app locked / vault
    // engaged) - a closed DB must never fail a settings write, so swallow it.
    try {
      _ref.read(autoSyncServiceProvider).notifyLocalChange();
    } catch (_) {
      // Sync unavailable (e.g. DB closed behind the vault lock) - ignore.
    }
  }

  Future<void> setTerminalTheme(String id) async {
    await _ref.read(settingsServiceProvider).setTerminalThemeId(id);
    _ref.read(terminalThemeIdProvider.notifier).state = id;
    _nudgeSync('terminal_theme');
  }

  Future<void> setTerminalFontFamily(TerminalFontFamily family) async {
    await _ref.read(settingsServiceProvider).setTerminalFontFamily(family);
    _ref.read(terminalFontFamilyProvider.notifier).state = family;
    _nudgeSync('terminal_font');
  }

  Future<void> setTerminalFontSize(double requested) async {
    final size = clampTerminalFontSize(requested);
    await _ref.read(settingsServiceProvider).setTerminalFontSize(size);
    _ref.read(terminalFontSizeProvider.notifier).state = size;
    _nudgeSync('terminal_font_size');
  }

  Future<void> setScrollbackLines(int lines) async {
    await _ref.read(settingsServiceProvider).setScrollbackLines(lines);
    _ref.read(scrollbackLinesProvider.notifier).state = lines;
    _nudgeSync('scrollback_lines');
  }

  Future<void> setBellEnabled(bool enabled) async {
    await _ref.read(settingsServiceProvider).setBellEnabled(enabled);
    _ref.read(bellEnabledProvider.notifier).state = enabled;
    _nudgeSync('bell_enabled');
  }

  /// Recording (presenter) mode. Device-local, so no sync nudge, you don't want
  /// it turning on across all your devices.
  Future<void> setRecordingMode(bool enabled) async {
    await _ref.read(settingsServiceProvider).setRecordingModeEnabled(enabled);
    // Every Redactable.display consults the singleton, so it changes in the
    // same tick as the provider (see recordingModeProvider for the seed).
    Redactor.instance.enabled = enabled;
    _ref.read(recordingModeProvider.notifier).state = enabled;
  }

  /// Recording-mode level. Device-local like the mode itself.
  Future<void> setRecordingRedactLevel(RedactLevel level) async {
    await _ref.read(settingsServiceProvider).setRecordingRedactLevel(
        level == RedactLevel.strict ? 'strict' : 'layout');
    Redactor.instance.level = level;
    _ref.read(recordingRedactLevelProvider.notifier).state = level;
  }

  Future<void> setTerminalLigatures(bool enabled) async {
    await _ref.read(settingsServiceProvider).setTerminalLigatures(enabled);
    _ref.read(terminalLigaturesProvider.notifier).state = enabled;
    _nudgeSync('terminal_ligatures');
  }

  Future<void> setMonitorAlertsEnabled(bool enabled) async {
    await _ref.read(settingsServiceProvider).setMonitorAlertsEnabled(enabled);
    _ref.read(monitorAlertsEnabledProvider.notifier).state = enabled;
    _nudgeSync('monitor_alerts_enabled');
  }

  Future<void> setHapticFeedback(bool enabled) async {
    await _ref.read(settingsServiceProvider).setHapticFeedback(enabled);
    _ref.read(hapticFeedbackProvider.notifier).state = enabled;
    _nudgeSync('haptic_feedback');
  }

  Future<void> setKeepScreenAwake(bool enabled) async {
    await _ref.read(settingsServiceProvider).setKeepScreenAwake(enabled);
    _ref.read(keepScreenAwakeProvider.notifier).state = enabled;
    _nudgeSync('keep_screen_awake');
  }

  Future<void> setTerminalCursorShape(TerminalCursorShape style) async {
    await _ref.read(settingsServiceProvider).setTerminalCursorShape(style);
    _ref.read(cursorStyleProvider.notifier).state = style;
    _nudgeSync('cursor_style');
  }

  Future<void> setCursorBlink(bool blink) async {
    await _ref.read(settingsServiceProvider).setCursorBlink(blink);
    _ref.read(cursorBlinkProvider.notifier).state = blink;
    _nudgeSync('cursor_blink');
  }

  Future<void> setCursorVisibility(TerminalCursorVisibility visibility) async {
    await _ref.read(settingsServiceProvider).setCursorVisibility(visibility);
    _ref.read(cursorVisibilityProvider.notifier).state = visibility;
  }

  Future<void> setAutoExecuteSnippets(bool enabled) async {
    await _ref.read(settingsServiceProvider).setAutoExecuteSnippets(enabled);
    _ref.read(autoExecuteSnippetsProvider.notifier).state = enabled;
  }

  Future<void> setVolumeKeysEnabled(bool enabled) async {
    await _ref.read(settingsServiceProvider).setVolumeKeysEnabled(enabled);
    _ref.read(volumeKeysEnabledProvider.notifier).state = enabled;
  }

  Future<void> setSecurityLockEnabled(bool enabled) async {
    await _ref.read(settingsServiceProvider).setSecurityLockEnabled(enabled);
    _ref.read(securityLockEnabledProvider.notifier).state = enabled;
  }

  /// The lock screen's count of open sessions. The computer's own: never synced.
  Future<void> setLockShowSessions(bool show) async {
    await _ref.read(settingsServiceProvider).setLockShowSessions(show);
    _ref.read(lockShowSessionsProvider.notifier).state = show;
  }

  Future<void> setAutoBackupInterval(String interval) async {
    await _ref.read(settingsServiceProvider).setAutoBackupInterval(interval);
    _ref.read(autoBackupIntervalProvider.notifier).state = interval;
  }

  Future<void> setSyncMode(String mode) async {
    await _ref.read(settingsServiceProvider).setSyncMode(mode);
    _ref.read(syncModeProvider.notifier).state = mode;
  }

  Future<void> setSyncInterval(int minutes) async {
    await _ref.read(settingsServiceProvider).setSyncIntervalMinutes(minutes);
    _ref.read(syncIntervalProvider.notifier).state = minutes;
  }

  Future<void> setDefaultPort(int port) async {
    await _ref.read(settingsServiceProvider).setDefaultPort(port);
    _ref.read(defaultPortProvider.notifier).state = port;
    _nudgeSync('default_port');
  }

  Future<void> setDefaultUsername(String username) async {
    await _ref.read(settingsServiceProvider).setDefaultUsername(username);
    _ref.read(defaultUsernameProvider.notifier).state = username;
    _nudgeSync('default_username');
  }

  Future<void> setConnectionTimeout(int seconds) async {
    await _ref.read(settingsServiceProvider).setConnectionTimeout(seconds);
    _ref.read(connectionTimeoutProvider.notifier).state = seconds;
    _nudgeSync('connection_timeout');
  }

  Future<void> setCopyOnSelect(bool enabled) async {
    await _ref.read(settingsServiceProvider).setCopyOnSelect(enabled);
    _ref.read(copyOnSelectProvider.notifier).state = enabled;
    _nudgeSync('copy_on_select');
  }

  Future<void> setTmuxAutoDetect(bool enabled) async {
    await _ref.read(settingsServiceProvider).setTmuxAutoDetect(enabled);
    _ref.read(tmuxAutoDetectProvider.notifier).state = enabled;
    _nudgeSync('tmux_auto_detect');
  }

  /// This computer's own choice (not synced: whether the mosh program is
  /// installed is this computer's).
  Future<void> setMoshSystemClient(bool on) async {
    await _ref.read(settingsServiceProvider).setMoshSystemClient(on);
    _ref.read(moshSystemClientProvider.notifier).state = on;
  }

  Future<void> setOsc52Clipboard(bool enabled) async {
    await _ref.read(settingsServiceProvider).setOsc52Clipboard(enabled);
    _ref.read(osc52ClipboardProvider.notifier).state = enabled;
    _nudgeSync('osc52_clipboard');
  }

  // Session log settings are device-local (they name a folder here), so
  // none of them nudges sync.
  Future<void> setSessionLogEnabled(bool enabled) async {
    await _ref.read(settingsServiceProvider).setSessionLogEnabled(enabled);
    _ref.read(sessionLogEnabledProvider.notifier).state = enabled;
  }

  Future<void> setSessionLogDirectory(String path) async {
    await _ref.read(settingsServiceProvider).setSessionLogDirectory(path);
    _ref.read(sessionLogDirectoryProvider.notifier).state = path;
  }

  Future<void> setSessionLogTimestamps(bool enabled) async {
    await _ref.read(settingsServiceProvider).setSessionLogTimestamps(enabled);
    _ref.read(sessionLogTimestampsProvider.notifier).state = enabled;
  }

  /// (This device's own: not sent to the person's other devices.)
  Future<void> setKeyboardIncognito(bool enabled) async {
    await _ref.read(settingsServiceProvider).setKeyboardIncognito(enabled);
    _ref.read(keyboardIncognitoProvider.notifier).state = enabled;
  }

  /// (This device's own: not sent to the person's other devices.)
  Future<void> setCompactKeyboard(bool enabled) async {
    await _ref.read(settingsServiceProvider).setCompactKeyboard(enabled);
    _ref.read(compactKeyboardProvider.notifier).state = enabled;
  }

  /// (This device's own: not sent to the person's other devices.)
  Future<void> setTerminalReadAloud(bool enabled) async {
    await _ref.read(settingsServiceProvider).setTerminalReadAloud(enabled);
    _ref.read(terminalReadAloudProvider.notifier).state = enabled;
  }

  /// (This device's own: not sent to the person's other devices.)
  Future<void> setOptionAsMeta(bool enabled) async {
    await _ref.read(settingsServiceProvider).setOptionAsMeta(enabled);
    _ref.read(optionAsMetaProvider.notifier).state = enabled;
  }

  /// (This device's own: not sent to the person's other devices.)
  Future<void> setKeysRowHardware(HardwareKeysRow mode) async {
    await _ref.read(settingsServiceProvider).setKeysRowHardware(mode.name);
    _ref.read(keysRowHardwareProvider.notifier).state = mode;
  }

  Future<void> setShowExtraKeyboardRow(bool enabled) async {
    await _ref.read(settingsServiceProvider).setShowExtraKeyboardRow(enabled);
    _ref.read(showExtraKeyboardRowProvider.notifier).state = enabled;
    _nudgeSync('show_extra_keyboard');
  }

  Future<void> setSoftKeyboardScrollableMode(bool enabled) async {
    await _ref
        .read(settingsServiceProvider)
        .setSoftKeyboardScrollableMode(enabled);
    _ref.read(softKeyboardScrollableModeProvider.notifier).state = enabled;
    _nudgeSync('soft_keyboard_scrollable_mode');
  }

  Future<void> setSoftKeyboardStyle(SoftKeyRowStyle style) async {
    await _ref.read(settingsServiceProvider).setSoftKeyboardStyle(style.name);
    _ref.read(softKeyboardStyleProvider.notifier).state = style;
    _nudgeSync('soft_keyboard_style');
  }

  /// (This device's own: not sent to the person's other devices.)
  Future<void> setSoftKeyboardKeySize(SoftKeySize size) async {
    await _ref.read(settingsServiceProvider).setSoftKeyboardKeySize(size.name);
    _ref.read(softKeyboardKeySizeProvider.notifier).state = size;
  }

  Future<void> setSoftKeyboardDisabledKeys(Set<String> ids) async {
    await _ref.read(settingsServiceProvider).setSoftKeyboardDisabledKeys(ids);
    _ref.read(softKeyboardDisabledKeysProvider.notifier).state = ids;
    _nudgeSync('soft_keyboard_disabled_keys');
  }

  Future<void> setSoftKeyboardRowOrders(
    List<String> row1,
    List<String> row2,
  ) async {
    final s = _ref.read(settingsServiceProvider);
    await s.setSoftKeyboardRow1Order(row1);
    await s.setSoftKeyboardRow2Order(row2);
    _ref.read(softKeyboardRow1OrderProvider.notifier).state = row1;
    _ref.read(softKeyboardRow2OrderProvider.notifier).state = row2;
    _nudgeSync('soft_keyboard_row1_order');
  }

  /// Reset key order (both rows) back to the catalog defaults.
  Future<void> resetSoftKeyboardRowOrders() async {
    final s = _ref.read(settingsServiceProvider);
    await s.setSoftKeyboardRow1Order(const <String>[]);
    await s.setSoftKeyboardRow2Order(const <String>[]);
    _ref.read(softKeyboardRow1OrderProvider.notifier).state =
        List<String>.from(defaultSoftRow1);
    _ref.read(softKeyboardRow2OrderProvider.notifier).state =
        List<String>.from(defaultSoftRow2);
    _nudgeSync('soft_keyboard_row1_order');
  }

  Future<void> setCloseConfirmation(bool enabled) async {
    await _ref.read(settingsServiceProvider).setCloseConfirmation(enabled);
    _ref.read(closeConfirmationProvider.notifier).state = enabled;
    _nudgeSync('close_confirmation');
  }

  Future<void> setKeepaliveInterval(int seconds) async {
    await _ref.read(settingsServiceProvider).setKeepaliveIntervalSeconds(seconds);
    _ref.read(keepaliveIntervalProvider.notifier).state = seconds;
    _nudgeSync('keepalive_interval');
  }

  Future<void> setNotifyConnectionLost(bool enabled) async {
    await _ref.read(settingsServiceProvider).setNotifyConnectionLost(enabled);
    _ref.read(notifyConnectionLostProvider.notifier).state = enabled;
    _nudgeSync('notify_connection_lost');
  }

  Future<void> setNotifyTransferComplete(bool enabled) async {
    await _ref.read(settingsServiceProvider).setNotifyTransferComplete(enabled);
    _ref.read(notifyTransferCompleteProvider.notifier).state = enabled;
    _nudgeSync('notify_transfer_complete');
  }

  Future<void> setNotifyTransferFailed(bool enabled) async {
    await _ref.read(settingsServiceProvider).setNotifyTransferFailed(enabled);
    _ref.read(notifyTransferFailedProvider.notifier).state = enabled;
    _nudgeSync('notify_transfer_failed');
  }

  Future<void> setNotifySecurityAlerts(bool enabled) async {
    await _ref.read(settingsServiceProvider).setNotifySecurityAlerts(enabled);
    _ref.read(notifySecurityAlertsProvider.notifier).state = enabled;
    _nudgeSync('notify_security_alerts');
  }

  Future<void> setNotifyUpdateAvailable(bool enabled) async {
    await _ref.read(settingsServiceProvider).setNotifyUpdateAvailable(enabled);
    _ref.read(notifyUpdateAvailableProvider.notifier).state = enabled;
    _nudgeSync('notify_update_available');
  }

  /// A computer's "Also show as system notifications". Turned on, macOS asks
  /// its person first; where they say no it stays off, and false is
  /// answered (the switch says why). True where the setting is now [enabled].
  Future<bool> setDesktopSystemNotifications(bool enabled) async {
    if (enabled && !await NotificationService.requestComputerPermission()) return false;
    await _ref.read(settingsServiceProvider).setDesktopSystemNotifications(enabled);
    _ref.read(desktopSystemNotificationsProvider.notifier).state = enabled;
    await NotificationService.setComputerSystemNotices(enabled);
    return true;
  }

  Future<void> setDefaultAuthMethod(String method) async {
    await _ref.read(settingsServiceProvider).setDefaultAuthMethod(method);
    _ref.read(defaultAuthMethodProvider.notifier).state = method;
    _nudgeSync('default_auth_method');
  }

  Future<void> setDefaultIdentityId(String? id) async {
    await _ref.read(settingsServiceProvider).setDefaultIdentityId(id);
    _ref.read(defaultIdentityIdProvider.notifier).state = id;
  }

  Future<void> setSnippetDestructiveConfirmation(bool enabled) async {
    await _ref.read(settingsServiceProvider).setSnippetDestructiveConfirmation(enabled);
    _ref.read(snippetDestructiveConfirmProvider.notifier).state = enabled;
    _nudgeSync('snippet_destructive_confirm');
  }

  Future<void> setDefaultSnippetCategory(String? category) async {
    await _ref.read(settingsServiceProvider).setDefaultSnippetCategory(category);
    _ref.read(defaultSnippetCategoryProvider.notifier).state = category;
  }

  Future<void> setHealthChecksEnabled(bool enabled) async {
    await _ref.read(settingsServiceProvider).setServerHealthChecksEnabled(enabled);
    _ref.read(healthChecksEnabledProvider.notifier).state = enabled;
  }

  Future<void> setHealthCheckInterval(int seconds) async {
    await _ref.read(settingsServiceProvider).setHealthCheckIntervalSeconds(seconds);
    _ref.read(healthCheckIntervalProvider.notifier).state = seconds;
  }

  Future<void> setAutoReconnectEnabled(bool enabled) async {
    await _ref.read(settingsServiceProvider).setAutoReconnectEnabled(enabled);
    _ref.read(autoReconnectEnabledProvider.notifier).state = enabled;
    _nudgeSync('auto_reconnect');
  }

  Future<void> setDangerousCommandProtection(bool enabled) async {
    await _ref.read(settingsServiceProvider).setDangerousCommandProtection(enabled);
    _ref.read(dangerousCommandProtectionProvider.notifier).state = enabled;
    _nudgeSync('dangerous_command_protection');
  }

  Future<void> setAskBeforeTrustingNewKeys(bool enabled) async {
    await _ref.read(settingsServiceProvider).setAskBeforeTrustingNewKeys(enabled);
    _ref.read(askBeforeTrustingKeysProvider.notifier).state = enabled;
    _nudgeSync('ask_before_trusting_keys');
  }

  Future<void> setTerminalMargin(double margin) async {
    await _ref.read(settingsServiceProvider).setTerminalMargin(margin);
    _ref.read(terminalMarginProvider.notifier).state = margin;
    _nudgeSync('terminal_margin');
  }

  Future<void> setExtraKeyboardPosition(String position) async {
    await _ref.read(settingsServiceProvider).setExtraKeyboardPosition(position);
    _ref.read(extraKeyboardPositionProvider.notifier).state = position;
    _nudgeSync('extra_keyboard_position');
  }
}

final settingsUpdaterProvider = Provider<SettingsUpdater>((ref) {
  return SettingsUpdater(ref);
});

// ── Automation ──────────────────────────────────────────────────

/// Whether external automation (Tasker, Shortcuts, intents) is enabled.
///
/// Wraps a Notifier instead of a plain StateProvider so writes
/// flush through the SettingsService → SharedPreferences. Without
/// this, the engine toggle visually flipped but didn't survive a
/// restart, and the AutomationManager looked at the persisted value
/// (always default-false) when starting up.
final automationEnabledProvider =
    NotifierProvider<AutomationEnabledNotifier, bool>(
  AutomationEnabledNotifier.new,
);

class AutomationEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    return ref.read(settingsServiceProvider).automationEnabled;
  }

  /// Persist + update in one call. The state setter alone wouldn't
  /// flush to disk.
  Future<void> set(bool value) async {
    state = value;
    await ref.read(settingsServiceProvider).setAutomationEnabled(value);
  }

  Future<void> toggle() => set(!state);
}

// ── Per-connection terminal theme override ─────────────────────

/// Optional per-connection terminal theme override.
///
/// Returns the theme ID stored in SharedPreferences for [connectionId],
/// or `null` if the connection uses the global default.
/// Key format: `terminal_theme_<connectionId>`.
final connectionTerminalThemeProvider =
    Provider.family<String?, String>((ref, connectionId) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getString('terminal_theme_$connectionId');
});

/// The terminal theme a host's sessions show: its own where its form gives
/// it one, else the app's. Every terminal of a session reads it: a phone's,
/// a computer's pane, tmux's panes. (A phone's alone did; a computer's pane
/// and tmux's showed the app's.)
final hostTerminalThemeProvider = Provider.family<TerminalTheme, String?>((ref, connectionId) {
  final app = ref.watch(terminalThemeProvider);
  if (connectionId == null) return app;
  final own = ref.watch(connectionTerminalThemeProvider(connectionId));
  return own == null ? app : (app_themes.TerminalThemes.all[own] ?? app);
});

// ── Backup dirty flag ──────────────────────────────────────────

/// Set to true when data changes (connection/identity/snippet CRUD).
/// Cleared after a backup runs. Used to trigger backup-on-close.
final backupDirtyProvider = StateProvider<bool>((ref) => false);
