import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart' show AccountPlan;
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/google_desktop_oauth.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/services/sync/google_drive_sync_backend.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_disconnect.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';
import 'package:zestssh/services/sync/unread_sync_store.dart';
import 'package:zestssh/services/sync_service.dart' show SyncException;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show PlanChip;
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

/// Bridges the docked panel's ✕ (in a different file, so it can't reach the
/// private [State]) to the screen's dirty-guarded close. The State registers
/// its guarded-close handler on this controller in `initState`; the docked
/// panel header calls [requestClose] to run it.
class SyncBackendCloseController {
  Future<void> Function()? _attemptClose;
  bool Function()? _isDirtyGetter;

  /// Ask the embedded screen to close, honouring its unsaved-changes guard.
  Future<void> requestClose() async => await _attemptClose?.call();

  /// Whether the embedded screen currently has unsaved edits. Lets the host
  /// (nav-away / dock-switch paths) avoid silently tearing the panel down with
  /// half-entered store credentials still in it. False when no screen mounted.
  bool get isDirty => _isDirtyGetter?.call() ?? false;
}

/// App-lifetime singleton so BOTH the settings view (which passes it to the
/// embedded [SyncBackendScreen]) and unrelated widgets that can switch the dock
/// (the theme-editor buttons) share one controller - they consult [isDirty] and
/// run [requestClose] before replacing a dirty sync-backend panel.
final syncBackendCloseControllerProvider =
    Provider<SyncBackendCloseController>((ref) => SyncBackendCloseController());

/// Lets the user choose WHERE their end-to-end-encrypted sync data lives:
/// the hosted ZestSSH Cloud (paid), a self-hosted server, or a bring-your-own
/// store (WebDAV / S3-compatible / Google Drive) which is free.
class SyncBackendScreen extends ConsumerStatefulWidget {
  const SyncBackendScreen({super.key, this.onClose, this.closeController});

  /// Docked/embedded mode: when non-null the screen drops its route [PopScope]
  /// + [ResponsiveScaffold] chrome (the docked panel supplies the header + ✕)
  /// and reports a completed close (after save or a confirmed discard) through
  /// this callback instead of `context.pop`. Null = the classic full-screen
  /// route flow used on mobile + the legacy desktop screen.
  final VoidCallback? onClose;

  /// Docked/embedded mode: lets the docked panel's ✕ trigger the same
  /// dirty-guarded close the route's system-back would.
  final SyncBackendCloseController? closeController;

  /// Present the storage picker as a MODAL dialog (embedded mode) rather than
  /// pushing a full-screen route. Used from the Profile & Sync surface - which
  /// is itself a modal on desktop - so choosing storage stays one navigation
  /// model (a dialog inside a dialog) instead of a full page with a back arrow
  /// stacked over a modal. The dialog header's ✕ runs the same dirty guard the
  /// docked panel does.
  static Future<void> showModal(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final closeController = SyncBackendCloseController();
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => Dialog(
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.syncBackendSyncStorage,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: AppLocalizations.of(context)!.close,
                      icon: const Icon(LucideIcons.x, size: 20),
                      // Route the ✕ through the screen's unsaved-changes guard.
                      onPressed: () => closeController.requestClose(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.divider),
              Flexible(
                child: SyncBackendScreen(
                  onClose: () => Navigator.of(dialogCtx).pop(),
                  closeController: closeController,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<SyncBackendScreen> createState() => _SyncBackendScreenState();
}

class _SyncBackendScreenState extends ConsumerState<SyncBackendScreen> {
  late SyncBackendKind _kind;

  // Custom server
  final _serverUrl = TextEditingController();
  final _serverToken = TextEditingController();

  // WebDAV
  final _webdavUrl = TextEditingController();
  final _webdavUser = TextEditingController();
  final _webdavPass = TextEditingController();
  final _webdavPath = TextEditingController();

  // S3
  final _s3Endpoint = TextEditingController();
  final _s3Region = TextEditingController();
  final _s3Bucket = TextEditingController();
  final _s3Key = TextEditingController();
  final _s3Secret = TextEditingController();
  final _s3Prefix = TextEditingController();
  bool _s3PathStyle = true;

  bool _obscureSecrets = true;
  bool _testing = false;
  bool _saving = false;
  String? _testError;
  // Raw technical text for the failed test, surfaced only behind a
  // "Copy details" button - never in the headline.
  String? _testErrorDetail;
  bool _testOk = false;

  /// True once the user has touched any field/toggle since the last save.
  /// Drives the unsaved-changes guard so backing out can't silently drop
  /// half-entered store credentials.
  bool _dirty = false;

  /// Each field's listener, to take it off again.
  final _wordListeners = <TextEditingController, VoidCallback>{};

  /// True when hosted in the docked Settings panel (vs pushed as a route).
  bool get _embedded => widget.onClose != null;

  List<TextEditingController> get _allControllers => [
        _serverUrl, _serverToken, _webdavUrl, _webdavUser, _webdavPass,
        _webdavPath, _s3Endpoint, _s3Region, _s3Bucket, _s3Key, _s3Secret,
        _s3Prefix,
      ];

  @override
  void initState() {
    super.initState();
    final c = ref.read(syncProviderConfigProvider);
    // (A build with no ZestSSH Cloud does not offer it: what stands for
    // "nothing chosen yet" there opens on the first store it does offer.)
    _kind = c.kind == SyncBackendKind.zestServer && !zestHasCloud ? SyncBackendKind.webdav : c.kind;
    _serverUrl.text = c.serverUrl ?? '';
    _serverToken.text = c.serverToken ?? '';
    _webdavUrl.text = c.webdavUrl ?? '';
    _webdavUser.text = c.webdavUsername ?? '';
    _webdavPass.text = c.webdavPassword ?? '';
    _webdavPath.text = c.webdavPath ?? '';
    _s3Endpoint.text = c.s3Endpoint ?? '';
    _s3Region.text = c.s3Region ?? '';
    _s3Bucket.text = c.s3Bucket ?? '';
    _s3Key.text = c.s3AccessKeyId ?? '';
    _s3Secret.text = c.s3SecretAccessKey ?? '';
    _s3Prefix.text = c.s3Prefix ?? '';
    _s3PathStyle = c.s3UsePathStyle;
    // Add listeners AFTER seeding text so the initial fill doesn't mark dirty;
    // each marks it on a change of its words, not of its cursor or selection
    // (a click into a field asked to discard changes that were never made).
    for (final ctrl in _allControllers) {
      var words = ctrl.text;
      void heard() {
        if (ctrl.text == words) return;
        words = ctrl.text;
        _markDirty();
      }

      _wordListeners[ctrl] = heard;
      ctrl.addListener(heard);
    }
    // Docked mode: let the panel header's ✕ run the same dirty-guarded close,
    // and expose the dirty flag so the host won't silently tear the panel down
    // (nav-away / dock-switch) with unsaved credentials still in it.
    final ctrl = widget.closeController;
    if (ctrl != null) {
      ctrl._attemptClose = _attemptGuardedClose;
      ctrl._isDirtyGetter = () => _dirty;
    }
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    // Detach from the controller, but only if it still points at THIS state -
    // a fresh instance may already have claimed it.
    final ctrl = widget.closeController;
    if (ctrl != null && ctrl._attemptClose == _attemptGuardedClose) {
      ctrl._attemptClose = null;
      ctrl._isDirtyGetter = null;
    }
    for (final ctrl in _allControllers) {
      final heard = _wordListeners[ctrl];
      if (heard != null) ctrl.removeListener(heard);
      ctrl.dispose();
    }
    super.dispose();
  }

  /// Run the unsaved-changes guard, then close. Shared by the docked panel's ✕
  /// (via [SyncBackendCloseController]) and the route's system-back path.
  Future<void> _attemptGuardedClose() async {
    if (_dirty && !await _confirmDiscard()) return; // keep editing
    _closeOrPop();
  }

  /// Close via the embedded [onClose] callback when docked, else pop the route.
  void _closeOrPop() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      if (mounted) context.pop();
    }
  }

  /// Build a config object from the current form state (trimmed).
  SyncProviderConfig _draft() {
    String? t(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    return SyncProviderConfig(
      kind: _kind,
      serverUrl: t(_serverUrl),
      serverToken: t(_serverToken),
      webdavUrl: t(_webdavUrl),
      webdavUsername: t(_webdavUser),
      webdavPassword: _webdavPass.text.isEmpty ? null : _webdavPass.text,
      webdavPath: t(_webdavPath),
      s3Endpoint: t(_s3Endpoint),
      s3Region: t(_s3Region),
      s3Bucket: t(_s3Bucket),
      s3AccessKeyId: t(_s3Key),
      s3SecretAccessKey: _s3Secret.text.isEmpty ? null : _s3Secret.text,
      s3Prefix: t(_s3Prefix),
      s3UsePathStyle: _s3PathStyle,
    );
  }

  /// Why [draft]'s storage cannot be used on this device with this build, or
  /// null. Google Drive on a computer needs the browser sign-in client; a
  /// build without it says so instead of failing inside the plugin.
  String? _notAvailableHere(SyncProviderConfig draft) =>
      draft.kind == SyncBackendKind.googleDrive &&
              !GoogleDriveSyncBackend.availableHere
          ? AppLocalizations.of(context)!.googleDriveNotOnThisComputer
          : null;

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final draft = _draft();
    if (!draft.isComplete) {
      setState(() {
        _testOk = false;
        _testError = l10n.syncBackendFillEveryRequiredField;
        _testErrorDetail = null;
      });
      return;
    }
    final insecure = draft.insecureTransportError ?? _notAvailableHere(draft);
    if (insecure != null) {
      setState(() {
        _testOk = false;
        _testError = insecure;
        _testErrorDetail = null;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _testErrorDetail = null;
      _testOk = false;
    });
    try {
      final backend = SyncBackendFactory.build(draft);
      await backend.checkConnection();
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testError = null;
        _testErrorDetail = null;
        // A Drive test on a computer is also the sign-in: show who it is.
        _driveStatus = null;
      });
    } on SyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testError = e.message;
        _testErrorDetail = e.detail;
      });
    } catch (e) {
      if (!mounted) return;
      // Never dump the raw exception into the card - translate to a plain
      // headline and park the raw text behind the copy button.
      final friendly =
          describeNetworkError(e, subject: l10n.syncBackendThisStore);
      setState(() {
        _testOk = false;
        _testError = friendly.message;
        _testErrorDetail = friendly.detail;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final draft = _draft();
    if (!draft.isComplete) {
      showTopSnackBar(context, l10n.syncBackendFillEveryRequiredField,
          isError: true);
      return;
    }
    final insecure = draft.insecureTransportError ?? _notAvailableHere(draft);
    if (insecure != null) {
      showTopSnackBar(context, insecure, isError: true,
          duration: const Duration(seconds: 6));
      return;
    }

    // The kept choice could not be read (3.4.2): what is shown here is the
    // hosted default, not the store this device syncs with. Read it again;
    // where macOS still does not let it be read, nothing is written over and
    // nothing of sync's is deleted. A choice that was read and could not be
    // made sense of is replaced by this one, and this device's sync is left
    // as it is (whether it is a switch is not known).
    final store = ref.read(syncProviderConfigProvider.notifier);
    await store.ensureLoaded();
    if (!mounted) return;
    final unread = store.unreadBecause;
    if (unread != null && SyncStoreUnknownException(unread).keychain) {
      final refused = SyncStoreUnknownException(unread);
      showTopSnackBar(context, refused.message, isError: true, details: refused.detail);
      return;
    }

    final current = ref.read(syncProviderConfigProvider);
    final setup = ref.read(syncSetupStateServiceProvider);
    final isActive = unread == null && await setup.isSyncActive();
    // A store switch is any change to WHICH store we point at (kind OR
    // location), not just the provider kind - editing a WebDAV URL or S3
    // bucket must also disconnect the stale DEK/version, or sync stalls.
    final switchingProvider = current.storeIdentity != draft.storeIdentity;

    // Switching the storage location while sync is active would leave this
    // device pointing at a store it never set up. Disconnect locally first
    // (the OLD store keeps its data - nothing is deleted remotely).
    if (isActive && switchingProvider && mounted) {
      final confirmed = await _confirmSwitch(current, draft);
      if (confirmed != true) return;
    }

    setState(() => _saving = true);
    try {
      if (isActive && switchingProvider) {
        await _disconnectLocally();
      }
      await ref.read(syncProviderConfigProvider.notifier).save(draft, overUnreadable: true);
      if (!mounted) return;
      // The draft is now the saved state - clear the guard so the pop below
      // (and any later back-out) doesn't prompt to discard.
      _dirty = false;
      showTopSnackBar(
        context,
        switchingProvider
            ? draft.kind.isHosted
                ? l10n.syncBackendStorageSetTo(draft.kind.label)
                : '${l10n.syncBackendStorageSetTo(draft.kind.label)} '
                    '${l10n.syncBackendSetUpSyncToStart}'
            : l10n.syncBackendStorageSettingsSaved,
        isSuccess: true,
      );
      _closeOrPop();
    } catch (e) {
      if (!mounted) return;
      // In the app's words, with what was thrown to copy (it was glued to
      // "Could not save:").
      showTopSnackBar(context, l10n.syncBackendNotSaved, isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Disconnect sync on THIS device without touching remote data.
  Future<void> _disconnectLocally() => disconnectSyncOnThisDevice(
        autoSync: ref.read(autoSyncServiceProvider),
        setup: ref.read(syncSetupStateServiceProvider),
        settings: ref.read(settingsServiceProvider),
        secureStorage: ref.read(secureStorageProvider),
        // Disconnecting sync clears its credentials - drop any cached MEK too.
        lockVault: ref.read(vaultSessionProvider.notifier).lock,
      );

  Future<bool?> _confirmSwitch(
      SyncProviderConfig from, SyncProviderConfig to) {
    final l10n = AppLocalizations.of(context)!;
    final sameKind = from.kind == to.kind;
    final body = sameKind
        ? l10n.syncBackendSwitchSameKindBody(to.kind.label)
        : l10n.syncBackendSwitchDifferentKindBody(from.kind.label, to.kind.label);
    // The app's own question (it was a plain dialog).
    return ZestConfirmDialog.show(
      context,
      // An ordinary question: nothing is deleted (3.4, nothing amber).
      tone: ZestDialogTone.neutral,
      title: l10n.syncBackendSwitchStorageTitle,
      body: body,
      confirmLabel: l10n.syncBackendSwitch,
      cancelLabel: l10n.cancel,
    );
  }

  /// Ask before throwing away unsaved store credentials. Returns true to
  /// allow the pop.
  Future<bool> _confirmDiscard() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      // Throws away what was typed: red, as every discard of the app's.
      tone: ZestDialogTone.destructive,
      title: l10n.syncBackendDiscardChangesTitle,
      body: l10n.syncBackendDiscardChangesBody,
      confirmLabel: l10n.syncBackendDiscard,
      cancelLabel: l10n.syncBackendKeepEditing,
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    // Docked mode: the panel supplies the header + ✕ (which drives the dirty
    // guard through the close controller), so return the bare body - no route
    // PopScope, no ResponsiveScaffold chrome.
    if (_embedded) {
      return _buildBody(context);
    }
    // canPop follows the dirty flag: a clean screen pops immediately; a dirty
    // one is intercepted so the AppBar/system back can confirm the discard.
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) {
          context.pop();
        }
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return ResponsiveScaffold(
      title: AppLocalizations.of(context)!.syncBackendSyncStorage,
      actions: const [GuideHelpButton(feature: 'sync', size: 20), SizedBox(width: 4)],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final savedKind = ref.watch(syncProviderConfigProvider).kind;
    return LayoutBuilder(
        builder: (context, constraints) {
          final twoColumn = constraints.maxWidth > 820;

          // One store is picked: each card's dot radio in one group.
          final providerColumn = RadioGroup<SyncBackendKind>(
            groupValue: _kind,
            onChanged: (kind) {
              if (kind != null) _pickKind(kind);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel(l10n.syncBackendChooseWhereYourDataSyncs),
                const SizedBox(height: 8),
                ..._providerCards(savedKind),
              ],
            ),
          );

          final configColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel(_kind.label.toUpperCase()),
              const SizedBox(height: 10),
              _configForm(),
              // Storage of one's own: what still reaches ZestSSH's servers,
              // and that the synced data never does (asked by someone who saw
              // a connection to ZestSSH's host while syncing to WebDAV).
              if (_kind != SyncBackendKind.zestServer) ...[
                const SizedBox(height: 12),
                KeyedSubtree(
                    key: const ValueKey('own-storage-note'),
                    child: _infoBox(AppLocalizations.of(context)!.syncBackendOwnStorageNote)),
              ],
              if (_testError != null || _testOk) ...[
                const SizedBox(height: 14),
                _testResult(),
              ],
              const SizedBox(height: 22),
              _actions(),
            ],
          );

          if (twoColumn) {
            // Desktop: provider list on the left, config for the selected
            // provider on the right (§3), so the config never sprawls and
            // the choice + its settings read as one screen.
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              children: [
                _encryptedBanner(),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 300, child: providerColumn),
                    const SizedBox(width: 28),
                    Expanded(child: configColumn),
                  ],
                ),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _encryptedBanner(),
              const SizedBox(height: 16),
              providerColumn,
              const SizedBox(height: 20),
              configColumn,
            ],
          );
        },
      );
  }

  // ── Pieces ────────────────────────────────────────────────────────

  Widget _encryptedBanner() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.brandOrange.withValues(alpha: 0.12),
            AppColors.brandOrange.withValues(alpha: 0.02),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: AppColors.brandOrange.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.shieldCheck, color: AppColors.accentInk, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.syncBackendEncryptedBanner,
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.onSurfaceDim,
          ),
        ),
      );

  List<Widget> _providerCards(SyncBackendKind savedKind) {
    final l10n = AppLocalizations.of(context)!;
    final signedIn = ref.watch(isSignedInProvider);
    // ZestSSH Cloud leads the list (user request), then the four self-run
    // stores. Cloud still carries the only other "Needs an account" marker in
    // the app for a guest; once signed in it reads its tier tag instead.
    final items = <(SyncBackendKind, IconData, String, String, String)>[
      if (zestHasCloud)
      (
        SyncBackendKind.zestServer,
        LucideIcons.cloud,
        SyncBackendKind.zestServer.label,
        l10n.storageCloudHelp,
        signedIn ? 'Juiced' : 'NeedsAccount',
      ),
      (
        SyncBackendKind.webdav,
        LucideIcons.server,
        SyncBackendKind.webdav.label,
        l10n.storageWebdavHelp,
        'Free',
      ),
      (
        SyncBackendKind.s3,
        LucideIcons.database,
        SyncBackendKind.s3.label,
        l10n.storageS3Help,
        'Free',
      ),
      (
        SyncBackendKind.googleDrive,
        LucideIcons.hardDrive,
        SyncBackendKind.googleDrive.label,
        l10n.storageDriveHelp,
        'Free',
      ),
      // "Your own ZestSSH server" is no longer offered (removed 2026-10-08:
      // there is no server to run, so it only served someone who wrote one).
      // A device already set up with one still sees it, as what it uses, and
      // can move to another store.
      if (savedKind == SyncBackendKind.custom)
        (
          SyncBackendKind.custom,
          LucideIcons.terminal,
          l10n.storageSelfHosted,
          l10n.storageSelfHostedHelp,
          'Advanced',
        ),
    ];
    return [
      for (final (kind, icon, title, desc, tag) in items)
        _providerCard(kind, icon, title, desc, tag, savedKind == kind),
    ];
  }

  /// [kind] picked as the store to set up (the one it has, picked again,
  /// changes nothing).
  void _pickKind(SyncBackendKind kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _testOk = false;
      _testError = null;
      _dirty = true;
    });
  }

  Widget _providerCard(SyncBackendKind kind, IconData icon, String title,
      String desc, String tag, bool isCurrent) {
    final l10n = AppLocalizations.of(context)!;
    final selected = _kind == kind;
    final tagColor = switch (tag) {
      'Free' => AppColors.success,
      'Juiced' => AppColors.cloudSync,
      _ => AppColors.onSurfaceDim,
    };
    final tagLabel = switch (tag) {
      'Free' => l10n.syncBackendTagFree,
      'Juiced' => l10n.syncBackendTagJuiced,
      'Advanced' => l10n.syncBackendTagAdvanced,
      'NeedsAccount' => l10n.accountNeedsAccount,
      _ => tag,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? AppColors.brandOrange.withValues(alpha: 0.10)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _pickKind(kind),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? AppColors.brandOrange
                    : AppColors.divider,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 22,
                    color: selected
                        ? AppColors.accentInk
                        : AppColors.onSurfaceVariant),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Wrap (not Row) so the extra "Current" chip never
                      // overflows on narrow mobile widths with a long label.
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14.5),
                          ),
                          // Juiced, the plan ZestSSH Cloud comes with,
                          // says what it is when tapped (the plan's chip,
                          // 4.0); a team's seat is not shown its name.
                          if (tag == 'Juiced')
                            const PlanChip(key: ValueKey('sync-store-juiced'), plan: AccountPlan.juiced)
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: tagColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                tagLabel,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: tagColor,
                                ),
                              ),
                            ),
                          // Marks the store this device actually syncs to now,
                          // so a draft selection is never confused with saved.
                          if (isCurrent)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color:
                                    AppColors.brandOrange.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                l10n.syncBackendCurrent,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.accentInk,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        desc,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                // One store is picked: a dot radio, the one the dialogs
                // have; a check is for where several can be picked (this
                // was a check in a
                // circle).
                Radio<SyncBackendKind>(key: ValueKey('sync-store-radio-${kind.name}'), value: kind),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _configForm() {
    final l10n = AppLocalizations.of(context)!;
    switch (_kind) {
      case SyncBackendKind.zestServer:
        return _infoBox(l10n.syncBackendZestServerInfo);
      case SyncBackendKind.webdav:
        return Column(
          children: [
            _field(_webdavUrl, l10n.syncBackendServerUrl,
                hint: 'https://cloud.example.com/remote.php/dav/files/me/',
                mask: maskEndpointUrl),
            _plainHttpNote(_webdavUrl),
            _field(_webdavUser, l10n.syncBackendUsername,
                hint: l10n.syncBackendWebdavUsernameHint,
                mask: (v) => Redactable.username(v).display),
            _field(_webdavPass, l10n.syncBackendPassword,
                hint: l10n.syncBackendWebdavPasswordHint, secret: true),
            _field(_webdavPath, l10n.syncBackendFolderOptional,
                hint: '/ZestSSH/sync/'),
            _hint(l10n.syncBackendWebdavHint),
          ],
        );
      case SyncBackendKind.s3:
        return Column(
          children: [
            _field(_s3Endpoint, l10n.syncBackendEndpoint,
                hint: 'https://<acct>.r2.cloudflarestorage.com',
                mask: maskEndpointUrl),
            _plainHttpNote(_s3Endpoint),
            // A region code identifies nothing; the bucket and the key prefix
            // name an organisation, so they take the name rule while recording.
            _field(_s3Region, l10n.syncBackendRegion,
                hint: 'auto (R2), us-west-004 (B2)…'),
            _field(_s3Bucket, l10n.syncBackendBucket,
                hint: 'zestssh-sync',
                mask: (v) => Redactable.account(v).display),
            // The key id names the credential: bullets while recording.
            _field(_s3Key, l10n.syncBackendAccessKeyId,
                mask: (v) => Redactable.password(v).display),
            _field(_s3Secret, l10n.syncBackendSecretAccessKey, secret: true),
            _field(_s3Prefix, l10n.syncBackendKeyPrefixOptional,
                hint: 'zestssh/', mask: (v) => Redactable.account(v).display),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AppColors.brandOrange,
              value: _s3PathStyle,
              onChanged: (v) => setState(() {
                _s3PathStyle = v;
                _dirty = true;
              }),
              title: Text(l10n.syncBackendPathStyleAddressing,
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                l10n.syncBackendPathStyleSubtitle,
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
            _hint(l10n.syncBackendS3Hint),
          ],
        );
      case SyncBackendKind.googleDrive:
        // A phone signs in through the Google plugin. A computer has no such
        // plugin: it signs in through the browser, when this build was given
        // the client for that, and says plainly when it was not.
        if (!GoogleDesktopOAuth.usedOnThisPlatform) {
          return _infoBox(l10n.syncBackendGoogleDriveInfo);
        }
        if (!GoogleDriveSyncBackend.availableHere) {
          return _notice(l10n.googleDriveNotOnThisComputer, AppColors.warning,
              LucideIcons.alertTriangle);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _infoBox(l10n.googleDriveDesktopInfo),
            _driveDesktopStatus(),
          ],
        );
      case SyncBackendKind.custom:
        return Column(
          children: [
            _field(_serverUrl, l10n.syncBackendServerUrlWithV1,
                hint: 'https://sync.example.com/v1', mask: maskEndpointUrl),
            _plainHttpNote(_serverUrl),
            _field(_serverToken, l10n.syncBackendAccessTokenOptional,
                hint: l10n.syncBackendCustomTokenHint, secret: true),
            _hint(l10n.syncBackendCustomHint),
          ],
        );
    }
  }

  /// [mask] marks a field whose value is an identifier (an endpoint host, a
  /// username, a key id): while recording mode is on it renders masked and
  /// read-only, and a tap runs the reveal gate.
  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
    String Function(String raw)? mask,
  }) {
    const style = TextStyle(fontSize: 14);
    final decoration = InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle:
          TextStyle(color: AppColors.onSurfaceDim, fontSize: 12.5),
      filled: true,
      fillColor: AppColors.surfaceDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.brandOrange),
      ),
    );
    final field = TextField(
        controller: controller,
        obscureText: secret && _obscureSecrets,
        autocorrect: false,
        enableSuggestions: false,
        style: style,
        decoration: decoration.copyWith(
          suffixIcon: secret
              ? IconButton(
                  tooltip: _obscureSecrets ? AppLocalizations.of(context)!.zestDialogShow : AppLocalizations.of(context)!.zestDialogHide,
                  icon: Icon(
                    _obscureSecrets
                        ? LucideIcons.eyeOff
                        : LucideIcons.eye,
                    size: 18,
                    color: AppColors.onSurfaceDim,
                  ),
                  onPressed: () =>
                      setState(() => _obscureSecrets = !_obscureSecrets),
                )
              : null,
        ),
      );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: mask == null
          ? field
          : RecordingMaskedFormField(
              controller: controller,
              mask: mask,
              decoration: decoration,
              style: style,
              child: field,
            ),
    );
  }

  Widget _infoBox(String text) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 13, height: 1.45, color: AppColors.onSurfaceVariant)),
      );

  /// The Google account connected on this computer (browser sign-in), read
  /// from the keychain; reloaded after a test and after a disconnect.
  Future<({bool connected, String? email})>? _driveStatus;

  Future<({bool connected, String? email})> _loadDriveStatus() async {
    try {
      final oauth = GoogleDesktopOAuth.instance;
      final connected =
          await oauth.isConnected(const [GoogleDriveSyncBackend.appDataScope]);
      return (connected: connected, email: connected ? await oauth.email() : null);
    } catch (_) {
      return (connected: false, email: null);
    }
  }

  /// Under the Drive explanation on a computer: which account is connected,
  /// and the way to disconnect it (which revokes it at Google and removes it
  /// from this computer, and leaves the sync file in Drive alone).
  Widget _driveDesktopStatus() {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<({bool connected, String? email})>(
      future: _driveStatus ??= _loadDriveStatus(),
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status == null || !status.connected) return const SizedBox.shrink();
        final email = status.email;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Icon(LucideIcons.checkCircle2,
                  size: 16, color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  email == null
                      ? l10n.googleDriveConnected
                      : l10n.googleDriveConnectedAs(
                          Redactable.username(email).displayIn(ref)),
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: () async {
                  await GoogleDesktopOAuth.instance.signOut();
                  if (!mounted) return;
                  setState(() {
                    _driveStatus = _loadDriveStatus();
                    _testOk = false;
                  });
                  showTopSnackBar(this.context, l10n.googleDriveDisconnected);
                },
                child: Text(l10n.googleDriveDisconnect),
              ),
            ],
          ),
        );
      },
    );
  }

  /// What plain http means for the address in [url], said while it is typed
  /// (the same rule Test and Save apply, on every platform): a note when it
  /// is an address on the person's own network, where plain http is allowed
  /// and the server's password travels unencrypted; the refusal when it is
  /// anything else. Nothing for https.
  Widget _plainHttpNote(TextEditingController url) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: url,
        builder: (context, value, _) {
          final l10n = AppLocalizations.of(context)!;
          switch (plainHttpUseOf(value.text)) {
            case PlainHttpUse.none:
              return const SizedBox.shrink();
            case PlainHttpUse.ownNetwork:
              return _notice(l10n.plainHttpOwnNetworkNote, AppColors.warning,
                  LucideIcons.alertTriangle);
            case PlainHttpUse.refused:
              return _notice(l10n.plainHttpOwnNetworkOnly, AppColors.error,
                  LucideIcons.shieldAlert);
          }
        },
      );

  Widget _notice(String text, Color color, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: AppColors.onSurfaceVariant)),
              ),
            ],
          ),
        ),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5, height: 1.4, color: AppColors.onSurfaceDim)),
      );

  Widget _testResult() {
    final l10n = AppLocalizations.of(context)!;
    final ok = _testOk;
    final color = ok ? AppColors.success : AppColors.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? LucideIcons.checkCircle2 : LucideIcons.alertCircle,
              color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ok
                      ? l10n.syncBackendConnectionSucceeded
                      : (_testError ?? l10n.syncBackendConnectionFailed),
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: color),
                ),
                // Raw failure text (socket/HTTP trace) tucked behind a copy
                // button so the headline stays plain.
                if (!ok && _testErrorDetail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: CopyDetailsButton(
                      detail: _testErrorDetail!,
                      color: color,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions() {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: (_testing || _saving) ? null : _test,
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.plugZap, size: 16),
            label: Text(_testing
                ? l10n.syncBackendTesting
                : l10n.syncBackendTestConnection),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentInk,
              side: BorderSide(color: AppColors.brandOrange),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: (_testing || _saving) ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: ButtonSpinner(),
                  )
                : const Icon(LucideIcons.check, size: 18),
            label: Text(l10n.save),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }
}
