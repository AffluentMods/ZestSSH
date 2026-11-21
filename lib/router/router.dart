import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart' show ImportFile;
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/features/onboarding/onboarding_screen.dart';
import 'package:zestssh/features/onboarding/lan_scan_screen.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/connection/qr_scan_screen.dart';
import 'package:zestssh/ui/screens/desktop/desktop_shell.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/providers/settings_providers.dart' show largeScreenLayoutProvider;
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/screens/identity/identity_list_screen.dart';
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/screens/security/lock_curtain.dart';
import 'package:zestssh/ui/screens/purchase/upgrade_screen.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/import/ssh_config_import_screen.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';
import 'package:zestssh/ui/screens/notifications/notifications_screen.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/session_logs_screen.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/settings/remote_screens_settings.dart';
import 'package:zestssh/ui/screens/settings/sftp_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart' show TeamPage;
import 'package:zestssh/ui/screens/terminal/mobile_split_terminal.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/session_swipe.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/profile/email_auth_screen.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show kEmailAuthCreate;
import 'package:zestssh/ui/screens/profile/recovery_key_screen.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/screens/monitoring/server_detail_screen.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/settings/about_screen.dart';
import 'package:zestssh/ui/screens/replay/session_replay_screen.dart';
import 'package:zestssh/ui/screens/settings/help_support_screen.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart';
import 'package:zestssh/ui/screens/help/guide_reader_screen.dart';
import 'package:zestssh/ui/screens/help/guides_screen.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/screens/help/ask_astryx_screen.dart';
import 'package:zestssh/providers/help_dock_provider.dart' show HubTab;
import 'package:zestssh/ui/screens/help/support_hub_screen.dart';
import 'package:zestssh/ui/screens/help/ticket_detail_screen.dart';
import 'package:zestssh/ui/screens/help/tickets_screen.dart';
import 'package:zestssh/ui/screens/sharing/share_view_screen.dart';
import 'package:zestssh/ui/screens/settings/known_hosts_screen.dart';
import 'package:zestssh/ui/screens/settings/sync_backend_screen.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/sftp_dual_pane_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_guide_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_history_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_wizard_screen.dart';
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/ui/screens/automation/workflow_list_screen.dart';
import 'package:zestssh/ui/screens/automation/workflow_editor_screen.dart';
import 'package:zestssh/ui/screens/help/ios_backgrounding_help_screen.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/ui/screens/transcripts/transcript_viewer_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcripts_screen.dart';
import 'package:zestssh/providers/desktop_providers.dart' show ConnectionEditorTarget;

/// A [Page] that shows its child as a centered dialog overlay on desktop.
///
/// Used by GoRouter so that routes like connection-edit and profile appear as
/// popup dialogs when navigated to on desktop (matching the behaviour of
/// their respective `showAdaptive` helpers).
class _DialogPage<T> extends Page<T> {
  final Widget child;
  final double widthFraction;
  final double heightFraction;
  final double maxWidth;
  final double minWidth;
  final double maxHeight;
  final double minHeight;

  const _DialogPage({
    required this.child,
    this.widthFraction = 0.55,
    this.heightFraction = 0.80,
    this.maxWidth = 700,
    this.minWidth = 480,
    this.maxHeight = 900,
    this.minHeight = 500,
    super.key,
  });

  @override
  Route<T> createRoute(BuildContext context) {
    return DialogRoute<T>(
      context: context,
      settings: this,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        final dialogWidth =
            (size.width * widthFraction).clamp(minWidth, maxWidth);
        final dialogHeight =
            (size.height * heightFraction).clamp(minHeight, maxHeight);
        return Dialog(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Notifier used to trigger GoRouter redirect re-evaluation without
/// recreating the entire router instance.
class _RouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Home: the computer's shell on a computer and on a phone's or a tablet's
/// large screen (4.0: [usesDesktopShell]), the phone's tabs on a
/// smaller one (a small tablet's too). Turning a tablet can change which: the
/// sessions, their tabs and the pages' state are the app's, not Home's, and
/// stay.
class AppHome extends ConsumerWidget {
  const AppHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // This device's choice for a large screen (4.1.1): changed in Settings,
    // Home is the other one at once.
    ref.watch(largeScreenLayoutProvider);
    return usesDesktopShell(context) ? const DesktopShell() : const HomeScreen();
  }
}

/// The terminal's page, for a session's id in [state].
Page<void> terminalPage(GoRouterState state) {
  final sessionId = state.pathParameters['sessionId']!;
  // On mobile/tablet, wrap with MobileSplitTerminal for split support.
  // On desktop, show TerminalScreen directly (desktop has its own tab system).
  final Widget screen =
      isDesktopPlatform ? TerminalScreen(sessionId: sessionId) : MobileSplitTerminal(primarySessionId: sessionId);
  final arguments = <String, String>{...state.pathParameters, ...state.uri.queryParameters};
  // A phone's session reached by a swipe on the top bar (3.1) slides in from
  // that side; every other way in is the page as it was.
  if (state.extra case final SessionSwipe swipe) {
    return SessionSwipePage(
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: arguments,
      restorationId: state.pageKey.value,
      direction: swipe.direction,
      sessionId: sessionId,
      child: screen,
    );
  }
  return MaterialPage<void>(
    key: state.pageKey,
    name: state.name ?? state.path,
    arguments: arguments,
    restorationId: state.pageKey.value,
    child: screen,
  );
}

/// The app-level GoRouter, provided via Riverpod.
final routerProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _RouterRefreshNotifier();

  // Listen (not watch) to trigger redirects without recreating router.
  ref.listen(isAppLockedProvider, (_, _) => refreshNotifier.notify());
  // Re-evaluate when the database opens/closes (1.8 encrypting lock): a locked
  // app shows only the unlock screen; unlocking opens the DB and flips this.
  ref.listen(dbReadyProvider, (_, _) => refreshNotifier.notify());
  // Re-evaluate the first-run gate when the saved-connection count changes
  // (e.g. the very first import/scan/add flips it out of onboarding). Safe
  // while locked: connectionCountProvider emits nothing until the DB opens.
  ref.listen(connectionCountProvider, (_, _) => refreshNotifier.notify());

  final router = GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      // "Locked" means the UI lock is engaged OR the database is not yet open
      // (1.8 encrypting lock: the DB only opens after the vault is unwrapped).
      // Either way the ONLY safe surface is the lock screen, which reads no DAO.
      // This check runs BEFORE the onboarding gate below so nothing touches the
      // database while db == null.
      final locked = ref.read(isAppLockedProvider) || !ref.read(dbReadyProvider);

      final isOnLockScreen = state.matchedLocation == Routes.securityLock;

      // If locked and not already on lock screen, redirect to lock
      if (locked && !isOnLockScreen) {
        return Routes.securityLock;
      }

      // If unlocked and on lock screen, redirect to home
      if (!locked && isOnLockScreen) {
        return Routes.home;
      }

      // ── First-run onboarding gate (F1) ───────────────────────────
      //
      // Show onboarding ONLY for a genuinely-new user: the completed-flag
      // is unset AND there are zero saved connections. An existing user who
      // updates the app (has connections, no flag) must NEVER be sent here.
      //
      // `count` is null while the count is still unknown (stream not yet
      // emitted). We only route TO onboarding once we KNOW it's zero, so an
      // existing user is never redirected on the strength of a not-yet-loaded
      // count. Onboarding is treated as complete if the flag is set OR any
      // connection exists.
      final settings = ref.read(settingsServiceProvider);
      final count = ref.read(connectionCountProvider).valueOrNull;
      final onboardingDone =
          settings.hasCompletedOnboarding || (count != null && count > 0);
      final isOnOnboarding = state.matchedLocation == Routes.onboarding;

      if (!onboardingDone && count == 0 && !isOnOnboarding) {
        return Routes.onboarding;
      }
      // Left onboarding behind (completed or a connection now exists) but
      // still sitting on the route - go home.
      if (isOnOnboarding && onboardingDone) {
        return Routes.home;
      }

      return null;
    },
    routes: [
      // ── Lock screen ──────────────────────────────────────────────
      // The curtain at the app's root draws the lock screen on its doors
      // (4.0): here, under it, only a backdrop, and none of the app's pages.
      GoRoute(
        path: Routes.securityLock,
        builder: (context, state) => const LockBackdrop(),
      ),

      // ── First-run onboarding (F1) ────────────────────────────────
      GoRoute(
        path: Routes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),

      // ── Home ─────────────────────────────────────────────────────
      GoRoute(
        path: Routes.home,
        builder: (context, state) => const AppHome(),
      ),

      // ── Connection edit ──────────────────────────────────────────
      GoRoute(
        path: Routes.connectionEdit,
        pageBuilder: (context, state) {
          // A new host of a kind its caller chose (a remote screen through
          // one of the hosts, 4.0).
          final target = state.extra is ConnectionEditorTarget ? state.extra as ConnectionEditorTarget : null;
          final screen = ConnectionEditScreen(
              initialProtocol: target?.initialProtocol,
              initialVia: target?.initialVia,
              initialHost: target?.initialHost,
              initialLabel: target?.initialLabel);
          if (isDesktopPlatform) {
            return _DialogPage(child: screen);
          }
          return MaterialPage(child: screen);
        },
      ),
      GoRoute(
        path: Routes.connectionEditId,
        pageBuilder: (context, state) {
          final id = state.pathParameters['id']!;
          final screen = ConnectionEditScreen(connectionId: id);
          if (isDesktopPlatform) {
            return _DialogPage(child: screen);
          }
          return MaterialPage(child: screen);
        },
      ),
      GoRoute(
        path: Routes.connectionScanQr,
        builder: (context, state) => const QrScanScreen(),
      ),

      // ── Identity management ──────────────────────────────────────
      GoRoute(
        path: Routes.identityList,
        builder: (context, state) => const IdentityListScreen(),
      ),
      GoRoute(
        path: Routes.identityEdit,
        pageBuilder: (context, state) {
          // Optional pre-loaded key from an external import entry point
          // (Settings > Import PuTTY Keys converts the .ppk, then routes here).
          final imported =
              state.extra is InitialImportedKey ? state.extra as InitialImportedKey : null;
          final screen = IdentityEditScreen(initialImportedKey: imported);
          if (isDesktopPlatform) {
            return _DialogPage(child: screen);
          }
          return MaterialPage(child: screen);
        },
      ),
      GoRoute(
        path: Routes.identityEditId,
        pageBuilder: (context, state) {
          final id = state.pathParameters['id']!;
          final screen = IdentityEditScreen(identityId: id);
          if (isDesktopPlatform) {
            return _DialogPage(child: screen);
          }
          return MaterialPage(child: screen);
        },
      ),
      GoRoute(
        path: Routes.keyGeneration,
        builder: (context, state) => const KeyGenerationScreen(),
      ),

      // ── Terminal ─────────────────────────────────────────────────
      GoRoute(
        path: Routes.terminal,
        pageBuilder: (context, state) => terminalPage(state),
      ),

      // ── Settings ─────────────────────────────────────────────────
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),

      // ── Appearance ────────────────────────────────────────────────
      GoRoute(
        path: Routes.appearance,
        builder: (context, state) => const AppearanceScreen(),
      ),

      // ── Purchase / Upgrade ────────────────────────────────────────
      GoRoute(
        path: Routes.upgrade,
        builder: (context, state) => const UpgradeScreen(),
      ),

      // ── Security ─────────────────────────────────────────────────
      GoRoute(
        path: Routes.pinSetup,
        builder: (context, state) => const PinSetupScreen(),
      ),

      // ── SSH Config Import ─────────────────────────────────────────
      GoRoute(
        path: Routes.sshConfigImport,
        // extra true: straight to choosing the file (the Termius guide); a
        // file: that one, chosen under Import a file.
        builder: (context, state) => SshConfigImportScreen(
          pickFile: state.extra == true,
          file: state.extra is ImportFile ? state.extra as ImportFile : null,
        ),
      ),

      // ── Local network scan (F1) ───────────────────────────────────
      GoRoute(
        path: Routes.lanScan,
        builder: (context, state) => const LanScanScreen(),
      ),

      // ── PuTTY Registry Import ──────────────────────────────────────
      GoRoute(
        path: Routes.puttyImport,
        builder: (context, state) => const PuttyImportScreen(),
      ),

      // ── Snippets ──────────────────────────────────────────────────
      GoRoute(
        path: Routes.snippets,
        // The setup guide, New snippet and the menu in the bar, the search
        // alone under it.
        builder: (context, state) => const SnippetsPhoneScreen(),
      ),

      // ── Keys and Port forwarding: a phone's Manage tab (3.1), a
      // tablet's More tab (3.0 UI) ──────────────────────────
      GoRoute(
        path: Routes.keys,
        pageBuilder: (context, state) => manageSectionPage(context, state, ManageSection.keys),
      ),
      GoRoute(
        path: Routes.portForwards,
        pageBuilder: (context, state) => manageSectionPage(context, state, ManageSection.portForwards),
      ),
      GoRoute(
        path: Routes.team,
        builder: (context, state) => const TeamPhoneScreen(),
      ),
      GoRoute(
        path: Routes.teamPage,
        builder: (context, state) => TeamPhonePageScreen(
          page: TeamPage.values.where((p) => p.name == state.pathParameters['page']).firstOrNull ??
              TeamPage.overview,
        ),
      ),

      // ── Networks (mobile) ────────────────────────────────────────
      // Desktop reaches Networks through the DesktopShell's sidebar
      // (NetworksPage in a split view); these routes are the mobile
      // surface - a full-screen list and a full-route editor.
      GoRoute(
        path: Routes.networks,
        builder: (context, state) => const NetworksMobileScreen(),
      ),
      GoRoute(
        path: Routes.networkEditId,
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return NetworkEditorRoutePage(networkId: id);
        },
      ),

      // ── Profile / Cloud Sync ────────────────────────────────────
      GoRoute(
        path: Routes.profile,
        pageBuilder: (context, state) {
          const screen = ProfileScreen();
          if (isDesktopPlatform) {
            return const _DialogPage(
              child: screen,
              widthFraction: 0.45,
              maxWidth: 520,
              minWidth: 380,
              maxHeight: 700,
              minHeight: 400,
              heightFraction: 0.75,
            );
          }
          return const MaterialPage(child: screen);
        },
      ),

      // ── Recovery Key ──────────────────────────────────────────────
      GoRoute(
        path: Routes.recoveryKey,
        builder: (context, state) => RecoveryKeyScreen(
          mode: state.extra is RecoveryKeyMode ? state.extra as RecoveryKeyMode : RecoveryKeyMode.setup,
        ),
      ),
      GoRoute(
        path: Routes.emailAuth,
        builder: (context, state) => EmailAuthScreen(createAccount: state.extra == kEmailAuthCreate),
      ),

      // ── Sync storage (bring-your-own backend) ─────────────────────
      GoRoute(
        path: Routes.syncBackend,
        builder: (context, state) => const SyncBackendScreen(),
      ),

      // ── Notifications (mobile history) ────────────────────────────
      GoRoute(
        path: Routes.notifications,
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: Routes.notificationSettings,
        builder: (context, state) => const NotificationSettingsScreen(),
      ),
      GoRoute(
        path: Routes.setupGuide,
        builder: (context, state) => SetupGuideScreen(
          topic: state.extra is SetupTopic
              ? state.extra as SetupTopic
              : SetupTopic.automation,
        ),
      ),
      GoRoute(
        path: Routes.terminalSettings,
        builder: (context, state) => const TerminalSettingsScreen(),
      ),
      GoRoute(
        path: Routes.keyboardRow,
        builder: (context, state) => const KeyboardRowScreen(),
      ),
      GoRoute(
        path: Routes.sessionLogs,
        builder: (context, state) => const SessionLogsScreen(),
      ),
      GoRoute(
        path: Routes.sftpSettings,
        builder: (context, state) => const SftpSettingsScreen(),
      ),
      GoRoute(
        path: Routes.screenSettings,
        builder: (context, state) => const RemoteScreensSettingsScreen(),
      ),
      GoRoute(
        path: Routes.automationSettings,
        builder: (context, state) => const AutomationSettingsScreen(),
      ),
      GoRoute(
        path: Routes.dataSettings,
        builder: (context, state) => const DataSettingsScreen(),
      ),

      // ── Server Monitor ────────────────────────────────────────────
      GoRoute(
        path: Routes.monitor,
        builder: (context, state) => const ServerMonitorScreen(),
      ),
      GoRoute(
        path: Routes.serverDetail,
        builder: (context, state) {
          final connectionId = state.pathParameters['connectionId']!;
          final extra = state.extra as Map<String, dynamic>? ?? {};
          return ServerDetailScreen(
            connectionId: connectionId,
            serverName: extra['serverName'] as String? ?? '',
            host: extra['host'] as String? ?? '',
            port: extra['port'] as int? ?? 22,
          );
        },
      ),

      // ── About ────────────────────────────────────────────────────────
      GoRoute(
        path: Routes.about,
        builder: (context, state) => const AboutScreen(),
      ),

      // ── Help & Support ────────────────────────────────────────────
      GoRoute(
        path: Routes.help,
        builder: (context, state) => const HelpSupportScreen(),
      ),

      // ── Help > Guides: the search over the guides, and one guide ──
      GoRoute(
        path: Routes.guides,
        builder: (context, state) => GuidesScreen(
          onOpen: (slug) => context.push(Routes.guide, extra: slug),
        ),
      ),
      GoRoute(
        path: Routes.guide,
        builder: (context, state) => GuideReaderScreen(
          slug: state.extra is String ? state.extra as String : '',
          onOpenGuide: (slug) => context.push(Routes.guide, extra: slug),
        ),
      ),

      // ── In-app report (bug / suggestion / question) ───────────────
      GoRoute(
        path: Routes.report,
        builder: (context, state) => ReportIssueScreen(
          initialType:
              state.extra is FeedbackType ? state.extra as FeedbackType : null,
        ),
      ),

      // ── Tickets: what was sent to support, and the answers ────────
      GoRoute(
        path: Routes.tickets,
        builder: (context, state) => TicketsScreen(
          onOpen: (nonce) => context.push(Routes.ticket, extra: nonce),
          onContactSupport: () => context.push(Routes.contactSupport),
        ),
      ),
      GoRoute(
        path: Routes.ticket,
        builder: (context, state) => TicketDetailScreen(
          nonce: state.extra is String ? state.extra as String : '',
          onLeave: () => context.pop(),
          onNewTicket: () => context.pushReplacement(Routes.contactSupport),
        ),
      ),
      // ── The Support Hub (3.4): My tickets, Known issues, Ideas ────
      GoRoute(
        path: Routes.supportHub,
        builder: (context, state) => SupportHubScreen(
          tab: state.extra is HubTab ? state.extra as HubTab : null,
          onClose: () => context.pop(),
        ),
      ),
      // Ask Astryx (4.0): "Open a ticket with this" fills the support form in.
      GoRoute(
        path: Routes.askAstryx,
        builder: (context, state) => AskAstryxScreen(
          onOpenTicket: () => context.push(Routes.contactSupport),
          onSearchGuides: () => context.push(Routes.guides),
          onContactSupport: () => context.push(Routes.contactSupport),
          onOpenGuide: (slug) => context.push(Routes.guide, extra: slug),
        ),
      ),
      GoRoute(
        path: Routes.contactSupport,
        builder: (context, state) => ContactSupportScreen(
          // Sent (or kept to be sent): its own page takes the form's place.
          onDone: (nonce) =>
              context.pushReplacement(Routes.ticket, extra: nonce),
        ),
      ),

      // ── A live view of someone else's session (3.0, session sharing) ──
      GoRoute(
        path: Routes.shareView,
        builder: (context, state) => ShareViewScreen(
          shareId: state.extra is String ? state.extra as String : '',
          onLeave: () => context.pop(),
        ),
      ),

      // ── Known Hosts ────────────────────────────────────────────────
      GoRoute(
        path: Routes.knownHosts,
        builder: (context, state) => const KnownHostsScreen(),
      ),

      // ── Triggers (trigger / highlight rules) ──────────────────────
      GoRoute(
        path: Routes.triggers,
        builder: (context, state) => const TriggersScreen(),
      ),

      // ── Command History ───────────────────────────────────────────
      GoRoute(
        path: Routes.commandHistory,
        builder: (context, state) => const CommandHistoryScreen(),
      ),

      // ── Saved transcripts ─────────────────────────────────────────
      GoRoute(
        path: Routes.transcripts,
        builder: (context, state) => const TranscriptsScreen(),
      ),
      GoRoute(
        path: Routes.transcriptView,
        builder: (context, state) {
          final path = state.extra;
          return path is String ? TranscriptViewerScreen(path: path) : const TranscriptsScreen();
        },
      ),

      // ── Session Replay ────────────────────────────────────────────
      GoRoute(
        path: Routes.replay,
        builder: (context, state) {
          final data = state.extra as SessionReplayData;
          return SessionReplayScreen(data: data);
        },
      ),

      // ── Remote-to-Remote SFTP ────────────────────────────────────
      GoRoute(
        path: Routes.sftpRemote,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          // Remote↔remote is now served by the unified SftpDualPaneScreen
          // (seeded with a remote on BOTH sides) so it inherits the full
          // reference surface; the old SftpRemoteDualPaneScreen was retired.
          return SftpDualPaneScreen(
            leftSftp: extra['leftSftp'] as SftpService,
            leftLabel: extra['leftLabel'] as String,
            sftp: extra['rightSftp'] as SftpService,
            connectionLabel: extra['rightLabel'] as String,
          );
        },
      ),

      // ── Text Editor ───────────────────────────────────────────────
      GoRoute(
        path: Routes.editor,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return TextEditorScreen(
            fileName: extra?['fileName'] as String? ?? 'untitled',
            initialContent: extra?['content'] as String? ?? '',
            onSave: extra?['onSave'] as Future<void> Function(String)?,
          );
        },
      ),

      // ── Automation ──────────────────────────────────────────────
      GoRoute(
        path: Routes.automationGuide,
        builder: (context, state) => const AutomationGuideScreen(),
      ),
      GoRoute(
        path: Routes.automationHistory,
        builder: (context, state) => const AutomationHistoryScreen(),
      ),
      GoRoute(
        path: Routes.automationWizard,
        builder: (context, state) => const AutomationWizardScreen(),
      ),

      // ── Scheduled Tasks ──────────────────────────────────────────
      GoRoute(
        path: Routes.scheduledTasks,
        builder: (context, state) => const ScheduledTasksScreen(),
      ),

      // ── Workflows ─────────────────────────────────────────────────
      GoRoute(
        path: Routes.workflowList,
        builder: (context, state) => const WorkflowListScreen(),
      ),
      GoRoute(
        path: Routes.workflowEditor,
        builder: (context, state) {
          final workflow = state.extra as Workflow?;
          return WorkflowEditorScreen(workflow: workflow);
        },
      ),

      // ── iOS Backgrounding Help ──────────────────────────────────
      GoRoute(
        path: Routes.iosBackgrounding,
        builder: (context, state) => const IosBackgroundingHelpScreen(),
      ),
    ],
    // Clear of a phone's status and navigation bars, as every page (this one
    // has no bar of its own).
    errorBuilder: (context, state) => Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.alertCircle, size: 48, color: Colors.white38),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context)!.routerErrPageNotFound,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go(Routes.home),
                child: Text(AppLocalizations.of(context)!.routerErrGoHome),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  ref.onDispose(router.dispose);
  return router;
});
