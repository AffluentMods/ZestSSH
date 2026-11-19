import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:zestssh/features/screens/window/view_windows.dart';
import 'package:zestssh/app.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/setup/setup_command_host.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/services/store_handover_start.dart';
import 'package:zestssh/services/deep_link_service.dart';
import 'package:zestssh/services/demo_seed.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/features/screens/window/screen_window_app.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/services/multi_window_service.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/services/prometheus_secure_settings.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/services/shortcut_service.dart';
import 'package:zestssh/services/tray_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:xterm/xterm.dart' as xterm;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/services/window_service.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart' show editorDraftStoreProvider;
import 'package:zestssh/ui/screens/editor/editor_windows.dart';
import 'package:zestssh/ui/windows/editor_window.dart';
import 'package:zestssh/router/router.dart' show routerProvider;
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/ui/screens/desktop/detached_terminal_window.dart';
import 'package:zestssh/ui/screens/error/database_error_screen.dart';
import 'package:zestssh/ui/screens/error/migration_error_screen.dart';
import 'package:zestssh/ui/screens/error/startup_error_screen.dart';
import 'package:zestssh/ui/widgets/broken_widget_notice.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/leftover_copies.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/utf8_chunks.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart' show KeychainAccessDenied;
import 'package:zestssh/services/profiles/profile_boot.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_move.dart' show ProfileMoveFailed;
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/platform_licences.dart';
import 'package:zestssh/ui/screens/error/mac_keychain_update_screen.dart';
import 'package:zestssh/ui/screens/error/moving_data_screen.dart';
import 'package:zestssh/services/app_instance_lock.dart';
import 'package:zestssh/utils/after_next_frame.dart';

/// Global [ProviderContainer] shared between the main window and all
/// secondary (detached terminal) windows. Because `desktop_multi_window`
/// runs secondary windows in the same process and Dart isolate, they
/// share memory. This lets detached terminals access the same Riverpod
/// state (active sessions, settings, etc.) as the main window.
ProviderContainer? _sharedContainer;

/// Deep link URI passed via command-line args (e.g. Windows URL protocol).
Uri? _launchDeepLink;

/// What followed "admin" on the command line (3.0: the setup file
/// from a terminal), kept until the app is up and runs it.
List<String>? _adminArgs;

void main(List<String> args) {
  // ── Secondary window entry point ──────────────────────────────
  // desktop_multi_window passes args as: ["multi_window", windowId, jsonPayload]
  if (args.isNotEmpty && isDesktopPlatform) {
    if (args.firstOrNull == 'multi_window' && args.length >= 3) {
      final windowId = int.tryParse(args[1]);
      if (windowId != null) {
        _runSecondaryWindow(windowId, args.sublist(1));
        return;
      }
    }
    // Also handle legacy format where args[0] is the window ID directly
    final windowId = int.tryParse(args.firstOrNull ?? '');
    if (windowId != null) {
      _runSecondaryWindow(windowId, args);
      return;
    }

    // The setup file from a terminal (3.0), as in
    // `zestssh admin plan FILE`.
    if (kOrchardsEnabled && args.first == 'admin') {
      unawaited(_runAdminCommandLine(args.sublist(1)));
      return;
    }

    // Check for zestssh:// deep link URL (e.g. OAuth callback)
    for (final arg in args) {
      if (arg.startsWith('zestssh://')) {
        _launchDeepLink = Uri.tryParse(arg);
        break;
      }
    }
  }

  // ── Primary (main) window entry point ─────────────────────────
  _runMainWindow();
}

/// The app started with a command for the setup file. What was typed is
/// read first: when it is no command, how it is used is said and the
/// program ends before any window opens. A command starts the app as ever
/// (a locked app asks to be unlocked, a signed-out one to sign in), runs
/// once it is up, and ends the program with its code.
Future<void> _runAdminCommandLine(List<String> args) async {
  await startAdminCommandLine(args);
  _adminArgs = args;
  _runMainWindow();
}

/// Run the main ZestSSH application window.
void _runMainWindow() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Before anything touches the keychain.
    installKeychainStore();

    // The licences of this platform's native libraries, for the licences
    // page (read only when the page asks).
    registerPlatformLicences();

    AppLogger.init();
    AppLogger.info('ZestSSH starting');
    // A computer's ZestSSH holds a lock for as long as it runs; a command
    // (zestssh admin) that finds it held says to close ZestSSH first and
    // ends. The app itself starts either way (found in a code audit).
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final held = await AppInstanceLock.take();
      if (!held && _adminArgs != null) {
        await endAdminBesideOpenApp();
        return;
      }
    }
    // Which app this is and which folders it writes to, for the details an
    // error can be copied with (nothing is read that is not on this device).
    unawaited(ErrorReport.prime());
    // What the app left in the temporary folder where it was ended in the
    // middle of something: a Mosh or Eternal Terminal session's key, copies
    // of files on a host, in the clear.
    unawaited(clearLeftoverCopies());

    FlutterError.onError = (details) {
      final msg = details.exceptionAsString();
      AppLogger.error('Flutter error: $msg', details.exception, details.stack);

      // Suppress the _dependents.isEmpty assertion - it's a benign
      // race during widget disposal and doesn't affect app behaviour.
      if (msg.contains('_dependents.isEmpty')) {
        AppLogger.warning('Suppressed _dependents.isEmpty assertion');
        return;
      }
    };

    // Show user-friendly error screen instead of red error in release, with
    // the details to copy (it said "Something went wrong" and no more).
    ErrorWidget.builder = (FlutterErrorDetails details) {
      if (kReleaseMode) return BrokenWidgetNotice(details);
      // In debug, suppress _dependents assertion red screens too -
      // show a grey placeholder instead of the alarming red error.
      final msg = details.exceptionAsString();
      if (msg.contains('_dependents.isEmpty')) {
        return const SizedBox.shrink();
      }
      return ErrorWidget(details.exception);
    };

    // ── A Mac after an update (3.3.2) ─────────────────────────────
    // Before anything reads the keychain (Firebase's own sign-in included): macOS
    // will ask for the login password for each saved key, as the Mac app is signed
    // ad-hoc and each build is a new app to it. Said once for each build, with
    // Continue; never for a command from a terminal, which has nobody to press it.
    if (Platform.isMacOS && _adminArgs == null) {
      try {
        await sayKeychainAsksAfterUpdate(
          prefs: await systemPreferences(),
          build: (await PackageInfo.fromPlatform()).buildNumber,
          names: () => keychainNamesIn(deviceKeychain),
          // Not _show: a failure that follows still has its own screen to say it.
          show: runApp,
        );
      } catch (e) {
        AppLogger.warning('The notice of the keychain after an update was not shown (${errorKind(e)})');
      }
    }

    // Initialise Firebase
    try {
      await Firebase.initializeApp();
    } catch (e) {
      AppLogger.warning('Firebase init failed (non-fatal): $e');
    }

    // ── One ZestSSH per Windows PC, the Store's preferred (see
    // lib/services/store_handover.dart). Before any data opens, anything is drawn, or the preferences
    // are first read (a hand-over taken in brings its own): the website copy hands its data to
    // a Store copy at least as new, and ends; the Store copy takes over one at most as new, or ends.
    // Never a debug run, and never a build that is not the release (storeHandoverAtStart): a
    // contributor's `flutter run` must not copy an installed ZestSSH's data or end into the Store's copy.
    if (Platform.isWindows && !kDebugMode && await storeHandoverAtStart(rawPrefs: systemPreferences, command: _adminArgs != null)) {
      exit(0);
    }

    final SharedPreferences rawPrefs = await systemPreferences();

    // ── Profiles (computers; to-do 60) ──────────────────────────
    // A person's data is in a profile, and a person's settings in its database.
    // Before anything opens: a move to profiles goes as far as it can without
    // the database, and which profile opens is settled. Everything below reads
    // settings through the helper, so a phone, which has none, reads as ever.
    final boot = await bootProfiles(
      rawPrefs: rawPrefs,
      // On the screen before it begins: it can take a while, before any window
      // there would be, and a person who ends it has it to do again. Not _show: a
      // failure still has this screen to take the place of (StartupWindow.failed).
      sayMoving: () async {
        runApp(MovingDataApp(language: rawPrefs.getString('app_locale')));
        await WidgetsBinding.instance.endOfFrame.timeout(const Duration(seconds: 2), onTimeout: () {});
      },
    );
    final SharedPreferences prefs = boot.prefs;
    final profileStart = boot.start;
    if (profileStart == null) await TerminalThemes.loadCustomThemes(prefs);
    await PinnedHttpClient.init();

    // Recording mode must be masking from the very first frame (it persists
    // across restarts, spec 7c) and its stand-ins are keyed to this install:
    // seed the Redactor before anything builds, rather than when the first
    // widget happens to read the provider.
    final bootSettings = SettingsService(prefs);
    Redactor.instance
      ..salt = bootSettings.recordingMaskSalt
      ..level = bootSettings.recordingRedactLevel == 'strict'
          ? RedactLevel.strict
          : RedactLevel.layout
      ..enabled = bootSettings.recordingModeEnabled;

    // ── Pre-migration backup ────────────────────────────────────
    // A copy before opening the database where opening it will upgrade it (it
    // last opened at another schema version, or at one not known), in case the
    // migration fails. It was made at every start, a whole copy each time (3.3).
    String? migrationBackupPath;
    try {
      migrationBackupPath = await MigrationBackupService.backupBeforeUpgrade(
        schemaVersion: AppDatabase.currentSchemaVersion,
      );
      if (migrationBackupPath != null) AppLogger.info('Pre-migration backup ready: $migrationBackupPath');
    } catch (e) {
      AppLogger.warning('Pre-migration backup failed (non-fatal): $e');
    }

    // ── Open database ───────────────────────────────────────────
    // Encrypting lock ON (1.8 vault): the SQLCipher DB key is wrapped behind
    // the PIN / master password, so DO NOT open the database here. It opens
    // only after the unlock screen unwraps the vault (see security_providers /
    // security_lock_screen); the DB session starts null and the router shows
    // the lock screen. Lock OFF opens now, with the existing migration/error
    // recovery, exactly as before.
    // Decide lock-ON vs lock-OFF from the ACTUAL secure-storage vault state,
    // NOT the cached prefs flag: a mistimed process kill during enable/disable
    // can leave the flag disagreeing with storage, and trusting the flag then
    // either funnels an interrupted-enable user into the data-wiping reset
    // screen or strands an interrupted-disable user at an unlockable screen.
    // reconcileBootLockState() derives the truth and self-heals partial state.
    final encryptingLockOn = profileStart?.lockOn ?? await VaultSlotService.reconcileBootLockState();
    if ((prefs.getBool('encrypting_lock_enabled') ?? false) != encryptingLockOn) {
      // Keep the in-session flag (read by the lock lifecycle + settings UI)
      // consistent with the reconciled truth.
      await prefs.setBool('encrypting_lock_enabled', encryptingLockOn);
    }
    AppDatabase? db;
    if (!encryptingLockOn) {
    try {
      if (profileStart != null) {
        // The account's or the guest's: an unfinished move finishes as it opens.
        db = await ProfileManager.instance!.openCurrent();
        await TerminalThemes.loadCustomThemes(prefs);
      } else {
        db = await AppDatabase.open();
      }
      AppLogger.info(
        kDebugMode
            ? 'Database opened (unencrypted debug mode)'
            : 'Database opened (SQLCipher encrypted)',
      );
      // (Old migration backups are cut where every database opens:
      // MigrationBackupService.noteOpened, from AppDatabase's beforeOpen.)
    } on MigrationIntegrityException catch (e, stack) {
      // ── Migration integrity failure ─────────────────────────
      // The migration ran but left the database in a bad state.
      // Attempt to restore from the pre-migration backup.
      AppLogger.error('Migration integrity check failed', e, stack);

      var backupRestored = false;
      if (migrationBackupPath != null) {
        try {
          await MigrationBackupService.restoreFromBackup(migrationBackupPath);
          backupRestored = true;
          AppLogger.info('Database restored from pre-migration backup');
        } catch (restoreError) {
          AppLogger.error(
            'Failed to restore from backup',
            restoreError,
          );
        }
      }

      String? dbPath;
      try {
        dbPath = await AppDatabase.databasePath;
      } catch (_) {}

      // What stands behind it, as a report a person may paste anywhere: the
      // database's path names the account's folder, and is scrubbed.
      final report = await databaseFailureReport(
        migration: true,
        error: e,
        stack: stack,
        databasePath: dbPath,
        backupRestored: backupRestored,
      );

      // Started for a command (3.0): the terminal is told and the
      // program ends. The app says why on its own screen when it is opened.
      if (_adminArgs != null) await endAdminWithoutData();

      _show(MigrationErrorApp(
        report: report,
        backupRestored: backupRestored,
        backupPath: migrationBackupPath,
        onContinue: _startupWindow.retry,
        onSetAside: backupRestored || failureMayPass(e) ? null : _setAsideAndStart(),
      ));
      return;
    } on ProfileMoveFailed catch (e, stack) {
      // ── A move that could not go on ─────────────────────────
      // Nothing is lost: the next start goes on from where it stopped. The
      // originals are all still there.
      AppLogger.error('The move to profiles stopped', e, stack);
      if (_adminArgs != null) await endAdminWithoutData();
      _show(await startupErrorAppFor(e, stack,
          onRetry: _startupWindow.retry, onSetAside: await startWayOut(e, retry: _startupWindow.retry)));
      return;
    } catch (e, stack) {
      // ── General database failure ────────────────────────────
      AppLogger.error('Database open failed', e, stack);

      // If this looks like a migration failure (not an encryption/IO
      // error), try restoring from the pre-migration backup.
      // Never data from a newer ZestSSH, nor a failure of the moment (a
      // file another process holds): no copy is put back over those (found in
      // a code audit).
      final isMigrationRelated = !dataStaysAsItIs(e) &&
          (e.toString().contains('migration') ||
              e.toString().contains('table') ||
              e.toString().contains('column') ||
              e.toString().contains('SQL'));

      var backupRestored = false;
      if (isMigrationRelated && migrationBackupPath != null) {
        try {
          await MigrationBackupService.restoreFromBackup(migrationBackupPath);
          backupRestored = true;
          AppLogger.info(
            'Database restored from pre-migration backup after general error',
          );
        } catch (restoreError) {
          AppLogger.error(
            'Failed to restore from backup',
            restoreError,
          );
        }
      }

      String? dbPath;
      try {
        dbPath = await AppDatabase.databasePath;
        final dbFile = File(dbPath);
        final exists = await dbFile.exists();
        final sizeKb = exists ? (await dbFile.length()) ~/ 1024 : 0;
        AppLogger.error(
          'DB diagnostics: path=$dbPath, exists=$exists, size=${sizeKb}KB',
        );
      } catch (_) {}

      // What stands behind it, as a report a person may paste anywhere: the
      // database's path names the account's folder, and is scrubbed.
      final report = await databaseFailureReport(
        migration: isMigrationRelated,
        error: e,
        stack: stack,
        databasePath: dbPath,
        backupRestored: backupRestored,
      );

      // Started for a command (3.0): the terminal is told and the
      // program ends. The app says why on its own screen when it is opened.
      if (_adminArgs != null) await endAdminWithoutData();

      if (isMigrationRelated) {
        _show(MigrationErrorApp(
          report: report,
          backupRestored: backupRestored,
          backupPath: migrationBackupPath,
          onContinue: _startupWindow.retry,
          onSetAside: backupRestored || dataStaysAsItIs(e) ? null : _setAsideAndStart(),
        ));
      } else {
        final moving = await ProfileManager.instance?.moveUnderWay() ?? false;
        // macOS did not let ZestSSH read the database's key (3.3.2): the data is
        // only waiting for a yes, and is never offered for deletion.
        final keychainDenied = e is KeychainAccessDenied;
        _show(DatabaseErrorApp(
          report: report,
          databasePath: dbPath,
          onRetry: _startupWindow.retry,
          keychainDenied: keychainDenied,
          newerData: e is DatabaseNewerThanApp,
          // (A failure is said on the screen: it did nothing anyone could see.)
          // Only on a phone, and only where nothing says the data is just waiting
          // (resetOffered): it sets the files aside, the key kept. A computer has Set
          // aside below, which Put it back undoes.
          onReset: resetOffered(e, moving: moving, computer: ProfileManager.instance != null)
              ? () async {
                  await AppDatabase.setAsideAndRecreate();
                  _startupWindow.retry();
                }
              : null,
          // A profile that cannot open never stops the others.
          onOpenOther: ProfileManager.instance?.canOpenAnother ?? false
              ? () => unawaited(ProfileManager.instance!.openGuestNextStart().then((_) => _startupWindow.retry()))
              : null,
          // The way out when a move's database does not open, and for any other, where
          // Try again will not help: nothing is deleted.
          onSetAside: dataStaysAsItIs(e) ? null : _setAsideAndStart(),
        ));
      }
      return;
    }
    }

    // ── Demo data for marketing footage (debug builds only) ───────
    // With --dart-define=ZEST_DEMO_SEED=true a debug build fills an empty
    // install with the made-up world of the screenshot tests
    // (lib/services/demo_seed.dart). kDemoSeed is a constant false in release
    // and profile builds, which leave all of this out.
    if (kDemoSeed && db != null) {
      try {
        final seeded = await seedDemoIfAsked(
            db: db, prefs: prefs, secrets: IdentitySecretStore.forDatabase(db, appKeychain));
        AppLogger.info(seeded == null
            ? 'Demo seed: the database holds data or was seeded before, left as it is'
            : 'Demo seed: ${seeded.hosts} hosts, ${seeded.keys} keys, ${seeded.snippets} snippets');
      } catch (e, stack) {
        AppLogger.error('Demo seed failed', e, stack);
      }
    }

    // Initialise desktop services (window manager + system tray)
    if (isDesktopPlatform) {
      await WindowService.init(prefs);
      await TrayService.init();
    }

    // Initialise RevenueCat for in-app purchases (mobile only)
    if (isMobilePlatform) {
      await PurchaseService.init();
    }

    // Initialise deep links on all platforms, mobile-only services after
    await DeepLinkService.init();
    // Inject command-line deep link (e.g. Windows URL protocol cold start)
    if (_launchDeepLink != null) {
      DeepLinkService.injectLink(_launchDeepLink!);
      _launchDeepLink = null;
    }
    if (isMobilePlatform) {
      await NotificationService.init();
      ShortcutService.initialize();
    }

    // Create the shared ProviderContainer used by all windows
    _sharedContainer = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    // Lock OFF: adopt the database opened above. Lock ON: leave the session
    // null so the router shows the unlock screen and the DB opens only after
    // the vault is unwrapped.
    if (db != null) {
      _sharedContainer!.read(databaseSessionProvider.notifier).seed(db);
    }

    // ── One-time security migration ──────────────────────────────
    // Move legacy Prometheus credentials from SharedPreferences (plaintext)
    // to FlutterSecureStorage (encrypted). Runs once; subsequent calls
    // are no-ops because the SharedPreferences keys will already be gone.
    await _migrateLegacyPrometheusCredentials(prefs);

    // Set up method handler on the main window to receive calls from
    // secondary (detached) windows (e.g. reattach, window close events).
    if (isDesktopPlatform) {
      // Track active terminal bridges: sessionId → (windowId, subscription)
      final Map<String, (int, StreamSubscription)> terminalBridges = {};

      // What a window of the app's own asks the main window: from a window of
      // the plugin's (its own engine) over the channel, and from a window this
      // engine draws as a view (view_windows.dart) straight here.
      Future<Object?> onWindowCall(MethodCall call, int fromWindowId) async {
        switch (call.method) {
          // ── The app lock in pop-out windows (3.0) ──
          case 'appLockState':
            return _sharedContainer!.read(isAppLockedProvider) ? '1' : '0';

          case 'activity':
            // Someone is working in a pop-out window: not idle.
            _sharedContainer!.read(idleClockProvider).touch();
            EditorWindows.instance.touched(fromWindowId);
            return '';

          case 'editorNanoKeys':
            // A person's setting, kept by the main window for a window of its
            // own (which has no way to the profile's database).
            await prefs.setBool('editor_nano_keys', call.arguments == '1');
            return '';

          case 'editorMinimap':
            await prefs.setBool('editor_minimap', call.arguments == '1');
            return '';

          // ── The editor's windows of their own: their saves, reads,
          // drafts and moves go through here, where the connections are
          // (lib/ui/screens/editor/editor_windows.dart).
          // A screen in a window of its own asking to be brought back to
          // its tab (lib/features/screens/window/screen_windows.dart).
          case final String method when method.startsWith('screenWindow'):
            return await ScreenWindows.instance.handle(method, call.arguments, fromWindowId) ?? '';

          case final String method when method.startsWith('editor'):
            return await EditorWindows.instance.handle(method, call.arguments, fromWindowId) ?? '';

          case 'startTerminalBridge':
            try {
              final data =
                  jsonDecode(call.arguments as String) as Map<String, dynamic>;
              final sessionId = data['sessionId'] as String;
              final targetWindowId = data['targetWindowId'] as int;

              final sessions =
                  _sharedContainer!.read(activeSessionsProvider);
              final session = sessions[sessionId];
              if (session?.session?.shell != null) {
                final shell = session!.session!.shell;
                final sub = shell.stdout.listen((bytes) {
                  try {
                    DesktopMultiWindow.invokeMethod(
                      targetWindowId,
                      'terminalOutput',
                      base64Encode(bytes),
                    );
                  } catch (e) {
                    AppLogger.error('Terminal bridge output failed: $e');
                  }
                });
                terminalBridges[sessionId] = (targetWindowId, sub);
                AppLogger.info(
                  'Terminal bridge started: $sessionId → window $targetWindowId',
                );
              }
            } catch (e) {
              AppLogger.error('Failed to start terminal bridge', e);
            }

          case 'terminalInput':
            // Nothing is typed into a session while the app is locked.
            if (_sharedContainer!.read(isAppLockedProvider)) return '';
            try {
              final data =
                  jsonDecode(call.arguments as String) as Map<String, dynamic>;
              final sessionId = data['sessionId'] as String;
              final inputBytes =
                  base64Decode(data['data'] as String);
              _sharedContainer!.read(activeSessionsProvider.notifier).sendInput(sessionId, inputBytes);
            } catch (e) {
              AppLogger.error('Failed to forward terminal input', e);
            }

          case 'reattachSession':
            try {
              final data =
                  jsonDecode(call.arguments as String) as Map<String, dynamic>;
              final sessionId = data['sessionId'] as String?;
              if (sessionId != null) {
                final bridge = terminalBridges.remove(sessionId);
                bridge?.$2.cancel();
                MultiWindowService.instance.handleMethodCall(
                  'requestReattach',
                  jsonEncode({'sessionId': sessionId}),
                  fromWindowId,
                );
                afterNextFrame((_) {
                  final focused = FocusManager.instance.primaryFocus;
                  if (focused != null) {
                    focused.unfocus();
                    Future.delayed(const Duration(milliseconds: 100), () {
                      focused.requestFocus();
                    });
                  }
                });
              }
            } catch (e) {
              AppLogger.error('Failed to reattach session', e);
            }

          default:
            MultiWindowService.instance.handleMethodCall(
              call.method,
              call.arguments,
              fromWindowId,
            );
        }
        return '';
      }

      DesktopMultiWindow.setMethodHandler(onWindowCall);
      ViewWindows.instance.mainCall =
          (method, arguments, from) => onWindowCall(MethodCall(method, arguments), from);

      // A tab moved into the main window's editor from a window of its own
      // joins its tabs (3.4.1); the windows of their own keep their drafts
      // in this profile's databases.
      EditorWindows.instance
        ..takeIntoMain = (doc) async {
          // Below the app's navigator, where its questions and notices show.
          final navigator = _sharedContainer!.read(routerProvider).routerDelegate.navigatorKey.currentState;
          final context = navigator?.overlay?.context ?? navigator?.context;
          if (context == null || !context.mounted) return false;
          return takeIntoEditor(context, doc);
        }
        ..drafts = () {
          // This profile's: a window opened in another one is answered
          // nothing (EditorWindows._answerDraft), and every window closes at
          // a change of profile (ProfileController._stopWhatRuns).
          try {
            return _sharedContainer!.read(editorDraftStoreProvider);
          } catch (_) {
            return null; // No database open (the app is locked).
          }
        };

      // Recording mode reaches the editor's windows of their own as it
      // changes, and they mask as this window does (security review 3.4.1, L3).
      Redactor.instance.onChanged = () => unawaited(EditorWindows.instance.broadcastRecording());

      // Pop-out windows cover themselves while the app is locked (3.0):
      // each hears every change.
      _sharedContainer!.listen<bool>(
        isAppLockedProvider,
        (_, locked) {
          unawaited(MultiWindowService.instance.broadcastAppLock(locked));
          ViewWindows.instance.locked.value = locked;
        },
      );

      // On Windows a remote screen's window of its own is a view of this
      // engine (view_windows.dart): no second engine to race this one in the
      // graphics driver.
      if (ViewWindows.supported) {
        final container = _sharedContainer!;
        ViewWindows.instance
          ..locked.value = container.read(isAppLockedProvider)
          ..onActivity = () => container.read(idleClockProvider).touch();
        final views = ViewWindowsBackend();
        ScreenWindows.instance.backend = views;
        EditorWindows.instance.backend = views;
      }
    }

    _show(
      UncontrolledProviderScope(
        container: _sharedContainer!,
        // The windows this engine draws as views of its own, beside the app.
        child: const ViewWindowsHost(child: ZestSSHApp()),
      ),
    );

    // Started with a command for the setup file (3.0): it runs
    // once the app is unlocked and signed in, and ends the program.
    final admin = _adminArgs;
    if (admin != null) {
      _adminArgs = null;
      unawaited(runAdminFromCommandLine(_sharedContainer!, admin));
    }
  }, (error, stack) {
    AppLogger.error('Unhandled error', error, stack);
    // Before a window was shown, nothing would ever say it: the window stayed
    // blank, or the starting screen stayed for good. The app failed before its
    // window could open (its settings, its keychain, the window itself): says
    // so, with the details to copy and Try again.
    unawaited(_startupWindow.failed(error, stack));
  });
}

/// Whether the app has shown a window of its own, and what says a failure until
/// then.
final StartupWindow _startupWindow = StartupWindow(
  show: runApp,
  start: () => main([]),
  wayOut: (error) => startWayOut(error, retry: () => _startupWindow.retry()),
  // Started for a command: the terminal is told and the program ends.
  beforeSaying: () async {
    if (_adminArgs != null) await endAdminWithoutData();
  },
);

/// Shows [app] as the app's window.
void _show(Widget app) => _startupWindow.showApp(app);

/// What did not open goes to a folder of its own and the app starts again, deleting
/// nothing: the way out of a move that cannot finish, whichever screen it ended on.
/// Null where there is none to set aside: a phone.
Future<void> Function()? _setAsideAndStart() {
  final manager = ProfileManager.instance;
  if (manager == null) return null;
  return () async {
    await manager.setAsideCurrent();
    _startupWindow.retry();
  };
}

/// Buffer for terminal output that arrives before the standalone child
/// window's widget tree is ready to consume it.
final List<String> _earlyTerminalOutput = [];

/// In a pop-out window: whether the app is locked, as the main window last
/// said (3.0).
final ValueNotifier<bool> _popOutLocked = ValueNotifier<bool>(false);

/// In a pop-out window: tells the main window someone is working here.
void _popOutActivity() {
  unawaited(DesktopMultiWindow.invokeMethod(0, 'activity').catchError((Object _) => null));
}

/// Run a secondary (detached terminal) window.
///
/// Called when `desktop_multi_window` spawns a new window. The [windowId]
/// identifies this window and [args] contains the JSON payload with the
/// session ID and connection label.
void _runSecondaryWindow(int windowId, List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // Its own engine, in the same process. It reads no secret today; if it ever
  // does, it takes the same lock as the main window.
  installKeychainStore();
  // Fire-and-forget: file logging will be ready shortly after
  AppLogger.init();

  // Parse the JSON arguments passed by MultiWindowService.detachSession()
  String sessionId = '';
  String connectionLabel = '';
  String? localeName;
  Object? themeJson;
  int? accent;
  Map<String, dynamic>? paneTreeJson;
  Map<String, dynamic>? editorPayload;
  Map<String, dynamic>? screenRaw;
  ScreenWindowPayload? screenPayload;
  var copyOnSelect = true;
  String? shortcuts;

  if (args.length >= 2) {
    try {
      final payload = jsonDecode(args[1]) as Map<String, dynamic>;
      sessionId = payload['sessionId'] as String? ?? '';
      connectionLabel = payload['connectionLabel'] as String? ?? '';
      localeName = payload['locale'] as String?;
      themeJson = payload['theme'];
      accent = payload['accent'] as int?;
      paneTreeJson = payload['paneTree'] as Map<String, dynamic>?;
      copyOnSelect = payload['copyOnSelect'] as bool? ?? true;
      shortcuts = payload['shortcuts'] as String?;
      if (payload['type'] == 'editor') editorPayload = payload;
      if (payload['type'] == kScreenWindowType) {
        screenRaw = payload;
        screenPayload = ScreenWindowPayload.fromJson(payload);
      }
    } catch (e) {
      AppLogger.error('Failed to parse secondary window args', e);
    }
  }

  AppLogger.info(
    'Secondary window $windowId starting for session $sessionId '
    '($connectionLabel)',
  );

  // Set up method handler for inter-window communication.
  // In the shared-container path, forward to MultiWindowService.
  // In the standalone path (_sharedContainer == null), only handle
  // basic commands - MultiWindowService is useless in a separate isolate.
  // Also buffer 'terminalOutput' calls that arrive before the widget tree
  // is ready, so scrollback content is not lost.
  DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
    switch (call.method) {
      case 'appLock':
        _popOutLocked.value = call.arguments == '1';

      case 'terminalOutput':
        // Buffer terminal data that arrives before the widget is ready.
        // The _StandaloneDetachedWindow will drain this buffer on init.
        _earlyTerminalOutput.add(call.arguments as String);

      case 'close':
        // Main window requested this window to close
        WindowController.fromWindowId(windowId).close();

      case kScreenWindowEventMethod:
        // What the main window passes on of a screen shown in this window.
        return await answerScreenWindowCall(windowId, call.method, call.arguments, from: fromWindowId) ?? '';

      case 'editorAddTab':
      case 'editorFocusTab':
      case 'editorRecording':
        // A tab handed to this editor window, one to bring to the front, or
        // the main window's recording mode as it changed.
        return await answerEditorWindowCall(windowId, call.method, call.arguments) ?? '';

      case 'acceptSession':
      case 'requestReattach':
        // Only forward to MultiWindowService when the shared container
        // is available (same isolate). In a standalone child window the
        // singleton is a fresh empty instance and cannot do anything useful.
        if (_sharedContainer != null) {
          MultiWindowService.instance.handleMethodCall(
            call.method,
            call.arguments,
            fromWindowId,
          );
        }

      default:
        if (_sharedContainer != null) {
          MultiWindowService.instance.handleMethodCall(
            call.method,
            call.arguments,
            fromWindowId,
          );
        }
    }
    return '';
  });

  // Editor pop-out: render the text editor instead of a terminal shell. It
  // pulls its files and proxies every save over the method channel to the
  // main window (which owns the SFTP client).
  // A secondary window has no console: a build failure must say what it was,
  // on the app's own background, instead of Flutter's release-mode grey box
  // (which is all a popped-out editor showed while its screen threw).
  ErrorWidget.builder = (details) => SecondaryWindowError(details);

  // A remote screen in a window of its own: its picture read and its input
  // sent by the session's number, the session itself the main window's.
  final screen = screenPayload;
  if (screen != null && screenRaw != null) {
    final raw = screenRaw;
    runZonedGuarded(() {
      runApp(screenWindowApp(
        windowId: windowId,
        payload: screen,
        raw: raw,
        backend: const PluginEditorWindowBackend(),
        locked: _popOutLocked,
        onActivity: _popOutActivity,
      ));
      unawaited(DesktopMultiWindow.invokeMethod(0, 'appLockState').then((locked) {
        _popOutLocked.value = locked == '1';
      }).catchError((Object _) {/* the main window answers the next change */}));
    }, (error, stack) {
      AppLogger.error('Screen window unhandled error', error, stack);
    });
    return;
  }

  if (editorPayload != null) {
    final editor = editorPayload;
    runZonedGuarded(() {
      runApp(editorWindowApp(
        windowId: windowId,
        payload: editor,
        backend: const PluginEditorWindowBackend(),
        locked: _popOutLocked,
        onActivity: _popOutActivity,
      ));
      // The lock as it stands now: a change sent before this window listened
      // would otherwise be missed.
      unawaited(DesktopMultiWindow.invokeMethod(0, 'appLockState').then((locked) {
        _popOutLocked.value = locked == '1';
      }).catchError((Object _) {/* the main window answers the next change */}));
    }, (error, stack) {
      AppLogger.error('Editor window unhandled error', error, stack);
    });
    return;
  }

  // Suppress harmless Flutter text input errors in child windows.
  // The xterm TerminalView may try to register a text input client before
  // the view is ready, producing "view ID is null" PlatformExceptions.
  FlutterError.onError = (details) {
    final msg = details.exceptionAsString();
    if (msg.contains('view ID is null') || msg.contains('no client is set')) {
      return; // Suppress harmless Flutter text input errors in child windows
    }
    FlutterError.presentError(details);
  };

  // desktop_multi_window creates child windows in a SEPARATE Dart isolate
  // on Windows, so the global _sharedContainer is NOT available. The child
  // window gets its own widget tree with its own state.
  //
  // Terminal I/O is forwarded via method channels (bidirectional):
  //   Main → Child: 'terminalOutput' with base64-encoded bytes
  //   Child → Main: 'terminalInput' with base64-encoded bytes
  //   Child → Main: 'reattachSession' to return session to main window
  //
  // The native C++ routing layer (MultiWindowManager::HandleWindowChannelCall)
  // supports both directions - it looks up the target window and forwards.
  //
  // If the shared container IS available (future platforms may share
  // isolates), use it directly for full provider access.
  if (_sharedContainer != null) {
    runApp(
      UncontrolledProviderScope(
        container: _sharedContainer!,
        child: secondaryWindowApp(
          // A title that names no host, as the window's own (see
          // MultiWindowService.detachSession): it was the connection's name.
          title: 'ZestSSH',
          localeName: localeName,
          theme: themeJson,
          accent: accent,
          home: DetachedTerminalWindow(
            sessionId: sessionId,
            connectionLabel: connectionLabel,
            windowId: windowId,
            paneTreeJson: paneTreeJson,
          ),
        ),
      ),
    );
  } else {
    // Separate isolate - run a standalone detached shell with method
    // channel bridge for terminal data.
    // Wrap in runZonedGuarded to catch async PlatformExceptions from
    // the child window's text input system (view ID is null errors).
    runZonedGuarded(() {
      runApp(
        secondaryWindowApp(
          // A title that names no host (as above).
          title: 'ZestSSH',
          localeName: localeName,
          theme: themeJson,
          accent: accent,
          home: _StandaloneDetachedWindow(
            sessionId: sessionId,
            connectionLabel: connectionLabel,
            windowId: windowId,
            copyOnSelect: copyOnSelect,
            shortcuts: shortcuts,
          ),
        ),
      );
    }, (error, stack) {
      final msg = error.toString();
      if (msg.contains('view ID is null') ||
          msg.contains('no client is set')) {
        return; // Suppress harmless text input errors in child window
      }
      AppLogger.error('Child window unhandled error', error, stack);
    });
  }
}

/// Migrate legacy Prometheus credentials from plaintext SharedPreferences
/// to encrypted FlutterSecureStorage.
///
/// Before the PrometheusSecureSettings migration, bearer tokens, basic auth
/// user/password were stored in SharedPreferences (unencrypted). This moves
/// any remaining legacy values to secure storage and deletes the plaintext
/// copies. Safe to call on every launch -- it is a no-op when the legacy
/// keys no longer exist.
Future<void> _migrateLegacyPrometheusCredentials(
    SharedPreferences prefs) async {
  try {
    final settings = SettingsService(prefs);
    final secure = PrometheusSecureSettings(appKeychain);

    // Bearer token
    final legacyBearer = settings.prometheusBearerToken;
    if (legacyBearer != null && legacyBearer.isNotEmpty) {
      final existing = await secure.getBearerToken();
      if (existing == null || existing.isEmpty) {
        await secure.setBearerToken(legacyBearer);
      }
      await settings.clearLegacyPrometheusBearerToken();
      AppLogger.info('Migrated Prometheus bearer token to secure storage');
    }

    // Basic auth user
    final legacyUser = settings.prometheusBasicAuthUser;
    if (legacyUser != null && legacyUser.isNotEmpty) {
      final existing = await secure.getBasicAuthUser();
      if (existing == null || existing.isEmpty) {
        await secure.setBasicAuthUser(legacyUser);
      }
      await settings.clearLegacyPrometheusBasicAuthUser();
      AppLogger.info('Migrated Prometheus basic auth user to secure storage');
    }

    // Basic auth password
    final legacyPass = settings.prometheusBasicAuthPassword;
    if (legacyPass != null && legacyPass.isNotEmpty) {
      final existing = await secure.getBasicAuthPassword();
      if (existing == null || existing.isEmpty) {
        await secure.setBasicAuthPassword(legacyPass);
      }
      await settings.clearLegacyPrometheusBasicAuthPassword();
      AppLogger.info(
          'Migrated Prometheus basic auth password to secure storage');
    }
  } catch (e) {
    // Migration failure is non-fatal - the legacy values remain in
    // SharedPreferences and will be migrated on the next launch.
    AppLogger.warning('Prometheus credential migration failed (non-fatal): $e');
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Standalone detached window - runs in a separate Dart isolate.
// Communicates with the main window via method channels for terminal I/O.
// ═══════════════════════════════════════════════════════════════════════

class _StandaloneDetachedWindow extends StatefulWidget {
  final String sessionId;
  final String connectionLabel;
  final int windowId;

  /// What the main window handed it of a person's settings: it reads none
  /// itself, as they are in the profile's database.
  final bool copyOnSelect;
  final String? shortcuts;

  const _StandaloneDetachedWindow({
    required this.sessionId,
    required this.connectionLabel,
    required this.windowId,
    required this.copyOnSelect,
    this.shortcuts,
  });

  @override
  State<_StandaloneDetachedWindow> createState() =>
      _StandaloneDetachedWindowState();
}

class _StandaloneDetachedWindowState extends State<_StandaloneDetachedWindow> {
  late final xterm.Terminal _terminal;
  late final xterm.TerminalController _controller;
  bool _connected = false;
  bool _reattachSent = false;
  // Copy-on-select (PuTTY style). This window runs in a SEPARATE isolate with
  // no Riverpod container: the main window hands it the setting.
  late bool _copyOnSelect;
  // The keys Settings binds copy and paste to (terminalKeys), handed as well.
  ShortcutBindings? _bindings;
  final _copyOnRelease = CopyOnRelease();
  // The session's output comes in pieces that can cut a character in two:
  // one decoder for all of it puts such a character together.
  final _utf8 = Utf8Chunks();

  @override
  void initState() {
    super.initState();
    _terminal = xterm.Terminal(maxLines: 5000);
    _controller = xterm.TerminalController();
    _copyOnSelect = widget.copyOnSelect;
    _bindings = ShortcutBindings.fromRaw(widget.shortcuts);
    // Forward keyboard input to the main window via method channel
    _terminal.onOutput = (data) => _sendInput(data);
    _setupMethodChannel();

    // Drain any terminal output that arrived before the widget was ready.
    // The initial method handler in _runSecondaryWindow buffers these.
    if (_earlyTerminalOutput.isNotEmpty) {
      for (final encoded in _earlyTerminalOutput) {
        final data = base64Decode(encoded);
        _terminal.write(_utf8.decode(data));
      }
      _earlyTerminalOutput.clear();
      _connected = true;
    }
  }

  /// PuTTY-style copy on highlight: when a drag-select finishes, copy the
  /// selection and clear the highlight. A mouse's alone, never at a right
  /// click's release ([CopyOnRelease]).
  void _maybeCopySelection(PointerUpEvent event) {
    if (!_copyOnRelease.up(event) || !_copyOnSelect) return;
    copySelectionAndClear(_terminal, _controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    // Notify the main window that this session should be reattached.
    // Guard against double-send if the close button already sent it.
    if (!_reattachSent) {
      _reattachSent = true;
      try {
        DesktopMultiWindow.invokeMethod(
          0, // main window
          'reattachSession',
          jsonEncode({'sessionId': widget.sessionId}),
        );
      } catch (e) {
        AppLogger.warning('Failed to send reattachSession on dispose: $e');
      }
    }
    super.dispose();
  }

  void _setupMethodChannel() {
    // This REPLACES the handler set in _runSecondaryWindow, so it must
    // handle ALL methods the child window needs (not just terminal I/O).
    //
    // This runs in a standalone child window (separate isolate on Windows),
    // so we must NOT call any singletons (MultiWindowService, WindowService)
    // that belong to the main window's isolate.
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      switch (call.method) {
        case 'terminalOutput':
          // Receive terminal output from main window
          final data = base64Decode(call.arguments as String);
          _terminal.write(_utf8.decode(data));
          if (!_connected && mounted) {
            setState(() => _connected = true);
          }

        case 'close':
          WindowController.fromWindowId(widget.windowId).close();

        case 'acceptSession':
        case 'requestReattach':
        default:
          // In the standalone child window we cannot forward to
          // MultiWindowService - it's a separate isolate with a fresh
          // empty singleton. Silently ignore unrecognized methods.
          break;
      }
      return '';
    });
  }

  void _sendInput(String data) {
    if (data.isEmpty) return;
    try {
      DesktopMultiWindow.invokeMethod(
        0, // main window
        'terminalInput',
        jsonEncode({
          'sessionId': widget.sessionId,
          'data': base64Encode(utf8.encode(data)),
        }),
      );
    } catch (e) {
      AppLogger.warning('Failed to send terminal input to main window: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // Title bar
          Container(
            height: 42,
            color: const Color(0xFF161619),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _connected ? Colors.green : Colors.orange,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.connectionLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(LucideIcons.x, size: 16),
                  color: Colors.white54,
                  tooltip: gl10n.mainAppCloseReturnToMain,
                  onPressed: () {
                    // Explicitly send reattach before closing so the
                    // main window gets notified even if dispose doesn't
                    // fire reliably on all platforms.
                    if (!_reattachSent) {
                      _reattachSent = true;
                      try {
                        DesktopMultiWindow.invokeMethod(
                          0, // main window
                          'reattachSession',
                          jsonEncode({'sessionId': widget.sessionId}),
                        );
                      } catch (_) {}
                    }
                    WindowController.fromWindowId(widget.windowId).close();
                  },
                ),
              ],
            ),
          ),
          // Terminal
          Expanded(
            child: _connected
                ? Listener(
                    onPointerDown: _copyOnRelease.down,
                    onPointerUp: _maybeCopySelection,
                    child: xterm.TerminalView(
                      _terminal,
                      controller: _controller,
                      autofocus: false,
                      // A terminal's own keys, as every terminal has them
                      // (terminalKeys); this window has no settings to ask
                      // with, so a paste goes in as it is.
                      shortcuts: terminalKeys(
                        paste: () => pasteClipboardAsIs(context, _terminal),
                        bindings: _bindings,
                        selected: () => _controller.selection != null,
                      ),
                      onKeyboardPaste: (text) => pasteTextAsIs(context, _terminal, text),
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                          color: AppColors.orangeLight,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          gl10n.mainAppConnectingToTerminal,
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
