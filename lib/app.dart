import 'dart:async';
import 'dart:io';

import 'package:zestssh/ui/widgets/fido_prompt_sheet.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart' show editorDraftSweepProvider;
import 'package:zestssh/ui/widgets/browser_sign_in_help.dart';
import 'package:zestssh/ui/widgets/sign_in_again.dart' show refreshSignIn;
import 'package:zestssh/services/store_handover_start.dart';
import 'package:zestssh/services/review_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:zestssh/ui/screens/sync/cloud_device_room.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/automation/automation_link_question.dart' show answerAutomationLinks;
import 'package:zestssh/features/orchards/widgets/team_host_commands_question.dart' show answerTeamCommandRequests;
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/rules/reveal_gate.dart' show answerConfirmItIsYouRequests;
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart' show answerPassAskRequests;
import 'package:zestssh/features/orchards/widgets/join_team.dart' show answerJoinLink;
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/ui/widgets/idle_lock_watcher.dart';
import 'package:zestssh/ui/screens/security/lock_curtain.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/tab_focus_traversal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show PointerInputTracker;
import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/services/sync/sync_network.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/ui/screens/sync/stale_reconcile_dialog.dart';
import 'package:zestssh/ui/screens/sync/sync_now.dart';
import 'package:zestssh/features/tickets/ticket_poller.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/notification_permission_provider.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/services/account/device_approval_alerts.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/signed_out_notice.dart';
import 'package:zestssh/services/account/lockout_watch.dart';
import 'package:zestssh/services/account/two_step.dart' show SecondStepPasskeys;
import 'package:zestssh/services/account/two_step_api.dart' show securityNudges, TwoStepRefusal;
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart' show ItsYou, confirmOrSignIn;
import 'package:zestssh/ui/screens/profile/profile_screen.dart' show ProfileScreen;
import 'package:zestssh/providers/two_step_providers.dart' show addPasskeyRequestProvider, signedInAccountUid, twoStepApiProvider;
import 'package:zestssh/ui/screens/profile/widgets/two_step_section.dart' show kLockoutNoticeId;
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart' show dayWords, twoStepProblem;
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart';
import 'package:zestssh/providers/locale_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/ui/screens/sharing/share_app_hooks.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart' show ScheduledTasksHere, computerTaskSchedulerProvider, scheduledTasksHere;
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/sync/kept_sync.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart';
import 'package:zestssh/router/link_pages.dart';
import 'package:zestssh/router/router.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/auto_backup_service.dart';
import 'package:zestssh/providers/backup_dirty_watch.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';
import 'package:zestssh/providers/backup_destination_providers.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/providers/cert_reminder_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/monitor_alert_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/jump_host_gate_notice.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/features/screens/session/screen_background.dart';
import 'package:zestssh/features/screens/window/screen_windows_recording.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/tray_service.dart';
import 'package:zestssh/services/window_service.dart';
import 'package:zestssh/ui/screens/desktop/app_closing.dart' show ClosingPanel, closeWithoutShell;
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart' show SupportTicketRow;
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/services/deep_link_service.dart';
import 'package:zestssh/services/keep_awake_controller.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/config/official_identity.dart' show zestHasCloud;
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/services/policy_notice_service.dart';
import 'package:zestssh/ui/screens/connection/share_link_add.dart' show addShareLinkHost;
import 'package:zestssh/ui/widgets/app_notices.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/features/automation/automation_refusals.dart' show sayAutomationRefusals;
import 'package:zestssh/ui/screens/terminal/phone_sign_in_questions.dart' show PhoneSignInQuestions;
import 'package:zestssh/features/hosts/connect_link.dart';
import 'package:zestssh/services/widget_service.dart';
import 'package:zestssh/services/task_scheduler_service.dart';
import 'package:zestssh/services/windows_titlebar_theme.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/leftover_copies.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/pointer_recovery.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/link_gate.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart' show keychainDenials;
import 'package:zestssh/services/profiles/profile_manager.dart' show DataElsewhere, DataElsewhereKind;
import 'package:zestssh/ui/widgets/mac_keychain_notice.dart';
import 'package:zestssh/ui/screens/profile/widgets/older_version_data_dialog.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/ui/screens/profile/widgets/guest_data_question.dart';
import 'package:zestssh/services/background_polling.dart';
import 'package:zestssh/utils/after_next_frame.dart';

/// Root widget for ZestSSH.
///
/// Sets up [MaterialApp.router] with the orange-on-dark theme
/// and GoRouter navigation with security lock redirect.
/// Builds every widget on screen again: for what reads the theme's colours
/// directly (AppColors, ZestTokens) rather than through the context, after
/// the theme changed.
@visibleForTesting
void rebuildEverything() {
  void mark(Element element) {
    element.markNeedsBuild();
    element.visitChildren(mark);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(mark);
}

class ZestSSHApp extends ConsumerStatefulWidget {
  const ZestSSHApp({super.key});

  @override
  ConsumerState<ZestSSHApp> createState() => _ZestSSHAppState();
}

class _ZestSSHAppState extends ConsumerState<ZestSSHApp>
    with WidgetsBindingObserver {
  /// The theme the app was last built with (its rebuild key), to see a change.
  String? _shownTheme;

  StreamSubscription<Uri>? _deepLinkSub;
  StreamSubscription<void>? _unreadableLinkSub;

  /// Links answered once the app is unlocked ([LinkGate]).
  late final _linkGate = LinkGate(locked: () => ref.read(isAppLockedProvider), answer: _answerDeepLink);
  ProviderSubscription<bool>? _unlockedSub;

  /// Drives change-based auto-sync: fires on every local DB write.
  StreamSubscription<void>? _dbChangeSub;

  /// The device's network, as the service that knows how ZestSSH Cloud
  /// stands hears of it ([_tieCloudReach]); set once, for as long as the
  /// app runs.
  StreamSubscription<bool>? _reachNetworkSub;

  /// Ends what keeps the checks of whether hosts can be reached to Settings
  /// and to the sessions there are (wireReachabilityChecks); set once, as
  /// the app starts.
  void Function()? _reachabilityWiring;

  /// Asks how the tickets on this device stand, while the database is open
  /// (see [TicketPoller]). Null while the app is locked.
  TicketPoller? _ticketPoller;

  /// Held so we can remove the syncError listener in dispose().
  AutoSyncService? _autoSync;

  /// Says that macOS did not let ZestSSH read a saved key (3.3.2), on a Mac.
  MacKeychainNotice? _keychainNotice;

  /// De-dup guard so a repeating sync error posts one toast, not a stack.
  bool _syncErrorShown = false;
  bool _clockSkewShown = false;

  void _onSyncError() {
    final sync = _autoSync;
    if (sync == null || sync.syncError.value == null) {
      _syncErrorShown = false;
      return;
    }
    if (_syncErrorShown || !mounted) return;
    // In the app's language, with what stands behind it to copy (the title
    // was English, and nothing could be copied), and with "Sync now" where
    // that is the way out (lib/ui/screens/sync/sync_now.dart).
    _syncErrorShown = showSyncPausedNotice(
      sync,
      ref.read(notificationCenterProvider.notifier),
      onSyncNow: () => requestAccountSyncNow(ref.read(accountSyncNowRequestProvider.notifier)),
      onMakeRoom: () {
        final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
        if (context != null) unawaited(showCloudDeviceRoom(context));
      },
    );
  }

  /// A notice's "Sync now" asked for the account page's own Sync now: opened
  /// here, where there is always a screen to open it from, unless an account
  /// page already on screen has taken the request (it takes it at once, so
  /// this looks a moment later).
  void _onAccountSyncNowAsked(bool? before, bool asked) {
    if (!asked) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (context != null) openAccountForSyncNow(context, ref);
    });
  }

  /// Surface a host-key DISAGREEMENT between devices found during a sync (one
  /// device may have been MITM'd). It is never auto-merged; this warns.
  void _onHostKeyConflict() {
    final hosts = _autoSync?.hostKeyConflict.value;
    if (hosts == null || hosts.isEmpty) return;
    if (!mounted) return;
    _autoSync?.hostKeyConflict.value = null;
    ref.read(notificationCenterProvider.notifier).warning(
          gl10n.syncHostKeyConflictTitle,
          // (The hosts, masked in recording mode; they were shown as they are.)
          body: gl10n.syncHostKeyConflictBody(Redactable.freeText(hosts).displayIn(ref)),
          dismissAfter: const Duration(seconds: 14),
        );
  }

  /// Says that the sync store gave this device an old copy of the account's
  /// data (a cryptography audit found it said nothing, and
  /// every item unchanged here went back to that copy).
  void _onStoreWentBack() {
    if (!mounted) return;
    ref.read(notificationCenterProvider.notifier).warning(
          gl10n.syncStoreWentBackTitle,
          body: gl10n.syncStoreWentBackBody,
          dismissAfter: const Duration(seconds: 14),
        );
  }

  /// Warn once when this device's clock is far enough off the sync server that
  /// newest-wins conflict resolution could pick the wrong version.
  void _onClockSkew() {
    final skew = _autoSync?.clockSkew.value;
    if (skew == null) {
      _clockSkewShown = false;
      return;
    }
    if (_clockSkewShown || !mounted) return;
    _clockSkewShown = true;
    final mins = skew.inMinutes.abs();
    ref.read(notificationCenterProvider.notifier).warning(
          gl10n.syncClockWrongTitle,
          body: skew.isNegative ? gl10n.syncClockBehind(mins) : gl10n.syncClockAhead(mins),
          dismissAfter: const Duration(seconds: 12),
        );
  }

  /// Stale-device reconcile prompt. A device offline longer than the tombstone
  /// retention window asks before it merges (and would resurrect) rows the
  /// cloud has already deleted-and-forgotten. Resolves the user's choice back
  /// to the sync cycle. No UI context (very early launch) resolves to cancel,
  /// which pauses that cycle safely - nothing is resurrected unattended.
  Future<StaleReconcileChoice> _onStaleReconcile(
      StaleReconcileReport report) async {
    final context =
        ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
    if (context == null || !mounted) return StaleReconcileChoice.cancel;
    return showStaleReconcileDialog(
      context,
      report: report,
      lastSync: ref.read(settingsServiceProvider).lastSyncTime,
    );
  }

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  bool _startupRan = false;
  ProviderSubscription<bool>? _dbReadySub;
  ProviderSubscription<UserProfile?>? _accountSub;
  ProviderSubscription<int>? _teamsSub;
  DateTime? _entitlementsAskedAt;
  ProviderSubscription<bool>? _accountSyncNowSub;
  bool _handlingSignedOutElsewhere = false;
  StreamSubscription<String>? _approvalNudges;
  StreamSubscription<void>? _securityNudges;

  /// Someone asked to recover this account (3.3, the two-step contract,
  /// section 6.5): said here, wherever the person is, with "This wasn't
  /// me" one tap away, on every signed-in device.
  late final _lockoutWatch = LockoutRecoveryWatch(
    api: () => ref.read(twoStepApiProvider),
    tell: (waiting) => ref.read(notificationCenterProvider.notifier).show(AppNotification(
          id: kLockoutNoticeId,
          title: gl10n.lockoutWaitingTitle,
          body: gl10n.lockoutNoticeBody(dayWords(gl10n, waiting.completesAt)),
          severity: NotificationSeverity.error,
          actionLabel: gl10n.lockoutNotMe,
          onAction: _lockoutNotMe,
        )),
    clear: () => ref.read(notificationCenterProvider.notifier).remove(kLockoutNoticeId),
  );

  /// "This wasn't me" from the notice: the recovery ends at once, with no
  /// new sign-in, and the person is told what to do next.
  Future<void> _lockoutNotMe() async {
    final center = ref.read(notificationCenterProvider.notifier);
    try {
      final cancelled = await ref.read(twoStepApiProvider).cancelLockoutRecovery();
      center.remove(kLockoutNoticeId);
      center.success(cancelled ? gl10n.lockoutCancelledTitle : gl10n.lockoutNothingWaitingTitle,
          body: cancelled ? gl10n.lockoutCancelled : gl10n.lockoutNothingWaiting);
    } catch (e) {
      final problem = twoStepProblem(gl10n, e);
      center.error(gl10n.lockoutNotCancelled,
          body: problem.text, details: e is TwoStepRefusal ? e.shownCode : '$e');
    }
  }

  /// A new device of this account asks for the sync key (3.0):
  /// said here, with the approval one tap away, when this device holds
  /// the key on ZestSSH Cloud.
  late final _approvalAlerts = DeviceApprovalAlerts(
    api: () => ref.read(deviceApprovalsApiProvider),
    canApprove: () async =>
        kOrchardsEnabled &&
        // (Known to be ZestSSH Cloud: not while the store could not be read.)
        ref.read(syncStoreKnownHostedProvider) &&
        await ref.read(syncSetupStateServiceProvider).isSyncActive(),
    tell: (request) => ref.read(notificationCenterProvider.notifier).show(AppNotification(
          id: 'device-approval-${request.id}',
          title: gl10n.approveWho(request.name),
          body: gl10n.approveAlertBody,
          severity: NotificationSeverity.warning,
          actionLabel: gl10n.approveAlertAction,
          onAction: () {
            final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
            if (context != null) unawaited(showApproveNewDevice(context));
          },
        )),
  );

  /// Signed-in devices (3.0): whenever an account signs in, or the
  /// app starts signed in, this device makes sure it is in the account's
  /// device list with current labels.
  void _watchAccountForDeviceList() {
    _accountSub = ref.listenManual<UserProfile?>(currentUserProvider,
        (prev, next) {
      if (next == null) {
        _accountArrivedFor = null;
        DeviceSessionHeader.current = null;
        _lockoutWatch.forget();
        return;
      }
      if (prev?.uid == next.uid) return;
      _accountArrived(next);
    }, fireImmediately: true);
    sessionRevokedSignal.addListener(_onSignedOutElsewhere);
    sessionExpiredSignal.addListener(_onSessionExpired);
    // What the account has is asked again whenever its teams change: a
    // paid team's seat gives Squeezed and Juiced, and the rail's Upgrade
    // stayed until a restart after joining one;
    // leaving or being removed takes them away as promptly.
    _teamsSub = ref.listenManual<int>(orchardListVersionProvider, (prev, next) {
      if (prev != next) _askEntitlements();
    });
    _approvalNudges = deviceApprovalNudges.stream.listen((id) => unawaited(_approvalAlerts.heard(id)));
    _securityNudges = securityNudges.stream.listen((_) {
      if (ref.read(currentUserProvider) != null) unawaited(_lockoutWatch.check(now: true));
    });
    _shareHooks.start();
    _accountSyncNowSub = ref.listenManual<bool>(accountSyncNowRequestProvider, _onAccountSyncNowAsked);
    _reauthRequestSub = ref.listenManual<({int n, bool signInOnly})>(reauthSignInRequestProvider, (prev, next) {
      if (prev?.n != next.n) unawaited(_signInAgainForTeams(signInOnly: next.signInOnly));
    });
    _addPasskeyRequestSub = ref.listenManual<int>(addPasskeyRequestProvider, (prev, next) {
      if (prev == next) return;
      final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (context != null && context.mounted) unawaited(ProfileScreen.openAccount(context, ref));
    });
  }

  String? _accountArrivedFor;

  /// The account signed in is at work on this device. On a computer that waits
  /// for its profile, as what is written here is its: a Mac's Firebase sign-in
  /// comes before its profile opens, and the opening comes back here.
  void _accountArrived(UserProfile account) {
    if (_accountArrivedFor == account.uid) return;
    // Nor with the database closed: what is kept reads as none then. It comes back
    // here as the profile opens.
    if (Profiles.on && (Profiles.current?.uid != account.uid || SecretSeal.openTree == null)) return;
    _accountArrivedFor = account.uid;
    unawaited(ref.read(deviceSessionServiceProvider).ensure());
    unawaited(_syncAtEndOfSignIn());
    // A recovery of the account someone asked for, said at once.
    _lockoutWatch.forget();
    unawaited(_lockoutWatch.check(now: true));
  }

  ProviderSubscription<({int n, bool signInOnly})>? _reauthRequestSub;
  ProviderSubscription<int>? _addPasskeyRequestSub;

  /// The notice that a team's Sign-in lasts is about to run out: signs in again
  /// where the person is, or a passkey's tap where it counts for that team
  /// (from a security review), and the teams sync with it.
  Future<void> _signInAgainForTeams({bool signInOnly = false}) async {
    final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final shown = await confirmOrSignIn(
      context,
      ref,
      about: gl10n.stepUpReauthBody,
      sayWindow: false,
      askFirst: false,
      signInOnly: signInOnly,
      wrongAccount: gl10n.orchardSignInWrongAccount,
    );
    if (shown != ItsYou.confirmed || !mounted) return;
    unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
  }

  bool _syncAtEndOfSignInRunning = false;

  /// The end of a sign-in, and of a start where one was not finished: the sync
  /// this device kept through a sign-out nobody asked for comes back by itself;
  /// else an account that syncs on ZestSSH Cloud is asked, once, to bring this
  /// device back in (syncAfterSignIn). While the database
  /// is closed nothing can be read: its opening comes back here.
  Future<void> _syncAtEndOfSignIn() async {
    if (_syncAtEndOfSignInRunning || !mounted || !ref.read(dbReadyProvider)) return;
    _syncAtEndOfSignInRunning = true;
    try {
      await SignInChange.settled();
      if (!mounted) return;
      final user = ref.read(currentUserProvider);
      if (user == null) return;
      final uid = await signedInAccountUid(user, ref.read(secureStorageProvider));
      if (uid == null || !mounted) return;
      await ref.read(syncProviderConfigProvider.notifier).ensureLoaded();
      if (!mounted) return;
      final next = await syncAfterSignIn(
        uid: uid,
        kept: ref.read(keptSyncProvider),
        setup: ref.read(syncSetupStateServiceProvider),
        settings: ref.read(settingsServiceProvider),
        backend: () => ref.read(syncBackendProvider),
      );
      if (!mounted) return;
      switch (next) {
        case SyncAfterSignIn.nothing:
          break;
        case SyncAfterSignIn.resumed:
          ref.read(autoSyncServiceProvider).startAutoSync();
          ref.read(notificationCenterProvider.notifier).success(gl10n.syncResumedTitle, body: gl10n.syncResumedBody);
        case SyncAfterSignIn.ask:
          _askToTurnSyncOn();
      }
    } catch (e) {
      AppLogger.warning('Sync at the end of a sign-in: $e');
    } finally {
      _syncAtEndOfSignInRunning = false;
    }
  }

  void _tellStoreHandover() {
    final notice = takeStoreHandoverNotice();
    final setAside = takeStoreHandoverSetAside();
    if ((notice == null && setAside == null) || !mounted) return;
    final center = ref.read(notificationCenterProvider.notifier);
    // A notice's title holds 120 characters: the words go under a short one.
    final title = gl10n.storeHandoverNoticeTitle;
    // What the person chose not to keep, and where it is until it goes.
    if (setAside != null) center.info(title, body: gl10n.storeHandoverSetAside(setAside.join(', ')));
    switch (notice) {
      case null:
        break;
      case StoreHandoverNotice.removed:
        center.success(title, body: gl10n.storeHandoverRemoved);
      case StoreHandoverNotice.removedKeptStore:
        center.success(title, body: gl10n.storeHandoverRemovedKeptStore);
      case StoreHandoverNotice.forAllAccounts:
        center.info(title, body: gl10n.storeHandoverForAllAccounts);
      case StoreHandoverNotice.notRemoved:
        center.warning(title, body: gl10n.storeHandoverNotRemoved);
      case StoreHandoverNotice.openWebsiteOnce:
        center.info(title, body: gl10n.storeHandoverOpenWebsiteOnce);
      case StoreHandoverNotice.storeCopyOlder:
        center.info(title, body: gl10n.storeHandoverStoreCopyOlder);
    }
  }

  /// Asks for the sync password on the account page, or, where that would
  /// open over a dialog or the welcome (a sign-in that is part of joining a
  /// team, or of the first start), says so in a notice with the same way on.
  void _askToTurnSyncOn() {
    final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
    if (context != null && ref.read(settingsServiceProvider).hasCompletedOnboarding && !_popupOnTop(context)) {
      _requestTurnSyncOn();
      return;
    }
    ref.read(notificationCenterProvider.notifier).show(AppNotification(
          id: 'turn-sync-on',
          title: gl10n.syncTurnOnTitle,
          body: gl10n.syncTurnOnNotice,
          severity: NotificationSeverity.info,
          actionLabel: gl10n.syncTurnOnAction,
          onAction: _requestTurnSyncOn,
        ));
  }

  bool _popupOnTop(BuildContext context) {
    Route<dynamic>? top;
    Navigator.of(context, rootNavigator: true).popUntil((route) {
      top = route;
      return true;
    });
    return top is PopupRoute;
  }

  /// Asks the account page to ask for the sync password (one on screen takes
  /// it at once), and opens the page where none is.
  void _requestTurnSyncOn() {
    final request = ref.read(accountTurnSyncOnRequestProvider.notifier);
    request.state = false;
    request.state = true;
    scheduleMicrotask(() {
      if (!mounted) return;
      final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (context != null) openAccountForTurnSyncOn(context, ref);
    });
  }

  /// Where the app is at as it closes from the lock screen ([closeWithoutShell]).
  final _closingWithoutShell = ValueNotifier<String?>(null);
  bool _closeWithoutShellRunning = false;

  /// The window's close and the tray's Quit while the shell is not there.
  Future<void> _closeNoShell({bool quit = false}) async {
    if (_closeWithoutShellRunning || !mounted) return;
    _closeWithoutShellRunning = true;
    try {
      await closeWithoutShell(
        ref,
        step: _closingWithoutShell,
        l10n: gl10n,
        question: () => ref.read(routerProvider).routerDelegate.navigatorKey.currentContext,
        quit: quit,
      );
    } finally {
      _closeWithoutShellRunning = false;
    }
  }

  /// Session sharing (3.0): invitations as they come, the notices of a
  /// share, and the end of everything shared when the account signs out.
  late final _shareHooks = ShareAppHooks(
      ref, () => ref.read(routerProvider).routerDelegate.navigatorKey.currentContext);

  /// ZestSSH Cloud says another device signed this one out: sign out here
  /// too, keep every local host and key, and say what happened.
  /// Asks ZestSSH Cloud again what the account has (Squeezed, Juiced),
  /// when someone is signed in.
  void _askEntitlements() {
    if (!mounted || ref.read(currentUserProvider) == null) return;
    _entitlementsAskedAt = DateTime.now();
    unawaited(ref.read(isProProvider.notifier).refresh());
    unawaited(ref.read(isCloudSyncProvider.notifier).refresh());
  }

  /// ZestSSH Cloud says this computer's sign-in ran out (30 days without
  /// use): one notice, with Sign in, which signs in again where the person
  /// is: same account, nothing signed out, sync and everything on the device
  /// kept (from a security review).
  void _onSessionExpired() {
    if (!mounted || ref.read(currentUserProvider) == null) return;
    ref.read(notificationCenterProvider.notifier).show(AppNotification(
          id: 'session-expired',
          title: gl10n.sessionExpiredTitle,
          body: gl10n.sessionExpiredBody,
          severity: NotificationSeverity.warning,
          actionLabel: gl10n.devicesSignInAgainTitle,
          onAction: () async {
            final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
            if (context == null || !context.mounted) return;
            if (!await refreshSignIn(context, ref) || !mounted) return;
            ref.read(notificationCenterProvider.notifier).remove('session-expired');
            unawaited(ref.read(autoSyncServiceProvider).triggerSync());
            unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
          },
        ));
  }

  Future<void> _onSignedOutElsewhere() async {
    if (!mounted || _handlingSignedOutElsewhere) return;
    if (ref.read(currentUserProvider) == null) return;
    _handlingSignedOutElsewhere = true;
    try {
      // This device may be changing its own sign-in right now (the
      // account's first second step signs out every sign-in without one,
      // and it signs in again a moment later): looked at once that is over.
      await SignInChange.settled();
      if (!mounted) return;
      // Asked again with this device's sign-in as it is now: an answer to a
      // sign-in it has since replaced is not this device signed out
      // ([stillSignedInHere]). The team's live line, which that answer
      // stopped, opens again with the next sync.
      if (await stillSignedInHere(ref.read(deviceSessionServiceProvider).api)) {
        AppLogger.info('Signed-in devices: a "signed out" for a replaced sign-in, passed over');
        unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
        return;
      }
      if (!mounted || ref.read(currentUserProvider) == null) return;
      await signOutAccount(ref, signedOutElsewhere: true);
      if (!mounted) return;
      final notice = signedOutNotice(gl10n, sessionRevokedReason);
      ref.read(notificationCenterProvider.notifier).warning(
            notice.title,
            body: notice.body,
            dismissAfter: const Duration(seconds: 14),
          );
    } catch (e) {
      AppLogger.error('Signing out after a remote sign-out failed', e);
    } finally {
      _handlingSignedOutElsewhere = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (ReviewPrompt.onThisDevice) unawaited(ref.read(reviewPromptProvider).seen());
    // The passkey step of a sign-in uses this device's own passkeys.
    SecondStepPasskeys.platform = ref.read(passkeyPlatformProvider);
    // A locked app has no shell to close it.
    if (!_isMobile) {
      WindowService.instance?.setOnCloseWithoutShell(() => unawaited(_closeNoShell()));
      TrayService.instance?.onQuitWithoutShell = () => unawaited(_closeNoShell(quit: true));
      // "Also show as system notifications" (4.0): started where this
      // computer's person turned it on; a click on one brings the window to
      // the front, at the place it is about.
      unawaited(NotificationService.setComputerSystemNotices(ref.read(desktopSystemNotificationsProvider)));
      NotificationService.onComputerTap = _onSystemNotificationClicked;
    }
    // The home screen widget told the lock as the app starts, before the
    // hosts are known (behind an encrypting lock they are not until unlock).
    if (_isMobile) WidgetsBinding.instance.addPostFrameCallback((_) => _pushHomeWidget());
    // What the Store copy did about the website copy at its start (one ZestSSH
    // per Windows PC, store_handover_start.dart): said once, when the app is up.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tellStoreHandover());
    // macOS did not let ZestSSH read one of its saved keys (3.3.2): said once, with
    // Try again, after which what waited (sync) goes on.
    final denials = keychainDenials;
    if (denials != null) {
      _keychainNotice = MacKeychainNotice(
        denials: denials,
        show: (notice) => ref.read(notificationCenterProvider.notifier).show(notice),
        remove: (id) => ref.read(notificationCenterProvider.notifier).remove(id),
        afterTryAgain: () {
          // The store sync uses, where macOS did not let it be read, is read
          // again first (3.4.2: the hosted default stood for it for the whole
          // run), and sync goes on with it.
          unawaited(readAgainThenSync(
            readAgain: () => ref.read(syncProviderConfigProvider.notifier).readAgain(),
            sync: () => mounted ? _autoSync?.triggerSync() : null,
          ));
          // The sign-in macOS did not let the start read is read again (3.4.1).
          unawaited(ref.read(profileControllerProvider).readSignInAgain());
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _keychainNotice?.start();
      });
    }
    // A change of profile stops and starts what a lock does.
    final profiles = ref.read(profileControllerProvider);
    profiles.onStop = _onDbClosed;
    profiles.onStart = _onDbOpened;
    profiles.onGuestData = () => unawaited(_askAboutGuestData());
    profiles.onQuit = () {
      final quit = TrayService.instance?.onQuit;
      if (quit != null) {
        quit();
      } else {
        unawaited(_closeNoShell(quit: true));
      }
    };
    _startWhenDbReady();
    _watchAccountForDeviceList();
  }

  /// Drive the DB-touching startup work off the database's open/closed state.
  ///
  /// Encrypting lock OFF (default): the DB is open at first frame and never
  /// closes, so [_onDbOpened] runs exactly once at startup - identical to the
  /// pre-1.8 behavior. Encrypting lock ON: the DB is closed until the vault is
  /// unwrapped, so nothing reads it while the app sits on the unlock screen; and
  /// on auto-lock the DB CLOSES again, so [_onDbClosed] tears down the DB-bound
  /// subscriptions and [_onDbOpened] re-attaches them on the next unlock.
  void _startWhenDbReady() {
    if (ref.read(dbReadyProvider)) {
      _onDbOpened();
    }
    _dbReadySub = ref.listenManual<bool>(dbReadyProvider, (prev, ready) {
      if (ready) {
        _onDbOpened();
      } else {
        _onDbClosed();
      }
    });
  }

  Future<void> _keepDetectedIcons() async {
    try {
      final kept = await keepDetectedHostIcons(
        dao: ref.read(connectionsDaoProvider),
        crud: ref.read(connectionCrudProvider),
        seen: ref.read(osDetectionCacheProvider),
      );
      if (kept > 0) AppLogger.info('Kept the seen system icon on $kept host(s)');
    } catch (e) {
      AppLogger.warning('Keeping the seen system icons failed: ${errorKind(e)}');
    }
  }

  void _onDbOpened() {
    unawaited(_sealSecretsAtRest());
    // The systems this device has seen on hosts become the hosts' own icons
    // where they have none, so every device shows them (3.2).
    unawaited(_keepDetectedIcons());
    // One-time, DB-independent setup on the first open.
    if (!_startupRan) {
      _startupRan = true;
      _handleDeepLinks();
    } else {
      // A change of profile built it anew, and nothing else asks for it, so its
      // links would go unanswered until the next start.
      ref.read(automationProvider);
    }
    // Tickets: what was written with no network (reports, support tickets,
    // follow-ups) is sent, and the tickets on this device are brought up to
    // date. A device that holds no ticket asks the server nothing.
    try {
      final poller = ref.read(ticketPollerProvider);
      poller.onReplies = _onTicketReplies;
      poller.start();
      _ticketPoller = poller;
    } catch (e) {
      AppLogger.warning('Ticket poller not started: ${errorKind(e)}');
    }
    // (Re)attach the DB-bound startup work. Safe to re-run: [_onDbClosed]
    // removed the sync-error listeners and nulled `_dbChangeSub`, so the
    // `addListener` / `??=` calls below re-establish rather than duplicate.
    _runStartupTasks();
    unawaited(_syncAtEndOfSignIn());
    unawaited(_afterProfileOpened());
    unawaited(_cancelOrphanedScheduledTasks());
    // A computer's scheduled tasks run while the app is open or in the tray,
    // and unlocked (4.0): what was missed while it was locked runs once.
    if (scheduledTasksHere == ScheduledTasksHere.computer) {
      try {
        ref.read(computerTaskSchedulerProvider).start();
      } catch (e) {
        AppLogger.error('Scheduled tasks did not start', e);
      }
    }
  }

  /// WorkManager's jobs whose task has no row here go (Android): left by a wipe, or by
  /// a database that went, they kept their command text and could not be cancelled from
  /// the app (found in a code review).
  Future<void> _cancelOrphanedScheduledTasks() async {
    if (!TaskSchedulerService.isAvailable) return;
    try {
      final rows = await ref.read(scheduledTasksDaoProvider).getAll();
      final cancelled = await TaskSchedulerService.cancelOrphans({for (final t in rows) t.id});
      if (cancelled > 0) AppLogger.info('Scheduler: cancelled $cancelled job(s) with no task');
    } catch (e) {
      AppLogger.warning('Scheduled jobs with no task were left for now (${errorKind(e)})');
    }
  }

  /// A profile opened on a computer: what stopped halfway is finished, and an
  /// older version's data is offered, if there is any. Nothing here stands in
  /// the way of the hosts on the device.
  Future<void> _afterProfileOpened() async {
    final profiles = ref.read(profileControllerProvider);
    if (!profiles.on) return;
    try {
      await profiles.afterOpened();
      if (!mounted) return;
      final account = ref.read(currentUserProvider);
      if (account != null) _accountArrived(account);
      final found = await profiles.olderVersionData();
      if (found != null && mounted) {
        final (older, summary) = found;
        ref.read(notificationCenterProvider.notifier).show(AppNotification(
              id: 'older-version-data',
              title: gl10n.olderDataTitle,
              body: olderDataWords(gl10n, summary),
              severity: NotificationSeverity.warning,
              dismissAfter: Duration.zero,
              actionLabel: gl10n.olderDataAction,
              onAction: () {
                final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
                if (context != null) unawaited(showOlderVersionData(context, ref, older, summary));
              },
            ));
      }
      if (mounted && await profiles.setAsideHere() && mounted) {
        ref.read(notificationCenterProvider.notifier).show(AppNotification(
              id: 'data-set-aside',
              title: gl10n.profileSetAsideTitle,
              body: ErrorCodes.withCode(gl10n.profileSetAsideBody, ErrorCodes.profileSetAside),
              severity: NotificationSeverity.warning,
              dismissAfter: Duration.zero,
              actionLabel: gl10n.olderDataAction,
              onAction: () {
                final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
                if (context != null) unawaited(showSetAsideData(context, ref));
              },
            ));
      }
      // Nothing here, and the person's data elsewhere on this computer (a Mac): said,
      // with what opens it.
      final elsewhere = mounted ? await profiles.dataElsewhere() : null;
      if (elsewhere != null && mounted) _sayDataElsewhere(elsewhere);
      if (profiles.putBackFailed) {
        ref.read(notificationCenterProvider.notifier).warning(
              gl10n.profileSetAsideTitle,
              body: ErrorCodes.withCode(gl10n.profilePutBackFailed, ErrorCodes.profileSetAside),
            );
      }
      // Last, as it may wait for the network, and nothing above should.
      if (mounted) await profiles.settleCopy();
    } catch (e) {
      AppLogger.warning('After a profile opened: ${errorKind(e)}');
    }
  }

  void _sayDataElsewhere(DataElsewhere found) {
    final notices = ref.read(notificationCenterProvider.notifier);
    const id = 'data-elsewhere';
    notices.show(AppNotification(
      id: id,
      title: gl10n.profileElsewhereTitle,
      body: switch (found.kind) {
        DataElsewhereKind.copy => gl10n.profileElsewhereCopyBody,
        DataElsewhereKind.open => gl10n.profileElsewhereOpenBody,
        DataElsewhereKind.signIn => gl10n.profileElsewhereSignInBody,
      },
      severity: NotificationSeverity.warning,
      dismissAfter: Duration.zero,
      actionLabel: switch (found.kind) {
        DataElsewhereKind.copy => gl10n.profileElsewhereBringBack,
        DataElsewhereKind.open => gl10n.profileElsewhereOpen,
        DataElsewhereKind.signIn => gl10n.profileSignIn,
      },
      onAction: () {
        notices.remove(id);
        if (found.kind == DataElsewhereKind.signIn) {
          unawaited(ref.read(routerProvider).push<void>(Routes.profile));
          return;
        }
        unawaited(() async {
          try {
            await ref.read(profileControllerProvider).bringBackElsewhere(found);
            notices.success(gl10n.profileElsewhereDone);
          } catch (e) {
            AppLogger.warning('Data elsewhere was not brought back (${errorKind(e)})');
            notices.warning(gl10n.profileElsewhereFailed, details: '$e');
          }
        }());
      },
    ));
  }

  /// An account new on this computer has finished signing in: what guest data holds
  /// is asked about, once. Whatever goes wrong, it stays guest data, and the account
  /// page has the same question.
  Future<void> _askAboutGuestData() async {
    try {
      final found = await ref.read(profileControllerProvider).guestData();
      if (found == null || found.empty || !mounted) return;
      final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (context != null && context.mounted) await showGuestDataQuestion(context, ref, found);
    } catch (e) {
      AppLogger.warning('The question about guest data: ${errorKind(e)}');
    }
  }

  /// While the encrypting lock is on, every secret kept as it was is sealed
  /// at each unlock ([sealSecretsAtRest]): one a build before this one wrote,
  /// or one written as the lock was being turned on. While it is off (the
  /// setting is the vault's state, set so at start in main.dart), sealing
  /// left on, or a secret left sealed, by turning it off when the app stopped
  /// part way, is put right ([settleSecretsAtRest]).
  Future<void> _sealSecretsAtRest() async {
    try {
      final tree = ref.read(databaseSessionProvider);
      if (tree == null) return;
      final lockOn = ref.read(settingsServiceProvider).encryptingLockEnabled;
      final changed = await settleSecretsAtRest(tree, ref.read(secureStorageProvider), lockOn: lockOn);
      if (changed > 0) AppLogger.info('${lockOn ? 'Sealed' : 'Opened'} $changed secrets at rest');
    } catch (e) {
      AppLogger.warning('Secrets at rest not sealed: ${errorKind(e)}');
    }
  }

  void _onDbClosed() {
    // Re-lock closed the executor; tear down everything bound to it so no query
    // hits a closed database. Re-attached on the next unlock by [_onDbOpened].
    _dbChangeSub?.cancel();
    _dbChangeSub = null;
    _ticketPoller?.stop();
    _ticketPoller = null;
    // Stop the periodic pollers, not just their listeners: their timers would
    // otherwise keep firing every interval against the now-closed DB (each
    // firing throwing a StateError from databaseProvider). startAutoSync() /
    // resume() are idempotent, so _onDbOpened re-establishes them on unlock.
    _autoSync?.stopAutoSync();
    try {
      ref.read(agentlessMonitorPollerProvider.notifier).pause();
      ref.read(connectionHealthProvider.notifier).pause();
    } catch (_) {/* poller may not be constructed yet */}
    try {
      ref.read(cloudAccountsProvider.notifier).stop();
    } catch (_) {/* not constructed yet */}
    if (scheduledTasksHere == ScheduledTasksHere.computer) ref.read(computerTaskSchedulerProvider).stop();
    _autoSync?.syncError.removeListener(_onSyncError);
    _autoSync?.clockSkew.removeListener(_onClockSkew);
    _autoSync?.hostKeyConflict.removeListener(_onHostKeyConflict);
    _autoSync?.storeWentBack.removeListener(_onStoreWentBack);
    _autoSync?.staleReconcileHandler = null;
    _autoSync = null;
  }

  /// Support answered: a notice in the app with a way to open the ticket,
  /// and on a phone a system notification as well (on a computer where its
  /// person turned that on and the window is not in front, 4.0; a click on
  /// it opens the Support Hub's tickets). Both name the ticket by
  /// its number only: the bell's history is kept outside the encrypted
  /// database, other apps with notification access can read a system
  /// notification, and a ticket's subject can be private.
  void _onTicketReplies(List<SupportTicketRow> replies) {
    if (!mounted || replies.isEmpty) return;
    final l10n = gl10n;
    final center = ref.read(notificationCenterProvider.notifier);
    for (final t in replies) {
      final number = t.number;
      center.show(AppNotification(
        // One per ticket: a second answer takes the place of the first.
        id: 'ticket-reply-${t.nonce}',
        title: l10n.ticketReplyNoticeTitle,
        body: number == null ? null : l10n.ticketReplyNoticeBody(number),
        dismissAfter: const Duration(seconds: 10),
        actionLabel: l10n.ticketReplyNoticeOpen,
        onAction: () => _openTicket(t.nonce),
      ));
    }
    final number = replies.first.number;
    Future<void> system() => NotificationService.showTicketReply(
          title: l10n.ticketReplyNoticeTitle,
          body: number == null ? l10n.ticketsTitle : l10n.ticketReplyNoticeBody(number),
        );
    unawaited(_isMobile ? system() : NotificationService.onComputer(system));
  }

  /// A click on one of this computer's system notifications (4.0): the
  /// window to the front (from the tray, or restored where it was
  /// minimised), and for an answer from support the Support Hub's tickets,
  /// as a phone opens its tickets. A connection lost, a workflow's notice and
  /// an alert are on the window itself (the session's tab, the corner's
  /// card), as the phone's go to its app.
  void _onSystemNotificationClicked(String? payload) {
    unawaited(() async {
      try {
        if (await windowManager.isMinimized()) await windowManager.restore();
        await windowManager.show();
        await windowManager.focus();
      } catch (e) {
        AppLogger.debug('The window was not brought to the front: $e');
      }
    }());
    // (The Support Hub is the account service's: a build with none has no
    // tickets to open, and its window is only brought forward.)
    if (!mounted || payload != 'ticket_reply' || !zestHasCloud) return;
    ref.read(supportHubTicketProvider.notifier).state = null;
    ref.read(supportHubComposeProvider.notifier).state = null;
    ref.read(supportHubOpenProvider.notifier).state = true;
  }

  /// Gives the home screen widget your Tree's hosts and the app lock, as they
  /// are now (homeWidgetUpdate decides what it may see).
  void _pushHomeWidget() {
    if (!mounted) return;
    final update = homeWidgetUpdate(
      inTree: ref.read(activeSpaceProvider) is TreeSpace,
      locked: ref.read(securityLockEnabledProvider),
      connections: ref.read(allConnectionsProvider).valueOrNull,
    );
    if (update != null) unawaited(WidgetService.publish(ref.read(sharedPreferencesProvider), update));
  }

  /// Opens one ticket's conversation: its own screen on a phone, the Support
  /// Hub on a computer.
  void _openTicket(String nonce) {
    if (_isMobile) {
      ref.read(routerProvider).push(Routes.ticket, extra: nonce);
    } else {
      ref.read(supportHubTicketProvider.notifier).state = nonce;
      ref.read(supportHubComposeProvider.notifier).state = null;
      ref.read(supportHubOpenProvider.notifier).state = true;
    }
  }

  /// Track session IDs that were connected before the app was backgrounded.
  /// Used on iOS to detect sessions that disconnected while in the background.
  Set<String> _connectedBeforeBackground = {};

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    ref.read(platformBrightnessProvider.notifier).state =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // A computer stops asking for answers while its window is hidden (the
    // notice is in the app, where nobody would see it) and asks again when
    // it is back. A phone keeps asking while the app is alive, so the system
    // notification can arrive.
    if (state == AppLifecycleState.resumed) {
      // Back in front: what the account has, at most every five minutes.
      final asked = _entitlementsAskedAt;
      if (asked == null || DateTime.now().difference(asked) > const Duration(minutes: 5)) _askEntitlements();
      _ticketPoller?.onForeground();
      // An invitation to a shared session that came meanwhile shows now.
      _shareHooks.onForeground();
      // A recovery of the account someone asked for, at most every half hour.
      if (ref.read(currentUserProvider) != null) unawaited(_lockoutWatch.check());
      // A computer's sign-in renewed once it is a week old: it ran out after
      // 30 days of use and signed the computer out.
      unawaited(ref.read(deviceSessionServiceProvider).renewIfOld());
    } else if (!_isMobile &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused)) {
      _ticketPoller?.onBackground();
    }
    // Remote screens (4.0): on iOS, closed cleanly before the system
    // suspends the app, and connected again when it is back
    // (ScreenBackgroundKeeper); the picture is paused by its views everywhere.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      try {
        unawaited(ref.read(screenBackgroundProvider).hidden());
      } catch (_) {/* provider not ready */}
    } else if (state == AppLifecycleState.resumed) {
      try {
        final back = ref.read(screenBackgroundProvider).resumed();
        if (back > 0) {
          final navContext = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
          if (navContext != null && navContext.mounted) showScreensBackNotice(navContext);
        }
      } catch (_) {/* provider not ready */}
    }
    final lockNotifier = ref.read(isAppLockedProvider.notifier);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      lockNotifier.onAppBackgrounded();
      _backupOnCloseIfDirty();

      // Pause agentless monitor polling while backgrounded on a phone or
      // tablet - it only runs in the foreground there. A computer's window
      // that loses focus goes on watching (backgroundPollingStops).
      if (backgroundPollingStops(state, computer: Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        try {
          ref.read(agentlessMonitorPollerProvider.notifier).pause();
          ref.read(connectionHealthProvider.notifier).pause();
        } catch (_) {/* provider not ready - poller will start on resume */}
      }

      // On iOS, snapshot which sessions are currently connected (not its
      // remote screens: the app closes those itself, and connects them
      // again, ScreenBackgroundKeeper).
      if (Platform.isIOS) {
        _connectedBeforeBackground = connectedBeforeBackground(ref.read(activeSessionsProvider),
            isScreen: ref.read(activeSessionsProvider.notifier).isScreen);
      }
    } else if (state == AppLifecycleState.resumed) {
      lockNotifier.onAppResumed();

      // Resume agentless monitor polling now the app is foregrounded again.
      try {
        ref.read(agentlessMonitorPollerProvider.notifier).resume();
        ref.read(connectionHealthProvider.notifier).resume();
      } catch (_) {/* provider not ready yet */}

      // An Orchard past its offline limit closes the moment the app is back
      // (3.0), not at the next minute's check: the timer may not
      // have run while the app was away.
      if (kOrchardsEnabled) {
        try {
          unawaited(ref.read(orchardSyncSchedulerProvider).checkOfflineLimits());
          // A new invitation to a team shows now, not at the next round.
          ref.read(orchardSyncSchedulerProvider).foregrounded();
        } catch (_) {/* provider not ready yet */}
      }

      // Re-check the OS notification permission: the user may have returned from
      // the system settings page after tapping the permission banner's action.
      try {
        ref.invalidate(notificationsEnabledProvider);
      } catch (_) {/* provider not ready yet */}

      // While ZestSSH Cloud was not answering, it is asked the moment the
      // app is in front again: a phone's timers did not run meanwhile.
      try {
        ref.read(cloudReachProvider).appResumed();
      } catch (_) {/* provider not ready yet */}

      // Pull on resume - deferred to a post-frame callback so it never runs
      // inline in the lifecycle callback during a window maximize/restore.
      afterNextFrame((_) {
        if (!mounted) return;
        try {
          ref.read(autoSyncServiceProvider).triggerSync();
        } catch (e) {
          AppLogger.error('Resume auto-sync failed', e);
        }
      });

      // On iOS, check if any sessions disconnected while backgrounded
      if (Platform.isIOS) {
        _checkForDisconnectedSessionsOnResume();
      }
    }
  }

  /// Ties the service that knows how ZestSSH Cloud stands to what tells it
  /// and to what it tells (once): every request to the service says how it
  /// went, the device's network says when it changes, and the moment the
  /// service answers again sync and the Orchards catch up without anybody
  /// pressing anything.
  void _tieCloudReach() {
    if (_reachNetworkSub != null) return;
    final reach = ref.read(cloudReachProvider);
    PinnedHttpClient.onExchange = reach.hear;
    reach.addBackListener(_cloudIsBack);
    _reachNetworkSub = syncNetworkUp().listen(
      (up) => reach.networkChanged(up: up),
      onError: (Object _) {},
    );
  }

  void _cloudIsBack() {
    if (!mounted) return;
    try {
      ref.read(autoSyncServiceProvider).networkChanged();
    } catch (e) {
      AppLogger.warning('Sync did not catch up after ZestSSH Cloud came back: $e');
    }
    if (kOrchardsEnabled) {
      try {
        ref.read(orchardSyncSchedulerProvider).cloudIsBack();
      } catch (e) {
        AppLogger.warning('The Orchards did not catch up after ZestSSH Cloud came back: $e');
      }
    }
  }

  /// Check if sessions disconnected while the app was in the iOS background.
  /// Shows a snackbar if any were lost, with a "Why?" action linking to
  /// the iOS backgrounding help screen.
  void _checkForDisconnectedSessionsOnResume() {
    if (_connectedBeforeBackground.isEmpty) return;

    // Allow a brief delay for the session state to settle after resume
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;

      final sessions = ref.read(activeSessionsProvider);
      int disconnectedCount = 0;

      for (final sessionId in _connectedBeforeBackground) {
        final current = sessions[sessionId];
        if (current == null ||
            current.status == SessionStatus.disconnected ||
            current.status == SessionStatus.error) {
          disconnectedCount++;
        }
      }

      _connectedBeforeBackground = {};

      if (disconnectedCount > 0) {
        // Said where it can be seen, in the app's language, and true to the
        // setting (3.0: it looked for a messenger above the app,
        // found none and was never shown, said "Reconnecting" in English
        // whether or not connecting again by itself was on).
        final navContext = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
        if (navContext == null || !navContext.mounted) return;
        showResumeNotice(
          navContext,
          dropped: disconnectedCount,
          reconnecting: ref.read(autoReconnectEnabledProvider),
          onWhy: () => ref.read(routerProvider).push(Routes.iosBackgrounding),
        );
      }
    });
  }

  /// As the app goes to the background: the daily or weekly backup where it
  /// is due, or else one of what changed, at most once an hour
  /// ([AutoBackupService.onLeaving]). Non-blocking, fire-and-forget. The
  /// changed flag is cleared only as a backup that holds the changes is
  /// begun, so a change made inside the hour is in the next one.
  void _backupOnCloseIfDirty() {
    AutoBackupService.onLeaving(
      changed: ref.read(backupDirtyProvider),
      taken: () => ref.read(backupDirtyProvider.notifier).state = false,
      backupService: ref.read(backupServiceProvider),
      settings: ref.read(settingsServiceProvider),
      secureStorage: ref.read(secureStorageProvider),
      copyTo: _copyAutoBackup,
    ).then(_onAutoBackup);
  }

  bool _autoBackupNoPasswordShown = false;

  /// Says what an automatic backup did when it matters: none made for want
  /// of a password (once a run, with a way to set one), one that failed, or
  /// one that could not be copied everywhere. (3.0: it went to
  /// the log only.)
  void _onAutoBackup(AutoBackupOutcome outcome) {
    if (!mounted) return;
    final center = ref.read(notificationCenterProvider.notifier);
    switch (outcome.status) {
      case AutoBackupStatus.idle:
        return;
      case AutoBackupStatus.noPassword:
        if (_autoBackupNoPasswordShown) return;
        _autoBackupNoPasswordShown = true;
        center.show(AppNotification(
          id: const Uuid().v4(),
          title: gl10n.autoBackupNoPasswordTitle,
          body: gl10n.autoBackupNoPasswordBody,
          severity: NotificationSeverity.warning,
          actionLabel: gl10n.settingsMobSetPassword,
          onAction: _setAutoBackupPassword,
        ));
      case AutoBackupStatus.failed:
        final said = outcome.error ?? gl10n.backupSvcCouldNotWrite;
        center.error(
          gl10n.autoBackupFailedTitle,
          body: said,
          details: ErrorReport.build(what: said, where: 'Making an automatic backup', details: outcome.detail),
        );
      case AutoBackupStatus.made:
        if (outcome.notCopied.isEmpty) return;
        final said = gl10n.autoBackupNotCopiedBody(outcome.notCopied.keys.join(', '));
        center.warning(
          gl10n.autoBackupNotCopiedTitle,
          body: said,
          // (What each place said; their names are on the screen, not in the
          // report.)
          details: ErrorReport.build(
            what: gl10n.autoBackupNotCopiedTitle,
            where: 'Copying an automatic backup',
            details: outcome.notCopied.values.join('\n'),
          ),
        );
    }
  }

  /// The notice's way to set the automatic backups' password.
  Future<void> _setAutoBackupPassword() async {
    final navContext = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    final password = await askAutoBackupPassword(navContext);
    if (password == null || !mounted) return;
    // Kept as Backup's own setting keeps it (sealed with the vault where one
    // is open), not written in the clear.
    await AutoBackupService.keepPassword(
        ref.read(secureStorageProvider), ref.read(databaseSessionProvider), password);
  }

  /// Copies a made automatic backup to the backup places set up in Settings
  /// (WebDAV and the like); the ones it could not be copied to.
  Future<Map<String, String>> _copyAutoBackup(File file, String filename) async {
    try {
      final manager = await ref.read(backupDestinationManagerProvider.future);
      final results = await manager.backupToAll(file, filename);
      // Where it went, the oldest of its kind beyond those kept here go
      // (3.4.2 sweep, L8).
      await manager.pruneAutoBackups([
        for (final r in results.entries)
          if (r.value == null) r.key,
      ], justCopied: filename);
      return {
        for (final r in results.entries)
          if (r.value != null) (manager.getDestination(r.key)?.displayName ?? r.key): r.value!,
      };
    } catch (e) {
      return {gl10n.autoBackupOtherPlaces: '$e'};
    }
  }

  Future<void> _removeShareLeftovers() async {
    try {
      final temp = await getTemporaryDirectory();
      await ConnectionShareService.removeLeftovers(temp.path);
    } catch (e) {
      AppLogger.warning('The temporary folder was not read (${errorKind(e)})');
    }
    await clearPickedCopies();
  }

  /// Run non-blocking startup tasks (auto-backup, auto-sync).
  void _runStartupTasks() {
    // What shares left in the temporary folder (a shared host, with its
    // password and key if they were chosen; an exported private key) is
    // deleted, and so are the copies of files picked on a phone to import.
    unawaited(_removeShareLeftovers());

    // Schedule after the first frame so providers are fully initialised
    afterNextFrame((_) async {
      // Load the selected sync provider (hosted / self-hosted / WebDAV / S3 /
      // Drive) BEFORE auto-sync's first cycle, so a bring-your-own user's
      // launch pull hits the right store instead of the hosted default.
      try {
        await ref.read(syncProviderConfigProvider.notifier).ensureLoaded();
      } catch (e) {
        AppLogger.error('Sync provider load failed', e);
      }

      // Auto backup check (non-blocking)
      try {
        AutoBackupService.checkAndRunAutoBackup(
          backupService: ref.read(backupServiceProvider),
          settings: ref.read(settingsServiceProvider),
          secureStorage: ref.read(secureStorageProvider),
          copyTo: _copyAutoBackup,
        ).then(_onAutoBackup);
      } catch (e) {
        AppLogger.error('Auto-backup check failed', e);
      }

      // Start auto sync (no-ops internally for 'manual' mode / no creds).
      // This runs one cycle immediately, which PULLS anything the other
      // device pushed - the launch-time half of "changes propagate".
      try {
        final autoSync = ref.read(autoSyncServiceProvider);
        // A sync that waits its time after the store could not be reached
        // goes at once when the device's network comes back or changes.
        autoSync.networkUp ??= syncNetworkUp;
        _tieCloudReach();
        autoSync.startAutoSync();

        // Drive change-based pushes: a local DB write to a SYNCED table
        // nudges auto-sync (debounced; no-op for users without sync creds).
        // Filtered to only the synced tables so automation/scheduled-task/
        // known-hosts churn never schedules a sync cycle (that unfiltered
        // firing, plus the echo loop, is what starved the UI and froze the
        // window on maximize in 1.5.26).
        // The Tree's tables: only they sync as your personal blob.
        final db = ref.read(treeDatabaseProvider);
        _dbChangeSub ??= db
            .tableUpdates(TableUpdateQuery.onAllTables([
              db.connections,
              db.identities,
              db.connectionGroups,
              db.snippets,
              db.portForwardRules,
              // Networks feature tables (v1.6) - a network-only edit must also
              // mark sync dirty so it pushes promptly ("everything should
              // sync"), not just ride along on the next other-table change.
              db.networks,
              db.hostNetworkOverrides,
              db.portForwardNetworkOverrides,
              // Connection tags (blob v13): a tag-only edit must mark sync dirty
              // so it pushes, otherwise tags never propagate.
              db.connectionTags,
            ]))
            .listen((_) => autoSync.notifyLocalChange());

        // Surface a split-brain / decrypt failure instead of letting sync
        // go silently dead. A short auto-dismiss + a de-dup flag keep it
        // from permanently filling the toast slots.
        _autoSync = autoSync;
        autoSync.syncError.addListener(_onSyncError);
        autoSync.clockSkew.addListener(_onClockSkew);
        autoSync.hostKeyConflict.addListener(_onHostKeyConflict);
        autoSync.storeWentBack.addListener(_onStoreWentBack);
        autoSync.staleReconcileHandler = _onStaleReconcile;
      } catch (e) {
        AppLogger.error('Auto-sync start failed', e);
      }

      // Orchards (3.0; off unless built with ZEST_ORCHARDS): their
      // own sync, item by item, at unlock, every 15 minutes and after a
      // change. Runs again on every unlock.
      if (kOrchardsEnabled) {
        try {
          ref.read(orchardSyncSchedulerProvider).start();
        } catch (e) {
          AppLogger.error('Orchard sync start failed', e);
        }
      }

      // Cloud accounts kept in sync (3.0 cloud import): checked a minute
      // after unlock, then every 30 minutes; nothing runs when none is kept.
      try {
        ref.read(cloudAccountsProvider.notifier).start();
      } catch (e) {
        AppLogger.error('Cloud account checks start failed', e);
      }

      // Bring the agentless Server Monitor poller to life so it starts
      // polling opt-in hosts (when the master toggle is on) without needing
      // any monitor UI open. It self-manages via the master-enable toggle.
      try {
        // The checks of whether hosts can be reached follow Settings and the
        // sessions there are from here on; until this, nothing is checked.
        if (mounted) {
          _reachabilityWiring ??= wireReachabilityChecks(ProviderScope.containerOf(context, listen: false));
        }
        ref.read(connectionHealthProvider.notifier).resume();
        ref.read(agentlessMonitorPollerProvider.notifier);
        // Re-arm the poller: _onDbClosed pauses it on auto-lock, so on the
        // unlock re-run this resumes it (idempotent; also a no-op on the first
        // startup where it is already running).
        ref.read(agentlessMonitorPollerProvider.notifier).resume();
        // Alert engine: observe the same monitor signals and notify on a host
        // going Critical / Warning / offline. Instantiated here so it runs for
        // the app's lifetime without any monitor screen open.
        ref.read(monitorAlertEngineProvider.notifier);
        // Reminders of certificates that run out: they look at the saved keys
        // from here on, for as long as the app runs.
        ref.read(certRemindersProvider);
        // Desktop: pause/resume with window focus so we only poll while the
        // app is actually in the foreground.
        WindowService.instance?.setForegroundCallbacks(
          onLost: () {
            try {
              ref.read(agentlessMonitorPollerProvider.notifier).pause();
              ref.read(connectionHealthProvider.notifier).pause();
            } catch (_) {}
          },
          onGained: () {
            // Recover a pointer the OS left "down" across the focus loss (a
            // window drag handed to the Win32 modal loop, or a monitor sleep) -
            // a lost pointer-up otherwise freezes the cursor and kills all
            // mouse input. Also makes Alt+Tab away-and-back a manual escape.
            PointerRecovery.recover();
            try {
              ref.read(agentlessMonitorPollerProvider.notifier).resume();
              ref.read(connectionHealthProvider.notifier).resume();
            } catch (_) {}
            // A new invitation to a team shows as the window comes back.
            if (kOrchardsEnabled) {
              try {
                ref.read(orchardSyncSchedulerProvider).foregrounded();
              } catch (_) {/* provider not ready yet */}
            }
          },
        );
      } catch (e) {
        AppLogger.error('Monitor poller init failed', e);
      }

      // Restore desktop session from secure storage (if previously signed in)
      _restoreDesktopSession();

      // One-time notice that the Privacy Policy / Terms were updated. Runs
      // once after the first home surface is shown (mobile + desktop). Fully
      // self-guarding - never blocks or crashes startup.
      if (mounted) {
        try {
          await PolicyNoticeService.maybeShow(ref);
        } catch (e) {
          AppLogger.error('Policy notice failed', e);
        }
      }

    });
  }

  Future<void> _restoreDesktopSession() async {
    try {
      final storage = ref.read(secureStorageProvider);
      final kept = await keptDesktopSession(storage);
      if (kept != null) {
        ref.read(desktopSessionProvider.notifier).state = kept;

        // Pro/CloudSync notifiers run their initial entitlement query
        // at app start via their constructor - at which point the
        // session token hasn't been read yet, so the call returns
        // null (treated as "leave state alone" → stays Free). Refresh
        // now that the token is available, otherwise a returning user
        // who already purchased on mobile sees Free until their next
        // sign-in event.
        unawaited(ref.read(isProProvider.notifier).refresh());
        unawaited(ref.read(isCloudSyncProvider.notifier).refresh());
      }
    } catch (e) {
      AppLogger.error('Desktop session restore failed', e);
    }
  }

  void _handleDeepLinks() {
    // Initialise the automation provider so it starts listening for intents
    ref.read(automationProvider);
    // An automation link asks its person before anything runs (3.0: nothing
    // asked, so every one was refused).
    answerAutomationLinks(ref, () => ref.read(routerProvider));

    // Handle initial deep link (cold start via shortcut/deep link)
    final initialLink = DeepLinkService.initialLink;
    if (initialLink != null) {
      // Delay to ensure router is ready
      afterNextFrame((_) {
        _navigateToDeepLink(initialLink);
      });
    }

    // A link that could not be read: said once, and nothing else is done with it.
    void sayUnreadable() {
      final context = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      showTopSnackBar(context, AppLocalizations.of(context)!.deepLinkUnreadable,
          isWarning: true, details: 'A zestssh:// link was opened whose address cannot be decoded (a percent sign not followed by valid UTF-8).');
    }

    if (DeepLinkService.takeUnreadableLink()) {
      afterNextFrame((_) => sayUnreadable());
    }
    _unreadableLinkSub = DeepLinkService.unreadableLinks.listen((_) => sayUnreadable());

    // Handle incoming deep links while app is running
    _deepLinkSub = _linkGate.listenTo(DeepLinkService.linkStream);
    // A link that came while the app was locked is answered once it is
    // unlocked ([LinkGate]).
    _unlockedSub = ref.listenManual<bool>(isAppLockedProvider, (_, locked) => _linkGate.lockChanged(locked));
  }

  /// [uri] answered now, or once the app is unlocked ([LinkGate]).
  Future<void> _navigateToDeepLink(Uri uri) => _linkGate.offer(uri);

  Future<void> _answerDeepLink(Uri uri) async {
    // Check if this is an automation deep link (execute/snippet)
    final automationParams =
        await DeepLinkService.extractAutomationParams(uri);
    if (automationParams != null) {
      AppLogger.info('Deep link → automation: ${automationParams['action']}');
      ref
          .read(automationProvider.notifier)
          .handleAutomation(automationParams);
      return;
    }

    // A saved host opened from a home-screen widget (zestssh://connect?id=)
    // or a shortcut that names it (zestssh://connect?name=, Siri). This is
    // the *browsable* scheme, so a hostile web page could also fire it - it
    // therefore asks before opening a session (openConnectLink).
    if (await answerConnectLink(uri, ref, ref.read(routerProvider))) return;
    // A host by its address (zestssh://connect?host=&user=&port=): Quick
    // connect opened with it typed in, for the person to connect or not.
    if (answerQuickConnectLink(uri, ref.read(routerProvider))) return;
    // A link to join a team with an invite code (zestssh://join#CODE): "Join
    // a team" with the code typed in, and nothing asked of anyone until the
    // person continues.
    if (answerJoinLink(uri, ref.read(routerProvider).routerDelegate.navigatorKey.currentContext)) return;

    // Web upgrade completed - the website bounces the browser back
    // to the desktop app via this URL once Stripe / RevenueCat
    // reports the payment as captured.  We refresh both entitlement
    // providers from the backend so Pro / Cloud Sync features
    // unlock immediately.
    if (uri.scheme == 'zestssh' &&
        (uri.host + uri.path) == 'upgrade-complete') {
      AppLogger.info(
          'Deep link → upgrade-complete, refreshing entitlements');
      ref.read(isProProvider.notifier).refresh();
      ref.read(isCloudSyncProvider.notifier).refresh();
      return;
    }

    // Connection-share URLs (`zestssh://add-host?...` and
    // `zestssh://share?d=<base64>`). Routed through a strict
    // parser + a mandatory confirmation dialog before anything
    // touches the database - see ConnectionShareUrlService for the
    // security boundary.
    final share = ConnectionShareUrlService.tryParse(uri);
    if (share != null) {
      AppLogger.info('Deep link → connection share for ${share.host}');
      await _handleConnectionShare(share, uri);
      return;
    }

    final route = DeepLinkService.uriToRoute(uri);
    if (route != null) {
      AppLogger.info('Deep link navigating to: $route');
      // A computer opens it in its shell (a phone's page took the shell's
      // place).
      await openLinkPage(ref, ref.read(routerProvider), route);
    }
  }

  /// Display the confirmation dialog for an incoming connection
  /// share, then save the connection on approval. No-op if the user
  /// cancels.
  Future<void> _handleConnectionShare(
    ParsedConnectionShare share,
    Uri sourceUri,
  ) async {
    // Use the router's navigator context - the State's `context` may
    // be off-screen if we're cold-starting from a deep link.
    final navContext =
        ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) {
      AppLogger.warning(
        'Share deep link arrived before UI was ready - dropping',
      );
      return;
    }
    // The confirmation, and the host into your Tree only on its yes, as a
    // pasted link's (Import hosts, Paste a share link) goes.
    await addShareLinkHost(navContext, share, sourceUri);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dbReadySub?.close();
    _accountSub?.close();
    _teamsSub?.close();
    _accountSyncNowSub?.close();
    _reauthRequestSub?.close();
    _addPasskeyRequestSub?.close();
    sessionRevokedSignal.removeListener(_onSignedOutElsewhere);
    sessionExpiredSignal.removeListener(_onSessionExpired);
    _approvalNudges?.cancel();
    _securityNudges?.cancel();
    _shareHooks.stop();
    _deepLinkSub?.cancel();
    _unreadableLinkSub?.cancel();
    _unlockedSub?.close();
    _dbChangeSub?.cancel();
    _reachNetworkSub?.cancel();
    _reachabilityWiring?.call();
    PinnedHttpClient.onExchange = null;
    _autoSync?.syncError.removeListener(_onSyncError);
    _autoSync?.clockSkew.removeListener(_onClockSkew);
    _autoSync?.hostKeyConflict.removeListener(_onHostKeyConflict);
    _autoSync?.storeWentBack.removeListener(_onStoreWentBack);
    _autoSync?.staleReconcileHandler = null;
    _keychainNotice?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    // Provide router to NotificationService for tap-to-navigate (mobile only)
    if (_isMobile) NotificationService.setRouter(router);

    // Push connection list to native home screen widget on every change, and
    // the app lock as it is turned on or off (the iPhone's widget shows no
    // host while it is on). Only your Tree's hosts: the widget's list sits
    // outside every encrypted database, so an Orchard's hosts never go there
    // (3.0).
    if (_isMobile) {
      ref.listen(allConnectionsProvider, (_, _) => _pushHomeWidget());
      ref.listen(securityLockEnabledProvider, (_, _) => _pushHomeWidget());
    }

    // Hold the OS wakelock while "Keep Screen Awake" is on and a terminal
    // session is connected. Reading the provider creates the single
    // always-alive controller, which listens to both inputs from then on;
    // its value never changes, so this watch never rebuilds the app.
    ref.watch(keepAwakeControllerProvider);

    // The editor's drafts older than 7 days go as each database opens (at
    // unlock, and as a team's opens), whether or not the editor is opened.
    ref.watch(editorDraftSweepProvider);

    // Recording mode keeps a screen out of a window of its own whatever the
    // main window shows (its tab is not there while Settings is).
    ref.watch(screenWindowsRecordingGuardProvider);

    // Said when automation did not run what a link or another app asked of
    // it: why, and an action that goes where that is put right.
    sayAutomationRefusals(ref, router: () => ref.read(routerProvider), phone: _isMobile);

    // Free-tier jump-host gate: a chain the connect path did not dial (jump
    // routing is Squeezed) is explained ONCE per host and source, with an
    // Upgrade action, so it never fails silently. The connect path raises it
    // on every gated connect; the once-only memory lives here, and the flag is
    // only set when the notice was actually shown.
    ref.listen(jumpHostGateNoticeProvider, (prev, next) {
      if (next == null) return;
      ref.read(jumpHostGateNoticeProvider.notifier).state = null;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final l10n = AppLocalizations.of(context);
      if (messenger == null || l10n == null) return;
      final settings = ref.read(settingsServiceProvider);
      if (settings.hasShownJumpGateNotice(next.key)) return;
      settings.markJumpGateNoticeShown(next.key);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            next.fromOverride
                ? l10n.jumpHostGateNoticeOverride(
                    next.hostLabel, next.networkName ?? '')
                : l10n.jumpHostGateNoticeBase(next.hostLabel),
          ),
          backgroundColor: AppColors.surface,
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: l10n.upgrade,
            textColor: AppColors.brandOrange,
            onPressed: () => ref.read(routerProvider).push('/upgrade'),
          ),
        ),
      );
    });

    // A session connecting asks the person to confirm it is them before a
    // saved password from a Crate that asks again goes to a host they may
    // change (3.0): asked here, over whatever screen is up.
    answerConfirmItIsYouRequests(
        ref, () => ref.read(routerProvider).routerDelegate.navigatorKey.currentContext);

    // A session connecting with a password from the person's password
    // manager asks here (3.0): to unlock Bitwarden or KeePassXC,
    // to allow a password to go to an address the first time, or to type it
    // this once when it could not be fetched.
    answerPasswordManagerRequests(
        ref, () => ref.read(routerProvider).routerDelegate.navigatorKey.currentContext);
    // A session of a team's host asks here before it types what the host's
    // record says it starts with, the first time for each text.
    answerTeamCommandRequests(ref, () => ref.read(routerProvider).routerDelegate.navigatorKey.currentContext);
    // "Offline pass from an owner" asked for from the notice that says an
    // offline limit is about to close something (3.0): opened here, over
    // whatever screen is up.
    answerPassAskRequests(ref, () => ref.read(routerProvider).routerDelegate.navigatorKey.currentContext);
    // What unlocked Bitwarden or KeePassXC is kept only until ZestSSH locks.
    ref.listen<bool>(isAppLockedProvider, (_, locked) {
      if (locked) ref.read(passwordManagersProvider)?.lock();
      // Session sharing (3.0): a viewer who was handed the keyboard loses it
      // when the app locks. Watching goes on.
      if (locked) SessionShares.appLocked();
    });

    // Mark the backup dirty when what a backup holds changes in your Tree.
    ref.listen(backupDirtyWatchProvider, (_, _) {});

    // Every theme, Ember included, is built by the one theme builder
    // (ZestTheme.toThemeData through appThemeDataProvider). Ember with no
    // custom accent used to fall back to the legacy AppTheme.dark(), so its
    // buttons, fields and switches were not the ones every other theme drew.
    final customAccent = ref.watch(customAccentColorProvider);
    final themeData = ref.watch(appThemeDataProvider);

    // Push the active ZestColorScheme through to the static AppColors
    // chrome tokens so widgets that read `AppColors.v3*` actually see
    // the new palette. Without this, only the Material widgets that
    // route through `Theme.of(context)` would shift on theme change -
    // 95% of the desktop chrome (pill bar, sidebar, dialogs) stayed
    // identical to the charcoal default because v3* were static const.
    final activeTheme = ref.watch(appThemeProvider);
    AppColors.applyTheme(activeTheme.colorScheme);
    // The windows this one opens show it too.
    mainWindowTheme = activeTheme;
    mainWindowAccent = customAccent;

    // Sync the Windows native title-bar (the OS-painted strip at the
    // top with min/max/close) to the theme brightness. Without this,
    // dark themes leave a glaring white strip across the top of the
    // window and light themes don't get the white DWM frame back.
    // No-op on macOS / Linux / mobile.
    WindowsTitleBar.setDarkMode(activeTheme.brightness == Brightness.dark);

    // KeyedSubtree forces a full rebuild whenever the theme id changes
    // - necessary because widgets read AppColors.v3* eagerly (not
    // via context), so they'd otherwise keep the previous theme's
    // values in their already-built subtrees until something else
    // triggered them to rebuild.
    //
    // The brand triad (primary/secondary/accent) is folded in too: the
    // Appearance-screen brand pickers reuse a single 'custom_brand' id, so
    // successive edits keep the same id - without these the eager readers
    // would go stale on the second pick.
    final activeScheme = activeTheme.colorScheme;
    final rebuildKey = ValueKey(
      'theme:${activeTheme.id}'
      ':accent:${customAccent?.toARGB32() ?? 0}'
      ':brand:${activeScheme.primary.toARGB32()}'
      ':${activeScheme.effectiveSecondary.toARGB32()}'
      ':${activeScheme.effectiveAccent.toARGB32()}',
    );
    // What stays open across a change of theme (the router's navigator and
    // the dialogs on it, Settings among them) is carried over by its global
    // key, not built again: its parts that read the colours directly kept the
    // theme before (Settings came out half light, half dark, until it was
    // closed and opened again). Once the new theme is in, everything on
    // screen is built again, once.
    if (_shownTheme != null && _shownTheme != rebuildKey.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => rebuildEverything());
    }
    _shownTheme = rebuildKey.value;

    // PointerRecovery.wrap tracks pointer down/up at the root so a stranded
    // pointer (lost up across a window drag or monitor sleep) can be cancelled
    // on the next focus-gain - passive, never absorbs input.
    return PointerRecovery.wrap(
      child: GestureDetector(
        // Dismiss keyboard when tapping outside text fields (non-terminal)
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: KeyedSubtree(
          key: rebuildKey,
          child: MaterialApp.router(
            title: 'ZestSSH',
            theme: themeData,
            debugShowCheckedModeBanner: false,
            routerConfig: router,
            // Tab and Shift+Tab walk every form, multi-line fields included.
            builder: (context, child) {
              // Keep the contextless localization accessor in sync with the
              // active locale so services and the system tray localize too.
              L10nGlobal.update(AppLocalizations.of(context)!);
              // The idle lock watches input everywhere (3.0).
              // "Check your browser" over everything while a sign-in waits
              // for the browser (computers; 3.3.0). The lock screen's doors over
              // the app's pages: the lock is drawn on them, and they split open
              // onto the app once the check passes (4.0).
              final content = BrowserSignInPopup(
                  child: TabMovesFocus(child: LockCurtain(child: child ?? const SizedBox.shrink())));
              // The kind of pointer in use (a finger, or a mouse or a
              // trackpad) for the controls' size (4.0, the density's Auto).
              return PointerInputTracker(
                child: IdleLockWatcher(
                // A phone's sign-in questions are the app's to ask, over
                // whatever is on screen (a computer's shell asks its own).
                child: _isMobile
                    // (And the sheet of a security key held to the phone or plugged
                    // in: lib/ui/widgets/fido_prompt_sheet.dart.)
                    ? PhoneSignInQuestions(router: router, child: FidoPromptHost(router: router, child: content))
                    : Stack(
                        children: [
                          content,
                          Positioned.fill(child: ClosingPanel(step: _closingWithoutShell)),
                        ],
                      ),
                ),
              );
            },
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            // null follows the system locale; a set value overrides it.
            locale: ref.watch(appLocaleProvider),
            // "System default" (locale == null) resolves the device language
            // against the shipped locales and reverts to English when it is not
            // one of them, instead of Flutter's default first-supported locale.
            localeListResolutionCallback: (locales, supported) =>
                resolveAppLocale(locales, supported),
          ),
        ),
      ),
    );
  }
}
