import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/passkey_step_up.dart';
import 'package:zestssh/services/account/two_step.dart' show PasskeyStepFailure;
import 'package:zestssh/services/account/two_step_api.dart' show TwoStepRefusal;
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/sign_in_again.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart' show errorKind;
import 'package:zestssh/utils/logger.dart';

/// What a change that needs a recent sign-in will do, said before the person
/// signs in again (3.0): one line, then what follows from it.
typedef StepUpSummary = ({String what, List<String> effects});

/// Signs the person in again so this device's sign-in is recent
/// ([refreshSignIn]): true when it is. A test's own stands in for the
/// browser and the password prompt.
typedef SignInRefresher = Future<bool> Function(BuildContext context, WidgetRef ref, {String? wrongAccount});

final signInRefresherProvider = Provider<SignInRefresher>(
    (ref) => (context, ref, {wrongAccount}) => refreshSignIn(context, ref, wrongAccount: wrongAccount));

/// Which recent sign-in a change needs (ZestSSH Cloud's recent_sign_in.js):
/// a team change one from the last two hours, an account change one from
/// the last ten minutes.
enum StepUpWindow { team, account }

/// Runs [change], a change to who is in an Orchard or what they may do.
/// When the server wants a recent sign-in first (3.0,
/// with the second factor when the account has one), the
/// person is told what the change will do ([summary]) and asked to sign in
/// again, and it runs once more. False when it did not run: they backed out,
/// or picked another account (they were told). Anything else [change]
/// throws goes to the caller. [window] says how long that sign-in counts
/// for: a team's two hours, or the account's ten minutes (deleting a team).
///
Future<bool> withRecentSignIn(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() change, {
  StepUpSummary? summary,
  StepUpWindow window = StepUpWindow.team,
}) async {
  try {
    await change();
    return true;
  } on OrchardServerException catch (e) {
    if (!e.recentSignInRequired) rethrow;
  }
  if (!context.mounted) return false;
  final l10n = AppLocalizations.of(context)!;
  final shown = await confirmOrSignIn(context, ref,
      summary: summary, window: window, wrongAccount: l10n.orchardSignInWrongAccount);
  if (shown != ItsYou.confirmed || !context.mounted) return false;
  await change();
  return true;
}

/// What "Confirm it's you" came to.
enum ItsYou {
  /// The person backed out.
  cancelled,

  /// They went on, and signing in did not happen: they were told.
  failed,

  /// This device counts as having just shown it is them.
  confirmed,
}

/// Shows it is the person, for a change that asks for a recent sign-in: with a
/// passkey where the account has one and this device can use it (security review
/// R3: one tap, with "Sign in another way" under it), else by signing in again
/// ([signInRefresherProvider]), after "Confirm it's you" says why. [askFirst]
/// false: where the person has just asked for it themselves, with no passkey to
/// offer, it goes straight to the sign-in. [signInOnly]: only a sign-in will do
/// (a team's Sign-in lasts where it requires company sign-in). After a sign-in
/// with no passkey to use, an account that could have one is told once
/// what it would save them.
Future<ItsYou> confirmOrSignIn(
  BuildContext context,
  WidgetRef ref, {
  StepUpSummary? summary,
  StepUpWindow window = StepUpWindow.team,
  String? about,
  String? wrongAccount,
  bool signInOnly = false,
  bool askFirst = true,
  bool sayWindow = true,
}) async {
  final stepUp = signInOnly ? null : ref.read(passkeyStepUpProvider);
  final tap = stepUp != null && await stepUp.available() ? stepUp : null;
  if (!context.mounted) return ItsYou.cancelled;
  if (tap != null) {
    final choice = await showZestModal<_Choice>(
      context: context,
      size: ZestModalSize.compact,
      child: _WithPasskeyDialog(stepUp: tap, summary: summary, window: window, about: about, sayWindow: sayWindow),
    );
    if (choice == _Choice.confirmed) return ItsYou.confirmed;
    if (choice != _Choice.signIn) return ItsYou.cancelled;
  } else if (askFirst && !await confirmItsYou(context, summary, window: window, about: about)) {
    return ItsYou.cancelled;
  }
  if (!context.mounted) return ItsYou.cancelled;
  final signIn = ref.read(signInRefresherProvider);
  if (!await signIn(context, ref, wrongAccount: wrongAccount)) return ItsYou.failed;
  if (tap == null && stepUp != null) unawaited(_offerPasskeyOnce(ref, stepUp));
  return ItsYou.confirmed;
}

/// After a sign-in that "Confirm it's you" asked for, on an account with no
/// passkey: a notice, once ever on this device, that one makes it a tap. Not a
/// question: whatever the sign-in was for goes on, and a first passkey has its
/// own words on the account page (it turns two-step sign-in on).
Future<void> _offerPasskeyOnce(WidgetRef ref, PasskeyStepUp stepUp) async {
  try {
    final settings = ref.read(settingsServiceProvider);
    if (settings.passkeyOffered) return;
    if (await ref.read(passkeyWayProvider.future) == PasskeyWay.none) return;
    if (!await stepUp.worthOffering()) return;
    await settings.setPasskeyOffered();
    final l10n = gl10n;
    ref.read(notificationCenterProvider.notifier).show(AppNotification(
          id: 'passkey-offer',
          title: l10n.stepUpOfferTitle,
          body: l10n.stepUpOfferBody,
          severity: NotificationSeverity.info,
          actionLabel: l10n.passkeyAdd,
          onAction: () => ref.read(addPasskeyRequestProvider.notifier).state++,
          // Long enough to read and act on: it is not asked again.
          dismissAfter: const Duration(seconds: 15),
        ));
  } catch (e) {
    // (The widget that asked may have gone: nothing depends on this.)
    AppLogger.info('The offer of a passkey was not made ($e)');
  }
}

enum _Choice { confirmed, signIn }

/// "Confirm it's you" where a passkey can do it. It stays open through a passkey
/// that did not work, saying why, with the sign-in one press away.
class _WithPasskeyDialog extends StatefulWidget {
  const _WithPasskeyDialog({
    required this.stepUp,
    required this.summary,
    required this.window,
    required this.about,
    required this.sayWindow,
  });

  final PasskeyStepUp stepUp;
  final StepUpSummary? summary;
  final StepUpWindow window;
  final String? about;
  final bool sayWindow;

  @override
  State<_WithPasskeyDialog> createState() => _WithPasskeyDialogState();
}

class _WithPasskeyDialogState extends State<_WithPasskeyDialog> {
  var _busy = false;
  TwoStepProblem? _said;
  Object? _cause;

  /// What ZestSSH Cloud answers where this device cannot confirm this way:
  /// signing in is what is left, with nothing to try again.
  static const _noWayHere = {'step-up-unavailable', 'no-passkeys', 'passkeys-unavailable'};

  Future<void> _tap() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _said = null;
      _cause = null;
    });
    try {
      await widget.stepUp.confirm();
      if (mounted) Navigator.of(context).pop(_Choice.confirmed);
    } catch (e) {
      AppLogger.info('Confirming with a passkey did not go through (${e is TwoStepRefusal ? e.shownCode : errorKind(e)})');
      if (!mounted) return;
      if (e is TwoStepRefusal && _noWayHere.contains(e.code)) {
        Navigator.of(context).pop(_Choice.signIn);
        return;
      }
      final failure = PasskeyStepFailure.of(e);
      setState(() {
        _busy = false;
        _said = failure == null ? TwoStepProblem(l10n.passkeyErrorUnknown) : passkeyStepProblem(l10n, failure);
        _cause = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final said = _said;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.info,
      icon: LucideIcons.shieldCheck,
      title: l10n.stepUpTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _ConfirmItsYou(
            summary: widget.summary,
            window: widget.window,
            about: widget.about,
            withPasskey: true,
            sayWindow: widget.sayWindow,
          ),
          if (said != null) ...[
            const SizedBox(height: 10),
            Text(
              said.code.isEmpty ? said.text : '${said.text} (${said.code})',
              key: const ValueKey('step-up-passkey-problem'),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: said.quiet ? ZestColors.textSecondary : ZestColors.statusError,
              ),
            ),
            if (!said.quiet && _cause != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: CopyDetailsButton(detail: '$_cause'),
              ),
          ],
          const SizedBox(height: 6),
          // Under what it says, not among the buttons: three do not fit in
          // every language.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('step-up-another-way'),
              onPressed: _busy ? null : () => Navigator.of(context).pop(_Choice.signIn),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 4),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l10n.stepUpSignInAnotherWay, style: const TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
      primaryKey: const ValueKey('step-up-use-passkey'),
      primaryAction: (
        label: l10n.twoStepUsePasskey,
        onPressed: _busy ? null : _tap,
        icon: LucideIcons.fingerprint,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _busy ? null : () => Navigator.of(context).pop()),
    );
  }
}

/// "Confirm it's you", the one dialog for every change that needs a recent
/// sign-in (found in a security review): what is about to happen,
/// one button to sign in again, and how long that sign-in counts for, by
/// [window]. True when the person chose to. Without a [summary], [about]
/// says what needs it.
Future<bool> confirmItsYou(BuildContext context, StepUpSummary? summary,
    {StepUpWindow window = StepUpWindow.team, String? about}) async {
  final l10n = AppLocalizations.of(context)!;
  final go = await ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.info,
    icon: LucideIcons.shieldCheck,
    title: l10n.stepUpTitle,
    body: _ConfirmItsYou(summary: summary, window: window, about: about),
    primaryAction: (
      label: l10n.devicesSignInAgainTitle,
      onPressed: () => Navigator.of(context).pop(true),
      icon: LucideIcons.logIn,
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
  );
  return go == true;
}

class _ConfirmItsYou extends StatelessWidget {
  const _ConfirmItsYou({
    required this.summary,
    required this.window,
    this.about,
    this.withPasskey = false,
    this.sayWindow = true,
  });

  final StepUpSummary? summary;
  final StepUpWindow window;
  final String? about;

  /// The button is a passkey's: the last line says so, not to sign in.
  final bool withPasskey;

  /// False where the two hours or ten minutes are not what this is about (a
  /// team's Sign-in lasts).
  final bool sayWindow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final team = window == StepUpWindow.team;
    final summary = this.summary;
    final passkeyLine = team ? l10n.stepUpPasskeyBody : l10n.stepUpPasskeyBodyAccount;
    if (summary == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(about ?? l10n.orchardSignInAgainBody,
              style: TextStyle(fontSize: 13, height: 1.45, color: ZestColors.textSecondary)),
          if (sayWindow) ...[
            const SizedBox(height: 8),
            Text(withPasskey ? passkeyLine : (team ? l10n.stepUpWindowTeam : l10n.stepUpWindowAccount),
                key: const ValueKey('step-up-window'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary)),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(team ? l10n.stepUpWhy : l10n.stepUpWhyAccount,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestColors.textSecondary)),
        const SizedBox(height: 12),
        Container(
          key: const ValueKey('step-up-summary'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          // One step lighter than the window it is in, with a hairline.
          decoration: BoxDecoration(
            color: ZestColors.surfaceChip,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ZestColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary.what,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestColors.textPrimary)),
              for (final e in summary.effects)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: 8),
                        child: Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(color: ZestColors.textTertiary, shape: BoxShape.circle),
                        ),
                      ),
                      Expanded(
                        child: Text(e,
                            style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestColors.textSecondary)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(withPasskey ? passkeyLine : (team ? l10n.stepUpBody : l10n.stepUpBodyAccount),
            key: const ValueKey('step-up-window'),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary)),
      ],
    );
  }
}
