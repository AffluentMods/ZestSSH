import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/join_readiness.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show trackingOnNames;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show crateLevelName;
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart' show inviteErrorMessage;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/connection/qr_scan_screen.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';
import 'package:zestssh/providers/settings_providers.dart' show recordingModeProvider;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

// Joining a team with an invite code: the
// person types or pastes the code (or its link), or scans its QR code on a
// phone. Their device asks ZestSSH Cloud for the offer by the lookup id it
// derives from the code, never the code, and checks it against the code
// (crypto/join_code_crypto.dart): only an offer that checks out is shown,
// with the team's name, who made the code and the role, and only then can
// they join. Joining needs their team keys on this device first
// (readyToJoin, team/join_readiness.dart), binds the code to their account
// and uses it up; whoever made it still lets them in before anything is
// shared with this device. A link (zestssh://join#CODE, zestssh://join?code=
// or https://zestssh.com/join#CODE) only opens this with the code typed in:
// nothing is asked of anyone until the person continues.
//
// Someone not signed in (it said "Sign in to use
// teams." with nothing to press before) signs in or creates an account here, in the
// same dialog, the code kept; once signed in it goes on to the team by itself.

/// "Join a team": with [code] typed in where a link or a scan brought one
/// ([fromLink] says so, and that nothing happens until they continue).
Future<void> showJoinTeam(BuildContext context, {String? code, bool fromLink = false}) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: JoinTeamDialog(initialCode: code, fromLink: fromLink),
  );
}

/// A link to join a team ([uri]): opens "Join a team" with its code typed in,
/// and nothing more. True when [uri] was such a link (answered or not).
bool answerJoinLink(Uri uri, BuildContext? context) {
  if (uri.scheme != 'zestssh' || (uri.host + uri.path) != 'join') return false;
  if (!kOrchardsEnabled || context == null || !context.mounted) return true;
  final code = joinCodeFromText(uri.toString());
  // Not the link itself: it carries the code.
  AppLogger.info('Deep link → join a team');
  unawaited(showJoinTeam(context, code: code, fromLink: true));
  return true;
}

class JoinTeamDialog extends ConsumerStatefulWidget {
  const JoinTeamDialog({super.key, this.initialCode, this.fromLink = false});

  final String? initialCode;
  final bool fromLink;

  @override
  ConsumerState<JoinTeamDialog> createState() => _JoinTeamDialogState();
}

class _JoinTeamDialogState extends ConsumerState<JoinTeamDialog> {
  late final _code = TextEditingController(
      text: widget.initialCode == null ? '' : writtenJoinCode(widget.initialCode!));
  String? _error;
  bool _busy = false;
  InviteCodePreview? _preview;

  /// Joined: waiting for its maker to let them in.
  bool _joined = false;

  /// A sign-in from this dialog is running (in the browser on a computer).
  bool _signingIn = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String _errorWords(Object e, AppLocalizations l10n) {
    if (e is InviteCodeError) {
      return switch (e.problem) {
        InviteCodeProblem.notACode => l10n.joinNotACode,
        InviteCodeProblem.checkFailed => l10n.joinCodeCheckFailed,
      };
    }
    if (e is OrchardServerException) {
      switch (e.code) {
        case 'join-code-invalid':
          return l10n.joinCodeNotValid;
        case 'guest-owners-only':
          return l10n.joinCodeGuestOwnersOnly;
        case 'guest-needs-end':
          return l10n.joinCodeGuestNeedsEnd;
        // Too many codes tried that found none: the joiner's own words,
        // where it said the inviter's "a lot of invitations" (found in the 3.0 docs
        // check).
        case 'rate-limited':
          return ErrorCodes.withCode(l10n.joinCodeTooManyTries, ErrorCodes.joinCodeTooManyTries);
      }
      if (e.status == 429) return ErrorCodes.withCode(l10n.joinCodeTooManyTries, ErrorCodes.joinCodeTooManyTries);
    }
    return inviteErrorMessage(e, l10n);
  }

  Future<void> _look() async {
    final l10n = AppLocalizations.of(context)!;
    if (joinCodeFromText(_code.text) == null) {
      setState(() => _error = l10n.joinNotACode);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await ref.read(orchardServiceProvider).previewInviteCode(_code.text);
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      AppLogger.warning('Orchards: an invite code was not shown (${errorKind(e)})');
      if (mounted) setState(() => _error = _errorWords(e, l10n));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    final preview = _preview;
    if (preview == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The team keys first: made here where that is all it takes, or what
      // stands in the way said with the way out.
      if (!await readyToJoin(context, ref) || !mounted) return;
      await ref.read(orchardServiceProvider).acceptInviteCode(preview);
      // The line opens, so the team arrives the moment they are let in.
      unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
      if (mounted) setState(() => _joined = true);
    } catch (e) {
      AppLogger.warning('Orchards: an invite code was not used (${errorKind(e)})');
      if (mounted) setState(() => _error = _errorWords(e, l10n));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Signs in from here: with [way] on a device that signs in itself, in the
  /// browser on a computer without Firebase (no [way]); [create] starts at
  /// Create an account. Signed in with a code typed in, it goes on to the
  /// team by itself.
  Future<void> _signIn({SignInWay? way, bool create = false}) async {
    if (_signingIn) return;
    setState(() {
      _signingIn = true;
      _error = null;
    });
    final bool signedIn;
    if (!signsInOnDevice) {
      signedIn = await signInInBrowser(context, ref, createAccount: create);
    } else {
      signedIn = await signInWith(context, ref, way ?? SignInWay.email, createAccount: create);
    }
    if (!mounted) return;
    setState(() => _signingIn = false);
    if (signedIn && joinCodeFromText(_code.text) != null) await _look();
  }

  Future<void> _scan() async {
    final l10n = AppLocalizations.of(context)!;
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => QrScanScreen(
        readCode: joinCodeFromText,
        title: l10n.joinScanTitle,
        hint: l10n.joinScanHint,
        notCode: l10n.joinScanNotCode,
      ),
    ));
    if (code == null || !mounted) return;
    _code.text = writtenJoinCode(code);
    await _look();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final preview = _preview;
    if (_joined && preview != null) return _joinedView(l10n, preview);
    if (preview != null) return _previewView(l10n, preview);
    if (ref.watch(currentUserProvider) == null) return _signInView(l10n);
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.users,
      title: l10n.joinTeamTitle,
      subtitle: l10n.joinTeamSubtitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.fromLink) ...[
            Text(l10n.joinFromLink,
                key: const ValueKey('join-from-link'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
            const SizedBox(height: 12),
          ],
          // A code is a secret until used: masked while recording.
          ZestTextField(
            key: const ValueKey('join-code-field'),
            controller: _code,
            label: l10n.inviteCodeLabel,
            hintText: 'ZEST-XXXX-XXXX-XXXX-XXXX-XXXX',
            helperText: l10n.joinCodeHelp,
            errorText: _error,
            obscureText: ref.watch(recordingModeProvider),
            onSubmit: _busy ? null : _look,
          ),
          if (QrScanScreen.isSupported) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('join-scan'),
                onPressed: _busy ? null : _scan,
                icon: const Icon(LucideIcons.scanLine, size: 16),
                label: Text(l10n.joinScan),
              ),
            ),
          ],
        ],
      ),
      primaryKey: const ValueKey('join-continue'),
      primaryAction: (label: l10n.joinContinue, onPressed: _busy ? null : _look, icon: LucideIcons.arrowRight),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }

  /// The code field, as the first view has it.
  Widget _codeField(AppLocalizations l10n) => ZestTextField(
        key: const ValueKey('join-code-field'),
        controller: _code,
        label: l10n.inviteCodeLabel,
        hintText: 'ZEST-XXXX-XXXX-XXXX-XXXX-XXXX',
        helperText: l10n.joinCodeHelp,
        errorText: _error,
        obscureText: ref.watch(recordingModeProvider),
      );

  /// Not signed in: the code (kept, and still to be typed or pasted where
  /// none came), and the sign-in, here. A device that signs in itself has its
  /// ways as buttons; a computer signs in in the browser, which comes back.
  Widget _signInView(AppLocalizations l10n) {
    final secondary = TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary);
    final busy = _signingIn || _busy;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.users,
      title: l10n.joinTeamTitle,
      subtitle: l10n.joinNeedsAccount,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _codeField(l10n),
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('join-code-kept'),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceSunken,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(LucideIcons.check, size: 16, color: ZestTokens.brand),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(l10n.joinCodeKept, style: secondary)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (signsInOnDevice)
            SignInWayButtons(onPick: busy ? null : (way) => _signIn(way: way))
          else if (_signingIn)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                key: const ValueKey('join-browser-waiting'),
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.brand),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.signInBrowserWaiting, style: secondary)),
                ],
              ),
              ],
            ),
        ],
      ),
      // A computer: Sign in opens the browser. A device with its own ways has
      // them above; Create an account is the email one, at its start.
      primaryKey: const ValueKey('join-sign-in'),
      primaryAction: signsInOnDevice
          ? null
          : (label: l10n.profileSignIn, onPressed: busy ? null : () => _signIn(), icon: LucideIcons.logIn),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      tertiaryKey: const ValueKey('join-create-account'),
      tertiaryAction: (label: l10n.welcomeCreateAccount, onPressed: busy ? null : () => _signIn(create: true)),
    );
  }

  Widget _previewView(AppLocalizations l10n, InviteCodePreview preview) {
    final invite = preview.offer.invite;
    final team = preview.shown.team.trim().isEmpty ? l10n.orchardUnnamed : preview.shown.team.trim();
    final maker = invite.invitedBy ?? l10n.myInvitationFromSomeone;
    final vaults = [
      for (final v in preview.shown.vaults)
        l10n.inviteSummaryVault(v.name, _levelWords(v.level, l10n)),
    ];
    final email = ref.watch(currentUserProvider)?.email;
    final secondary = TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary);
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.users,
      title: l10n.joinTeamTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: ZestTokens.brandSubtle,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ZestTokens.brandBorder),
              ),
              child: Icon(LucideIcons.users, size: 24, color: ZestTokens.brand),
            ),
          ),
          const SizedBox(height: 10),
          RedactedText(
            Redactable.workspace(team),
            key: const ValueKey('join-team-name'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            l10n.joinInvitedBy(Redactable.account(maker).displayIn(ref)),
            textAlign: TextAlign.center,
            style: secondary,
          ),
          const SizedBox(height: 14),
          _Rows(rows: [
            (l10n.joinYouJoinAs, preview.shown.role.trim().isEmpty ? l10n.orchardRoleMember : preview.shown.role.trim()),
            (l10n.joinYouGet, vaults.isEmpty ? l10n.joinYouGetNothing : vaults.join(l10n.listSeparator)),
            if (invite.endsAt case final ends?)
              (l10n.inviteAccessEnds, DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
                  .format(secondsAsDate(ends))),
            if (email != null) (l10n.joinYourAccount, Redactable.account(email).displayIn(ref)),
          ]),
          const SizedBox(height: 12),
          _CheckedLine(text: l10n.joinChecked(team)),
          if (!invite.tracking.isNone) ...[
            const SizedBox(height: 10),
            Text(l10n.myInvitationRecords(trackingOnNames(invite.tracking, l10n).join(l10n.listSeparator)),
                style: secondary),
          ],
          if (invite.rulesUnmet.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(l10n.myInvitationRulesUnmet(orchardRuleNames(invite.rulesUnmet, l10n)),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusWarning)),
          ],
          const SizedBox(height: 12),
          Text(
            isMobilePlatform
                ? l10n.joinLetsYouInPhone(Redactable.account(maker).displayIn(ref))
                : l10n.joinLetsYouInComputer(Redactable.account(maker).displayIn(ref)),
            style: secondary,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                key: const ValueKey('join-error'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusCritical)),
          ],
        ],
      ),
      primaryKey: const ValueKey('join-accept'),
      primaryAction: (label: l10n.joinAction(team), onPressed: _busy ? null : _join, icon: LucideIcons.check),
      secondaryKey: const ValueKey('join-not-now'),
      secondaryAction: (label: l10n.joinNotNow, onPressed: _busy ? null : () => Navigator.of(context).pop()),
    );
  }

  Widget _joinedView(AppLocalizations l10n, InviteCodePreview preview) {
    final maker = preview.offer.invite.invitedBy ?? l10n.myInvitationFromSomeone;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.hourglass,
      title: l10n.joinedTitle,
      body: Text(
        l10n.joinedBody(Redactable.account(maker).displayIn(ref)),
        key: const ValueKey('join-joined'),
        style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary),
      ),
      primaryAction: (label: l10n.done, onPressed: () => Navigator.of(context).pop(), icon: null),
    );
  }
}

String _levelWords(String level, AppLocalizations l10n) {
  final known = CrateLevel.values.where((l) => l.name == level).firstOrNull;
  return known == null ? l10n.crateLevelNone : crateLevelName(known, l10n);
}

/// Label and value rows in one bordered block.
class _Rows extends StatelessWidget {
  const _Rows({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rows[i].$1, style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(rows[i].$2,
                        textAlign: TextAlign.end,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The green line that says the code checked out.
class _CheckedLine extends StatelessWidget {
  const _CheckedLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final green = ZestTokens.statusHealthy;
    return Container(
      key: const ValueKey('join-checked'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: green.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(LucideIcons.shieldCheck, size: 16, color: green)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: green))),
        ],
      ),
    );
  }
}

