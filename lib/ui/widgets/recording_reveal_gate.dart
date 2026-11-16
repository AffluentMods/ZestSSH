import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The reveal gate (recording-mode spec, section 5).
///
/// Call before any action that puts a REAL identifier or secret on screen or
/// on the clipboard while recording mode is on: revealing a password,
/// revealing or copying a key or fingerprint, copying a host address,
/// exporting or backing up, copying an SFTP path, revealing an API key.
///
/// Returns true when the action may proceed: immediately when recording mode
/// is off, or after the user chose "Turn off recording mode", which ALSO turns
/// the mode off, so there is never a state where a real value is visible while
/// the user believes they are protected. Cancel is the default and returns
/// false. Deliberately no "do not ask again".
///
/// [ref] is optional: a plain StatefulWidget (the password prompt, ZestField)
/// can call this with only its context; the providers are reached through
/// the enclosing [ProviderScope].
Future<bool> confirmRevealWhileRecording(BuildContext context,
    [WidgetRef? ref]) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (!container.read(recordingModeProvider)) return true;
  final l10n = AppLocalizations.of(context)!;
  // The app's dialog (the dialog rules, 3.4): red for what it means (a
  // secret would show on a recorded screen). Cancel is the main button,
  // focused, in the brand's colour; the unsafe path is the red outlined one
  // beside it, a deliberate second click. Closed without an answer is
  // Cancel. Asked from a dialog (a password's eye in a prompt), it shows in
  // that dialog's place, which comes back as it was (rule 4: no dialog over
  // a dialog).
  final turnOff = await showZestInPlace<bool>(
    context: context,
    size: ZestModalSize.compact,
    builder: (ctx) => ZestDialogShell(
      key: const ValueKey('recording-reveal-gate'),
      size: ZestModalSize.compact,
      tone: ZestDialogTone.destructive,
      icon: LucideIcons.video,
      title: l10n.recModeRevealTitle,
      body: Text(
        l10n.recModeRevealBody,
        style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
      ),
      secondaryKey: const ValueKey('recording-reveal-turn-off'),
      secondaryDanger: true,
      secondaryAction: (label: l10n.recModeRevealDisable, onPressed: () => zestDialogPop(ctx, true)),
      primaryKey: const ValueKey('recording-reveal-cancel'),
      primaryBrand: true,
      autofocusPrimary: true,
      primaryAction: (label: l10n.recModeRevealCancel, icon: null, onPressed: () => zestDialogPop(ctx, false)),
    ),
  );
  if (turnOff != true) return false;
  await container.read(settingsUpdaterProvider).setRecordingMode(false);
  return true;
}
