import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_manager_requests.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_tool_setup.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

// The password manager questions a session asks (3.0), answered on
// screen: unlocking Bitwarden or KeePassXC, allowing a password to go to an
// address the first time, and typing a password this once when it could not
// be fetched (or on a phone, where the phone's password manager can fill
// it). Nothing typed here is kept.

/// The name a person knows the manager by.
String passwordManagerName(PasswordManagerKind kind) => switch (kind) {
      PasswordManagerKind.onePassword => '1Password',
      PasswordManagerKind.bitwarden => 'Bitwarden',
      PasswordManagerKind.keePassXc => 'KeePassXC',
    };

/// The tool's name, as installed.
String passwordManagerTool(PasswordManagerKind kind) => switch (kind) {
      PasswordManagerKind.onePassword => 'op',
      PasswordManagerKind.bitwarden => 'bw',
      PasswordManagerKind.keePassXc => 'keepassxc-cli',
    };

/// Why the password could not be fetched, and what to do.
String passwordManagerFailureText(AppLocalizations l10n, PasswordManagerKind kind, PmFailure failure) {
  final name = passwordManagerName(kind);
  final tool = passwordManagerTool(kind);
  return switch (failure) {
    PmFailure.notInstalled => l10n.pmFailNotInstalled(tool),
    PmFailure.notSignedIn => switch (kind) {
        PasswordManagerKind.onePassword => l10n.pmFailSignedOutOnePassword,
        PasswordManagerKind.bitwarden => l10n.pmFailSignedOutBitwarden,
        PasswordManagerKind.keePassXc => l10n.pmFailFailed(tool),
      },
    PmFailure.locked => l10n.pmFailLocked(name),
    PmFailure.wrongPassword => l10n.pmFailWrongPassword,
    PmFailure.notFound => l10n.pmFailNotFound(name),
    PmFailure.cancelled => l10n.pmFailCancelled(name),
    PmFailure.timedOut => l10n.pmFailTimedOut(name),
    PmFailure.noDatabase => l10n.pmFailNoDatabase,
    PmFailure.failed => l10n.pmFailFailed(tool),
  };
}

/// Answers the sessions' password manager questions on screen, in the
/// context [navigator] gives (the app's navigator). Call it from a build:
/// the app's root does.
void answerPasswordManagerRequests(WidgetRef ref, BuildContext? Function() navigator) {
  ref.listen<PasswordManagerRequest<Object?>?>(passwordManagerRequestProvider, (_, request) {
    if (request == null || !request.isOpen) return;
    unawaited(_answer(navigator(), request));
  });
}

Future<void> _answer(BuildContext? context, PasswordManagerRequest<Object?> request) async {
  try {
    if (context == null || !context.mounted) {
      _decline(request);
      return;
    }
    switch (request) {
      case PmUnlockRequest r:
        r.reply(await showPasswordManagerUnlock(context, r.kind, again: r.again));
      case PmApprovalRequest r:
        r.reply(await showPasswordManagerApproval(context, r.kind, r.item, r.destination) ?? false);
      case PmTypeOnceRequest r:
        r.reply(await showPasswordManagerTypeOnce(context, r.kind, r.destination,
            failure: r.failure, details: r.details));
    }
  } catch (e) {
    AppLogger.warning('Password managers: a question was not shown ($e)');
    _decline(request);
  }
}

void _decline(PasswordManagerRequest<Object?> request) => switch (request) {
      PmUnlockRequest r => r.reply(null),
      PmApprovalRequest r => r.reply(false),
      PmTypeOnceRequest r => r.reply(null),
    };

/// A password field the phone's password manager can fill; never saved to
/// it from here. It owns [controller]: emptied and disposed once the dialog
/// is gone (its closing animation still draws it).
class _SecretField extends StatefulWidget {
  const _SecretField({required this.controller, required this.label, this.onSubmitted, this.fieldKey});

  final TextEditingController controller;
  final String label;
  final VoidCallback? onSubmitted;
  final Key? fieldKey;

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  @override
  void dispose() {
    widget.controller
      ..clear()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: widget.fieldKey,
        controller: widget.controller,
        autofocus: true,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        autofillHints: const [AutofillHints.password],
        decoration: InputDecoration(labelText: widget.label, isDense: true, border: const OutlineInputBorder()),
        onSubmitted: widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
      );
}

/// Bitwarden's master password or KeePassXC's database password; null when
/// cancelled.
Future<String?> showPasswordManagerUnlock(BuildContext context, PasswordManagerKind kind, {required bool again}) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  final bitwarden = kind == PasswordManagerKind.bitwarden;
  void submit() {
    if (controller.text.isEmpty) return;
    Navigator.of(context, rootNavigator: true).pop(controller.text);
  }

  return ZestDialogShell.showModal<String>(
      context,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.info,
      icon: LucideIcons.lock,
      title: bitwarden ? l10n.pmUnlockBitwardenTitle : l10n.pmUnlockKeePassXcTitle,
      subtitle: bitwarden ? l10n.pmUnlockBitwardenBody : l10n.pmUnlockKeePassXcBody,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (again)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(l10n.pmUnlockWrong,
                  key: const ValueKey('pm-unlock-wrong'), style: TextStyle(fontSize: 12.5, color: AppColors.v3Error)),
            ),
          _SecretField(
            fieldKey: const ValueKey('pm-unlock-field'),
            controller: controller,
            label: bitwarden ? l10n.pmUnlockBitwardenField : l10n.pmUnlockKeePassXcField,
            onSubmitted: submit,
          ),
        ],
      ),
      primaryAction: (label: l10n.pmUnlock, onPressed: submit, icon: LucideIcons.unlock),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
      onSubmit: submit,
    );
}

/// Whether the password of [item] may go to [destination]; null or false
/// when not.
Future<bool?> showPasswordManagerApproval(
    BuildContext context, PasswordManagerKind kind, PasswordRefDescription item, String destination) {
  final l10n = AppLocalizations.of(context)!;
  final name = passwordManagerName(kind);
  Widget line(IconData icon, String text, {bool strong = false, Key? key}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: AppColors.v3TextSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  key: key,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
                      color: AppColors.v3TextPrimary)),
            ),
          ],
        ),
      );
  return ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.warning,
    icon: LucideIcons.keyRound,
    title: l10n.pmApproveTitle(name),
    subtitle: l10n.pmApproveLead,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Allow it only for what is expected: the sentences that warn.
        ZestCallout(l10n.pmApproveWarning),
        const SizedBox(height: 10),
        line(LucideIcons.fileKey, item.title, strong: true, key: const ValueKey('pm-approve-item')),
        if (item.where case final where?) line(LucideIcons.folder, where),
        if (item.username case final user?) line(LucideIcons.user, user),
        line(LucideIcons.arrowRight, l10n.pmApproveTo(Redactable.host(destination).display),
            key: const ValueKey('pm-approve-destination')),
      ],
    ),
    primaryAction: (
      label: l10n.pmApproveAllow,
      onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
      icon: LucideIcons.check
    ),
    secondaryAction: (label: l10n.pmApproveDeny, onPressed: () => Navigator.of(context, rootNavigator: true).pop(false)),
  );
}

/// The password typed this once (or filled by the phone's password
/// manager), after [failure] or on a device with no tools; null to stop.
Future<String?> showPasswordManagerTypeOnce(BuildContext context, PasswordManagerKind kind, String destination,
    {PmFailure? failure, String? details}) async {
  final l10n = AppLocalizations.of(context)!;
  final name = passwordManagerName(kind);
  final controller = TextEditingController();
  void submit() {
    if (controller.text.isEmpty) return;
    // The phone's password manager is not offered to save it.
    TextInput.finishAutofillContext(shouldSave: false);
    Navigator.of(context, rootNavigator: true).pop(controller.text);
  }

  return ZestDialogShell.showModal<String>(
      context,
      size: ZestModalSize.standard,
      // What went wrong, plainly: nothing amber.
      tone: failure == null ? ZestDialogTone.info : ZestDialogTone.neutral,
      icon: failure == null ? LucideIcons.keyRound : LucideIcons.alertTriangle,
      title: failure == null ? l10n.pmTypeTitle(name) : l10n.pmFailedTitle(name),
      subtitle: failure == null
          ? l10n.pmTypePhoneBody(name)
          : failure == PmFailure.notInstalled
              ? l10n.pmSetupTypeOnceMissing(passwordManagerTool(kind))
              : passwordManagerFailureText(l10n, kind, failure),
      body: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The tool is not there: set up here for the next time (it
            // pointed to Settings).
            if (failure == PmFailure.notInstalled) ...[
              PasswordManagerToolSetup(key: const ValueKey('pm-setup-in-type-once'), kind: kind),
              const SizedBox(height: 12),
            ],
            if (details != null) ...[
              PasswordManagerDetails(details: details),
              const SizedBox(height: 12),
            ],
            Text(l10n.pmTypeFor(Redactable.host(destination).display),
                key: const ValueKey('pm-type-destination'),
                style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
            const SizedBox(height: 8),
            _SecretField(
              fieldKey: const ValueKey('pm-type-field'),
              controller: controller,
              label: failure == null ? l10n.pmTypeField : l10n.pmTypeOnceField,
              onSubmitted: submit,
            ),
            const SizedBox(height: 6),
            Text(l10n.pmTypeNotKept, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
          ],
        ),
      ),
      primaryAction: (label: l10n.pmConnect, onPressed: submit, icon: LucideIcons.plug),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
      onSubmit: submit,
    );
}

/// What the tool said, readable and copied in one tap (for asking Astryx or
/// anyone else what it means).
class PasswordManagerDetails extends StatelessWidget {
  const PasswordManagerDetails({super.key, required this.details});

  final String details;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('pm-details'),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.v3BorderSubtle.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.pmDetails,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.v3TextSecondary)),
              ),
              TextButton.icon(
                key: const ValueKey('pm-details-copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: details));
                  if (context.mounted) showTopSnackBar(context, l10n.pmDetailsCopied, isSuccess: true);
                },
                icon: const Icon(LucideIcons.copy, size: 13),
                label: Text(l10n.copy),
              ),
            ],
          ),
          SelectableText(details, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.4)),
        ],
      ),
    );
  }
}
