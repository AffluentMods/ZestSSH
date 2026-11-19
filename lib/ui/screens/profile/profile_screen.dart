import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync/unread_sync_store.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/ui/screens/sync/sync_failing_text.dart';
import 'package:zestssh/ui/screens/sync/sync_hosting_dialog.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart' show ItsYou, StepUpWindow, confirmOrSignIn;
import 'package:zestssh/features/orchards/key_replacement.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/team/team_sync_offer.dart' show redeemTeamCode;
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/services/sync/join_with_handover.dart';
import 'package:zestssh/services/sync/password_change.dart';
import 'package:zestssh/ui/screens/profile/recovery_key_check.dart';
import 'package:zestssh/ui/screens/profile/account_question.dart';
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart';
import 'package:zestssh/ui/screens/profile/recovery_key_screen.dart' show RecoveryKeyMode;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show signInFromAnywhere, signsInOnDevice;
import 'package:zestssh/ui/screens/profile/widgets/locked_copies_row.dart' show showLockedCopies;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/services/account/account_deletion_api.dart';
import 'package:zestssh/services/account/account_deletion_flow.dart';
import 'package:zestssh/services/account/account_name.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/account/sync_reset_api.dart';
import 'package:zestssh/services/account/sync_reset_flow.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show PlanChip;
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart' show recoveryProofServiceProvider;
import 'package:zestssh/services/sync/recovery_key_replacement.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_disconnect.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';
import 'package:zestssh/ui/screens/settings/sync_backend_screen.dart';
import 'package:zestssh/ui/screens/sync/sync_reset_ui.dart';
import 'package:zestssh/ui/screens/sync/sync_setup_elsewhere.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_section.dart';
import 'package:zestssh/services/account/sign_in_ways.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart' show menuPositionAt;
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;
import 'package:zestssh/ui/screens/settings/ssh_config_export.dart' show exportSshConfig;
import 'package:zestssh/ui/screens/profile/master_password_dialog.dart';
import 'package:zestssh/ui/widgets/profile_avatar.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/sign_in_again.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/redeem_code_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/local_data_wipe.dart';
import 'package:zestssh/ui/screens/profile/widgets/guest_data_question.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart' show showBackupPlacesDialog;
import 'package:zestssh/l10n/time_text.dart';

/// Which of the account page's sections a [ProfileScreen] shows (4.0, the
/// Settings pages): all of them (a phone's and a
/// tablet's Account page), or one Settings page's share of them.
enum ProfilePart {
  /// Every section, in order: the Account page of a phone or a tablet.
  all,

  /// Settings > Account: who is signed in, sign-in, keys, devices, sync, and
  /// the account's own danger rows (sign out, reset cloud sync, delete).
  account,

  /// Settings > Plan: Redeem a code, where the account is not fully entitled.
  plan,

  /// Settings > Backups and data: export, import, automatic backups, the
  /// cache, and the danger rows for this device's data (delete all local
  /// data, reset all settings).
  data,
}

/// Profile & Cloud Sync management screen.
///
/// Shows user avatar/info, sync status, and account actions.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({
    super.key,
    this.inDialog = false,
    this.embedded = false,
    this.part = ProfilePart.all,
    this.dataExtra,
  });

  /// Inside Settings (3.0 UI): the sections only, without a title bar
  /// or a scroll of their own.
  final bool embedded;

  /// Which sections are shown: all of them, or one Settings page's (4.0).
  final ProfilePart part;

  /// Under the Data section of [ProfilePart.data], above its danger rows (a
  /// computer's cloud accounts kept in sync).
  final Widget? dataExtra;

  /// Opens the account: on desktop, Settings > Account and security (3.0
  /// UI); on phones and tablets, the Account screen.
  static Future<void> openAccount(BuildContext context, WidgetRef ref) async {
    if (jumpToDesktopSettings(ref, SettingsJumpTarget.account)) return;
    await showAdaptive(context);
  }

  /// True when shown as a desktop dialog (via [showAdaptive]). In this mode the
  /// mobile-style back arrow is replaced by a close button - there is no
  /// navigation stack behind a dialog to go "back" to.
  final bool inDialog;

  /// Show as a dialog on desktop or push a route on mobile.
  static Future<void> showAdaptive(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width > 600;
    if (isWide) {
      // Desktop: a LEFT slide-in panel (not a centered modal). It runs the full
      // viewport height at a fixed width and enters from the left edge, so the
      // Account panel gets far more vertical room than a centred dialog. The
      // body scrolls; the panel itself never resizes as its content changes.
      // showGeneralDialog gives the same modal barrier as showDialog, so an
      // outside click AND Escape both dismiss it (Escape → DismissIntent on the
      // barrier); the header × closes it too.
      final panelWidth = min(540.0, size.width - 40);
      return showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel:
            MaterialLocalizations.of(context).modalBarrierDismissLabel,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (ctx, _, _) => Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: Material(
              clipBehavior: Clip.antiAlias,
              color: AppColors.background,
              elevation: 12,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: const ProfileScreen(inDialog: true),
            ),
          ),
        ),
        transitionBuilder: (ctx, animation, _, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-1, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            )),
            child: child,
          );
        },
      );
    } else {
      return context.push(Routes.profile);
    }
  }

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _isSigningIn = false;


  /// Cached sync setup state - null while loading. Used to gate the
  /// regular sync UI behind a "complete setup" wizard whenever setup is
  /// in progress or has been abandoned mid-way.
  SyncSetupSnapshot? _setupSnapshot;
  bool _runningSetupWizard = false;

  /// The account keys' version on this device (3.0: shown with "Replace
  /// keys"), null until read or when there are none here.
  int? _keyVersion;

  /// This account's own keys' fingerprint, read from this device (3.0):
  /// the words teammates compare with.
  Uint8List? _myFingerprint;
  bool _replacingKeys = false;

  /// The account has published keys this device does not hold (3.0):
  /// sync brings them from a device that has them, or, when every
  /// device that had them is gone, the person starts over.
  bool _keysElsewhere = false;
  bool _startingOver = false;

  /// Whether the account's sync store holds a recovery key (3.0):
  /// what this device saw last, then the store's answer; null while unknown.
  bool? _recoveryKeySet;
  bool _recoveryKeyChecked = false;
  bool _recoveryFlowOpen = false;
  bool _savingRecoveryKey = false;

  @override
  void initState() {
    super.initState();
    _refreshSetupState();
    if (kOrchardsEnabled) unawaited(_readKeyVersion());
  }

  Future<void> _readKeyVersion() async {
    final uid = ref.read(currentUserProvider)?.uid;
    if (uid == null) return;
    final stored = await ref.read(accountKeyServiceProvider).store.read(uid);
    final confirmed = stored != null && stored.state == StoredKeyState.confirmed;
    var elsewhere = false;
    if (!confirmed) {
      try {
        elsewhere = (await ref.read(accountKeyServiceProvider).api.mine())?.published != null;
      } catch (_) {
        // Offline: nothing to offer now.
      }
    }
    Uint8List? fingerprint;
    if (confirmed) {
      try {
        fingerprint = (await (await AccountKeys.fromSecretJson(stored.secret)).publish(uid)).fingerprint;
      } catch (_) {
        fingerprint = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _keyVersion = confirmed ? stored.version : null;
      _myFingerprint = fingerprint;
      _keysElsewhere = elsewhere;
    });
  }

  /// Starts over with new keys after every device that had them was lost
  /// (3.0). Asks first; signs the person in again when the server
  /// wants a recent sign-in. Afterwards the Orchards use the new keys, and
  /// each waits for two owners to give the access back.
  Future<void> _startOver() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.accountStartOverConfirmTitle,
      body: l10n.accountStartOverConfirmBody,
      confirmLabel: l10n.accountStartOverAction,
    );
    if (ok != true || !mounted) return;
    setState(() => _startingOver = true);
    try {
      final keys = ref.read(accountKeyServiceProvider);
      try {
        await keys.startOver();
      } on AccountKeysNeedRecentSignIn {
        if (!mounted) return;
        final shown =
            await confirmOrSignIn(context, ref, window: StepUpWindow.account, about: l10n.accountStartOverSignInBody);
        if (shown != ItsYou.confirmed || !mounted) return;
        await keys.startOver();
      }
      // The new keys from now on: the Orchards ask for them again, and sync
      // carries them to the account's other devices.
      ref.read(orchardAuthorProvider).forget();
      ref.read(accountKeyCheckerProvider).recheckSoon();
      ref.read(orchardListVersionProvider.notifier).state++;
      unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
      unawaited(ref.read(autoSyncServiceProvider).triggerSync());
      await _readKeyVersion();
      if (mounted) showTopSnackBar(context, l10n.accountStartOverDone, isSuccess: true);
    } on AccountKeysStillHere {
      if (mounted) showTopSnackBar(context, l10n.accountStartOverStillHere, isError: true);
      unawaited(_readKeyVersion());
    } on AccountKeysReplaceConflict {
      if (mounted) showTopSnackBar(context, l10n.accountStartOverChanged, isError: true);
    } catch (e) {
      AppLogger.warning('Starting over with new keys failed: $e');
      if (mounted) showTopSnackBar(context, l10n.accountStartOverFailed, isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _startingOver = false);
    }
  }

  /// Replaces the account's keys after a device was lost
  /// (3.0). Asks first; signs the person in again when the server wants a
  /// recent sign-in, and carries on with the same new keys.
  Future<void> _replaceKeys() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.accountReplaceKeysConfirmTitle,
      body: l10n.accountReplaceKeysConfirmBody,
      confirmLabel: l10n.accountReplaceKeysAction,
    );
    if (ok != true || !mounted) return;
    setState(() => _replacingKeys = true);
    try {
      KeyReplacementReport report;
      try {
        report = await ref.read(keyReplacementProvider).run();
      } on AccountKeysNeedRecentSignIn {
        if (!mounted) return;
        final shown =
            await confirmOrSignIn(context, ref, window: StepUpWindow.account, about: l10n.accountReplaceKeysSignInBody);
        if (shown != ItsYou.confirmed || !mounted) return;
        report = await ref.read(keyReplacementProvider).run();
      }
      if (!mounted) return;
      setState(() => _keyVersion = report.keyVersion);
      unawaited(_readKeyVersion());
      showTopSnackBar(
        context,
        report.complete
            ? l10n.accountReplaceKeysDone(report.keyVersion)
            : l10n.accountReplaceKeysPartly(report.keyVersion),
        isSuccess: report.complete,
        isInfo: !report.complete,
      );
      if (report.stranded > 0) {
        // What the others cannot open until it is saved again: its amber
        // sentence, and a button that says what it is (it said OK).
        await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.warning,
          title: l10n.accountReplaceKeysAction,
          body: '',
          warning: l10n.accountReplaceKeysStranded(report.stranded),
          showCancel: false,
          confirmLabel: l10n.desktopGotIt,
        );
      }
    } on AccountKeysNotReady {
      if (mounted) showTopSnackBar(context, l10n.accountReplaceKeysNotReady, isError: true);
    } on AccountKeysReplaceConflict {
      if (mounted) showTopSnackBar(context, l10n.accountReplaceKeysChanged, isError: true);
    } catch (e) {
      AppLogger.warning('Replacing account keys failed: $e');
      // Where ZestSSH Cloud or the way to it was what stopped it, that is
      // what is said, with its code.
      if (mounted) showTopSnackBar(context, cloudStopped(l10n, e) ?? l10n.accountReplaceKeysFailed, isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _replacingKeys = false);
    }
  }

  Future<void> _refreshSetupState() async {
    final snap = await ref.read(syncSetupStateServiceProvider).snapshot();
    if (!mounted) return;
    setState(() => _setupSnapshot = snap);
    _takeSyncNowRequest();
    _takeTurnSyncOnRequest();
  }

  /// A notice's "Sync now" asked for this page's own Sync now
  /// ([accountSyncNowRequestProvider]). The page takes the request once it
  /// knows whether sync is set up on this device (at once when it is on
  /// screen already, so the app opens no second account page over it; when
  /// that is read, on a page just opened), and starts its Sync now where its
  /// own button is offered: where sync is set up.
  void _takeSyncNowRequest() {
    final snapshot = _setupSnapshot;
    if (snapshot == null || !ref.read(accountSyncNowRequestProvider)) return;
    ref.read(accountSyncNowRequestProvider.notifier).state = false;
    if (snapshot.isComplete) unawaited(_syncNow());
  }

  /// The end of a sign-in asked this page to bring this device into the
  /// account's sync ([accountTurnSyncOnRequestProvider]): taken once it knows
  /// how sync stands here. It asks for the sync password at once, with nothing
  /// else first.
  void _takeTurnSyncOnRequest() {
    final snapshot = _setupSnapshot;
    if (snapshot == null || !ref.read(accountTurnSyncOnRequestProvider)) return;
    ref.read(accountTurnSyncOnRequestProvider.notifier).state = false;
    if (!snapshot.isComplete && !_runningSetupWizard && ref.read(currentUserProvider) != null) {
      unawaited(_runSyncSetupWizard(afterSignIn: true));
    }
  }

  /// The account's address, for a password manager to save the sync password
  /// under, where the store is the account's own.
  String? get _syncAccountAddress => _backend.kind.isHosted ? ref.read(currentUserProvider)?.email : null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(currentUserProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);
    // Bring-your-own stores (WebDAV / S3 / Drive / self-hosted) are free - they
    // don't require the paid Cloud Sync entitlement, so the sync UI is available
    // whenever a BYO backend is selected, even for free users.
    final isByo = ref.watch(syncIsBringYourOwnProvider);
    final canUseSync = isCloudSync || isByo;
    final syncState = ref.watch(syncStatusProvider);
    ref.listen<bool>(accountSyncNowRequestProvider, (_, asked) {
      if (asked) _takeSyncNowRequest();
    });
    ref.listen<bool>(accountTurnSyncOnRequestProvider, (_, asked) {
      if (asked) _takeTurnSyncOnRequest();
    });

    final setupComplete = _setupSnapshot?.isComplete ?? false;
    final pendingSetup = _setupSnapshot?.isInProgress ?? false;

    // One scrolling Account panel - the nav rail is gone. Desktop
    // (dialog) and mobile (route) share the same panel; only the signed-out
    // sign-in card differs.
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _accountSections(user, canUseSync, syncState, setupComplete, pendingSetup),
      );
    }
    return ResponsiveScaffold(
      title: l10n.accountTitle,
      maxWidth: 620,
      // In a desktop dialog there is no route to go "back" to - the close (×)
      // button lives far-right in the header instead of a back arrow.
      showBackButton: !widget.inDialog,
      actions: [
        // Sync state has one home - the SYNC section. No
        // header status badge repeating "All synced" three inches above it.
        if (widget.inDialog)
          IconButton(
            icon: const Icon(LucideIcons.x),
            tooltip: l10n.close,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
      ],
      body: _buildAccountPanel(
          user, canUseSync, syncState, setupComplete, pendingSetup),
    );
  }

  // ── Account panel (single scroll, one shape both states) ──────

  /// The one scrolling Account panel. The SAME six sections in the SAME order
  /// whether signed in or not (spec 1): You, Security, Devices, Sync, Data,
  /// Danger zone. Signing in fills the You row and unlocks two Security rows +
  /// the extra Danger rows; nothing moves and nothing appears out of nowhere.
  Widget _buildAccountPanel(
    UserProfile? user,
    bool canUseSync,
    SyncState syncState,
    bool setupComplete,
    bool pendingSetup,
  ) {
    final attention =
        _buildAttentionArea(canUseSync, setupComplete, pendingSetup);
    // Redeem a code lives here (both desktop and mobile) instead of a settings
    // row, and only when the account is not fully entitled: a code grants Pro
    // or Cloud Sync, so someone who already has both has no use for it.
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: _accountSections(user, canUseSync, syncState, setupComplete, pendingSetup, attention: attention),
    );
  }

  /// The Account panel's sections in order: You, Security, your keys,
  /// Devices, Sync, Data, the Danger zone.
  List<Widget> _accountSections(
    UserProfile? user,
    bool canUseSync,
    SyncState syncState,
    bool setupComplete,
    bool pendingSetup, {
    Widget? attention,
  }) {
    final isPro = ref.watch(isProProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);
    // (A code is redeemed at the account service: a build with none has no card.)
    final showRedeem = zestHasPlans && (!isPro || !isCloudSync);
    switch (widget.part) {
      case ProfilePart.plan:
        return [if (showRedeem) _buildRedeemCard()];
      case ProfilePart.data:
        return [
          _buildDataSection(),
          if (widget.dataExtra != null) ...[
            const SizedBox(height: 18),
            widget.dataExtra!,
          ],
          const SizedBox(height: 18),
          _buildDangerZone(user, account: false),
        ];
      case ProfilePart.all:
      case ProfilePart.account:
        break;
    }
    final all = widget.part == ProfilePart.all;
    attention ??= _buildAttentionArea(canUseSync, setupComplete, pendingSetup);
    final keys = _buildKeysSection(user != null);
    return [
      _buildYouSection(user),
      // In Settings, Redeem a code is the Plan page's (4.0).
      if (showRedeem && all) ...[
        const SizedBox(height: 12),
        _buildRedeemCard(),
      ],
      if (attention != null) ...[
        const SizedBox(height: 18),
        attention,
      ],
      const SizedBox(height: 18),
      _buildSecuritySection(user != null, canUseSync, setupComplete),
      if (keys != null) ...[
        const SizedBox(height: 18),
        keys,
      ],
      const SizedBox(height: 18),
      _buildDevicesSection(user != null),
      const SizedBox(height: 18),
      _buildSyncSectionV2(canUseSync, syncState, setupComplete),
      // In Settings, the data is the Backups and data page's (4.0).
      if (all) ...[
        const SizedBox(height: 18),
        _buildDataSection(),
      ],
      const SizedBox(height: 18),
      _buildDangerZone(user, local: all),
    ];
  }

  /// Your keys (3.0, Teams): the words teammates compare with you, from the
  /// keys on this device, and replacing them after a device is lost. Only
  /// with keys on this device.
  Widget? _buildKeysSection(bool signedIn) {
    final l10n = AppLocalizations.of(context)!;
    final version = _keyVersion;
    final fingerprint = _myFingerprint;
    if (!kOrchardsEnabled || !signedIn) return null;
    if (version == null) {
      // The account's keys are published and not on this device.
      if (!_keysElsewhere) return null;
      return _Section(
        label: l10n.accountYourKeys,
        child: _PanelCard(
          key: const ValueKey('account-keys-elsewhere'),
          children: [
            _PanelRow(
              title: l10n.accountKeysElsewhereTitle,
              desc: l10n.accountKeysElsewhereDesc,
              trailing: _NeutralButton(
                key: const ValueKey('account-start-over'),
                label: _startingOver ? l10n.accountStartOverBusy : l10n.accountStartOver,
                onTap: _startingOver ? null : _startOver,
              ),
            ),
          ],
        ),
      );
    }
    return _Section(
      label: l10n.accountYourKeys,
      child: _PanelCard(
        key: const ValueKey('account-your-keys'),
        children: [
          if (fingerprint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.accountKeysVersion(version),
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.onSurface)),
                  const SizedBox(height: 3),
                  Text(l10n.accountKeysWordsDesc,
                      style: TextStyle(fontSize: 11.5, height: 1.45, color: AppColors.onSurfaceDim)),
                  const SizedBox(height: 10),
                  FingerprintBox(fingerprint: fingerprint, key: const ValueKey('account-words')),
                ],
              ),
            ),
          _PanelRow(
            title: l10n.accountReplaceKeys,
            desc: l10n.accountReplaceKeysDesc(version),
            trailing: _NeutralButton(
              key: const ValueKey('account-replace-keys'),
              label: _replacingKeys ? l10n.accountReplaceKeysBusy : l10n.accountReplaceKeysAction,
              onTap: _replacingKeys ? null : _replaceKeys,
            ),
          ),
        ],
      ),
    );
  }

  /// A compact "Redeem a code" card (both desktop and mobile). Opens the
  /// redeem dialog and refreshes entitlements on success (grant is applied
  /// server-side). Only rendered when the account is not fully entitled.
  Widget _buildRedeemCard() {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: AppColors.surfaceLight,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final result = await showRedeemCodeDialog(context);
          // A code for team seats goes to a team: one this account owns,
          // or a new one named now (it said only where such codes go).
          if (result != null && result.teamCode && kOrchardsEnabled && mounted) {
            await redeemTeamCode(context, ref, result.code);
            return;
          }
          if (result == null || !result.ok) return;
          await ref.read(isProProvider.notifier).forceRefresh();
          await ref.read(isCloudSyncProvider.notifier).forceRefresh();
          if (mounted) {
            showTopSnackBar(context, result.message, isSuccess: true);
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Icon(LucideIcons.gift,
                  color: AppColors.accentInk, size: 22),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.settingsMobRedeemCode,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(l10n.settingsMobRedeemCodeDesc,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const Icon(LucideIcons.chevronRight, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ── You (identity) ────────────────────────────────────────────

  /// The You section: one identity card whose shape never changes. Guest fills
  /// it with "Guest / Not signed in" + a Sign in button and NO tier chip
  /// (licence attaches to an account). Signed in fills the name, email and
  /// account id, shows the plan's chip (from the single [accountPlanProvider]
  /// source; a tap explains the plans, 4.0), and a View licence header action.
  Widget _buildYouSection(UserProfile? user) {
    final l10n = AppLocalizations.of(context)!;
    final signedIn = user != null;
    final paid = ref.watch(accountPlanProvider) != AccountPlan.free;
    return _Section(
      label: l10n.accountSectionYou,
      trailing: signedIn
          ? _GhostButton(
              label: l10n.accountViewLicence,
              onTap: () => context.push(Routes.upgrade),
            )
          : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surface,
              AppColors.surface.withValues(alpha: 0.55),
            ],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.v3BorderSubtle),
        ),
        child: Row(
          children: [
            if (signedIn)
              Builder(
                builder: (avatarContext) => GestureDetector(
                  onTap: () => _editProfilePhoto(anchor: avatarContext),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.brandOrange.withValues(alpha: 0.4),
                        width: 2,
                      ),
                    ),
                    padding: const EdgeInsets.all(2),
                    child: const ProfileAvatar(size: 40),
                  ),
                ),
              )
            else
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.onSurfaceDim.withValues(alpha: 0.10),
                  border:
                      Border.all(color: AppColors.v3BorderSubtle),
                ),
                child: Icon(LucideIcons.user,
                    size: 20, color: AppColors.onSurfaceDim),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          signedIn
                              ? (user.displayName == null
                                  ? l10n.profileZestSshUser
                                  : Redactable.account(user.displayName!)
                                      .displayIn(ref))
                              : l10n.accountGuestName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            letterSpacing: -0.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // The plan's chip: signed-in + paid only. A guest shows
                      // no chip (a licence attaches to an account, per spec),
                      // and a free signed-in user has no paid plan to show. A
                      // tap says what each plan is (the plan popover, 4.0).
                      if (signedIn && paid) ...[
                        const SizedBox(width: 8),
                        const PlanChip(key: ValueKey('account-plan-chip')),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  if (signedIn && user.email != null)
                    RedactedText(
                      Redactable.account(user.email!),
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11.5,
                        color: AppColors.onSurfaceDim,
                      ),
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (!signedIn)
                    Text(
                      l10n.accountGuestSub,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: AppColors.onSurfaceDim,
                      ),
                    ),
                  if (signedIn &&
                      user.uid.isNotEmpty &&
                      user.uid != 'desktop-session') ...[
                    const SizedBox(height: 5),
                    _AccountIdRow(uid: user.uid),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            signedIn
                // A Builder, so a computer's menu opens at the button.
                ? Builder(
                    builder: (buttonContext) => _NeutralButton(
                      key: const ValueKey('account-manage'),
                      label: l10n.accountManage,
                      onTap: () => _editProfilePhoto(anchor: buttonContext),
                    ),
                  )
                : zestHasCloud
                    ? _NeutralButton(
                        label: l10n.profileSignIn,
                        onTap: _isSigningIn ? null : _startSignIn,
                      )
                    // A build with no account service: nobody to sign in to.
                    : const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  // ── Attention area ────────────────────────────────────────────

  /// Returns the top attention widget, or null when nothing needs attention.
  /// The interrupted-setup stepper (§C) covers the "recovery key not saved
  /// yet" case too - an unfinished setup is exactly the state in which the
  /// recovery key has not been saved, so a separate critical banner would be
  /// redundant. A completed sync always has a saved recovery key.
  Widget? _buildAttentionArea(
    bool canUseSync,
    bool setupComplete,
    bool pendingSetup,
  ) {
    if (canUseSync && pendingSetup && !setupComplete) {
      return _buildSetupStepper();
    }
    return null;
  }

  /// Interrupted-setup stepper (§C): 1 Account linked · 2 Master password ·
  /// 3 Recovery key. The single primed step carries the one primary action.
  Widget _buildSetupStepper() {
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(currentUserProvider);
    final email = user?.email;
    final shownEmail =
        email == null ? '' : Redactable.account(email).displayIn(ref);
    final snap = _setupSnapshot;
    final step2Done = snap?.hasSalt ?? false;
    final step3Done = snap?.hasRecoverySalt ?? false;
    final doneCount = 1 + (step2Done ? 1 : 0) + (step3Done ? 1 : 0);
    // The "now" (primed) step is the first that isn't done.
    final nowStep = !step2Done ? 2 : (!step3Done ? 3 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AttentionBanner(
          tone: _BannerTone.warn,
          title: l10n.accountSetupHalfTitle,
          body: l10n.accountSetupHalfDesc,
        ),
        const SizedBox(height: 12),
        ZestSectionHeader(
          label: '${l10n.accountFinishSetup} · ${l10n.accountStepOf(doneCount)}',
        ),
        const SizedBox(height: 9),
        _PanelCard(children: [
          _StepRow(
            index: 1,
            done: true,
            isNow: false,
            title: l10n.accountStepAccountLinked,
            desc: shownEmail,
          ),
          _StepRow(
            index: 2,
            done: step2Done,
            isNow: nowStep == 2,
            title: l10n.accountStepChoosePassword,
            desc: l10n.accountStepChoosePasswordDesc,
            action: nowStep == 2
                ? _PrimaryButton(
                    label: l10n.profileContinue,
                    onTap: _runningSetupWizard ? null : _runSyncSetupWizard,
                  )
                : null,
          ),
          _StepRow(
            index: 3,
            done: step3Done,
            isNow: nowStep == 3,
            title: l10n.accountStepSaveRecovery,
            desc: l10n.accountStepSaveRecoveryDesc,
            // Amber warn button - allowed as the ONE critical primary when the
            // recovery key is the outstanding step.
            action: nowStep == 3
                ? _WarnButton(
                    label: l10n.accountSaveRecoveryKey,
                    onTap: _runningSetupWizard ? null : _runSyncSetupWizard,
                  )
                : null,
          ),
        ]),
      ],
    );
  }

  // ── Security ──────────────────────────────────────────────────

  Widget _buildSecuritySection(
      bool signedIn, bool canUseSync, bool setupComplete) {
    final l10n = AppLocalizations.of(context)!;
    final syncReady = canUseSync && setupComplete;
    final hasRecovery = _setupSnapshot?.hasRecoverySalt ?? false;

    final rows = <Widget>[];
    // Device security (app lock, encryption at rest, hardware binding, host
    // keys) has ONE home: Settings > Security. The account's page held a row
    // that only opened it (3.0 UI review: a duplicate of Settings' own row,
    // with a button where every other row has a chevron); it is gone, and
    // this section holds what belongs to the account alone.
    // Two-step sign-in (3.0; passkeys since 3.3) is its own card,
    // above these rows (TwoStepSection). A guest sees the neutral "Needs an
    // account" chip there: a second step needs an identity to attach to.
    // How the account signs in (3.0: one account per email address), with
    // the way to a password for an account made through Google or Apple.
    if (signedIn) rows.add(_signInWaysRow());
    // What ZestSSH Cloud keeps so that each computer can open this account's data after
    // a sign-in (to-do 60).
    if (signedIn && ref.read(profileControllerProvider).on) {
      rows.add(_PanelRow(
        title: l10n.lockedCopiesTitle,
        desc: l10n.lockedCopiesDesc,
        trailing: _NeutralButton(
          key: const ValueKey('account-locked-copies'),
          label: l10n.olderDataAction,
          onTap: () => showLockedCopies(context, ref),
        ),
      ));
    }
    if (syncReady) {
      rows.add(_PanelRow(
        title: l10n.accountMasterPassword,
        desc: l10n.accountMasterPasswordDesc,
        trailing: _NeutralButton(
          label: l10n.accountChange,
          onTap: _changeSyncPassword,
        ),
      ));
      // The recovery key (3.0): shown once when it is made and never
      // kept here, so the row says whether the store holds one and makes a
      // new one. What this device saw last shows at once; the store is asked
      // once per visit.
      if (!_recoveryKeyChecked) {
        _recoveryKeyChecked = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadRecoveryKeyStatus());
      }
      final recovery = _recoveryKeySet ?? (hasRecovery ? true : null);
      rows.add(_PanelRow(
        title: l10n.zestProfileNavRecoveryKey,
        desc: switch (recovery) {
          true => l10n.accountRecoveryKeyDesc,
          false => l10n.accountRecoveryKeyNone,
          null => l10n.accountRecoveryKeyUnknown,
        },
        titleTrailing: recovery == true
            ? _StatusPill(
                label: l10n.zestProfileRecoverySaved,
                color: AppColors.success,
              )
            : null,
        trailing: _savingRecoveryKey
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : recovery == false
                ? _WarnButton(
                    label: l10n.accountRecoveryKeyMake,
                    onTap: _replaceRecoveryKey,
                  )
                // Check a kit's key without changing anything (3.0,
                // recovery kit), or make a new one.
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _NeutralButton(
                        key: const ValueKey('recovery-key-check'),
                        label: l10n.recoveryCheckButton,
                        onTap: _checkRecoveryKey,
                      ),
                      const SizedBox(width: 8),
                      _NeutralButton(
                        label: l10n.accountRecoveryKeyReplace,
                        onTap: _replaceRecoveryKey,
                      ),
                    ],
                  ),
      ));
      // Teams (3.0): the account's own keys are their own section below
      // (your words, and replacing the keys).
    }

    return _Section(
      label: l10n.accountSecurity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TwoStepSection(
            signedIn: signedIn,
            // Sync on ZestSSH Cloud, set up and on here: the card may ask for
            // the sync password once, so that a recovery keeps the data.
            proveSyncPassword:
                syncReady && !ref.watch(syncIsBringYourOwnProvider) ? _proveSyncPasswordForRecovery : null,
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 10),
            _PanelCard(children: rows),
          ],
          // Before sync is set up, master password + recovery key don't exist
          // yet - say so, instead of leaving a gap where two rows will appear.
          if (!syncReady) ...[
            const SizedBox(height: 8),
            _PanelNote(text: l10n.syncSecurityPending, standalone: true),
          ],
        ],
      ),
    );
  }

  // ── How you sign in ───────────────────────────────────────────

  /// The ways into the account, each named once, and the password: an
  /// account made through Google or Apple has none until its owner sets one
  /// with the emailed link (then the address and the password sign in to the
  /// same account); one that has it changes it the same way.
  Widget _signInWaysRow() {
    final l10n = AppLocalizations.of(context)!;
    return ref.watch(signInWaysProvider).when(
          loading: () => _PanelRow(
            key: const ValueKey('sign-in-ways'),
            title: l10n.accountSignInWays,
            trailing: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          // A computer signed in through the browser asks ZestSSH Cloud, and
          // where it cannot say, the row says where the ways are seen and
          // changed, as the two-step row does: no error, and no Retry that
          // would change nothing.
          error: (e, _) {
            AppLogger.warning('Sign-in ways: not loaded (${errorKind(e)})');
            final web = AuthService.currentUser == null;
            return _PanelRow(
              key: const ValueKey('sign-in-ways'),
              title: l10n.accountSignInWays,
              desc: web ? l10n.accountSignInWaysWeb : l10n.accountSignInWaysFailed,
              trailing: web
                  ? _NeutralButton(label: l10n.twoStepOpenWeb, onTap: _openTwoStepWeb)
                  : _NeutralButton(
                      label: l10n.retry,
                      onTap: () => ref.invalidate(signInWaysProvider),
                    ),
            );
          },
          data: (ways) {
            if (ways == null) return const SizedBox.shrink();
            return _PanelRow(
              key: const ValueKey('sign-in-ways'),
              title: l10n.accountSignInWays,
              below: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final way in ways.ways)
                    _StatusPill(label: _signInWayName(way, l10n), color: AppColors.onSurfaceDim),
                ],
              ),
              desc: ways.hasPassword ? l10n.accountSignInWaysAny : l10n.accountSignInWaysNoPassword,
              trailing: _NeutralButton(
                key: const ValueKey('sign-in-ways-password'),
                label: ways.hasPassword ? l10n.accountChangePassword : l10n.accountSetPassword,
                onTap: _sendingPasswordLink || ways.email.isEmpty ? null : () => _sendPasswordLink(ways.email),
              ),
            );
          },
        );
  }

  static String _signInWayName(SignInWay way, AppLocalizations l10n) => switch (way) {
        SignInWay.google => 'Google',
        SignInWay.apple => 'Apple',
        SignInWay.microsoft => 'Microsoft',
        SignInWay.company => l10n.signInWayCompany,
        SignInWay.password => l10n.signInWayPassword,
      };

  bool _sendingPasswordLink = false;

  /// Emails [email] the link to choose a password, and says whether it went.
  Future<void> _sendPasswordLink(String email) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _sendingPasswordLink = true);
    final sent = await ref.read(passwordLinkSenderProvider)(email);
    if (!mounted) return;
    setState(() => _sendingPasswordLink = false);
    if (sent) {
      showTopSnackBar(context, l10n.accountPasswordLinkSent(email), isSuccess: true);
      return;
    }
    // A device with Firebase tried that as well: there is nothing further to go to.
    if (signsInOnDevice) {
      showTopSnackBar(
        context,
        ErrorCodes.withCode(l10n.accountPasswordLinkFailed, ErrorCodes.passwordLinkNotSent),
        isError: true,
      );
      return;
    }
    // A computer holds no Firebase: the website's sign-in page reaches it from the
    // browser, so ZestSSH Cloud being busy or down never leaves anyone without a link.
    final open = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.accountPasswordLinkOtherWayTitle,
      body: ErrorCodes.withCode(l10n.accountPasswordLinkOtherWayBody, ErrorCodes.passwordLinkNotSent),
      confirmLabel: l10n.accountPasswordLinkOpenSite,
    );
    if (open != true || !mounted) return;
    final opened = await ref.read(passwordLinkPageOpenerProvider)();
    if (!opened && mounted) showTopSnackBar(context, l10n.profileCouldNotOpenBrowser, isError: true);
  }

  // ── Two-step sign-in ──────────────────────────────────────────

  // Two-step sign-in has a card of its own in the Security section
  // (TwoStepSection, 3.3): what ZestSSH Cloud says of the account, a
  // recovery someone asked for, the passkeys, the authenticator app and the
  // recovery codes. The sign-in ways row sends a computer to zestssh.com
  // where it cannot say.

  Future<void> _openTwoStepWeb() async {
    try {
      await launchUrl(Uri.parse(kTwoStepWebPage),
          mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.warning('Opening the two-step page failed: $e');
      if (mounted) {
        showTopSnackBar(
            context, AppLocalizations.of(context)!.profileCouldNotOpenBrowser,
            isError: true, details: '$e');
      }
    }
  }

  // ── Devices ───────────────────────────────────────────────────

  Widget _buildDevicesSection(bool signedIn) {
    final l10n = AppLocalizations.of(context)!;
    // Last-sync time is NOT shown per-device: it has one home, the SYNC section
    // alone. Signed out, this is identity only: this device's name
    // and OS. Signed in, it is the account's device list from ZestSSH Cloud
    // (3.0): each device's platform and when it signed in, nothing
    // else, with sign-out. ZestSSH tracks nothing more about a personal
    // account's devices (no last active, no OS or app version).
    if (!signedIn) {
      return _Section(
        label: l10n.zestProfileNavDevices,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelCard(children: [
              _DeviceRow(
                icon: _devicePlatformIcon(),
                name: _thisDeviceNameShown(),
                subtitle: _deviceOsLabel(),
                thisDeviceLabel: l10n.zestProfileThisDevice,
              ),
            ]),
            const SizedBox(height: 8),
            _PanelNote(text: l10n.accountDevicesGuestNote, standalone: true),
          ],
        ),
      );
    }

    // A list belongs to the account it was loaded for.
    final uid = ref.read(currentUserProvider)?.uid;
    if (uid != _devicesUid) {
      _devicesUid = uid;
      _devices = null;
      _devicesFailed = false;
    }
    if (_devices == null && !_devicesLoading && !_devicesFailed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevices());
    }
    final devices = _devices;
    final rows = <Widget>[];
    if (devices == null) {
      rows.add(_devicesFailed
          ? _PanelRow(
              title: l10n.devicesLoadFailed,
              // Why, with its code, as every error says it (the design audit).
              desc: _devicesError == null ? null : cloudStopped(l10n, _devicesError!),
              trailing: _NeutralButton(label: l10n.retry, onTap: _loadDevices),
            )
          : const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ));
    } else {
      for (final d in devices) {
        rows.add(_DeviceRow(
          icon: d.isPhone ? LucideIcons.smartphone : LucideIcons.monitor,
          name: _sessionName(l10n, d),
          subtitle: _sessionDetails(l10n, d),
          thisDeviceLabel: d.current ? l10n.zestProfileThisDevice : null,
          trailing: d.current
              ? null
              : _NeutralButton(
                  label: l10n.devicesSignOut,
                  onTap: _devicesBusy ? null : () => _signOutDevice(d),
                ),
        ));
      }
    }

    return _Section(
      label: l10n.zestProfileNavDevices,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelCard(children: rows),
          // Teams (3.0): hand the sync key to a new device
          // after both screens show the same words. Only where this device
          // holds the key, on ZestSSH Cloud.
          if (kOrchardsEnabled && _setupSnapshot?.isComplete == true && !ref.watch(syncIsBringYourOwnProvider)) ...[
            const SizedBox(height: 8),
            _PanelCard(children: [
              _PanelRow(
                title: l10n.devicesApproveTitle,
                desc: l10n.devicesApproveDesc,
                trailing: _NeutralButton(
                  key: const ValueKey('devices-approve'),
                  label: l10n.devicesApproveAction,
                  onTap: () => showApproveNewDevice(context),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 8),
          _PanelCard(children: [
            _PanelRow(
              title: l10n.devicesSignOutEverywhere,
              desc: l10n.devicesSignOutEverywhereDesc,
              trailing: _NeutralButton(
                label: l10n.devicesSignOutEverywhere,
                onTap: _devicesBusy ? null : _signOutEverywhere,
                danger: true,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          _PanelNote(text: l10n.devicesOlderVersionsNote, standalone: true),
        ],
      ),
    );
  }

  /// A device's name in the list: its platform. These are product names, not
  /// translated copy.
  String _sessionName(AppLocalizations l10n, DeviceSessionInfo d) {
    return switch (d.platform) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      _ => l10n.devicesUnknownDevice,
    };
  }

  String _sessionDetails(AppLocalizations l10n, DeviceSessionInfo d) {
    final parts = <String>[
      if (d.createdAt != null)
        l10n.devicesSignedInOn(DateFormat.yMMMd(l10n.localeName).format(d.createdAt!)),
    ];
    return parts.join(' \u00b7 ');
  }

  Future<void> _loadDevices() async {
    if (_devicesLoading || !mounted) return;
    setState(() {
      _devicesLoading = true;
      _devicesFailed = false;
    });
    try {
      final service = ref.read(deviceSessionServiceProvider);
      // Make sure this device is listed (and marked) before listing.
      await service.ensure();
      final list = await service.api.list();
      final uid = ref.read(currentUserProvider)?.uid;
      if (mounted && uid == _devicesUid) setState(() => _devices = list);
    } catch (e) {
      AppLogger.warning('Loading signed-in devices failed: $e');
      if (mounted) {
        setState(() {
          _devicesFailed = true;
          _devicesError = e;
        });
      }
    } finally {
      if (mounted) setState(() => _devicesLoading = false);
    }
  }

  Future<void> _signOutDevice(DeviceSessionInfo device) async {
    final l10n = AppLocalizations.of(context)!;
    final name = _sessionName(l10n, device);
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.devicesSignOutConfirmTitle,
      body: l10n.devicesSignOutConfirmBody(name),
      confirmLabel: l10n.devicesSignOut,
    );
    if (ok != true || !mounted) return;
    final result = await _withRecentSignIn((api) => api.signOut(device.id));
    if (!mounted) return;
    if (result == _DeviceActionResult.done) {
      showTopSnackBar(context, l10n.devicesSignedOutOne(name));
      await _loadDevices();
    }
  }

  Future<void> _signOutEverywhere() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.devicesSignOutEverywhereConfirmTitle,
      body: l10n.devicesSignOutEverywhereConfirmBody,
      confirmLabel: l10n.devicesSignOutEverywhere,
    );
    if (ok != true || !mounted) return;
    final result =
        await _withRecentSignIn((api) => api.signOutEverywhere());
    if (!mounted) return;
    if (result != _DeviceActionResult.done &&
        result != _DeviceActionResult.googleNotRevoked) {
      return;
    }
    // Every session is gone on the server, this one included.
    await signOutAccount(ref, signedOutElsewhere: true);
    if (!mounted) return;
    setState(() => _devices = null);
    if (result == _DeviceActionResult.googleNotRevoked) {
      // Phones and tablets may still be signed in through Google: the amber
      // sentence (it was a yellow dialog with OK).
      await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.warning,
        title: l10n.devicesSignOutEverywhere,
        body: '',
        warning: l10n.devicesGoogleRevokeFailed,
        showCancel: false,
        confirmLabel: l10n.desktopGotIt,
      );
    } else {
      showTopSnackBar(context, l10n.devicesSignedOutEverywhereDone);
    }
  }

  /// Runs [action]. When ZestSSH Cloud wants a sign-in from the last few
  /// minutes first, says so, signs the person in again and retries once.
  Future<_DeviceActionResult> _withRecentSignIn(
      Future<void> Function(DeviceSessionsApi api) action) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(deviceSessionServiceProvider).api;
    setState(() => _devicesBusy = true);
    try {
      try {
        await action(api);
        return _DeviceActionResult.done;
      } on DeviceSessionsException catch (e) {
        if (!e.needsRecentSignIn) rethrow;
      }
      if (!mounted) return _DeviceActionResult.cancelled;
      final shown = await confirmOrSignIn(context, ref, window: StepUpWindow.account, about: l10n.devicesSignInAgainBody);
      if (shown != ItsYou.confirmed || !mounted) return _DeviceActionResult.cancelled;
      await action(api);
      return _DeviceActionResult.done;
    } on DeviceSessionsException catch (e) {
      // This device itself was signed out elsewhere: the app handles that.
      if (e.signedOut) return _DeviceActionResult.failed;
      if (e.identityRevokeFailed) return _DeviceActionResult.googleNotRevoked;
      if (mounted) {
        showTopSnackBar(context, cloudStopped(l10n, e, status: e.status) ?? l10n.devicesActionFailed, isError: true, details: '$e');
      }
      return _DeviceActionResult.failed;
    } catch (e) {
      AppLogger.warning('Signed-in devices action failed: $e');
      if (mounted) {
        showTopSnackBar(context, cloudStopped(l10n, e) ?? l10n.devicesActionFailed, isError: true, details: '$e');
      }
      return _DeviceActionResult.failed;
    } finally {
      if (mounted) setState(() => _devicesBusy = false);
    }
  }

  // ── Sync ──────────────────────────────────────────────────────

  Widget _buildSyncSectionV2(
    bool canUseSync,
    SyncState syncState,
    bool setupComplete,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(syncProviderConfigProvider);
    // "Chosen" = a real backend has been selected. The default is the hosted
    // ZestSSH Cloud, which a guest can't reach, so a fresh/default state reads
    // "Not chosen" rather than defaulting to the one option they can't use
    // (spec 2 / §B). Any BYO backend, a completed setup, or ZestSSH Cloud for
    // someone signed in who has Juiced (where Set up goes straight to it)
    // count as chosen. For an account without Juiced ZestSSH Cloud is no
    // more a choice than for a guest: its storage comes with Juiced (Set up
    // says so, with the free choices), and a setup begun on it and refused
    // does not make it one. (A setup begun on storage of one's own is
    // counted by its kind.)
    final storageChosen = setupComplete ||
        config.kind != SyncBackendKind.zestServer ||
        (ref.watch(currentUserProvider) != null && ref.watch(isCloudSyncProvider));

    // ── Sync row: set-up shows status + On + Sync now; not set up shows the
    // encryption promise + a Set up sync action. The help text names the
    // master password and recovery key, never the cloud (spec 1 note 4). ──
    // The card's outline says how sync stands at a glance (the status bar
    // reads the same syncHealthProvider): red when it is failing, amber when
    // this device is behind or paused, the usual hairline otherwise (off
    // too: not set up is no failure).
    final health = ref.watch(syncHealthProvider);
    final Widget syncRow;
    final Color? cardTone;
    Widget? scheduleRow;
    if (setupComplete) {
      final confirmedAt = _newer(syncState.lastSyncedAt, health.confirmedAt);
      final failing = syncState.error != null || health.health == SyncHealth.failing;
      // Paused by its person (3.0): sync stays set up, nothing runs by
      // itself until the pause ends, and Sync now still syncs.
      final pause = health.health == SyncHealth.paused ? health.pause : null;
      final pausedUntil = pause?.until;
      final statusDesc = syncState.isSyncing || health.health == SyncHealth.syncing
          ? l10n.profileSyncingUpload
          : syncState.error != null
              ? syncState.error!
              : health.health == SyncHealth.failing
                  ? syncFailingText(health, l10n, unknown: l10n.statusBarSyncError)
                  : pause != null
                      ? (pausedUntil == null
                          ? l10n.accountSyncPausedIndefinitely
                          : l10n.accountSyncPausedUntil(syncPausedUntilText(pausedUntil, l10n.localeName)))
                      : health.health == SyncHealth.behind && health.waiting
                          ? l10n.profileSyncWaiting
                          : confirmedAt != null
                              ? profileLastSyncedText(l10n, confirmedAt)
                              : l10n.profileNeverSynced;
      cardTone = failing
          ? AppColors.v3Error
          : health.health == SyncHealth.behind || pause != null
              ? AppColors.v3Warning
              : null;
      syncRow = _PanelRow(
        title: l10n.zestProfileNavSync,
        desc: statusDesc,
        titleTrailing: pause != null
            ? _StatusPill(label: l10n.accountSyncPausedPill, color: AppColors.v3Warning)
            : _StatusPill(
                label: l10n.settingsInlineStatusOn,
                color: AppColors.success,
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NeutralButton(
              key: ValueKey(pause != null ? 'sync-resume' : 'sync-pause'),
              label: pause != null ? l10n.accountSyncResume : l10n.accountSyncPause,
              onTap: pause != null
                  ? () => unawaited(ref.read(autoSyncServiceProvider).endPause())
                  : () => unawaited(pauseSyncAsked(context, ref)),
            ),
            const SizedBox(width: 8),
            _NeutralButton(label: l10n.accountSyncNow, onTap: _syncNow),
          ],
        ),
      );
      // When it syncs by itself (3.0): on every change, every so many
      // minutes or hours, or only by hand.
      scheduleRow = _PanelRow(
        title: l10n.settingsSyncMode,
        desc: syncScheduleLabel(l10n, ref.watch(syncModeProvider), ref.watch(syncIntervalProvider)),
        trailing: _NeutralButton(
          key: const ValueKey('sync-schedule'),
          label: l10n.accountChange,
          onTap: () => unawaited(chooseSyncScheduleAsked(context, ref)),
        ),
      );
    } else {
      // Not set up is a choice, not a failure: the usual hairline and a
      // neutral Off (it was outlined and marked in red, as a failing sync
      // is).
      cardTone = null;
      syncRow = _PanelRow(
        key: const ValueKey('sync-row-off'),
        title: l10n.zestProfileNavSync,
        desc: l10n.accountSyncHelpOff,
        titleTrailing: _StatusPill(
          label: l10n.settingsInlineStatusOff,
          color: AppColors.v3TextTertiary,
        ),
        trailing: _NeutralButton(
          label: l10n.accountSyncSetUp,
          onTap: _startSyncSetup,
        ),
      );
    }

    // ── Storage row: same slot both states, differing only by content. Guest
    // reads "Not chosen"/"Choose"; a chosen store reads its label/"Change". ──
    final storageLabel = (config.label != null && config.label!.isNotEmpty)
        ? '${config.kind.label} · '
            '${Redactable.freeText(config.label!).displayIn(ref)}'
        : config.kind.label;
    final storageRow = _PanelRow(
      title: l10n.zestProfileNavStorage,
      desc: l10n.accountStorageHelp,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              storageChosen ? storageLabel : l10n.accountStorageNotChosen,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                color: storageChosen
                    ? AppColors.onSurface
                    : AppColors.onSurfaceDim,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // One word for one action: Change, as the rows above say it.
          _NeutralButton(
            label: storageChosen
                ? l10n.accountChange
                : l10n.accountStorageChoose,
            onTap: _openStoragePicker,
          ),
        ],
      ),
    );

    return _Section(
      label: l10n.zestProfileNavSync,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelCard(
            key: const ValueKey('sync-card'),
            tone: cardTone,
            children: [
              syncRow,
              ?scheduleRow,
              storageRow,
              // Restoring is a row of the card it belongs to (its button
              // stood alone under the card).
              if (setupComplete)
                _PanelRow(
                  key: const ValueKey('sync-restore-row'),
                  title: l10n.accountRestore,
                  desc: l10n.teamAdminRestoreDesc,
                  trailing: _NeutralButton(
                    key: const ValueKey('sync-restore'),
                    label: l10n.teamAdminRestoreAction,
                    onTap: _restoreFromCloud,
                  ),
                ),
            ],
          ),
          // Raw failure text (socket/HTTP trace) behind a copy button.
          if (setupComplete &&
              syncState.error != null &&
              syncState.errorDetail != null)
            Align(
              alignment: Alignment.centerLeft,
              child: CopyDetailsButton(detail: syncState.errorDetail!),
            ),
          if (setupComplete) ...[
            const SizedBox(height: 8),
            _PanelNote(text: l10n.syncMergeNoteThreeWay, standalone: true),
            // A store that takes any write: said, where that is the one in use.
            if (!ref.watch(syncProviderConfigProvider).kind.refusesCrossingWrites)
              _PanelNote(
                  key: const ValueKey('sync-note-crossing-writes'), text: l10n.syncNoteCrossingWrites, standalone: true),
          ],
        ],
      ),
    );
  }

  /// "Set up sync": open the storage picker first when nothing usable is chosen
  /// (a guest on the default cloud), else run the master-password + recovery
  /// wizard against the chosen store.
  void _startSyncSetup() {
    final config = ref.read(syncProviderConfigProvider);
    final signedIn = ref.read(currentUserProvider) != null;
    final storageChosen =
        config.kind != SyncBackendKind.zestServer || signedIn;
    if (!storageChosen) {
      _openStoragePicker();
      return;
    }
    _runSyncSetupWizard();
  }

  // ── Data (export / import) ────────────────────────────────────

  Widget _buildDataSection() {
    final l10n = AppLocalizations.of(context)!;
    final interval = ref.watch(autoBackupIntervalProvider);
    final lastBackup = ref.watch(settingsServiceProvider).lastAutoBackupTime;
    final intervalLabel = interval == 'daily'
        ? l10n.settingsInlineDaily
        : interval == 'weekly'
            ? l10n.settingsInlineWeekly
            : l10n.settingsInlineOff;
    final lastBackupDesc = lastBackup == null
        ? l10n.accountLastBackupNever
        : l10n.accountLastBackup(DateFormat.yMd(l10n.localeName).add_jm().formatPlain(lastBackup));
    return _Section(
      label: l10n.accountData,
      child: _PanelCard(children: [
        // Guest data beside this account: the question it was asked once, for as long
        // as there is anything to bring.
        GuestDataRow(
          builder: (context, summary, onChoose) => _PanelRow(
            title: l10n.guestDataTitle,
            desc: summary.hosts > 0 ? l10n.guestDataRowDesc(summary.hosts) : l10n.guestDataRowDescKeys(summary.keys),
            trailing: _NeutralButton(
              key: const ValueKey('account-guest-data'),
              label: l10n.olderDataAction,
              onTap: onChoose,
            ),
          ),
        ),
        _PanelRow(
          title: l10n.accountExport,
          desc: l10n.accountExportDescAll,
          trailing: _NeutralButton(
            label: l10n.accountExportAction,
            onTap: _exportBackup,
          ),
        ),
        _PanelRow(
          title: l10n.accountImport,
          desc: l10n.accountImportDesc,
          trailing: _NeutralButton(
            label: l10n.accountImportAction,
            onTap: _importBackup,
          ),
        ),
        // Your hosts as an SSH config, with no keys and no passwords: for
        // another SSH client, or to bring hosts into a team (Import hosts,
        // then SSH config). It was on a phone's Settings only, and not to
        // be found on a computer.
        _PanelRow(
          title: l10n.settingsMobConnectionsAsSshConfig,
          desc: l10n.settingsMobConnectionsAsSshConfigDesc,
          trailing: _NeutralButton(
            key: const ValueKey('account-export-ssh-config'),
            label: l10n.accountExportAction,
            onTap: () => exportSshConfig(context, ref),
          ),
        ),
        _PanelRow(
          title: l10n.accountAutoBackups,
          desc: lastBackupDesc,
          // Its state as a pill, as Sync's is: green while it runs, grey
          // while off (it was plain grey words beside the button).
          titleTrailing: _StatusPill(
            key: ValueKey('auto-backup-state-$interval'),
            label: intervalLabel,
            color: interval == 'daily' || interval == 'weekly' ? AppColors.success : AppColors.onSurfaceDim,
          ),
          trailing: _NeutralButton(
            label: l10n.accountChange,
            onTap: _configureAutoBackup,
          ),
        ),
        // Where automatic backups are copied (a WebDAV server): a computer
        // had no way to add one (found in a code audit).
        _PanelRow(
          title: l10n.accountBackupPlaces,
          desc: l10n.accountBackupPlacesDesc,
          trailing: _NeutralButton(
            key: const ValueKey('account-backup-places'),
            label: l10n.accountChange,
            onTap: () => showBackupPlacesDialog(context),
          ),
        ),
        _PanelRow(
          title: l10n.accountClearCache,
          desc: l10n.accountClearCacheHelp,
          trailing: _NeutralButton(
            label: l10n.settingsInlineClear,
            onTap: _clearCache,
          ),
        ),
      ]),
    );
  }

  /// Pick the automatic-backup cadence (Off / Daily / Weekly). The backup is
  /// made on this device and copied to the backup places set up in Settings;
  /// turning it on asks for its password when none is kept.
  Future<void> _configureAutoBackup() async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(autoBackupIntervalProvider);
    // One of a few: the app's choice (3.4), titled, with Cancel (a sheet of
    // three rows with no title before).
    final choice = await showZestChoice<String>(
      context,
      title: l10n.settingsAutoBackup,
      icon: LucideIcons.archive,
      selected: current,
      choices: [
        for (final (value, label) in [
          ('off', l10n.settingsInlineOff),
          ('daily', l10n.settingsInlineDaily),
          ('weekly', l10n.settingsInlineWeekly),
        ])
          ZestChoice(value: value, label: label, key: ValueKey('auto-backup-$value')),
      ],
    );
    if (choice != null && mounted) {
      await setAutoBackupInterval(context, ref, choice);
    }
  }

  /// Clear ephemeral caches (sync/backup bookkeeping timestamps). Nothing the
  /// user created is touched.
  Future<void> _clearCache() async {
    final l10n = AppLocalizations.of(context)!;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.remove('last_sync_time');
    await prefs.remove('last_auto_backup_time');
    if (mounted) {
      showTopSnackBar(context, l10n.accountClearCacheDone, isSuccess: true);
    }
  }

  /// Wipe everything ZestSSH keeps on this device: every connection, key,
  /// password, certificate and snippet, the secrets in the OS secure storage,
  /// automatic backups, logs and settings (see [LocalDataWiper]). Local-only
  /// and irreversible. Sync goes off and the account is signed out first, so
  /// the wipe is never uploaded and nothing comes back on the next sync; the
  /// synced copy stays where it is.
  Future<void> _deleteAllLocalData() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await _confirmAction(
      l10n.accountDeleteLocal,
      l10n.accountDeleteLocalHelp,
      isDestructive: true,
    );
    if (ok != true || !mounted) return;
    // On a computer with other profiles: this profile, or everything here.
    final profiles = ref.read(profileControllerProvider);
    var everything = false;
    if (profiles.on && await profiles.otherDataHere()) {
      if (!mounted) return;
      if (!profiles.mayDeleteEverything) {
        // Someone else's accounts are here: theirs go only with their own sign-in
        // (found in a code review), so this profile only.
        final only = await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.destructive,
          title: l10n.deleteLocalWhichTitle,
          body: l10n.deleteLocalWhichBodySomeoneElses,
          confirmLabel: l10n.deleteLocalThisProfile,
        );
        if (only != true || !mounted) return;
      } else {
        final others = profiles.otherAccounts;
        final choice = await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.destructive,
          title: l10n.deleteLocalWhichTitle,
          body: others.isEmpty
              ? l10n.deleteLocalWhichBodyGuest
              : l10n.deleteLocalWhichBody(others.map((a) => Redactable.account(a).display).join(', ')),
          confirmLabel: l10n.deleteLocalThisProfile,
          cancelLabel: l10n.deleteLocalEverything,
        );
        if (!mounted || choice == null) return;
        if (choice == false) {
          final sure = await ZestConfirmDialog.show(
            context,
            tone: ZestDialogTone.destructive,
            title: l10n.deleteLocalEverything,
            body: l10n.deleteLocalEverythingSure,
            confirmLabel: l10n.delete,
          );
          if (sure != true || !mounted) return;
          everything = true;
        }
      }
    }
    final deleted = await deleteAllLocalData(
      ref.read,
      everything: everything,
      // Keys given to the system's SSH agent that it did not take back: said, and asked;
      // their fingerprints stay on the computer's list either way.
      whenKeysStay: () async =>
          mounted &&
          await ZestConfirmDialog.show(
                context,
                // It deletes, red; what ssh may still do, in amber.
                tone: ZestDialogTone.destructive,
                title: l10n.accountDeleteLocal,
                body: '',
                warning: l10n.deleteLocalAgentKeysStay,
                confirmLabel: l10n.delete,
              ) ==
              true,
    );
    if (!deleted || !mounted) return;
    // Said with the app's own notice (a plain dialog built here).
    await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.success,
      title: l10n.moreDataDeletedTitle,
      body: l10n.moreDataDeletedMessage,
      confirmLabel: l10n.done,
      showCancel: false,
    );
  }

  // ── Danger zone ───────────────────────────────────────────────

  /// The Danger zone: the account's rows ([account]: sign out, reset cloud
  /// sync, delete the account) and this device's ([local]: delete all local
  /// data; on Settings' Backups and data page also reset all settings). In
  /// Settings each page has its own share (4.0); a phone's Account page has
  /// all of them, as before.
  Widget _buildDangerZone(UserProfile? user, {bool account = true, bool local = true}) {
    final l10n = AppLocalizations.of(context)!;
    final signedIn = user != null;
    // A reset is the hosted store's: a store of one's own is emptied by the
    // person who runs it.
    final hostedStore = ref.watch(syncProviderConfigProvider).kind == SyncBackendKind.zestServer;
    final rows = <Widget>[
      // Sign out (signed in only): ends the account's sign-in here; what
      // is on the device stays, and its row says so.
      if (account && signedIn)
        _DangerRow(
          title: l10n.accountSignOutThisDevice,
          desc: ref.read(profileControllerProvider).on ? l10n.accountSignOutDescLocks : l10n.accountSignOutDesc,
          actionLabel: l10n.accountSignOutAction,
          onAction: _signOut,
        ),
      // Delete all local data: available in BOTH states (a guest has local
      // data too), so it never disappears when signed out.
      if (local)
        _DangerRow(
          title: l10n.accountDeleteLocal,
          desc: l10n.accountDeleteLocalHelp,
          actionLabel: l10n.delete,
          onAction: _deleteAllLocalData,
          destructive: true,
        ),
      // Reset all settings, with the data of this device in Settings (it was
      // General's own Danger zone): what survives is said in its question.
      if (local && widget.part == ProfilePart.data)
        KeyedSubtree(
          key: const ValueKey('settings-danger-zone'),
          child: _DangerRow(
            title: l10n.settingsInlineResetAllSettings,
            desc: l10n.settingsResetAllHelp,
            actionLabel: l10n.settingsInlineReset,
            onAction: _resetAllSettings,
            destructive: true,
          ),
        ),
      // Reset cloud sync (signed in, on ZestSSH Cloud): for a lost master
      // password. The cloud copy goes out of use; nothing here is deleted.
      if (account && signedIn && hostedStore)
        KeyedSubtree(
          key: const ValueKey('reset-cloud-sync'),
          child: _DangerRow(
            title: l10n.syncResetTitle,
            desc: l10n.syncResetRowDesc,
            actionLabel: l10n.syncResetRowAction,
            onAction: _resetCloudSync,
            destructive: true,
          ),
        ),
      // Delete account (signed in only): purges the server side too.
      if (account && signedIn)
        _DangerRow(
          title: l10n.accountDeleteAccount,
          desc: l10n.accountDeleteAccountDesc,
          actionLabel: l10n.accountDeleteAction,
          onAction: _deleteAccount,
          destructive: true,
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return _Section(
      label: l10n.accountDangerZone,
      danger: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 9),
            rows[i],
          ],
        ],
      ),
    );
  }

  /// Every setting back to its default, after a question in the tone of
  /// what cannot be taken back; the data is not touched (Settings' Backups
  /// and data page, 4.0; it was General's).
  Future<void> _resetAllSettings() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.settingsInlineResetAllSettingsTitle,
      body: l10n.settingsResetAllHelp,
      confirmLabel: l10n.settingsInlineReset,
    );
    if (confirmed != true) return;
    await ref.read(settingsServiceProvider).resetAllToDefaults();
    if (mounted) showTopSnackBar(context, l10n.settingsInlineSettingsResetRestart, width: 360);
  }

  /// Friendly OS name for the current device (data, not translated copy).
  String _deviceOsLabel() {
    final os = Platform.operatingSystem;
    switch (os) {
      case 'macos':
        return 'macOS';
      case 'ios':
        return 'iOS';
      default:
        return os.isEmpty ? os : os[0].toUpperCase() + os.substring(1);
    }
  }

  /// [_thisDeviceName] in its display form (recording mode): a machine name
  /// identifies the user's device, so it takes the account rule; the OS-label
  /// fallback is a product name and passes through.
  String _thisDeviceNameShown() {
    final name = _thisDeviceName();
    if (name == _deviceOsLabel()) return name;
    return Redactable.account(name).displayIn(ref);
  }

  /// A friendly name for the current machine. On desktop [Platform.localHostname]
  /// is a real machine name (e.g. "DESKTOP-AB12"); if it is empty or the OS
  /// refuses to report it, fall back to the OS label. Never fabricated.
  String _thisDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) return host;
    } catch (_) {
      // localHostname can throw (OSError) on some platforms - fall through to
      // the OS label rather than surfacing an error in the UI.
    }
    return _deviceOsLabel();
  }

  /// Platform glyph for the current device: a phone on mobile, a monitor on
  /// desktop. Purely presentational.
  IconData _devicePlatformIcon() {
    return (Platform.isAndroid || Platform.isIOS)
        ? LucideIcons.smartphone
        : LucideIcons.monitor;
  }

  // ── Data actions (export / import) - the ONE home for backups ──

  // Full-backup export / import now live in the shared backup_actions helpers
  // so Settings > Data drives the exact same flow. These thin wrappers keep the
  // Profile buttons working.
  Future<void> _exportBackup() => runBackupExport(context, ref);

  Future<void> _importBackup() => runBackupImport(context, ref);

  /// Typed-email confirmation before account deletion. Falls back
  /// to a plain destructive confirm when the signed-in user has no email.
  Future<bool> _confirmDeleteByEmail(String? email) async {
    final l10n = AppLocalizations.of(context)!;
    if (email == null || email.isEmpty) {
      final ok = await _confirmAction(
        l10n.profileDeleteAccount,
        l10n.profileDeleteAccountConfirmMsg,
        isDestructive: true,
      );
      return ok == true;
    }
    // The confirmation phrase shows the real email, and the user must type it
    // back: the reveal gate (spec 5) only proceeds by turning recording mode
    // off, so a recording never captures it.
    if (!await confirmRevealWhileRecording(context, ref)) return false;
    if (!mounted) return false;
    final typed = await showZestInputDialog(
      context: context,
      title: l10n.accountDeleteConfirmTitle,
      subtitle: l10n.accountDeleteConfirmSubtitle(email),
      icon: LucideIcons.trash2,
      tone: ZestDialogTone.destructive,
      fieldLabel: l10n.accountEmailLabel,
      hintText: email,
      confirmLabel: l10n.delete,
      validator: (v) => v.trim().toLowerCase() == email.toLowerCase()
          ? null
          : l10n.accountDeleteEmailMismatch,
    );
    return typed != null;
  }

  // ── Setup Wizard UI ───────────────────────────────────────────

  // ── Sign in (from the guest You row) ──────────────────────────

  /// Signs in (from the guest You row): in the browser on a computer without
  /// Firebase, otherwise with the way picked from a sheet (account_sign_in.dart,
  /// where the welcome screen and Join a team sign in too).
  Future<void> _startSignIn() async {
    setState(() => _isSigningIn = true);
    try {
      await signInFromAnywhere(context, ref);
    } finally {
      if (mounted) setState(() => _isSigningIn = false);
    }
  }

  // ── Profile Photo ─────────────────────────────────────────────

  /// Presents "Change photo" / "Remove photo" for the account avatar. The
  /// photo is a local-only display preference - never uploaded or synced.
  /// Remove is there once a photo was set in ZestSSH, on every device; the
  /// photo a sign-in brings is the provider's and stays.
  ///
  /// A computer opens a menu at [anchor] (the Manage button or the photo),
  /// as its other menus do: the sheet a phone and a tablet slide up from the
  /// bottom of the screen was, on a computer, far from the button and out of
  /// place.
  Future<void> _editProfilePhoto({BuildContext? anchor}) async {
    final l10n = AppLocalizations.of(context)!;
    final hasCustom = ref.read(customAvatarPathProvider) != null ||
        ref.read(syncedAvatarUrlProvider) != null;
    final String? choice;
    if (!isTouchLayout && anchor != null) {
      choice = await _photoMenu(anchor, hasCustom, l10n);
    } else {
      choice = await _photoSheet(hasCustom, l10n);
    }
    if (!mounted) return;
    if (choice == 'edit-name') {
      await _editName();
    } else if (choice == 'change') {
      await _pickProfilePhoto();
    } else if (choice == 'remove') {
      await ref.read(customAvatarPathProvider.notifier).remove();
      if (mounted) {
        showTopSnackBar(context, l10n.profileAvatarRemoved, isSuccess: true);
      }
    } else if (choice == 'sign-out') {
      // Sign out from Manage too (it was only at
      // the bottom of the page, under the danger zone).
      await _signOut();
    }
  }

  /// Edit name (an account made with a password
  /// has none, and nothing could give it one): typed in a small dialog, set on
  /// this device at once. The field shows the real name, so while the screen is
  /// recorded recording goes off first, or nothing opens. What stops it is said
  /// in the dialog, with Copy details, and what was typed stays there.
  Future<void> _editName() async {
    final l10n = AppLocalizations.of(context)!;
    if (!await confirmRevealWhileRecording(context, ref) || !mounted) return;
    final current = ref.read(currentUserProvider)?.displayName ?? '';
    final changer = ref.read(accountNameChangerProvider);
    Object? failure;
    final name = await showZestInputDialog(
      context: context,
      title: l10n.accountEditNameTitle,
      subtitle: l10n.accountEditNameBody,
      icon: LucideIcons.pencil,
      fieldLabel: l10n.accountEditNameLabel,
      initialValue: current,
      confirmLabel: l10n.save,
      maxLength: kAccountNameMax,
      inputFormatters: [FilteringTextInputFormatter.deny(kAccountNameRefuses)],
      validator: (value) => cleanAccountName(value).isEmpty ? l10n.accountEditNameRequired : null,
      errorDetails: () => failure == null ? null : '$failure',
      onConfirm: (value) async {
        failure = null;
        try {
          await changer(cleanAccountName(value));
          return null;
        } on AccountNameRefusal catch (e) {
          failure = e;
          if (e.invalidName) return l10n.accountEditNameInvalid;
          if (e.signInServiceDown) return l10n.accountEditNameIdentityFailed;
          return l10n.accountEditNameFailed;
        } catch (e) {
          failure = e;
          return l10n.accountEditNameFailed;
        }
      },
    );
    if (!mounted || name == null) return;
    showTopSnackBar(context, l10n.accountEditNameSaved, isSuccess: true);
  }

  /// A computer's menu for the photo, just under [anchor].
  Future<String?> _photoMenu(BuildContext anchor, bool hasCustom, AppLocalizations l10n) {
    final box = anchor.findRenderObject()! as RenderBox;
    PopupMenuItem<String> item(String value, IconData icon, String label, {Color? color}) =>
        PopupMenuItem<String>(
          key: ValueKey('account-photo-$value'),
          value: value,
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 13, color: color)),
            ],
          ),
        );
    return showMenu<String>(
      context: context,
      position: menuPositionAt(anchor, offset: Offset(0, box.size.height + 4)),
      color: ZestTokens.surfaceRaised,
      items: [
        item('edit-name', LucideIcons.pencil, l10n.accountEditName),
        item('change', LucideIcons.image, l10n.profileAvatarChangePhoto),
        if (hasCustom)
          item('remove', LucideIcons.trash2, l10n.profileAvatarRemovePhoto, color: AppColors.error),
        const PopupMenuDivider(height: 8),
        item('sign-out', LucideIcons.logOut, l10n.profileSignOut),
      ],
    );
  }

  /// A phone's and a tablet's sheet for the photo.
  Future<String?> _photoSheet(bool hasCustom, AppLocalizations l10n) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('account-photo-edit-name'),
              leading: Icon(LucideIcons.pencil, color: AppColors.accentInk),
              title: Text(l10n.accountEditName),
              onTap: () => Navigator.pop(ctx, 'edit-name'),
            ),
            ListTile(
              leading: Icon(LucideIcons.image,
                  color: AppColors.accentInk),
              title: Text(l10n.profileAvatarChangePhoto),
              onTap: () => Navigator.pop(ctx, 'change'),
            ),
            if (hasCustom)
              ListTile(
                leading:
                    Icon(LucideIcons.trash2, color: AppColors.error),
                title: Text(
                  l10n.profileAvatarRemovePhoto,
                  style: TextStyle(color: AppColors.error),
                ),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            ListTile(
              key: const ValueKey('account-photo-sign-out'),
              leading: const Icon(LucideIcons.logOut),
              title: Text(l10n.profileSignOut),
              onTap: () => Navigator.pop(ctx, 'sign-out'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickProfilePhoto() async {
    final l10n = AppLocalizations.of(context)!;
    final outcome = await ref
        .read(customAvatarPathProvider.notifier)
        .pickAndSet(dialogTitle: l10n.profileAvatarChangePhoto);
    if (!mounted) return;
    switch (outcome) {
      case AvatarPickOutcome.success:
        showTopSnackBar(context, l10n.profileAvatarUpdated, isSuccess: true);
      case AvatarPickOutcome.invalidType:
        showTopSnackBar(context, l10n.profileAvatarInvalidImage,
            isError: true);
      case AvatarPickOutcome.error:
        showTopSnackBar(context, l10n.profileAvatarPickFailed, isError: true);
      case AvatarPickOutcome.cancelled:
        break;
    }
  }

  /// Open the storage/backend picker. On desktop (where Profile & Sync is a
  /// modal) present it as a modal too - one navigation model, no full-page back
  /// arrow stacked over the dialog. On mobile keep the full-screen route.
  void _openStoragePicker() {
    if (MediaQuery.of(context).size.width > 600) {
      SyncBackendScreen.showModal(context);
    } else {
      context.push(Routes.syncBackend);
    }
  }

  /// ZestSSH Cloud keeps no copy for this account ([e]): said in a dialog,
  /// with the free way (storage of the person's own: the storage picker) and
  /// Juiced (the upgrade page).
  Future<void> _sayHostingNeeded(SyncHostingRequiredException e) async {
    final choice = await showSyncHostingNeeded(context, e.message);
    if (!mounted || choice == null) return;
    switch (choice) {
      case SyncHostingChoice.chooseStorage:
        _openStoragePicker();
      case SyncHostingChoice.getJuiced:
        unawaited(context.push(Routes.upgrade));
    }
  }

  // ── Actions ───────────────────────────────────────────────────

  Future<void> _signOut() async {
    final l10n = AppLocalizations.of(context)!;
    // What signing out does to sync, said as it is: ZestSSH Cloud's stops and
    // is turned on again with the sync password; a store of one's own goes on
    // (found in a security review).
    final hosted = ref.read(syncProviderConfigProvider).kind == SyncBackendKind.zestServer &&
        await ref.read(syncSetupStateServiceProvider).isSyncActive();
    if (!mounted) return;
    final profiles = ref.read(profileControllerProvider);
    final confirmed = await _confirmAction(
      l10n.profileSignOut,
      [
        if (profiles.on) l10n.signOutLocksBody,
        if (profiles.on && profiles.openSessions > 0) l10n.signOutSessionsClose(profiles.openSessions),
        if (hosted) l10n.profileSignOutConfirmMsg else if (!profiles.on) l10n.profileSignOutConfirmNotHosted,
      ].join('\n\n'),
    );
    if (confirmed != true) return;

    await signOutAccount(ref);
    if (mounted) await _refreshSetupState();
  }

  bool _isDeleting = false;
  bool _isResettingSync = false;

  // Signed-in devices (3.0), loaded when the Devices section shows.
  List<DeviceSessionInfo>? _devices;
  String? _devicesUid;
  bool _devicesLoading = false;
  bool _devicesFailed = false;
  Object? _devicesError;
  bool _devicesBusy = false;

  // Two-step sign-in (3.0), loaded when the Security section shows.

  /// Turns sync off on this device and forgets its sync keys, leaving its
  /// data and whatever a store holds ([disconnectSyncOnThisDevice]). What the
  /// account page says of sync starts over with it.
  Future<void> _disconnectSyncHere() async {
    await disconnectSyncOnThisDevice(
      autoSync: ref.read(autoSyncServiceProvider),
      setup: ref.read(syncSetupStateServiceProvider),
      settings: ref.read(settingsServiceProvider),
      secureStorage: ref.read(secureStorageProvider),
      lockVault: ref.read(vaultSessionProvider.notifier).lock,
    );
    ref.read(syncStatusProvider.notifier).clear();
  }

  /// Reset cloud sync (3.0): for the person who can no longer prove the
  /// master password and has no recovery key, or whose devices no longer
  /// agree about it. ZestSSH Cloud takes the account's cloud copy out of use
  /// (it sets it aside for a time; it cannot ask for a password nobody has,
  /// so it asks for a sign-in made moments ago), and sync is off on this
  /// device until it is set up again. The account, purchases, teams and
  /// every device's data stay.
  ///
  /// After the question and the typed email, [SyncResetFlow] signs the person
  /// in again, holds sync, asks the server and turns sync off here; then the
  /// person is told how it ended and may set sync up again at once.
  Future<void> _resetCloudSync() async {
    if (_isResettingSync || _isDeleting) return; // Prevent double-tap
    final l10n = AppLocalizations.of(context)!;
    final account = ref.read(currentUserProvider);
    if (account == null) return;
    if (!await askToResetCloudSync(context, keysElsewhere: kOrchardsEnabled && _keysElsewhere)) return;
    if (!mounted) return;
    if (!await confirmSyncResetByEmail(context, ref, account.email)) return;
    if (!mounted) return;

    final autoSync = ref.read(autoSyncServiceProvider);
    final inBrowser = AuthService.currentUser == null;
    setState(() => _isResettingSync = true);
    final stage = ValueNotifier<String>(
        syncResetStageText(l10n, SyncResetStage.signingIn, inBrowser: inBrowser));
    final closeProgress = _showDeletionProgress(stage);
    final SyncResetOutcome outcome;
    try {
      outcome = await SyncResetFlow(
        isSameAccount: (fresh) => isSameAccount(account, fresh),
        signInAgain: () => signInAgain(context),
        suspendSync: autoSync.suspend,
        resumeSync: autoSync.resume,
        api: SyncResetApi(),
        disconnectHere: _disconnectSyncHere,
      ).run(onStage: (s) => stage.value = syncResetStageText(l10n, s, inBrowser: inBrowser));
    } finally {
      closeProgress();
      if (mounted) setState(() => _isResettingSync = false);
    }
    if (!mounted) return;
    await _refreshSetupState();
    if (!mounted) return;
    if (await showSyncResetOutcome(context, outcome) && mounted) _startSyncSetup();
  }

  /// The store holds no vault while this device thinks sync is set up (cloud
  /// sync was reset from another device, or the store was emptied): says so,
  /// and with the person's yes turns sync off here and sets it up again.
  Future<void> _setUpSyncAgain() async {
    if (!await askToSetUpSyncAgain(context)) return;
    await _disconnectSyncHere();
    if (!mounted) return;
    await _refreshSetupState();
    if (!mounted) return;
    _startSyncSetup();
  }

  /// Delete account (3.0): the server side first,
  /// confirmed, then a last chance before this device's data goes too.
  ///
  /// After the typed-email confirmation, [AccountDeletionFlow] signs the
  /// person in again, turns sync off, deletes their own sync store when one
  /// is in use and the ZestSSH account (its synced data and sign-in), and
  /// checks the server has nothing left. Only then "Server data has been
  /// deleted", with the choice to wipe this device or keep its data.
  Future<void> _deleteAccount() async {
    if (_isDeleting) return; // Prevent double-tap
    final l10n = AppLocalizations.of(context)!;
    final account = ref.read(currentUserProvider);
    if (account == null) return;
    if (!await _confirmDeleteByEmail(account.email)) return;
    if (!mounted) return;

    final autoSync = ref.read(autoSyncServiceProvider);
    final backend = _backend;
    // The hosted store goes with the account; a store the person runs
    // themselves is deleted separately, when sync was ever set up.
    final ownStore = backend.kind != SyncBackendKind.zestServer &&
        await ref.read(secureStorageProvider).read(key: 'sync_salt') != null;
    if (!mounted) return;

    setState(() => _isDeleting = true);
    final stage = ValueNotifier<String>(
        _deletionStageText(l10n, AccountDeletionStage.signingIn));
    final closeProgress = _showDeletionProgress(stage);
    final AccountDeletionOutcome outcome;
    try {
      outcome = await AccountDeletionFlow(
        isSameAccount: (fresh) => isSameAccount(account, fresh),
        signInAgain: () => signInAgain(context),
        suspendSync: autoSync.suspend,
        resumeSync: autoSync.resume,
        api: AccountDeletionApi(),
        askSyncPassword: _askSyncPasswordForDeletion,
        deleteSyncStore: ownStore ? () => _deleteSyncStore(backend) : null,
        forgetSyncKeys: autoSync.clearSyncCredentials,
        soleOwnerOrchards: _soleOwnedOrchards,
        forgetAccount: (fresh) => forgetDeletedAccount(ref.read, fresh.uid),
      ).run(onStage: (s) => stage.value = _deletionStageText(l10n, s));
    } finally {
      closeProgress();
      // Clear the vault on every outcome: a cached sync key must not outlive
      // an attempt to delete the account it belongs to.
      ref.read(vaultSessionProvider.notifier).lock();
      if (mounted) setState(() => _isDeleting = false);
    }
    if (!mounted) return;

    switch (outcome) {
      case AccountDeletionCancelled():
        showTopSnackBar(context, l10n.accountDeleteNothingDeleted);
      case AccountDeletionWrongAccount():
        showTopSnackBar(context, l10n.accountDeleteWrongAccount,
            isError: true);
      case AccountDeletionFailed(:final code, :final somethingDeleted, :final orchards, :final cause, :final keptUntil):
        await ZestConfirmDialog.show(
          context,
          // What happened, said: a notice, not an alarm (it was yellow where
          // part was deleted), closed by Close (it said OK).
          tone: ZestDialogTone.info,
          title: somethingDeleted
              ? l10n.accountDeleteUnfinishedTitle
              : l10n.accountDeleteNotDeletedTitle,
          body: _deletionFailureText(l10n, code, somethingDeleted, orchards: orchards, cause: cause, keptUntil: keptUntil),
          showCancel: false,
          confirmLabel: l10n.close,
        );
      case AccountDeletionServerDone():
        await _offerLocalWipe();
    }
  }

  /// The sync password for the synced data on ZestSSH Cloud, turned into
  /// the verification value the server checks, derived with that data's own
  /// salt and parameters. Null when the person backs out.
  Future<Uint8List?> _askSyncPasswordForDeletion(HostedSyncData data) async {
    final l10n = AppLocalizations.of(context)!;
    final password = await _showPasswordDialog(l10n.profileEnterSyncPassword);
    if (password == null || password.isEmpty) return null;
    final mek = await SyncService.deriveKey(password, data.salt,
        params: data.argon2Params);
    return SyncService.computeVerificationHash(mek);
  }

  /// Deletes the synced data in a store the person runs themselves, then
  /// checks it holds nothing. WebDAV, S3 and Google Drive take the store's
  /// own credentials as the authorization; a self-hosted ZestSSH server
  /// checks the sync password. False when the person backs out of that.
  Future<bool> _deleteSyncStore(SyncBackend backend) async {
    var verificationHash = Uint8List(0);
    if (backend.kind == SyncBackendKind.custom) {
      final l10n = AppLocalizations.of(context)!;
      final password =
          await _showPasswordDialog(l10n.profileEnterSyncPassword);
      if (password == null || password.isEmpty) return false;
      verificationHash = await _verificationHashFor(backend, password);
    }
    await backend.purge(verificationHash);
    final status = await backend.getStatus();
    if (status.hasData) {
      throw const SyncException('The sync store still holds data');
    }
    return true;
  }

  /// The sync password's verification value, derived with the store's own
  /// salt and Argon2 parameters (this device's cached salt goes stale when
  /// the password is changed elsewhere, and older accounts use older
  /// parameters). Falls back to the cached salt when the store can't be read.
  Future<Uint8List> _verificationHashFor(
      SyncBackend backend, String password) async {
    final cached =
        await ref.read(secureStorageProvider).read(key: 'sync_salt');
    var salt = cached == null ? Uint8List(0) : base64Decode(cached);
    Map<String, dynamic>? params;
    try {
      final pulled = await backend.pull();
      salt = pulled.salt;
      params = pulled.argon2Params;
    } catch (e) {
      AppLogger.warning(
          'Account deletion: could not read the store, using the cached '
          'salt: $e');
    }
    final mek = await SyncService.deriveKey(password, salt, params: params);
    return SyncService.computeVerificationHash(mek);
  }

  String _deletionStageText(
      AppLocalizations l10n, AccountDeletionStage stage) {
    switch (stage) {
      case AccountDeletionStage.signingIn:
        return AuthService.currentUser == null
            ? l10n.accountDeleteStepSignInBrowser
            : l10n.accountDeleteStepSignIn;
      case AccountDeletionStage.stoppingSync:
        return l10n.accountDeleteStepStoppingSync;
      case AccountDeletionStage.deletingSyncStore:
        return l10n.accountDeleteStepDeletingStore;
      case AccountDeletionStage.deletingAccount:
        return l10n.accountDeleteStepDeletingAccount;
      case AccountDeletionStage.verifying:
        return l10n.accountDeleteStepVerifying;
    }
  }

  /// The Orchards on this device this account is the only owner of while
  /// others are in them, by name: deleting it waits until they are
  /// handed over.
  Future<List<String>> _soleOwnedOrchards() async {
    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(orchardServiceProvider);
    final out = <String>[];
    try {
      for (final o in await ref.read(orchardSummariesProvider.future)) {
        if (!o.active || !o.isOwner) continue;
        final people = await service.people(o.id);
        if (people.soleOwner && people.members.length > 1) out.add(orchardDisplayName(o.name, l10n));
      }
    } catch (e) {
      // The server checks the same before deleting anything of its own.
      AppLogger.warning('Account deletion: the Orchards could not be checked: $e');
    }
    return out;
  }

  String _deletionFailureText(AppLocalizations l10n, String code, bool somethingDeleted,
      {List<String> orchards = const [], Object? cause, DateTime? keptUntil}) {
    if (code == 'sync-reset-kept') return accountDeleteResetKeptText(l10n, keptUntil);
    if (code == 'sole-owner' || code == 'team-deletion-undoable') {
      final names = {
        for (final o in ref.read(orchardSummariesProvider).valueOrNull ?? const <OrchardSummary>[])
          o.id: orchardDisplayName(o.name, l10n),
      };
      final teams = orchards.map((o) => names[o] ?? o).join(', ');
      if (code == 'sole-owner') return l10n.accountDeleteSoleOwner(teams);
      return accountDeleteTeamBeingDeletedText(l10n, teams, keptUntil);
    }
    if (code == 'not-verified') return l10n.accountDeleteNotVerified;
    if (somethingDeleted) return l10n.accountDeleteFailedPartial;
    switch (code) {
      case 'verification-failed':
        return l10n.accountDeleteWrongSyncPassword;
      case 'sign-in-failed':
        return l10n.accountDeleteSignInFailed;
      // A server that does not record sign-in times yet refuses even a
      // fresh sign-in.
      case 'server-outdated':
      case 'recent-sign-in-required':
        return l10n.accountDeleteServerOutdated;
      default:
        return accountNotDeletedText(l10n, cause);
    }
  }

  /// A modal progress line for [_deleteAccount], in the app's dialog
  /// ([showZestBusy]; it was a Material one). Returns a closer that is safe to
  /// call more than once.
  VoidCallback _showDeletionProgress(ValueNotifier<String> text) =>
      showZestBusy(context, label: text.value, updates: text);

  /// The last chance: the server holds nothing any more, and wiping this
  /// device cannot be undone. Dismissing keeps the local data.
  Future<void> _offerLocalWipe() async {
    final l10n = AppLocalizations.of(context)!;
    final wipe = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.accountDeleteServerDoneTitle,
      body: l10n.accountDeleteServerDoneBody,
      bullets: [
        l10n.accountDeleteWipeBulletData,
        l10n.accountDeleteWipeBulletFiles,
        l10n.accountDeleteWipeBulletKept,
      ],
      confirmLabel: l10n.accountDeleteWipeLocal,
      cancelLabel: l10n.accountDeleteKeepLocal,
    );
    if (!mounted) return;
    if (wipe != true) {
      await ref.read(profileControllerProvider).keepAsGuest();
      if (!mounted) return;
      showTopSnackBar(context, l10n.accountDeleteKeptLocalSnack,
          isSuccess: true);
      return;
    }
    await wipeThisDevice(ref.read);
    if (!mounted) return;
    await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.success,
      title: l10n.accountDeleteAllDoneTitle,
      body: l10n.accountDeleteAllDoneBody,
      showCancel: false,
      confirmLabel: l10n.done,
    );
  }

  /// Run the bulletproof first-time sync setup wizard.
  ///
  /// State machine:
  ///   notStarted → signedIn → passwordChosen → recoverySaved →
  ///   recoveryConfirmed → complete
  ///
  /// At every step the state is persisted to OS-backed secure storage,
  /// so a crash, force-quit, or kernel panic mid-flow leaves the user
  /// in a known-recoverable state. Sync is NEVER considered active
  /// until the final markComplete() succeeds AFTER the first push
  /// has been ack'd by the server.
  Future<void> _runSyncSetupWizard({bool afterSignIn = false}) async {
    final l10n = AppLocalizations.of(context)!;
    final setup = ref.read(syncSetupStateServiceProvider);
    final notifier = ref.read(syncStatusProvider.notifier);

    // The store sync uses could not be read (3.4.2): a setup now would go to
    // ZestSSH Cloud in its stead and write over this device's sync. Read it
    // again; where it still cannot be read, say why, and change nothing.
    final store = ref.read(syncProviderConfigProvider.notifier);
    await store.ensureLoaded();
    if (!mounted) return;
    final unread = store.unreadBecause;
    if (unread != null) {
      final refused = SyncStoreUnknownException(unread);
      showTopSnackBar(context, refused.message, isError: true, details: refused.detail);
      return;
    }

    setState(() => _runningSetupWizard = true);
    try {
      // Step 1: mark setup as begun (idempotent - safe to call on resume).
      await setup.beginSetup();

      // Step 1b: does this account ALREADY have sync data on the server?
      // If so, this is a SECOND device → JOIN (verify the existing master
      // password, pull the existing key, restore) rather than CREATE.
      // Running the create wizard on a second device would mint a brand-new
      // data key and destructively overwrite the first device's cloud blob,
      // invalidating its password and recovery key. Only the FIRST device
      // ever runs the create flow below.
      SyncStatus status;
      try {
        // A store the person signs in to (Google Drive) is connected by them
        // here, before it is asked anything: its status cannot be read
        // without a sign-in.
        if (_backend.kind == SyncBackendKind.googleDrive) {
          await _backend.checkConnection();
        }
        // ZestSSH Cloud is asked first whether it keeps a copy for this
        // account (as the same step of the setup flow does): a purchase
        // made a moment ago counts, and an account without Juiced is told
        // so, not that a server could not be reached.
        await _backend.verifyEntitlement();
        status = await _backend.getStatus();
      } on SyncHostingRequiredException catch (e) {
        AppLogger.warning('Sync setup: ZestSSH Cloud is not part of this account');
        if (mounted) await _sayHostingNeeded(e);
        await _refreshSetupState();
        return;
      } catch (e) {
        AppLogger.warning('Sync getStatus failed before setup: $e');
        if (mounted) {
          showTopSnackBar(
            context,
            // The store's own reason (sign-in cancelled, not available on
            // this device) is said as it is; a store that could not be
            // reached, as what it is: ZestSSH Cloud and how it stands, or
            // the person's own storage.
            SyncFailure.ofStore(e, hosted: _backend.kind.isHosted).message,
            isError: true,
            duration: const Duration(seconds: 6), details: '$e'
          );
        }
        await _refreshSetupState();
        return;
      }
      if (status.hasData) {
        await _joinExistingSync(status, afterSignIn: afterSignIn);
        return;
      }
      // Asked to bring this device back into a sync that has gone meanwhile:
      // making one is the person's own choice.
      if (afterSignIn) return;

      // Step 2: master password. Confirmed twice to prevent typos that
      // would otherwise lock the user out forever (recovery key is the
      // only escape and they haven't seen it yet).
      if (!mounted) return;
      final password = await showNewMasterPasswordDialog(context, account: _syncAccountAddress);
      if (password == null || password.isEmpty) return;

      // Step 3: derive MEK, generate DEK, persist salt.
      final salt = SyncService.generateSalt();
      await setup.markPasswordChosen(salt: salt);
      final mek = await SyncService.deriveKey(password, salt);
      final dek = SyncService.generateDek();
      final wrappedDekPassword = await SyncService.wrapDek(dek, mek);
      final verificationHash =
          await SyncService.computeVerificationHash(mek);

      // Step 4: recovery key screen.
      if (!mounted) return;
      final recoveryKey = await context.push<String>(Routes.recoveryKey);
      if (recoveryKey == null) {
        await _refreshSetupState();
        return;
      }

      // Step 5: wrap DEK with recovery KEK so either path can decrypt.
      final recoverySaltBytes =
          await ref.read(syncSetupStateServiceProvider).readRecoverySalt();
      Uint8List? wrappedDekRecovery;
      Uint8List? recoverySalt;
      Uint8List? recoveryHash;
      if (recoverySaltBytes != null) {
        recoverySalt = Uint8List.fromList(recoverySaltBytes);
        final recoveryKek = await RecoveryKeyService.deriveRecoveryMek(
          recoveryKey,
          recoverySalt,
        );
        wrappedDekRecovery = await SyncService.wrapDek(dek, recoveryKek);
        recoveryHash = await SyncService.computeRecoveryVerificationHash(
          recoveryKek,
        );
      }

      // Step 6: first push with both wrapped DEKs.
      notifier.setSyncing(true);
      try {
        await _backend.verifyEntitlement();
        if (!mounted) return;
        final data = await _syncDataService.gatherAll();
        final (:version, :blobSize, updatedAt: _) = await _backend.push(
          data: data,
          dek: dek,
          salt: salt,
          verificationHash: verificationHash,
          wrappedDekPassword: wrappedDekPassword,
          wrappedDekRecovery: wrappedDekRecovery,
          recoverySalt: recoverySalt,
          recoveryHash: recoveryHash,
          deviceId: await _getDeviceId(),
          // First-ever push for this account/store - conflict (don't clobber)
          // if another device created data since our pre-setup status check.
          createOnly: true,
          // Fresh account: the MEK was derived with the current default.
          argon2Params: SyncService.argon2Params,
        );

        // Step 6: ONLY now flip the active flag. Throws if the prior
        // step is not recoveryConfirmed - defensive against any path
        // that would activate sync without the user confirming the key.
        await setup.markComplete();

        // Store DEK + verification hash so auto-sync works. Setup derived the
        // MEK with the current default params, so persist those.
        await ref.read(autoSyncServiceProvider).storeSyncCredentials(
              dek,
              verificationHash,
              argon2Params: SyncService.argon2Params,
            );
        final secureStorage = ref.read(secureStorageProvider);
        await secureStorage.write(
            key: 'sync_salt', value: base64Encode(salt));
        // The synced data is there now: its recovery proof can be kept.
        _registerRecoveryProof(mek);

        // Record the server version we just created, clear the dirty flag,
        // and turn ON automatic sync so future changes push and the other
        // device's changes pull without the user touching anything. This
        // is the fix for "set up sync but nothing ever syncs" - setup used
        // to leave the mode on 'manual' and never start the timer.
        final settings = ref.read(settingsServiceProvider);
        await settings.setSyncServerVersion(version);
        await settings.setSyncContentHash(
            SyncDataService.contentFingerprint(data, await dek.extractBytes()));
        await settings.setSyncDirty(false);
        await settings.setSyncMode('auto');
        ref.read(autoSyncServiceProvider).resetFailures();
        ref.read(autoSyncServiceProvider).startAutoSync();

        notifier.setSynced(DateTime.now(), blobSize);

        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileSyncedVersion(version),
            isSuccess: true,
          );
        }
      } catch (e) {
        // Another of the account's devices set sync up between this one's
        // look at the store and its first write: the write was refused, so
        // nothing was created here. The person is told that the recovery key
        // they were just shown opens nothing, and joins the vault that is
        // there.
        SyncStatus? theirs;
        if (mounted) {
          theirs = await stepAsideIfSetUpElsewhere(
            context,
            backend: _backend,
            setup: setup,
            syncing: notifier,
            refusal: e,
          );
        }
        if (theirs != null) {
          if (mounted) await _joinExistingSync(theirs);
          return;
        }
        AppLogger.error('Initial sync push failed during setup', e);
        notifier.setErrorFrom(e);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileSetupFailedResume(setupFailureSaid(e)),
            isError: true,
            details: setupFailureDetails(e),
            duration: const Duration(seconds: 6),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _runningSetupWizard = false);
        await _refreshSetupState();
      }
    }
  }

  /// JOIN an existing server sync from a second device.
  ///
  /// Verifies the user's EXISTING master password against the server,
  /// unwraps the EXISTING data key (never mints a new one), decrypts and
  /// merges the cloud data into this device, then reuses the server's salt
  /// + key so both devices share one encryption identity. No new recovery
  /// key is generated. This is the non-destructive counterpart to the
  /// create wizard.
  ///
  /// [afterSignIn]: the last step of a sign-in, in the words of that,
  /// led by the approval where another of the account's devices is
  /// signed in.
  Future<void> _joinExistingSync(SyncStatus status, {bool afterSignIn = false}) async {
    final l10n = AppLocalizations.of(context)!;
    final setup = ref.read(syncSetupStateServiceProvider);
    final notifier = ref.read(syncStatusProvider.notifier);

    final leadWithApproval = afterSignIn && await _anotherDeviceSignedIn();
    if (!mounted) return;
    final choice = await _showJoinUnlockDialog(
      afterSignIn ? l10n.syncTurnOnBody : l10n.profileJoinPrompt,
      title: afterSignIn ? l10n.syncTurnOnTitle : null,
      confirm: afterSignIn ? l10n.syncTurnOnAction : null,
      cancel: afterSignIn ? l10n.notNow : null,
      leadWithApproval: leadWithApproval,
    );
    if (choice == null) {
      await _refreshSetupState();
      return;
    }
    if (choice.useRecovery) {
      // Forgot the password - restore with the recovery key instead.
      await _restoreWithRecoveryKey();
      return;
    }
    if (choice.useApproval) {
      await _joinByApproval();
      return;
    }
    final password = choice.password;
    if (password == null || password.isEmpty) {
      await _refreshSetupState();
      return;
    }

    notifier.setSyncing(true);
    try {
      // Gate the paid feature on this device too (parity with CREATE);
      // the server also enforces, this just gives a clear message.
      await _backend.verifyEntitlement();

      // Pull the server blob to get its salt, argon2 params + wrapped DEK.
      final pullResult = await _backend.pull();
      final mek = await SyncService.deriveKey(
        password,
        pullResult.salt,
        params: pullResult.argon2Params,
      );

      // Verify against the server before trusting the password.
      final valid = await _backend.verifyPassword(mek);
      if (!valid) {
        notifier.setError(l10n.profileIncorrectSyncPassword);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileIncorrectSyncPassword,
            isError: true,
          );
        }
        await _refreshSetupState();
        return;
      }

      // Unwrap the EXISTING DEK (do NOT generate a new one) and merge.
      // Legacy blobs have no password-wrapped DEK - the MEK was used
      // directly as the data key (mirrors _restoreFromCloud). Handle that
      // instead of bailing, or a VALID password silently does nothing.
      final SecretKey dek;
      if (pullResult.wrappedDekPassword != null) {
        dek = await SyncService.unwrapDek(
            pullResult.wrappedDekPassword!, mek);
      } else {
        dek = mek;
      }
      final data =
          await SyncService.decrypt(pullResult.encryptedData, dek);
      final result = await _syncDataService.restoreAll(data);
      if (!result.success) {
        notifier.setError(result.error ?? l10n.profileRestoreFailed);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileJoinSaveFailed(
                result.error ?? l10n.profileRestoreFailed),
            isError: true,
            duration: const Duration(seconds: 7),
          );
        }
        await _refreshSetupState();
        return;
      }
      AppLogger.info(
          'Joined sync: merged ${result.recordsRestored} records');
      if (result.knownHostConflicts.isNotEmpty && mounted) {
        showTopSnackBar(
          context,
          l10n.profileJoinHostKeyConflicts(
              result.knownHostConflicts.join(', ')),
          isWarning: true,
          duration: const Duration(seconds: 10),
        );
      }

      // Persist credentials + the SERVER salt + server version so this
      // device's future syncs match the shared key, then activate.
      final verificationHash =
          await SyncService.computeVerificationHash(mek);
      await ref.read(autoSyncServiceProvider).storeSyncCredentials(
            dek,
            verificationHash,
            // Adopt the existing account's params (we derived with them above).
            argon2Params: pullResult.argon2Params,
          );
      _registerRecoveryProof(mek);
      final secureStorage = ref.read(secureStorageProvider);
      await secureStorage.write(
          key: 'sync_salt', value: base64Encode(pullResult.salt));
      final settings = ref.read(settingsServiceProvider);
      await settings.setSyncServerVersion(pullResult.version);
      // Join itself never pushes. But if THIS device contributed rows the cloud
      // didn't have (its own local-only config), the merged DB now differs from
      // the server blob - mark dirty so the next cycle pushes the union UP
      // instead of leaving that config local-only until the first edit. A fresh
      // device added nothing, so its post-merge fingerprint equals the cloud's
      // and it stays clean (no redundant push). The stored content hash is the
      // CLOUD fingerprint, so the next push's echo-skip compares against the
      // right baseline (the union differs from it, so it isn't skipped).
      final dekBytes = await dek.extractBytes();
      final cloudFingerprint =
          SyncDataService.contentFingerprint(data, dekBytes);
      final mergedData = await _syncDataService.gatherAll();
      final mergedFingerprint =
          SyncDataService.contentFingerprint(mergedData, dekBytes);
      await settings.setSyncContentHash(cloudFingerprint);
      await settings.setSyncDirty(mergedFingerprint != cloudFingerprint);
      await settings.setSyncMode('auto');
      await setup.markCompleteViaJoin(salt: pullResult.salt);
      ref.read(autoSyncServiceProvider).resetFailures();
      ref.read(autoSyncServiceProvider).startAutoSync();

      notifier.setSynced(
          pullResult.updatedAt, pullResult.encryptedData.length);
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.profileJoinedSyncSuccess,
          isSuccess: true,
        );
      }
    } on SyncDecryptionException catch (e) {
      notifier.setError(e.message, detail: e.detail);
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.profileJoinDecryptFailed,
          isError: true,
          duration: const Duration(seconds: 7), details: '$e'
        );
      }
      await _refreshSetupState();
    } catch (e) {
      notifier.setErrorFrom(e);
      if (mounted) {
        showTopSnackBar(context, l10n.profileJoinFailed(notifier.messageOf(e)),
            isError: true, details: '$e');
      }
      await _refreshSetupState();
    }
  }

  /// Whether another of the account's devices is signed in, and so could hand
  /// this one the sync key; false where that cannot be found out.
  Future<bool> _anotherDeviceSignedIn() async {
    try {
      final devices = await ref.read(deviceSessionServiceProvider).api.list();
      return devices.any((d) => !d.current);
    } catch (e) {
      AppLogger.warning('Sync: the account\'s devices could not be read to offer an approval ($e)');
      return false;
    }
  }

  /// JOIN with the key another of this account's devices hands over after
  /// both screens showed the same words (3.0), instead of the
  /// sync password: the steps of [_joinExistingSync] from the unwrapped key
  /// on ([joinWithHandover]). Nothing is kept unless the key opens the data.
  Future<void> _joinByApproval() async {
    final l10n = AppLocalizations.of(context)!;
    final setup = ref.read(syncSetupStateServiceProvider);
    final notifier = ref.read(syncStatusProvider.notifier);
    final handover = await showAskForApproval(context);
    if (handover == null || !mounted) return;

    notifier.setSyncing(true);
    try {
      await _backend.verifyEntitlement();
      final joined = await joinWithHandover(
        backend: _backend,
        handover: handover,
        dataService: _syncDataService,
        autoSync: ref.read(autoSyncServiceProvider),
        secureStorage: ref.read(secureStorageProvider),
        settings: ref.read(settingsServiceProvider),
      );
      final result = joined.restore;
      if (!result.success) {
        notifier.setError(result.error ?? l10n.profileRestoreFailed);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileJoinSaveFailed(result.error ?? l10n.profileRestoreFailed),
            isError: true,
            duration: const Duration(seconds: 7),
          );
        }
        return;
      }
      AppLogger.info('Joined sync by approval: merged ${result.recordsRestored} records');
      if (result.knownHostConflicts.isNotEmpty && mounted) {
        showTopSnackBar(
          context,
          l10n.profileJoinHostKeyConflicts(result.knownHostConflicts.join(', ')),
          isWarning: true,
          duration: const Duration(seconds: 10),
        );
      }
      await setup.markCompleteViaJoin(salt: joined.pull.salt);
      ref.read(autoSyncServiceProvider).resetFailures();
      ref.read(autoSyncServiceProvider).startAutoSync();
      notifier.setSynced(joined.pull.updatedAt, joined.pull.encryptedData.length);
      if (mounted) {
        showTopSnackBar(context, l10n.profileJoinedSyncSuccess, isSuccess: true);
      }
    } on SyncDecryptionException catch (e) {
      // What arrived does not open this account's data: nothing was kept.
      notifier.setError(e.message, detail: e.detail);
      if (mounted) {
        showTopSnackBar(context, l10n.askWrongKey, isError: true, duration: const Duration(seconds: 7), details: '$e');
      }
    } catch (e) {
      notifier.setErrorFrom(e);
      if (mounted) {
        showTopSnackBar(context, l10n.profileJoinFailed(notifier.messageOf(e)), isError: true, details: '$e');
      }
    }
  }


  SyncDataService get _syncDataService => ref.read(syncDataServiceProvider);

  /// The active cloud-sync backend (hosted, self-hosted, WebDAV, S3, Drive).
  /// Read fresh each use so a provider switch takes effect immediately.
  SyncBackend get _backend => ref.read(syncBackendProvider);

  /// Verify a MEK against the pulled account state, returning the DEK on
  /// success or null on failure - IDENTICAL to the inline verification the
  /// flows already perform: GCM DEK-unwrap when a password-wrapped DEK exists
  /// (a wrong MEK fails the GCM tag and throws), else [verifyPassword] (the MEK
  /// doubling as the data key for legacy blobs).
  ///
  /// SECURITY: this is the single gate that authenticates a MEK - typed OR
  /// cached - BEFORE any re-encryption/upload. For a legacy blob it runs
  /// [verifyPassword] against the stored blob; returning null here makes the
  /// caller abort without uploading, preserving the verify-before-reencrypt
  /// invariant a hostile store must not be able to sidestep.
  Future<SecretKey?> _verifySyncMek(
      SecretKey mek, SyncPullResult pullResult) async {
    if (pullResult.wrappedDekPassword != null) {
      try {
        // Unwrapping IS the verification - a wrong MEK fails the GCM auth tag.
        return await SyncService.unwrapDek(pullResult.wrappedDekPassword!, mek);
      } on SyncDecryptionException {
        // Wrong key, or a tampered/corrupt wrapper - a failed unlock either way.
        return null;
      }
      // Any OTHER (unexpected) error propagates to the flow's outer catch so it
      // surfaces honestly instead of being masked as "incorrect password".
    }
    // Legacy blob: verifyPassword returns a bool. A THROWN error (server 500 /
    // outage / entitlement) MUST propagate as a real error - never be flattened
    // into a false "incorrect password" that no correct password can clear (and
    // never evict a still-valid cached vault on a transient blip).
    final ok = await _backend.verifyPassword(mek);
    return ok ? mek : null;
  }

  /// A sync-unlock already awaiting the user, if any. Concurrent unlock attempts
  /// (a manual "Sync now" racing a "Restore", or a fast double-tap) share this
  /// one future instead of each stacking its own password dialog - the cause of
  /// "it synced, then instantly asked for the password again" before the first
  /// unlock had cached the vault MEK.
  Future<_SyncUnlock?>? _pendingUnlock;

  /// Obtain a verified MEK+DEK for [pullResult]. Reuses the unlocked vault if
  /// the cached MEK validates against THIS account's pulled state; else
  /// prompts. A fresh successful prompt caches the MEK (30-min vault). Returns
  /// null if the user cancels; returns `verified:false` when a TYPED password
  /// fails (caller shows the error). A cached MEK that fails is silently
  /// dropped + reprompted. Concurrent calls coalesce onto one in-flight prompt.
  Future<_SyncUnlock?> _unlockForSync(SyncPullResult pullResult,
      {required String opTitle, String? why}) {
    final pending = _pendingUnlock;
    if (pending != null) return pending;
    final future = _unlockForSyncImpl(pullResult, opTitle: opTitle, why: why);
    _pendingUnlock = future;
    future.whenComplete(() {
      if (identical(_pendingUnlock, future)) _pendingUnlock = null;
    });
    return future;
  }

  Future<_SyncUnlock?> _unlockForSyncImpl(SyncPullResult pullResult,
      {required String opTitle, String? why}) async {
    final vault = ref.read(vaultSessionProvider.notifier);
    final cachedMek = vault.mek;
    if (cachedMek != null) {
      final dek = await _verifySyncMek(cachedMek, pullResult);
      if (dek != null) {
        return _SyncUnlock(mek: cachedMek, dek: dek, verified: true);
      }
      vault.lock(); // stale / different account
    }
    final password = await _showPasswordDialog(opTitle, why: why);
    if (password == null || password.isEmpty) return null;
    final mek = await SyncService.deriveKey(
      password,
      pullResult.salt,
      params: pullResult.argon2Params,
    );
    final dek = await _verifySyncMek(mek, pullResult);
    if (dek == null) return _SyncUnlock(mek: mek, dek: null, verified: false);
    vault.unlock(mek);
    // On the side; the Security card's ask waits for it.
    final registering = ref.read(recoveryProofServiceProvider).register(mek);
    return _SyncUnlock(mek: mek, dek: dek, verified: true, proofRegistered: registering);
  }

  /// The Security card's ask, so that a recovery of the account keeps its
  /// data (3.3.1): the sync password through the same unlock as Sync now,
  /// with the account's own salt and settings, and the recovery proof
  /// registered with its key, waited for (a key the vault held already is
  /// registered here). True once proved; false where the person backed out
  /// or the password was wrong, which is said as Sync now says it.
  Future<bool> _proveSyncPasswordForRecovery() async {
    final l10n = AppLocalizations.of(context)!;
    final pullResult = await _backend.pull();
    if (!mounted) return false;
    final unlocked = await _unlockForSync(pullResult, opTitle: l10n.recoveryProofAskTitle, why: l10n.recoveryProofAskBody);
    if (unlocked == null) return false;
    if (!unlocked.verified) {
      if (mounted) showTopSnackBar(context, l10n.profileIncorrectSyncPassword, isError: true);
      return false;
    }
    await (unlocked.proofRegistered ?? ref.read(recoveryProofServiceProvider).register(unlocked.mek));
    return true;
  }

  Future<void> _syncNow() async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(syncStatusProvider.notifier);

    try {
      final secureStorage = ref.read(secureStorageProvider);

      // A store that holds no vault has nothing to prove a password against:
      // cloud sync was reset from another device, or the store was emptied.
      // Sync is set up again, with the person's yes.
      if (!(await _backend.getStatus()).hasData) {
        if (mounted) await _setUpSyncAgain();
        return;
      }

      // The same pull, merge and push as the background sync, with the keys
      // this device keeps: nothing to ask (it
      // asked for the sync password once the 30-minute cache was
      // gone, whether or not anything had changed). Only where those keys no
      // longer open the account does it ask, and it says why.
      final String? why;
      try {
        notifier.setSyncing(true);
        final version = await ref.read(autoSyncServiceProvider).syncNowManual();
        final status = await _backend.getStatus();
        notifier.setSynced(DateTime.now(), status.blobSize);
        if (mounted) showTopSnackBar(context, l10n.profileSyncedVersion(version));
        return;
      } on SyncWasResetException {
        rethrow;
      } on SyncHostingRequiredException {
        rethrow;
      } on SyncCloudDeviceLimitException {
        rethrow;
      } on SyncKeysMismatchException {
        why = l10n.syncPasswordChangedElsewhere;
      } on SyncDecryptionException {
        why = l10n.syncPasswordChangedElsewhere;
      } on SyncSetupRequiredException {
        // This device holds no keys to use: the sync password brings them.
        why = null;
      } finally {
        notifier.setSyncing(false);
      }

      // Pull FIRST so we derive with the ACCOUNT's own salt + Argon2 params -
      // not this build's current default. An account set up under older params
      // must still derive the same MEK to unwrap its DEK after the default
      // changes; deriving with the default here would fail on those accounts.
      final pullResult = await _backend.pull();

      // Acquire a VERIFIED MEK+DEK - reusing the unlocked vault when the cached
      // key validates against THIS account, else prompting. For a legacy blob
      // (wrappedDekPassword == null) the verification runs verifyPassword INSIDE
      // _unlockForSync BEFORE anything is re-encrypted/uploaded; a returned
      // verified:false aborts the flow with nothing pushed. Do NOT mint a fresh
      // DEK for a legacy blob: unlocked.dek is the MEK itself, matching the
      // prior inline behaviour, so we never re-key the account and strand
      // other devices.
      final unlocked = await _unlockForSync(pullResult,
          opTitle: l10n.profileUnlockSyncNowTitle, why: why);
      if (unlocked == null) return; // user cancelled
      if (!unlocked.verified) {
        notifier.setError(l10n.profileIncorrectSyncPassword);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileIncorrectSyncPassword,
            isError: true,
          );
        }
        return;
      }
      final mek = unlocked.mek;
      final dek = unlocked.dek!;

      notifier.setSyncing(true);

      final verificationHash =
          await SyncService.computeVerificationHash(mek);

      // Refresh this device's cached keys from the account as it is NOW: its
      // salt, verification value and KDF params. After a password change on
      // another device these were stale here, and the background cycle sends
      // them with every push.
      await secureStorage.write(
          key: 'sync_salt', value: base64Encode(pullResult.salt));
      final autoSync = ref.read(autoSyncServiceProvider);
      await autoSync.storeSyncCredentials(
        dek,
        verificationHash,
        argon2Params: pullResult.argon2Params,
      );

      // Merge what other devices pushed, THEN upload: the same pull, merge
      // and push cycle the background sync runs, including its conflict retry
      // and the long-offline check. The old manual path uploaded this
      // device's data over the store without merging, losing edits another
      // device had pushed and this one had not pulled yet.
      final version = await autoSync.syncNowManual();
      final status = await _backend.getStatus();

      notifier.setSynced(DateTime.now(), status.blobSize);
      if (mounted) {
        showTopSnackBar(context, l10n.profileSyncedVersion(version));
      }
    } catch (e) {
      notifier.setErrorFrom(e);
    }
  }

  Future<void> _restoreFromCloud() async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(syncStatusProvider.notifier);

    try {
      final pullResult = await _backend.pull();

      // Acquire a VERIFIED MEK+DEK - reusing the unlocked vault when the cached
      // key validates against THIS account, else prompting. For a wrapped blob
      // the DEK-unwrap GCM tag IS the verification; for a legacy blob it runs
      // verifyPassword. A wrong TYPED password yields verified:false and we bail
      // BEFORE decrypting/restoring; a stale cached MEK is dropped + reprompted.
      final unlocked = await _unlockForSync(pullResult,
          opTitle: l10n.profileUnlockRestoreTitle);
      if (unlocked == null) return; // user cancelled
      if (!unlocked.verified) {
        notifier.setError(l10n.profileIncorrectSyncPassword);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileIncorrectSyncPassword,
            isError: true,
          );
        }
        return;
      }
      final mek = unlocked.mek;
      final dek = unlocked.dek!;

      notifier.setSyncing(true);

      final data =
          await SyncService.decrypt(pullResult.encryptedData, dek);
      AppLogger.info('Restored sync data: ${data.keys}');

      final result = await _syncDataService.restoreAll(data);
      if (!result.success) {
        notifier.setError(result.error ?? l10n.profileRestoreFailed);
        return;
      }
      AppLogger.info(
          'Restored ${result.recordsRestored} records from cloud');

      // Store DEK + verification hash so auto-sync works.
      final verificationHash =
          await SyncService.computeVerificationHash(mek);
      await ref.read(autoSyncServiceProvider).storeSyncCredentials(
            dek,
            verificationHash,
            // Adopt the restored account's params (we derived with them above).
            argon2Params: pullResult.argon2Params,
          );
      final secureStorage = ref.read(secureStorageProvider);
      await secureStorage.write(
          key: 'sync_salt', value: base64Encode(pullResult.salt));

      // Sync accounting: adopt the pulled version + fingerprint so the
      // background cycle doesn't echo-push the just-restored data, clear
      // dirty, and lift any split-brain pause this restore may have fixed.
      final settings = ref.read(settingsServiceProvider);
      await settings.setSyncServerVersion(pullResult.version);
      await settings.setSyncContentHash(
          SyncDataService.contentFingerprint(data, await dek.extractBytes()));
      // A change made here later than the cloud's copy was kept: it goes up.
      await settings.setSyncDirty(result.keptHere > 0);
      ref.read(autoSyncServiceProvider).resetFailures();

      notifier.setSynced(
          pullResult.updatedAt, pullResult.encryptedData.length);
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.profileDataRestored,
          isSuccess: true,
        );
      }
    } on SyncDecryptionException catch (e) {
      notifier.setError(e.message, detail: e.detail);
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.profileSyncIntegrityFailed,
          isError: true,
          duration: const Duration(seconds: 8), details: '$e'
        );
      }
    } catch (e) {
      notifier.setErrorFrom(e);
    }
  }

  /// Unlock/join Cloud Sync on a device with no cached key. Returns the typed
  /// password, a `useRecovery` signal, or null (cancelled). Unlike the plain
  /// password prompt, this offers the recovery-key escape hatch inline. In the
  /// app's dialog frame, so a phone shows it as a sheet (3.0 UI).
  Future<({String? password, bool useRecovery, bool useApproval})?> _showJoinUnlockDialog(
    String message, {
    String? title,
    String? confirm,
    String? cancel,
    bool leadWithApproval = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    // Teams (3.0): another of this account's devices can hand
    // the key over instead, on ZestSSH Cloud.
    final approval = kOrchardsEnabled && !ref.read(syncIsBringYourOwnProvider);
    // The body holds the typed password (and lets go of it once the dialog
    // has gone); the dialog closes from inside its own route, once.
    final body = GlobalKey<_JoinUnlockBodyState>();
    String typed() => body.currentState?.password ?? '';
    var closed = false;
    void close([({String? password, bool useRecovery, bool useApproval})? value]) {
      final inside = body.currentContext;
      if (closed || inside == null) return;
      closed = true;
      Navigator.of(inside).pop(value);
    }

    final result = await ZestDialogShell.showModal<({String? password, bool useRecovery, bool useApproval})>(
      context,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.lock,
      title: title ?? l10n.profileUnlockCloudSync,
      body: _JoinUnlockBody(
        key: body,
        message: message,
        approval: approval,
        leadWithApproval: approval && leadWithApproval,
        onSubmit: () => close((password: typed(), useRecovery: false, useApproval: false)),
        onRecovery: () => close((password: null, useRecovery: true, useApproval: false)),
        onApproval: () => close((password: null, useRecovery: false, useApproval: true)),
      ),
      primaryAction: (
        label: confirm ?? l10n.profileContinue,
        onPressed: () => close((password: typed(), useRecovery: false, useApproval: false)),
        icon: null,
      ),
      secondaryAction: (label: cancel ?? l10n.cancel, onPressed: () => close()),
    );
    return result;
  }

  /// Prompt for the recovery key. Not obscured - it is meant to be typed or
  /// pasted from the saved copy, and it is not a reusable secret like a password.
  Future<String?> _showRecoveryKeyDialog() {
    final l10n = AppLocalizations.of(context)!;
    return showZestInputDialog(
      context: context,
      title: l10n.profileRestoreWithRecoveryTitle,
      icon: LucideIcons.key,
      fieldLabel: l10n.profileRecoveryKeyLabel,
      hintText: 'ZEST-XXXX-XXXX-XXXX-XXXX-XXXX',
      obscureText: false,
      confirmLabel: l10n.profileContinue,
      cancelLabel: l10n.cancel,
    );
  }

  /// Restore the vault with the recovery key when the master password is lost.
  ///
  /// Unwraps the DEK with the recovery key, decrypts + restores the vault
  /// locally, then requires a NEW master password (the old one is unknown -
  /// that is why recovery was used) and re-secures the vault under it. The push
  /// carries a recovery proof (the recovery verification hash) so the hosted
  /// server accepts the changed password_hash under write-verification without
  /// the old password. The existing recovery key stays valid (its wrapper is
  /// left untouched).
  Future<void> _restoreWithRecoveryKey() async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = ref.read(syncStatusProvider.notifier);

    if (!mounted) return;
    final recoveryKey = await _showRecoveryKeyDialog();
    if (recoveryKey == null || recoveryKey.trim().isEmpty) {
      await _refreshSetupState();
      return;
    }

    notifier.setSyncing(true);
    final RecoveryPullResult rec;
    try {
      await _backend.verifyEntitlement();
      rec = await _backend.pullWithRecoveryKey(recoveryKey.trim());
    } catch (e) {
      notifier.setErrorFrom(e);
      if (mounted) {
        showTopSnackBar(
          context,
          // "That key didn't work" only for a key the store refused: a store
          // that could not be asked says nothing of the key.
          recoveryRestoreFailedText(e, l10n.profileRecoveryKeyDidntWork,
              hosted: _backend.kind == SyncBackendKind.zestServer),
          isError: true, details: '$e'
        );
      }
      await _refreshSetupState();
      return;
    }

    try {
      // 1. Decrypt + restore the vault locally with the recovered DEK.
      final data =
          await SyncService.decrypt(rec.pullResult.encryptedData, rec.dek);
      final result = await _syncDataService.restoreAll(data);
      if (!result.success) {
        notifier.setError(result.error ?? l10n.profileRestoreFailed);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileRestoreSaveFailed(
                result.error ?? l10n.profileRestoreFailed),
            isError: true,
            duration: const Duration(seconds: 7),
          );
        }
        await _refreshSetupState();
        return;
      }

      // 2. The user recovered WITHOUT the old password, so they must set a new
      //    one to re-enable sync.
      if (!mounted) return;
      final newPassword = await showNewMasterPasswordDialog(context, account: _syncAccountAddress);
      if (newPassword == null || newPassword.isEmpty) {
        // Data IS restored locally; sync just stays paused until a password is
        // chosen. Don't leave the spinner up.
        notifier.setSyncing(false);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileRestoredSetPassword,
          );
        }
        await _refreshSetupState();
        return;
      }

      // 3. Re-wrap the recovered DEK under the new password. Keep the account's
      //    EXISTING Argon2 params so the still-valid recovery wrapper (derived
      //    under them) keeps working - mirrors _changeSyncPassword.
      final params = rec.pullResult.argon2Params;
      final newSalt = SyncService.generateSalt();
      final newMek =
          await SyncService.deriveKey(newPassword, newSalt, params: params);
      final newVerHash = await SyncService.computeVerificationHash(newMek);
      final newWrappedDek = await SyncService.wrapDek(rec.dek, newMek);

      // Proof of RECOVERY-key possession so the hosted server accepts the
      // changed password_hash under write-verification (the user can't prove
      // the OLD password - that is the whole point of recovery).
      final authorizeRecoveryHash =
          await SyncService.computeRecoveryVerificationHash(rec.recoveryKek);

      final (:version, :blobSize, updatedAt: _) = await _backend.push(
        data: await _syncDataService.stampForPush(data),
        dek: rec.dek,
        salt: newSalt,
        verificationHash: newVerHash,
        wrappedDekPassword: newWrappedDek,
        // Leave the recovery wrapper untouched (still valid); the server's
        // COALESCE preserves it when omitted.
        deviceId: await _getDeviceId(),
        argon2Params: params,
        expectedVersion: rec.pullResult.version,
        authorizeRecoveryHash: authorizeRecoveryHash,
      );

      // 4. Activate sync with the new key.
      await ref.read(autoSyncServiceProvider).storeSyncCredentials(
            rec.dek,
            newVerHash,
            argon2Params: params,
          );
      final secureStorage = ref.read(secureStorageProvider);
      await secureStorage.write(
          key: 'sync_salt', value: base64Encode(newSalt));
      final settings = ref.read(settingsServiceProvider);
      await settings.setSyncServerVersion(version);
      await settings.setSyncContentHash(
          SyncDataService.contentFingerprint(
              data, await rec.dek.extractBytes()));
      // A change made here later than the cloud's copy was kept: it goes up.
      await settings.setSyncDirty(result.keptHere > 0);
      await settings.setSyncMode('auto');
      await ref
          .read(syncSetupStateServiceProvider)
          .markCompleteViaJoin(salt: newSalt);
      ref.read(vaultSessionProvider.notifier).unlock(newMek);
      _registerRecoveryProof(newMek);
      ref.read(autoSyncServiceProvider).resetFailures();
      ref.read(autoSyncServiceProvider).startAutoSync();

      notifier.setSynced(DateTime.now(), blobSize);
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.profileRecoveredResecured,
          isSuccess: true,
        );
      }
    } catch (e) {
      notifier.setErrorFrom(e);
    } finally {
      if (mounted) await _refreshSetupState();
    }
  }

  /// Whether the store holds a recovery key: what this device saw last, then
  /// the store's own answer.
  Future<void> _loadRecoveryKeyStatus() async {
    final autoSync = ref.read(autoSyncServiceProvider);
    final seen = await autoSync.recoveryKeyStatus();
    if (mounted && seen != null && seen != _recoveryKeySet) {
      setState(() => _recoveryKeySet = seen);
    }
    final now = await autoSync.recoveryKeyStatus(refresh: true);
    if (mounted && now != null && now != _recoveryKeySet) {
      setState(() => _recoveryKeySet = now);
    }
  }

  /// Checks a recovery key the person types back from their kit (3.0,
  /// recovery kit): nothing changes, and a key that does not open this
  /// device's vault can be replaced at once.
  Future<void> _checkRecoveryKey() async {
    if (_recoveryFlowOpen) return;
    _recoveryFlowOpen = true;
    try {
      final l10n = AppLocalizations.of(context)!;
      final creds = await ref.read(autoSyncServiceProvider).readCredentials();
      if (!mounted) return;
      if (creds == null) {
        showTopSnackBar(context, l10n.syncNowNotSetUp, isError: true);
        return;
      }
      await runRecoveryKeyCheck(
        context,
        ref,
        backend: _backend,
        deviceDek: creds.dek,
        onMakeNew: () async {
          _recoveryFlowOpen = false;
          await _replaceRecoveryKey();
        },
      );
    } finally {
      _recoveryFlowOpen = false;
    }
  }

  /// Makes a new recovery key (3.0), for a person who lost theirs
  /// or never had one. The master password is proved against the store as
  /// it is now (an unlocked device alone does not hand out a second way into
  /// the vault); the key is made and shown on this device; then the data key
  /// wrapped under it goes to the store with a normal pull, merge and push.
  /// The old key stops working only once that push lands, and a failed push
  /// can be tried again with the same key, so what the person saved stays
  /// the key that works.
  Future<void> _replaceRecoveryKey() async {
    if (_recoveryFlowOpen) return;
    _recoveryFlowOpen = true;
    try {
      await _runRecoveryKeyReplacement();
    } finally {
      _recoveryFlowOpen = false;
    }
  }

  Future<void> _runRecoveryKeyReplacement() async {
    final l10n = AppLocalizations.of(context)!;
    final autoSync = ref.read(autoSyncServiceProvider);
    final creds = await autoSync.readCredentials();
    if (!mounted) return;
    if (creds == null) {
      showTopSnackBar(context, l10n.syncNowNotSetUp, isError: true);
      return;
    }

    // 1. The master password, proved against the store.
    ProvenVault? proven;
    final password = await showZestInputDialog(
      context: context,
      title: l10n.recoveryReplaceTitle,
      subtitle: l10n.recoveryReplaceBody,
      icon: LucideIcons.keyRound,
      fieldLabel: l10n.profileMasterSyncPassword,
      hintText: l10n.profileMasterSyncPassword,
      obscureText: true,
      confirmLabel: l10n.profileContinue,
      cancelLabel: l10n.cancel,
      busyLabel: l10n.recoveryReplaceChecking,
      onConfirm: (value) async {
        if (value.isEmpty) return l10n.recoveryReplaceWrongPassword;
        try {
          proven = await proveMasterPassword(_backend, value, deviceDek: creds.dek);
          return null;
        } on VaultProofException catch (e) {
          return switch (e.failure) {
            VaultProofFailure.wrongPassword => l10n.recoveryReplaceWrongPassword,
            VaultProofFailure.otherKey => l10n.recoveryReplaceOtherKey,
            VaultProofFailure.notSetUp => l10n.syncNowNotSetUp,
          };
        } on SyncException catch (e) {
          return e.message;
        } catch (e) {
          AppLogger.warning('Recovery key: the store could not be read: $e');
          return SyncFailure.ofStore(e, hosted: _backend.kind.isHosted).message;
        }
      },
    );
    final vault = proven;
    if (password == null || vault == null || !mounted) return;

    // This device now holds the store's current salt and verification value
    // (after a password change on another device too), so its pushes pass
    // the store's write check.
    await autoSync.storeSyncCredentials(
      vault.dek,
      vault.verificationHash,
      argon2Params: vault.argon2Params,
    );
    await ref
        .read(secureStorageProvider)
        .write(key: 'sync_salt', value: base64Encode(vault.salt));
    if (!mounted) return;
    // The password was just proved: its recovery proof can be kept.
    _registerRecoveryProof(vault.mek);

    // 2. The new key, made and shown here. Nothing changes until it is saved.
    final recoveryKey = await context.push<String>(
      Routes.recoveryKey,
      extra: RecoveryKeyMode.replace,
    );
    if (recoveryKey == null || !mounted) return;

    // 3. Onto the store, with a normal sync. Tried again on request with the
    //    same key, so the one the person saved is the one that works.
    setState(() => _savingRecoveryKey = true);
    try {
      final wrap = await wrapForRecovery(vault, recoveryKey);
      while (true) {
        try {
          await autoSync.replaceRecoveryKey(
            wrappedDek: wrap.wrappedDek,
            salt: wrap.salt,
            hash: wrap.hash,
          );
          break;
        } on SyncException catch (e) {
          if (!mounted) return;
          // What the store said, as every sync failure is said.
          final said = SyncFailure.ofStore(e, hosted: _backend.kind.isHosted).message;
          final again = await ZestConfirmDialog.show(
            context,
            tone: ZestDialogTone.neutral,
            title: l10n.recoveryReplaceFailedTitle,
            body: vault.hadRecovery ? l10n.recoveryReplaceFailedBody(said) : l10n.recoveryMakeFailedBody(said),
            confirmLabel: l10n.retry,
          );
          if (!mounted) return;
          if (again != true) {
            showTopSnackBar(
              context,
              vault.hadRecovery
                  ? l10n.recoveryReplaceAbandoned
                  : l10n.recoveryMakeAbandoned,
              isError: true,
              duration: const Duration(seconds: 7), details: '$e'
            );
            return;
          }
        }
      }
      if (!mounted) return;
      setState(() => _recoveryKeySet = true);
      showTopSnackBar(
        context,
        vault.hadRecovery ? l10n.recoveryReplaceDone : l10n.recoveryMadeDone,
        isSuccess: true,
      );
    } finally {
      if (mounted) setState(() => _savingRecoveryKey = false);
    }
  }

  Future<void> _changeSyncPassword() async {
    final l10n = AppLocalizations.of(context)!;
    // Step 1: Verify current password.
    final currentPassword =
        await _showPasswordDialog(l10n.profileEnterCurrentPassword);
    if (currentPassword == null || currentPassword.isEmpty) return;

    final notifier = ref.read(syncStatusProvider.notifier);
    notifier.setSyncing(true);

    try {
      final pullResult = await _backend.pull();
      final currentMek = await SyncService.deriveKey(
        currentPassword,
        pullResult.salt,
        params: pullResult.argon2Params,
      );
      final valid = await _backend.verifyPassword(currentMek);
      if (!valid) {
        notifier.setError(l10n.profileIncorrectCurrentPassword);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profileIncorrectCurrentPassword,
            isError: true,
          );
        }
        return;
      }

      // The verification hash the server currently has stored (proof of the OLD
      // password, since verifyPassword just succeeded with currentMek). Sent as
      // authorize_hash on the change-password push so the hosted server accepts
      // the CHANGED password_hash under write-verification - a stolen session
      // token, which can't derive this, cannot rewrite the vault's password.
      final oldVerHash = await SyncService.computeVerificationHash(currentMek);

      // Step 2: Get new password: typed twice, and held to the rules it was
      // set up under (it was typed once, with neither).
      if (!mounted) return;
      final newPassword = await showNewMasterPasswordDialog(context, title: l10n.profileEnterNewPassword, account: _syncAccountAddress);
      if (newPassword == null || newPassword.isEmpty) {
        notifier.setSyncing(false);
        return;
      }

      // Unwrap DEK with old MEK, re-wrap with new MEK.
      // No data re-encryption needed - only the key wrapping changes.
      SecretKey dek;
      if (pullResult.wrappedDekPassword != null) {
        dek = await SyncService.unwrapDek(
            pullResult.wrappedDekPassword!, currentMek);
      } else {
        // Legacy blob without DEK indirection - decrypt, generate DEK,
        // re-encrypt with new DEK.
        final data = await SyncService.decrypt(
            pullResult.encryptedData, currentMek);
        dek = SyncService.generateDek();
        // Push the re-encrypted blob below.
        final newSalt = SyncService.generateSalt();
        final newMek = await SyncService.deriveKey(newPassword, newSalt);
        final newVerHash =
            await SyncService.computeVerificationHash(newMek);
        final wrappedDek = await SyncService.wrapDek(dek, newMek);
        final (:version, :blobSize, updatedAt: _) = await _backend.push(
          data: await _syncDataService.stampForPush(data),
          dek: dek,
          salt: newSalt,
          verificationHash: newVerHash,
          wrappedDekPassword: wrappedDek,
          deviceId: await _getDeviceId(),
          // Fresh MEK derived with the current default - store those params.
          argon2Params: SyncService.argon2Params,
          authorizeHash: oldVerHash,
          // Only onto what was read: the new password was typed in between.
          expectedVersion: pullResult.version,
        );
        await ref.read(autoSyncServiceProvider).storeSyncCredentials(
              dek, newVerHash,
              argon2Params: SyncService.argon2Params);
        final secureStorage = ref.read(secureStorageProvider);
        await secureStorage.write(
            key: 'sync_salt', value: base64Encode(newSalt));
        // A new password, a new recovery proof.
        _registerRecoveryProof(newMek);
        // Password changed - the old cached MEK is now stale.
        ref.read(vaultSessionProvider.notifier).lock();
        notifier.setSynced(DateTime.now(), blobSize);
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.profilePasswordChangedVersion(version),
          );
        }
        return;
      }

      // Normal path: re-wrap DEK with new MEK, push just the key update.
      //
      // CRITICAL: derive the new MEK with the account's EXISTING Argon2 params
      // (pullResult.argon2Params), NOT the current default. An account's params
      // are immutable after creation: change-password can't re-wrap the
      // recovery-DEK (it doesn't have the recovery key), so upgrading the
      // params here would leave the stored argon2_params ahead of the
      // still-old recovery wrapper and permanently break the recovery key.
      // Keeping the account's params means password and recovery derivations
      // always agree.
      //
      // The blob is written again with the existing DEK (the salt changes),
      // and only onto the version that was read: the new password was typed
      // in between, and another device's upload since then is read and kept
      // (lib/services/sync/password_change.dart).
      final (:version, :blobSize, salt: newSalt, mek: newMek, verificationHash: newVerHash, argon2Params: _) =
          await pushPasswordChange(
        backend: _backend,
        pulled: pullResult,
        dek: dek,
        currentMek: currentMek,
        newPassword: newPassword,
        oldVerificationHash: oldVerHash,
        stamp: _syncDataService.stampForPush,
        deviceId: await _getDeviceId(),
      );

      await ref.read(autoSyncServiceProvider).storeSyncCredentials(
            dek, newVerHash,
            argon2Params: pullResult.argon2Params);
      final secureStorage = ref.read(secureStorageProvider);
      await secureStorage.write(
          key: 'sync_salt', value: base64Encode(newSalt));
      // A new password, a new recovery proof.
      _registerRecoveryProof(newMek);

      // Password changed - the old cached MEK is now stale.
      ref.read(vaultSessionProvider.notifier).lock();
      notifier.setSynced(DateTime.now(), blobSize);
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.profilePasswordChangedVersion(version),
        );
      }
    } catch (e) {
      notifier.setErrorFrom(e);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────

  /// Registers the account's recovery proof with this verified sync key
  /// (3.3, lib/services/account/recovery_proof.dart): quietly, on the side,
  /// never in the way of what the person is doing.
  void _registerRecoveryProof(SecretKey mek) => unawaited(ref.read(recoveryProofServiceProvider).register(mek));

  Future<bool?> _confirmAction(String title, String message,
          {bool isDestructive = false}) =>
      askAccountQuestion(context, title: title, message: message, destructive: isDestructive);

  Future<String?> _showPasswordDialog(String title, {String? why}) {
    final l10n = AppLocalizations.of(context)!;
    // Compact modal class (UX audit A1): titled header + close control,
    // trapped focus on the field, Enter submits / Escape cancels, and the
    // reveal (eye) toggle comes free from ZestTextField's obscureText.
    return showZestInputDialog(
      context: context,
      title: title,
      subtitle: why,
      icon: LucideIcons.lock,
      fieldLabel: l10n.profileMasterSyncPassword,
      hintText: l10n.profileMasterSyncPassword,
      obscureText: true,
      confirmLabel: l10n.profileContinue,
      cancelLabel: l10n.cancel,
      autofillHints: const [AutofillHints.password],
    );
  }

  static DateTime? _newer(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// Stable, non-identifying device id shared with [AutoSyncService].
  ///
  /// Deliberately does NOT include the machine hostname - the id is written
  /// into the (cloud-stored) sync blob, so leaking `DESKTOP-<name>` there
  /// would be free recon for anyone who grabs the file. Uses OS + a random
  /// suffix, persisted so it stays stable across pushes and matches the id
  /// auto-sync writes (they read the same secure-storage key).
  Future<String> _getDeviceId() async {
    final storage = ref.read(secureStorageProvider);
    var deviceId = await storage.read(key: 'device_id');
    if (deviceId == null || deviceId.isEmpty) {
      deviceId =
          '${Platform.operatingSystem}_${const Uuid().v4().substring(0, 8)}';
      await storage.write(key: 'device_id', value: deviceId);
    }
    return deviceId;
  }
}

/// Result of acquiring a verified sync key (S2 vault-unlock gating).
///
/// [dek] is present iff [verified]; a `verified:false` result carries the
/// derived-but-unverified MEK only so the caller can surface the standard
/// "incorrect password" error, and MUST NOT be used to encrypt/upload.
class _SyncUnlock {
  const _SyncUnlock({required this.mek, required this.dek, required this.verified, this.proofRegistered});
  final SecretKey mek;
  final SecretKey? dek; // present iff verified
  final bool verified;

  /// The recovery proof's registration, where the password was typed and
  /// proved just now (null for a key the vault held already).
  final Future<void>? proofRegistered;
}

// ════════════════════════════════════════════════════════════════════
//  Account panel building blocks
// ════════════════════════════════════════════════════════════════════

/// A titled section: a [ZestSectionHeader] (with optional trailing widget)
/// above its [child].
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child, this.trailing, this.danger = false});

  final String label;
  final Widget child;
  final Widget? trailing;

  /// The Danger zone: the header in red.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(label: label, trailing: trailing, danger: danger),
        const SizedBox(height: 9),
        child,
      ],
    );
  }
}

/// A rounded surface card whose [children] are separated by hairline dividers.
class _PanelCard extends StatelessWidget {
  const _PanelCard({super.key, required this.children, this.tone});

  final List<Widget> children;

  /// A status colour for the outline (red, amber): a quiet signal that
  /// blends with the card rather than a banner. Null keeps the hairline.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
          height: 1,
          thickness: 1,
          color: AppColors.v3BorderSubtle,
        ));
      }
      rows.add(children[i]);
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: tone?.withValues(alpha: 0.55) ?? AppColors.v3BorderSubtle,
        ),
        boxShadow: tone == null
            ? null
            : [BoxShadow(color: tone!.withValues(alpha: 0.10), blurRadius: 14, spreadRadius: -2)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

/// One row inside a [_PanelCard]: a title, optional description, and an
/// optional trailing widget (a button, pill, or status text).
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    super.key,
    required this.title,
    this.desc,
    this.trailing,
    this.titleTrailing,
    this.below,
  });

  final String title;
  final String? desc;
  final Widget? trailing;

  /// Shown under the title, above [desc] (the ways into an account).
  final Widget? below;

  /// An optional chip shown inline after the title (e.g. "Needs an account",
  /// the "On" status pill), distinct from [trailing] which is the row action.
  final Widget? titleTrailing;

  @override
  Widget build(BuildContext context) {
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Its pill after the title, or under it where the two do not fit
        // on a line (at twice the text size in Russian, the pill ran off
        // the row).
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface,
              ),
            ),
            ?titleTrailing,
          ],
        ),
        if (below != null) ...[
          const SizedBox(height: 6),
          below!,
        ],
        if (desc != null) ...[
          const SizedBox(height: 3),
          Text(
            desc!,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: AppColors.onSurfaceDim,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      // The row's button beside its words where they keep their room, and
      // under them where they would not: beside them on a phone, it broke
      // a long word ("Wiederherstellungsschlüssel").
      child: trailing == null ? words : BesideOrUnder(words: words, control: trailing!),
    );
  }
}

/// One device entry in the Devices section: a platform icon, the device name
/// (with a "This device" badge), and a secondary "OS · last synced" line. Only
/// ever renders genuinely-available data - there is no fabricated roster.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.icon,
    required this.name,
    required this.subtitle,
    this.thisDeviceLabel,
    this.trailing,
  });

  final IconData icon;
  final String name;
  final String subtitle;

  /// Shown as a pill when this row is the device in hand.
  final String? thisDeviceLabel;

  /// An action at the end of the row (Sign out).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.onSurfaceDim.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: AppColors.onSurface),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      // In the app's sans, as every row's title: a device is
                      // named by its system ("Windows", "iOS"), not by code
                      // (a design audit).
                      child: Text(
                        name,
                        key: const ValueKey('account-device-name'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurface,
                        ),
                      ),
                    ),
                    if (thisDeviceLabel != null) ...[
                      const SizedBox(width: 8),
                      // Grey with a device, as a team's devices show it:
                      // which one is in hand, not a state (green is for
                      // what is healthy).
                      ZestStatusPill(
                        key: const ValueKey('account-device-this'),
                        kind: ZestStatusKind.neutral,
                        icon: LucideIcons.monitorCheck,
                        label: thisDeviceLabel!,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: AppColors.onSurfaceDim,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// A muted note. Sits inside a [_PanelCard] by default, or [standalone] under
/// a card as a caption.
/// How a device-list action ended.
enum _DeviceActionResult {
  done,
  cancelled,
  failed,

  /// Every session was signed out, but Google sign-in was not revoked.
  googleNotRevoked,
}

class _PanelNote extends StatelessWidget {
  const _PanelNote({super.key, required this.text, this.standalone = false});

  final String text;
  final bool standalone;

  @override
  Widget build(BuildContext context) {
    final t = Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        height: 1.5,
        color: AppColors.onSurfaceDim,
      ),
    );
    return Padding(
      padding: standalone
          ? const EdgeInsets.symmetric(horizontal: 2)
          : const EdgeInsets.fromLTRB(13, 10, 13, 12),
      child: t,
    );
  }
}

/// A small tinted status pill (header status, "Saved", etc.).
class _StatusPill extends StatelessWidget {
  const _StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          // The nearest shade of it that reads on its own wash.
          color: zestInkOnTint(color, 0.12),
        ),
      ),
    );
  }
}

/// Solid orange primary button (compact). The ONE orange element per state.
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brandOrange,
        // Dark text on the brand fill, as on every theme (3.0 UI).
        foregroundColor: AppColors.onBrand(AppColors.brandOrange),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label),
    );
  }
}

/// Solid amber warn button - used only as the single critical primary (saving
/// the recovery key), per the one-accent-per-state rule.
class _WarnButton extends StatelessWidget {
  const _WarnButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.warning,
        foregroundColor: Colors.black87,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label),
    );
  }
}

/// Outlined neutral button (Change, Configure, Restore, Export, …).
class _NeutralButton extends StatelessWidget {
  const _NeutralButton({super.key, required this.label, required this.onTap, this.danger = false});

  final String label;
  final VoidCallback? onTap;

  /// It signs out, ends or removes something: red, as a destructive row's
  /// action is (a design audit).
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: danger ? AppColors.error : AppColors.onSurface,
        side: BorderSide(color: danger ? AppColors.error.withValues(alpha: 0.5) : AppColors.v3BorderStrong),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label),
    );
  }
}

/// Quiet text-style ("ghost") button - e.g. "View license".
class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: Text(label),
    );
  }
}

/// Tone for [_AttentionBanner].
enum _BannerTone { crit, warn }

/// A tinted attention banner (icon + title + body).
class _AttentionBanner extends StatelessWidget {
  const _AttentionBanner({
    required this.tone,
    required this.title,
    required this.body,
  });

  final _BannerTone tone;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final color =
        tone == _BannerTone.crit ? AppColors.error : AppColors.warning;
    final icon = tone == _BannerTone.crit
        ? LucideIcons.alertTriangle
        : LucideIcons.alertCircle;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One step in the interrupted-setup stepper (§C).
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.done,
    required this.isNow,
    required this.title,
    required this.desc,
    this.action,
  });

  final int index;
  final bool done;
  final bool isNow;
  final String title;
  final String desc;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    late final Color numBg;
    late final Color numBorder;
    late final Widget numChild;
    if (done) {
      numBg = AppColors.success;
      numBorder = AppColors.success;
      numChild = const Icon(LucideIcons.check, size: 12, color: Colors.black);
    } else if (isNow) {
      numBg = AppColors.brandOrange.withValues(alpha: 0.15);
      numBorder = AppColors.brandOrange;
      numChild = Text('$index',
          style: TextStyle(
              color: AppColors.accentInk,
              fontSize: 11,
              fontWeight: FontWeight.w700));
    } else {
      numBg = Colors.transparent;
      numBorder = AppColors.v3BorderStrong;
      numChild = Text('$index',
          style: TextStyle(
              color: AppColors.onSurfaceDim,
              fontSize: 11,
              fontWeight: FontWeight.w700));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: numBg,
              shape: BoxShape.circle,
              border: Border.all(color: numBorder, width: 1.5),
            ),
            child: numChild,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: (done || isNow)
                        ? AppColors.onSurface
                        : AppColors.onSurfaceDim,
                  ),
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: AppColors.onSurfaceDim,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 12),
            action!,
          ],
        ],
      ),
    );
  }
}

/// A danger-zone row: red-tinted card with a title, description, and an action
/// button ([destructive] tints the button red).
class _DangerRow extends StatelessWidget {
  const _DangerRow({
    required this.title,
    required this.desc,
    required this.actionLabel,
    required this.onAction,
    this.destructive = false,
  });

  final String title;
  final String desc;
  final String actionLabel;
  final VoidCallback onAction;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.error,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: AppColors.onSurfaceDim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: onAction,
            style: OutlinedButton.styleFrom(
              foregroundColor: destructive
                  ? AppColors.error
                  : AppColors.onSurface,
              side: BorderSide(
                color: destructive
                    ? AppColors.error.withValues(alpha: 0.5)
                    : AppColors.v3BorderStrong,
              ),
              backgroundColor: destructive
                  ? AppColors.error.withValues(alpha: 0.07)
                  : null,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle:
                  const TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}


/// A compact, copyable Account ID (the Firebase UID, which is also the
/// RevenueCat app user id). Shown on the signed-in profile so a user can send
/// it to support, e.g. to have a licence applied, without exposing their email
/// or relying on Sign in with Apple's Hide My Email.
class _AccountIdRow extends StatelessWidget {
  const _AccountIdRow({required this.uid});
  final String uid;

  String get _short => uid.length <= 16
      ? uid
      : '${uid.substring(0, 8)}...${uid.substring(uid.length - 4)}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.profileAccountIdTooltip(uid),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: uid));
          showTopSnackBar(context, l10n.profileAccountIdCopied,
              isSuccess: true);
        },
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.hash, size: 11, color: AppColors.onSurfaceDim),
              const SizedBox(width: 4),
              Text(
                _short,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: AppColors.onSurfaceDim,
                ),
              ),
              const SizedBox(width: 5),
              Icon(LucideIcons.copy, size: 11, color: AppColors.onSurfaceDim),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the join unlock dialog asks: the master password, with the ways
/// round it (the recovery key, another of this account's devices).
class _JoinUnlockBody extends StatefulWidget {
  const _JoinUnlockBody({
    super.key,
    required this.message,
    required this.approval,
    required this.onSubmit,
    required this.onRecovery,
    required this.onApproval,
    this.leadWithApproval = false,
  });

  final String message;

  /// Whether another of this account's devices can hand the key over.
  final bool approval;

  /// Whether that comes first, as a button: another device is signed in.
  final bool leadWithApproval;
  final VoidCallback onSubmit;
  final VoidCallback onRecovery;
  final VoidCallback onApproval;

  @override
  State<_JoinUnlockBody> createState() => _JoinUnlockBodyState();
}

class _JoinUnlockBodyState extends State<_JoinUnlockBody> {
  final _controller = TextEditingController();

  /// What has been typed.
  String get password => _controller.text;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.message,
          style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        if (widget.leadWithApproval) ...[
          OutlinedButton.icon(
            key: const ValueKey('join-approve-first'),
            onPressed: widget.onApproval,
            icon: const Icon(LucideIcons.monitorSmartphone, size: 16),
            label: Text(l10n.askFromDevice),
          ),
          const SizedBox(height: 14),
        ],
        // The app's password field: its label above, shown or hidden.
        ZestTextField(
          controller: _controller,
          label: l10n.profileMasterSyncPassword,
          obscureText: true,
          onSubmit: widget.onSubmit,
          autofillHints: const [AutofillHints.password],
        ),
        const SizedBox(height: 6),
        Text(
          l10n.syncPasswordManagerHint,
          style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        // The other ways in: quiet links under the field, close together.
        Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            _QuietLink(
              icon: LucideIcons.keyRound,
              label: l10n.profileForgotUseRecovery,
              onTap: widget.onRecovery,
            ),
            if (widget.approval && !widget.leadWithApproval)
              _QuietLink(
                key: const ValueKey('join-approve-from-device'),
                icon: LucideIcons.monitorSmartphone,
                label: l10n.askFromDevice,
                onTap: widget.onApproval,
              ),
          ],
        ),
      ],
    );
  }
}

/// Another way in, under a password field: small, in the secondary ink,
/// the accent's on hover; a focusable button all the same.
class _QuietLink extends StatelessWidget {
  const _QuietLink({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14),
      label: Text(label),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, fontWeight: FontWeight.w500),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ).copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? ZestTokens.brandInk : ZestTokens.textSecondary),
      ),
    );
  }
}

/// What is said when the account could not be deleted and nothing was: how
/// ZestSSH Cloud stands, with its code, where it or the way to it was what
/// stopped the request ([cause], see AccountDeletionFailed.cause), after
/// the one thing that matters most here, that nothing was deleted; and the
/// sentence there always was for everything else.
String accountNotDeletedText(AppLocalizations l10n, Object? cause) =>
    (cause == null ? null : cloudStopped(l10n, cause, lead: l10n.accountDeleteNothingDeleted)) ??
    l10n.accountDeleteFailedNothing;

/// "Last synced: {time}", the time as words inside the sentence ("Last
/// synced: just now", not "Just now"). [now] is for tests.
String profileLastSyncedText(AppLocalizations l10n, DateTime at, {DateTime? now}) =>
    l10n.profileLastSynced(timeAgoInSentence(l10n, at, now: now));
