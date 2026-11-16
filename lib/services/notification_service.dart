import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/features/orchards/sessionlogs/session_log_redactor.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/features/onboarding/data/display_text_sanitizer.dart';

/// The system's notifications of the app's notices: a session that ended by
/// itself, what a workflow has to say, a terminal alert that plays a sound,
/// and an answer from support.
///
/// A phone or a tablet shows them always (each where its own switch says).
/// A computer shows them only where its person turned on Settings >
/// Notifications > "Also show as system notifications" (4.0; off at first),
/// and then only while ZestSSH's window is not the one in front: in the
/// tray, minimised or behind another window ([onComputer]). Before 4.0 a
/// computer showed none, so with "Close to tray" on nothing was heard until
/// the window was opened again. On a computer they are Windows' toasts,
/// macOS's Notification Center (asked for the first time the switch is
/// turned on) and a Linux desktop's freedesktop notifications, at the
/// system's normal level, so the system's Do not disturb holds them back.
class NotificationService {
  static FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// A test's stand-in for the plugin (null puts the app's back), started
  /// afresh.
  @visibleForTesting
  static set debugPlugin(FlutterLocalNotificationsPlugin? plugin) {
    _plugin = plugin ?? FlutterLocalNotificationsPlugin();
    _initialized = false;
    _computerReady = false;
  }

  /// Puts everything a test may have changed back as the app starts.
  @visibleForTesting
  static void debugReset() {
    debugPlugin = null;
    _computerOn = false;
    debugOs = null;
    debugWindowInFront = null;
    debugShown = null;
    debugShownChannel = null;
    onComputerTap = null;
  }

  static bool _initialized = false;

  /// GoRouter instance for deep-link navigation on notification tap.
  static GoRouter? _router;

  /// The system the app runs on, as [Platform.operatingSystem] names it; a
  /// test's say where it is not null.
  @visibleForTesting
  static String? debugOs;

  static String get _os => debugOs ?? Platform.operatingSystem;
  static bool get _phone => _os == 'android' || _os == 'ios';
  static bool get _computer => _os == 'windows' || _os == 'macos' || _os == 'linux';

  /// FNV-1a hash for stable notification IDs across platforms.
  static int _notificationId(String label, [int offset = 0]) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < label.length; i++) {
      hash ^= label.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return hash + offset;
  }

  /// Channel IDs for notification grouping. Android shows each channel's
  /// name and description in its settings of the app's notifications: they
  /// are the app's, in the person's language (they were English in every
  /// language).
  ///
  /// A session that ended by itself, and what a workflow has to say.
  static const _connectionChannelId = 'zestssh_connections';

  /// Answers from support on a ticket sent from the app.
  static const _supportChannelId = 'zestssh_support';

  /// A terminal trigger that plays a sound, on a phone or a tablet.
  static const _triggerChannelId = 'zestssh_triggers';

  /// The channel [id], named in the language of the app.
  @visibleForTesting
  static AndroidNotificationChannel channelOf(String id) => switch (id) {
        _supportChannelId => AndroidNotificationChannel(id, gl10n.notifyChannelSupport,
            description: gl10n.notifyChannelSupportDesc, importance: Importance.defaultImportance),
        _triggerChannelId => AndroidNotificationChannel(id, gl10n.notifyChannelTriggers,
            description: gl10n.notifyChannelTriggersDesc, importance: Importance.high),
        _ => AndroidNotificationChannel(_connectionChannelId, gl10n.notifyChannelConnections,
            description: gl10n.notifyChannelConnectionsDesc, importance: Importance.high),
      };

  /// The ids of every channel of the app.
  @visibleForTesting
  static const channelIds = [_connectionChannelId, _supportChannelId, _triggerChannelId];

  /// The language the channels were last named in.
  static String? _channelsNamedIn;

  /// Names the channels in the app's language, where it is not the one
  /// they were last named in: at the start, before the first frame (when
  /// the app speaks English), and before a notification is shown, by then
  /// in the person's language. Android takes a channel's new name and
  /// description, and keeps its importance as it was made.
  static Future<void> _nameChannels() async {
    if (!Platform.isAndroid || _channelsNamedIn == gl10n.localeName) return;
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final id in channelIds) {
      await androidPlugin?.createNotificationChannel(channelOf(id));
    }
    _channelsNamedIn = gl10n.localeName;
  }

  /// Initialise the notification plugin (phones and tablets; a computer's
  /// is started by [setComputerSystemNotices], when its person wants them).
  static Future<void> init() async {
    if (_initialized) return;

    // A computer's wait for its person's switch.
    if (!_phone) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // The notification channels on Android, named in the app's language.
    await _nameChannels();

    _initialized = true;
    AppLogger.info('NotificationService initialized');
  }

  // ── A computer's system notifications (4.0) ─────────────────────

  /// Whether this computer's person turned on "Also show as system
  /// notifications" (Settings > Notifications). Off at first.
  static bool _computerOn = false;

  /// Whether the plugin is started for a computer.
  static bool _computerReady = false;

  /// Whether a computer shows the app's notices as the system's as well.
  static bool get computerSystemNotices => _computerOn;

  /// The name Windows registers ZestSSH's notifications under (its app user
  /// model id) and the id of what a click on one starts in the app (a COM
  /// class id, made for ZestSSH). Unpackaged, the plugin writes both under
  /// the person's own registry (HKEY_CURRENT_USER\Software\Classes\
  /// AppUserModelId), which the installer takes away when ZestSSH is
  /// uninstalled; the Microsoft Store's package has its own identity.
  static const windowsAppUserModelId = 'AffluentLabs.ZestSSH';
  static const _windowsActivatorGuid = 'a2586286-9f6f-4075-9000-b58c7e3fb834';

  /// Follows the setting: on, the plugin is started for this computer (once);
  /// off, nothing more goes to the system. Nothing on a phone, whose
  /// notifications are always on.
  static Future<void> setComputerSystemNotices(bool on) async {
    if (!_computer) return;
    _computerOn = on;
    if (on) await _startOnComputer();
  }

  static Future<void> _startOnComputer() async {
    if (_computerReady) return;
    try {
      // The app's own picture, beside the program: Windows names it in the
      // registry, a Linux desktop draws it.
      final icon = p.join(p.dirname(Platform.resolvedExecutable), 'data', 'flutter_assets', 'assets', 'ZestSSH.png');
      final ready = await _plugin.initialize(
        settings: InitializationSettings(
          // macOS asks its person when the switch is turned on
          // ([requestComputerPermission]), not as the app starts.
          macOS: const DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(
            defaultActionName: gl10n.settingsInlineOpen,
            defaultIcon: FilePathLinuxIcon(icon),
          ),
          windows: WindowsInitializationSettings(
            appName: 'ZestSSH',
            appUserModelId: windowsAppUserModelId,
            guid: _windowsActivatorGuid,
            iconPath: icon,
          ),
        ),
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );
      _computerReady = ready ?? true;
      _initialized = _computerReady;
      AppLogger.info('System notifications on this computer: ${_computerReady ? 'ready' : 'not available'}');
    } catch (e) {
      // The app's own notices go on as before.
      AppLogger.warning('System notifications could not start on this computer: $e');
    }
  }

  /// macOS asks its person once whether ZestSSH may show notifications:
  /// asked as the switch is turned on. True where they may (always on
  /// Windows and Linux, which ask nothing).
  static Future<bool> requestComputerPermission() async {
    if (_os != 'macos') return true;
    await _startOnComputer();
    final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    if (mac == null) return true;
    try {
      return await mac.requestPermissions(alert: true, sound: true) ?? false;
    } catch (e) {
      AppLogger.warning('macOS notification permission not asked: $e');
      return false;
    }
  }

  /// Whether ZestSSH's window is the one in front: visible, not minimised and
  /// focused. A test's say where it is not null.
  @visibleForTesting
  static Future<bool> Function()? debugWindowInFront;

  static Future<bool> _windowInFront() async {
    final debug = debugWindowInFront;
    if (debug != null) return debug();
    try {
      return await windowManager.isVisible() &&
          !await windowManager.isMinimized() &&
          await windowManager.isFocused();
    } catch (_) {
      // Not known: told, rather than missed.
      return false;
    }
  }

  /// On a computer, [show] where its person turned on "Also show as system
  /// notifications" and ZestSSH's window is not the one in front (its own
  /// notice is in sight there). Nothing otherwise.
  static Future<void> onComputer(Future<void> Function() show) async {
    if (!_computerOn) return;
    if (await _windowInFront()) return;
    await show();
  }

  /// What a click on one of a computer's notifications does, with its
  /// payload (the app: the window to the front, and the place it is about).
  static void Function(String? payload)? onComputerTap;

  // ── What is shown ───────────────────────────────────────────────

  /// Request notification permissions (iOS/Android 13+).
  static Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await iosPlugin?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }

    if (Platform.isAndroid) {
      final androidPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      return await androidPlugin?.requestNotificationsPermission() ?? false;
    }

    return false;
  }

  /// Whether the OS currently permits posting notifications. Drives the
  /// permission-denied banner. Defaults to true when the state is unknown or on
  /// desktop (no OS gate), so the banner only ever shows on a REAL denial.
  static Future<bool> areEnabled() async {
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await androidPlugin?.areNotificationsEnabled() ?? true;
    }
    if (Platform.isIOS) {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final options = await iosPlugin?.checkPermissions();
      return options?.isEnabled ?? true;
    }
    return true;
  }

  /// Open the OS app-notification settings page (the only way to re-enable a
  /// permanently-denied permission). flutter_local_notifications cannot do this.
  static Future<void> openSystemSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.notification);

  /// Show a "connection lost" notification: in the app's language, the
  /// host's name masked in recording mode (3.0: it said
  /// "Connection Lost" and `<name> disconnected` in English, the name as it
  /// is while recording).
  static Future<void> showConnectionLost({required String connectionLabel}) => _show(
        _notificationId(connectionLabel),
        gl10n.connectionLostTitle,
        gl10n.connectionLostEnded(Redactable.host(connectionLabel).display),
        payload: 'connection_lost:${_notificationId(connectionLabel)}',
      );

  /// Show a notice of the app's own: a workflow that finished, failed or has
  /// something to say. (They went through [showConnectionLost], so each
  /// said "Connection Lost".) A Notify step can carry the output of the step
  /// before it: what reads as a secret there (a private key, a password or a
  /// token after its name, a known token's form) is left out of the system's
  /// notification (4.0), which other apps that hold notification access can
  /// read; the app's own notice shows it as the run's panel does.
  static Future<void> showNotice({required String title, required String body}) =>
      _show(_notificationId(title, 2000), title, SessionLogRedactor().redact(body));

  /// A terminal trigger that plays a sound: the trigger by its name, and
  /// that a line matched it; not the line, which other apps that hold
  /// notification access could read. A phone or a tablet has no alert sound
  /// of its own, so its notification makes the sound; a computer plays the
  /// system's alert sound itself, so its notification is silent ([silent]).
  static Future<void> showTriggerSound({required String triggerName, bool silent = false}) {
    final name = sanitizeDisplayText(triggerName, maxLen: 120);
    return _show(_notificationId(name, 3000), name, gl10n.trgPhoneSoundBody,
        channel: _triggerChannelId, silent: silent);
  }

  /// Show "support answered your ticket". The caller passes text that names
  /// the ticket by its number only: a system notification is readable by
  /// other apps that hold notification access, and a ticket's subject can be
  /// private.
  static Future<void> showTicketReply({
    required String title,
    required String body,
  }) =>
      _show(_notificationId('ticket_reply', 2000), title, body, payload: 'ticket_reply', channel: _supportChannelId);

  /// What would be shown, for tests: called in place of the system's
  /// notification. Null in the app.
  @visibleForTesting
  static void Function(String title, String body)? debugShown;

  /// The channel of what [debugShown] was last given, for tests.
  @visibleForTesting
  static String? debugShownChannel;

  static Future<void> _show(int id, String title, String body,
      {String? payload, String channel = _connectionChannelId, bool silent = false}) async {
    final debug = debugShown;
    if (debug != null) {
      debugShownChannel = channel;
      return debug(title, body);
    }
    if (!_initialized) return;

    try {
      final NotificationDetails details;
      if (_phone) {
        await _nameChannels();
        final named = channelOf(channel);
        final support = channel == _supportChannelId;
        details = NotificationDetails(
          android: AndroidNotificationDetails(
            named.id,
            named.name,
            channelDescription: named.description,
            importance: support ? Importance.defaultImportance : Importance.high,
            priority: support ? Priority.defaultPriority : Priority.high,
            icon: '@mipmap/ic_launcher',
            color: AppColors.orange,
          ),
          iOS: support
              ? const DarwinNotificationDetails(presentAlert: true)
              : const DarwinNotificationDetails(
                  presentAlert: true,
                  presentBadge: true,
                  presentSound: true,
                ),
        );
      } else if (_computer && _computerOn && _computerReady) {
        details = computerDetails(silent: silent);
      } else {
        return;
      }
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        // SECURITY: payload is read by the system notification
        // service and accessible to other apps that hold notification-
        // listener permissions (Android), plus may be picked up by
        // crash reporters and adb logs. Use the hashed id (which
        // is opaque) as the key the user's *own* app needs to map
        // back to a connection - never embed the connection label
        // itself.
        payload: payload,
      );
    } catch (e) {
      AppLogger.error('Failed to show a notification', e);
    }
  }

  /// A computer's notification: at the system's normal level everywhere,
  /// so that its Do not disturb (Windows' and macOS's Focus, a Linux
  /// desktop's) holds it back as it holds others back (no alarm or urgent
  /// scenario on Windows, no critical urgency on Linux, no time sensitive
  /// level on macOS); [silent] where the app plays its own sound.
  @visibleForTesting
  static NotificationDetails computerDetails({bool silent = false}) => NotificationDetails(
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: !silent,
          interruptionLevel: InterruptionLevel.active,
        ),
        linux: LinuxNotificationDetails(
          urgency: LinuxNotificationUrgency.normal,
          suppressSound: silent,
        ),
        windows: WindowsNotificationDetails(
          audio: silent ? WindowsNotificationAudio.silent() : null,
        ),
      );

  /// Cancel all notifications.
  static Future<void> cancelAll() => _plugin.cancelAll();

  /// Set the GoRouter instance for notification tap navigation.
  ///
  /// Call this from `app.dart` once the router is available so that
  /// tapping a notification can navigate the user to the right screen.
  static void setRouter(GoRouter router) {
    _router = router;
  }

  /// A click on one of the app's notifications, for tests.
  @visibleForTesting
  static void debugTap(String? payload) =>
      _onNotificationTapped(NotificationResponse(notificationResponseType: NotificationResponseType.selectedNotification, payload: payload));

  static void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    AppLogger.info('Notification tapped: $payload');

    // A computer: its window to the front, and the place the notification
    // is about, by the app ([onComputerTap]).
    if (_computer) {
      onComputerTap?.call(payload);
      return;
    }

    if (payload == null || _router == null) return;

    // Payload format: "type:opaque_id" (the id is a hash of the
    // connection label, NOT the label itself - see the comment
    // in _show for why).
    // The handler is a coarse "go home" because the system
    // notification has already given the user the visual context.
    if (payload.startsWith('connection_lost:') ||
        payload.startsWith('connection_failed:')) {
      _router!.go('/');
    } else if (payload == 'ticket_reply') {
      // My tickets: the unread one is marked there.
      _router!.push('/tickets');
    }
  }
}
