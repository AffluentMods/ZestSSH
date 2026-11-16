import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/app_updater.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/update_check_now.dart' show openUpdateDownload;
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/number_text.dart';

/// Opens the update's dialog for [info]: the new version and its notes,
/// "Update and restart" and "Later" (3.0). The
/// title bar's pill, the status bar's version and Settings' "Check for
/// updates" all lead here.
///
/// "Update and restart" asks first where sessions are open, as quitting
/// does, naming how many end; then it reads the signed manifest again, so
/// that a release out since [info] was found is the one installed (3.3.1);
/// then it downloads the release with its progress (cancellable), checks
/// it, gets it ready, and the app quits, installs it and opens again
/// (lib/services/app_updater.dart). A copy that cannot replace itself
/// offers the download page instead, saying why.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  final dialog = GlobalKey<_UpdateDialogState>();
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    barrierDismissible: false,
    // Escape is its X: it stops a download, and closes it where nothing is
    // under way.
    onDismissAttempt: () async {
      dialog.currentState?._dismiss();
      return false;
    },
    child: UpdateDialog(key: dialog, info: info),
  );
}

/// Where the update's dialog is.
enum UpdateStage { offer, blocked, checking, downloading, verifying, preparing, restarting, waitingForWindows, failed }

class UpdateDialog extends ConsumerStatefulWidget {
  const UpdateDialog({super.key, required this.info});

  final UpdateInfo info;

  @override
  ConsumerState<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<UpdateDialog> {
  UpdateStage _stage = UpdateStage.offer;
  int _got = 0;
  int _total = 0;
  UpdateCancelToken? _cancel;
  UpdateFailure? _failure;
  CannotInstall? _blocked;

  /// Whether ZestSSH opens again once the update is in: Update and restart
  /// (true) or Update and close (false). Retry keeps the choice.
  bool _reopen = true;

  /// The release this dialog offers: the one it was opened with, until the
  /// manifest read again just before an update names another.
  late UpdateInfo _info = widget.info;

  @override
  void initState() {
    super.initState();
    final check = ref.read(appUpdaterProvider).check(_info);
    if (check is CannotInstall) {
      _stage = UpdateStage.blocked;
      _blocked = check;
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _start({required bool reopen}) async {
    // As quitting asks: the restart ends every open session.
    final open = ref.read(updateOpenSessionCountProvider);
    if (open > 0 && !await confirmUpdateWithSessions(context, open, reopen: reopen)) return;
    if (!mounted) return;
    _reopen = reopen;
    // A release may be out since this one was found (the app, or this
    // dialog, left open): the signed manifest is read again, as any check
    // reads it, and the release it names now is the one installed. Without
    // an answer (offline) it is the one this dialog has; where this copy is
    // the latest after all, that is said and nothing is downloaded.
    setState(() {
      _stage = UpdateStage.checking;
      _failure = null;
    });
    final latest = await ref.read(updateBannerProvider.notifier).checkNow();
    if (!mounted) return;
    switch (latest) {
      case UpdateAvailable(:final info):
        _info = info;
      case UpdateCheckUpToDate(:final current):
        showTopSnackBar(context, AppLocalizations.of(context)!.updateCheckUpToDate(current), isSuccess: true);
        _close();
        return;
      case UpdateCheckFailed():
        break;
    }
    final updater = ref.read(appUpdaterProvider);
    final check = updater.check(_info);
    if (check is CannotInstall) {
      setState(() {
        _stage = UpdateStage.blocked;
        _blocked = check;
      });
      return;
    }
    final target = (check as CanInstall).target;
    final token = UpdateCancelToken();
    setState(() {
      _stage = UpdateStage.downloading;
      _cancel = token;
      _got = 0;
      _total = _info.package?.size ?? 0;
      _failure = null;
    });
    final prefs = ref.read(sharedPreferencesProvider);
    try {
      final file = await updater.download(_info, cancel: token, onProgress: (got, total) {
        if (!mounted) return;
        setState(() {
          _got = got;
          _total = total;
          // The last bytes in: what is left is the check of the whole.
          if (got >= total) _stage = UpdateStage.verifying;
        });
      });
      if (!mounted) return;
      setState(() => _stage = UpdateStage.preparing);
      final current = await ref.read(appVersionProvider.future);
      final currentBuild = await ref.read(appBuildNumberProvider.future);
      final prepared = await updater.prepare(_info, file, target,
          currentVersion: current, currentBuild: currentBuild, reopen: _reopen);
      if (!mounted) return;
      setState(() => _stage = UpdateStage.restarting);
      final end = UpdateRestart.endApp;
      if (end == null) {
        throw const UpdateFailure(ErrorCodes.updateInstallFailed, 'The app has no window to quit from for the update.');
      }
      await markUpdatePending(prefs, prepared, from: current);
      final bool ended;
      try {
        // On Windows the launch returns once the setup is installing (it
        // may first wait for Windows to allow it, and say so); only then
        // does the app quit.
        ended = await end(() async {
          await updater.launch(prepared, cancel: token, onWaiting: () {
            if (mounted) setState(() => _stage = UpdateStage.waitingForWindows);
          });
          if (mounted) setState(() => _stage = UpdateStage.restarting);
        });
      } catch (_) {
        await prefs.remove(kUpdatePendingKey);
        rethrow;
      }
      if (!ended) {
        await prefs.remove(kUpdatePendingKey);
        if (mounted) setState(() => _stage = UpdateStage.offer);
      }
    } on UpdateCancelled {
      if (mounted) setState(() => _stage = UpdateStage.offer);
    } on UpdateFailure catch (f) {
      if (mounted) {
        setState(() {
          _stage = UpdateStage.failed;
          _failure = f;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = UpdateStage.failed;
          _failure = UpdateFailure(ErrorCodes.updateInstallFailed, 'Something unexpected stopped the update: $e', e);
        });
      }
    } finally {
      _cancel = null;
    }
  }

  void _close() => Navigator.of(context).pop();

  /// The X, and Escape: a download stops; with nothing under way it closes.
  void _dismiss() {
    final busy = _stage == UpdateStage.checking ||
        _stage == UpdateStage.preparing ||
        _stage == UpdateStage.restarting ||
        _stage == UpdateStage.verifying;
    if (_stage == UpdateStage.downloading || _stage == UpdateStage.waitingForWindows) {
      _cancel?.cancel();
    } else if (!busy) {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = _info.critical
        ? l10n.updateBannerImportantUpdate(_info.version)
        : l10n.updateBannerVersionAvailable(_info.version);
    final current = ref.watch(appVersionProvider).valueOrNull;
    final page = (label: l10n.appUpdateDownloadPage, onPressed: () => openUpdateDownload(context, _info.downloadUrl));

    final ({String label, VoidCallback? onPressed, IconData? icon})? primary;
    final ({String label, VoidCallback? onPressed})? secondary;
    ({String label, VoidCallback? onPressed})? tertiary;
    switch (_stage) {
      case UpdateStage.offer:
        primary = (label: l10n.appUpdateNow, onPressed: () => _start(reopen: true), icon: LucideIcons.refreshCw);
        // Later, the quiet one on the left: both ways of updating side by
        // side, stacked where they do not fit.
        secondary = (label: l10n.appUpdateAndClose, onPressed: () => _start(reopen: false));
        tertiary = (label: l10n.appUpdateLater, onPressed: _close);
      case UpdateStage.blocked:
        primary = (label: l10n.appUpdateDownloadPage, onPressed: () => openUpdateDownload(context, _info.downloadUrl), icon: LucideIcons.externalLink);
        secondary = (label: l10n.appUpdateLater, onPressed: _close);
      case UpdateStage.downloading:
      case UpdateStage.waitingForWindows:
        primary = null;
        secondary = (label: l10n.cancel, onPressed: () => _cancel?.cancel());
      case UpdateStage.checking:
      case UpdateStage.verifying:
      case UpdateStage.preparing:
      case UpdateStage.restarting:
        primary = null;
        secondary = null;
      case UpdateStage.failed:
        primary = (label: l10n.retry, onPressed: () => _start(reopen: _reopen), icon: LucideIcons.refreshCw);
        secondary = (label: l10n.close, onPressed: _close);
        tertiary = page;
    }

    return ZestDialogShell(
      key: const ValueKey('update-dialog'),
      // What it means (3.4): red where it failed (Retry stays the accent),
      // neutral where it cannot be installed here or the update is an
      // important one (the title and the shield say so), else plain news.
      tone: switch (_stage) {
        UpdateStage.failed => ZestDialogTone.destructive,
        UpdateStage.blocked => ZestDialogTone.neutral,
        _ => _info.critical ? ZestDialogTone.neutral : ZestDialogTone.info,
      },
      icon: _info.critical ? LucideIcons.shield : LucideIcons.arrowUpCircle,
      title: title,
      subtitle: current == null ? null : l10n.appUpdateYouHave(current),
      maxWidth: 500,
      bodyKey: const ValueKey('update-dialog-body'),
      autofocusPrimary: true,
      primaryKey: const ValueKey('update-dialog-primary'),
      secondaryKey: const ValueKey('update-dialog-secondary'),
      tertiaryKey: const ValueKey('update-dialog-tertiary'),
      primaryBrand: true,
      onClose: _dismiss,
      body: _body(l10n),
      primaryAction: primary,
      secondaryAction: secondary,
      tertiaryAction: tertiary,
    );
  }

  Widget _body(AppLocalizations l10n) {
    final muted = TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, height: 1.5, color: AppColors.v3TextSecondary);
    final notes = _info.notes;
    final children = <Widget>[];
    if (notes != null && (_stage == UpdateStage.offer || _stage == UpdateStage.blocked)) {
      children
        ..add(Text(l10n.appUpdateWhatsNew,
            style: TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)))
        ..add(const SizedBox(height: 6))
        ..add(Text(notes,
            key: const ValueKey('update-dialog-notes'),
            style: TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, height: 1.55, color: AppColors.v3TextSecondary)))
        ..add(const SizedBox(height: 14));
    }
    switch (_stage) {
      case UpdateStage.offer:
        children.add(Text('${l10n.appUpdateHowItGoes} ${l10n.appUpdateHowClose}', style: muted));
      case UpdateStage.blocked:
        children.add(_blockedNote(l10n));
      case UpdateStage.downloading:
        String mb(int b) => formatDecimal(b / 1000000, l10n: l10n);
        children
          ..add(Text(l10n.appUpdateDownloading,
              style: TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, color: AppColors.v3TextPrimary)))
          ..add(const SizedBox(height: 10))
          ..add(ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const ValueKey('update-dialog-progress'),
              value: _total > 0 ? (_got / _total).clamp(0, 1).toDouble() : null,
              minHeight: 6,
              color: AppColors.v3AccentPrimary,
              backgroundColor: AppColors.v3BorderSubtle,
            ),
          ))
          ..add(const SizedBox(height: 8))
          ..add(Text(l10n.appUpdateProgress(mb(_got), mb(_total)), style: muted));
      case UpdateStage.checking:
      case UpdateStage.verifying:
      case UpdateStage.preparing:
      case UpdateStage.restarting:
      case UpdateStage.waitingForWindows:
        final label = switch (_stage) {
          UpdateStage.checking => l10n.updateCheckChecking,
          UpdateStage.verifying => l10n.appUpdateVerifying,
          UpdateStage.preparing => l10n.appUpdatePreparing,
          UpdateStage.waitingForWindows => l10n.appUpdateWaitingForWindows,
          _ => _reopen ? l10n.appUpdateRestarting : l10n.appUpdateClosing,
        };
        children.add(Row(children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3AccentInk)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                key: const ValueKey('update-dialog-step'),
                style: TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, color: AppColors.v3TextPrimary)),
          ),
        ]));
      case UpdateStage.failed:
        final f = _failure!;
        final what = ErrorCodes.withCode(
            f.notAllowed ? l10n.appUpdateErrNotAllowed : updateFailureWords(l10n, f.code), f.code);
        children
          ..add(Text(what,
              key: const ValueKey('update-dialog-error'),
              style: TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, height: 1.5, color: AppColors.v3TextPrimary)))
          ..add(const SizedBox(height: 6))
          ..add(Align(
            alignment: AlignmentDirectional.centerStart,
            child: CopyDetailsButton(
              key: const ValueKey('update-dialog-copy-details'),
              detail: ErrorReport.build(
                what: what,
                where: 'Update to ${_info.version}',
                error: f.cause,
                details: f.detail,
              ),
            ),
          ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _blockedNote(AppLocalizations l10n) {
    final b = _blocked!;
    if (b.reason == InstallBlock.noPackage) {
      return Text(l10n.appUpdateNoPackage,
          key: const ValueKey('update-dialog-blocked'),
          style: TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, height: 1.5, color: AppColors.v3TextPrimary));
    }
    final code = ErrorCodes.updateCannotInstallHere;
    final mac = b.reason == InstallBlock.diskImage || b.reason == InstallBlock.translocated;
    final what = ErrorCodes.withCode(
        mac ? '${l10n.appUpdateErrCannotHere} ${l10n.appUpdateMacMoveHint}' : l10n.appUpdateErrCannotHere, code);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(what,
            key: const ValueKey('update-dialog-blocked'),
            style: TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, height: 1.5, color: AppColors.v3TextPrimary)),
        const SizedBox(height: 6),
        CopyDetailsButton(
          detail: ErrorReport.build(
            what: what,
            where: 'Update to ${_info.version}',
            details: 'Why: ${b.reason.name}${b.place == null ? '' : '\nWhere: ${b.place}'}',
          ),
        ),
      ],
    );
  }
}

/// What the person is told for an update's failure [code], in their language.
String updateFailureWords(AppLocalizations l10n, ErrorCode code) {
  if (code == ErrorCodes.updateDownloadFailed) return l10n.appUpdateErrDownload;
  if (code == ErrorCodes.updateNotSigned) return l10n.appUpdateErrNotSigned;
  if (code == ErrorCodes.updateFileMismatch) return l10n.appUpdateErrMismatch;
  if (code == ErrorCodes.updateCannotInstallHere) return l10n.appUpdateErrCannotHere;
  return l10n.appUpdateErrInstall;
}

/// At the start after an update: that it went in, or that the app opened
/// again on the old version, with the installer's log behind Copy details
/// (ZS-1905).
void showLastUpdateResult(BuildContext context, LastUpdate last) {
  final l10n = AppLocalizations.of(context)!;
  switch (last) {
    case LastUpdateInstalled(:final version):
      showTopSnackBar(context, l10n.appUpdateInstalled(version), isSuccess: true);
    case LastUpdateNotInstalled(:final version, :final log):
      final code = ErrorCodes.updateInstallFailed;
      final what = ErrorCodes.withCode(l10n.appUpdateErrInstall, code);
      showZestModal<void>(
        context: context,
        size: ZestModalSize.standard,
        child: Builder(
          builder: (ctx) => ZestDialogShell(
          key: const ValueKey('update-not-installed'),
          // It failed: red, with the download page in the accent (3.4).
          tone: ZestDialogTone.destructive,
          title: l10n.appUpdateNotInstalledTitle,
          maxWidth: 500,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(what, style: TextStyle(fontFamily: 'GeistSans', fontSize: 13.5, height: 1.5, color: AppColors.v3TextPrimary)),
              const SizedBox(height: 6),
              CopyDetailsButton(
                detail: ErrorReport.build(
                  what: what,
                  where: 'Update to $version, after the restart',
                  details: 'The app opened again on the old version.'
                      '${log == null ? '\nThe installer left no log.' : '\nThe installer\'s log, its last lines:\n$log'}',
                ),
              ),
            ],
          ),
          primaryAction: (
            label: l10n.appUpdateDownloadPage,
            onPressed: () => openUpdateDownload(ctx, kUpdateDownloadFallback),
            icon: LucideIcons.externalLink,
          ),
          primaryBrand: true,
          secondaryAction: (label: l10n.close, onPressed: () => Navigator.of(ctx).pop()),
        ),
        ),
      );
  }
}
