import 'dart:async';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/join_readiness.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show trackingOnNames;
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/features/orchards/widgets/invite_people_dialog.dart';
import 'package:zestssh/features/orchards/widgets/join_review.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/time_text.dart';

// Invitations (3.0). A member whose role lets them invite offers an
// address a role below their own, and Crates on top of it; the person accepts
// in their own ZestSSH; someone who may make that offer compares
// fingerprints with them and only then adds them (a member.add entry in the
// Orchard's record), which hands them the keys, sealed to the keys that were
// compared.

String crateLevelLabel(CrateLevel level, AppLocalizations l10n) => crateLevelName(level, l10n);

/// The Crates an offer of [role] with [grants] opens: the role's own, and
/// the extra ones (owners every one; admins every one that is not
/// owners-only, or what the Admin role opens once an owner changed it).
int offeredCrateCount(String role, Map<String, Set<String>> grants, OrchardSummary orchard,
    List<OrchardRoleView> roles) {
  if (role == FixedRoles.owner) return orchard.crates.length;
  if (role == FixedRoles.admin) return orchard.crates.where((c) => orchard.adminSwitchesIn(c).isNotEmpty).length;
  final own = roles.where((r) => r.id == role).firstOrNull?.crates.keys ?? const <String>[];
  return {...own, ...grants.keys}.length;
}

/// What went wrong with an invitation, in words a person can act on.
String inviteErrorMessage(Object error, AppLocalizations l10n) {
  if (error is OrchardInviteError) {
    return switch (error.problem) {
      OrchardInviteProblem.missingKeys => l10n.orchardInviteMissingKeys,
      OrchardInviteProblem.badKeys => l10n.orchardInviteKeysChanged,
      OrchardInviteProblem.notAccepted => l10n.orchardInviteStatusSent,
      OrchardInviteProblem.offerChanged => l10n.orchardInviteOfferChanged,
      OrchardInviteProblem.inviteOfferChanged => l10n.orchardInviteOfferChangedAddress,
    };
  }
  if (error is OrchardServerException) {
    switch (error.code) {
      case 'already-member':
        return l10n.orchardInviteErrorAlreadyMember;
      // Guests: someone outside the Orchard's proven domains.
      case 'guest-owners-only':
        return l10n.orchardGuestOwnersOnly;
      case 'guest-needs-end':
        return l10n.orchardGuestNeedsEnd;
      case 'rate-limited':
        return l10n.orchardInviteErrorRateLimited;
      case 'forbidden':
        return l10n.orchardInviteErrorForbidden;
      case 'invalid-request':
        return l10n.orchardInviteErrorInvalid;
      case 'recipient-keys-changed':
      case 'bad-signature':
        return l10n.orchardInviteKeysChanged;
      case 'expired':
        return l10n.orchardInviteErrorLapsed;
      // The Orchard's rules: an address outside its domains, someone
      // who accepted without meeting them, or this account accepting.
      case 'invitee-rules-unmet':
        return l10n.orchardInviteeRulesUnmet(orchardRuleNames(error.unmet ?? const [], l10n));
      case 'rules-unmet':
        return l10n.myInvitationRulesUnmet(orchardRuleNames(error.unmet ?? const [], l10n));
    }
    if (error.status == 429) return l10n.orchardInviteErrorRateLimited;
  }
  // Compare and add changes the team's record: what it refuses is said as
  // every other change to a team says it (it was "something failed on this
  // device").
  return orchardChangeErrorMessage(error, l10n);
}

/// How many more seats an invitation the server refused for seats needs,
/// or null when it was refused for something else. Where the server
/// does not say, one for this person beyond the seats taken.
int? inviteSeatsNeededOf(Object error) {
  if (error is! OrchardServerException || error.code != 'seats-full') return null;
  final needed = error.seatsNeeded;
  if (needed != null && needed > 0) return needed;
  final seats = error.seats, used = error.seatsUsed;
  return seats != null && used != null ? max(1, used + 1 - seats) : 1;
}

// ── Inviting ────────────────────────────────────────────────────────────

/// "Invite to" a team: by email or with a one-time code (invite_people_dialog
/// .dart). Returns once something was sent or made (or the dialog is
/// closed).
Future<bool> showInviteDialog(BuildContext context, WidgetRef ref, OrchardSummary orchard,
        {InviteWay way = InviteWay.email}) =>
    showInvitePeople(context, ref, orchard, way: way);

// ── The Orchard's invitations (those who may invite) ────────────────────

/// Bumped when someone is invited from outside the invitations list (the
/// Team page's header), so the list reads them again.
final orchardInvitesVersionProvider = StateProvider<int>((_) => 0);

/// The invitations of an Orchard, on its Members screen: who is invited,
/// who accepted and waits to be compared and added, and "Invite someone".
/// On a computer's Members page ([pageLayout]) the two lists are sections of
/// the page, filtered by [filter], and a row of "Waiting for you" opens its
/// review beside the list ([onOpenReview]).
class OrchardInvitesSection extends ConsumerStatefulWidget {
  const OrchardInvitesSection({
    super.key,
    required this.orchard,
    required this.onMembersChanged,
    this.showInviteButton = true,
    this.pageLayout = false,
    this.filter = '',
    this.onOpenReview,
    this.reviewing,
  });

  final OrchardSummary orchard;

  /// False where the page around it has its own Invite button.
  final bool showInviteButton;

  /// Someone was added: the member list reads again.
  final VoidCallback onMembersChanged;

  /// The Members page's layout on a computer.
  final bool pageLayout;

  /// What the Members page's filter field holds: only the invitations whose
  /// address or role has it are listed.
  final String filter;

  /// Opens the review of someone waiting beside the list (page layout).
  final void Function(InviteView view)? onOpenReview;

  /// The invitation whose review is open beside the list.
  final String? reviewing;

  @override
  ConsumerState<OrchardInvitesSection> createState() => _OrchardInvitesSectionState();
}

/// [invites] in the order the Members screen lists them: those to let in
/// first, then the rest by address, lapsed ones last.
List<InviteView> sortedInvites(List<InviteView> invites) {
  int rank(OrchardInvite i) => i.expired ? 2 : (i.accepted ? 0 : 1);
  return [...invites]..sort((a, b) {
      final r = rank(a.invite).compareTo(rank(b.invite));
      return r != 0 ? r : a.invite.email.compareTo(b.invite.email);
    });
}

/// Whether [view] has [filter] in its address or [roleLabel] (any case).
bool inviteMatches(InviteView view, String roleLabel, String filter) {
  final q = filter.trim().toLowerCase();
  return q.isEmpty || view.invite.email.toLowerCase().contains(q) || roleLabel.toLowerCase().contains(q);
}

class _OrchardInvitesSectionState extends ConsumerState<OrchardInvitesSection> {
  String? _busyId;

  /// Invitations ticked on a computer's page, to withdraw together.
  ///
  final _picked = <String>{};

  /// Reads the invitations fresh while this shows. The list is kept by the
  /// team page for as long as it is open, and read again when the team says
  /// someone waits; where that word did not come, the Members page still
  /// showed a code someone had used as unused, with nothing to review, while
  /// the Seats page (read fresh) said they waited.
  /// So it is read when this opens, and every 30 seconds after.
  Timer? _fresh;

  void _readFresh() {
    if (mounted) ref.invalidate(teamInvitesProvider(widget.orchard.id));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readFresh());
    _fresh = Timer.periodic(const Duration(seconds: 30), (_) => _readFresh());
  }

  @override
  void dispose() {
    _fresh?.cancel();
    super.dispose();
  }

  /// Reads the invitations again (the list watches them).
  void _load() => ref.read(orchardInvitesVersionProvider.notifier).state++;

  Future<void> _invite() async {
    if (await showInviteDialog(context, ref, widget.orchard)) _load();
  }

  Future<void> _review(InviteView view) async {
    // On a computer's page: the review beside the list.
    if (widget.onOpenReview != null) {
      widget.onOpenReview!(view);
      return;
    }
    // An invitation to an address: compare fingerprints, then add (as
    // before). A used code: the review panel.
    if (!view.invite.byCode) {
      // Listed with another offer than this device made: nobody is
      // let in on it from here.
      if (view.check?.offerChanged ?? false) {
        showTopSnackBar(context, AppLocalizations.of(context)!.orchardInviteOfferChangedAddress, isError: true);
        return;
      }
      final added =
          await letInvitedIn(context, ref, widget.orchard, view.invite, compare: true, offerDevice: view.deviceOffer);
      if (!mounted) return;
      if (added) widget.onMembersChanged();
      _load();
      return;
    }
    await showJoinReview(context, ref, widget.orchard, view);
    if (!mounted) return;
    widget.onMembersChanged();
    _load();
  }

  Future<void> _withdraw(OrchardInvite invite) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busyId = invite.id);
    try {
      await ref.read(orchardServiceProvider).withdrawInvite(widget.orchard.id, invite.id);
      if (mounted) showTopSnackBar(context, invite.byCode ? l10n.inviteCodeCancelled : l10n.orchardInviteWithdrawn);
    } catch (e) {
      AppLogger.warning('Orchards: an invitation was not withdrawn (${errorKind(e)})');
      if (mounted) showTopSnackBar(context, inviteErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busyId = null);
      _load();
    }
  }

  /// Withdraws [invites] after asking: their seats are freed.
  Future<void> _withdrawMany(List<OrchardInvite> invites) async {
    final l10n = AppLocalizations.of(context)!;
    if (invites.isEmpty) return;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.invitesWithdrawTitle(invites.length),
      body: l10n.invitesWithdrawBody,
      confirmLabel: l10n.invitesWithdrawN(invites.length),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyId = '');
    var done = 0;
    Object? failed;
    for (final invite in invites) {
      try {
        await ref.read(orchardServiceProvider).withdrawInvite(widget.orchard.id, invite.id);
        done++;
      } catch (e) {
        AppLogger.warning('Orchards: an invitation was not withdrawn (${errorKind(e)})');
        failed ??= e;
      }
    }
    if (!mounted) return;
    setState(() {
      _busyId = null;
      _picked.clear();
    });
    if (done > 0) showTopSnackBar(context, l10n.invitesWithdrawnN(done), isSuccess: true);
    if (failed != null) showTopSnackBar(context, inviteErrorMessage(failed, l10n), isError: true, details: '$failed');
    _load();
  }

  Future<void> _resend(OrchardInvite invite) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busyId = invite.id);
    try {
      final emailed = await ref.read(orchardServiceProvider).resendInvite(widget.orchard.id, invite);
      if (!mounted) return;
      final email = Redactable.account(invite.email).displayIn(ref);
      showTopSnackBar(context, emailed ? l10n.inviteResent(email) : l10n.orchardInviteSaved(email), isSuccess: emailed);
    } catch (e) {
      AppLogger.warning('Orchards: an invitation was not sent again (${errorKind(e)})');
      if (mounted) showTopSnackBar(context, inviteErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busyId = null);
      _load();
    }
  }

  Future<void> _codeInstead(OrchardInvite invite) async {
    if (await showInvitePeople(context, ref, widget.orchard, replacing: invite)) _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Read again when an invitation is made or answered, and when the server
    // says someone used a code or accepted meanwhile (the provider watches
    // both). One that cannot be read lists none.
    ref.listen(teamInvitesProvider(widget.orchard.id), (before, now) {
      if (now.hasError && !(before?.hasError ?? false)) {
        AppLogger.warning('Orchards: the invitations could not be read (${errorKind(now.error!)})');
      }
    });
    final read = ref.watch(teamInvitesProvider(widget.orchard.id));
    final invites = read.hasValue ? sortedInvites(read.value!) : (read.hasError ? const <InviteView>[] : null);
    // The page around it has the Invite button: an empty list shows nothing.
    if (!widget.showInviteButton && invites != null && invites.isEmpty) return const SizedBox.shrink();
    final roles = ref.watch(orchardRolesProvider(widget.orchard.id)).valueOrNull ?? const [];
    final names = orchardRoleNames(ref, widget.orchard.id);
    String roleOf(InviteView v) => orchardRoleLabel(v.invite.role, l10n, names: names);
    if (widget.pageLayout) return _page(invites, roleOf, l10n);
    final waiting = [...?invites?.where((v) => v.waiting)];
    final invited = [...?invites?.where((v) => !v.waiting)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(l10n.orchardInvitesTitle,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
            ),
            if (widget.showInviteButton)
              TextButton.icon(
                key: const ValueKey('invite-someone'),
                onPressed: _busyId == null ? _invite : null,
                icon: const Icon(LucideIcons.userPlus, size: 14),
                label: Text(l10n.orchardInviteAction),
              ),
          ],
        ),
        if (invites == null)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))),
          )
        else ...[
          if (waiting.isNotEmpty) ...[
            const SizedBox(height: 6),
            ZestSectionLabel(l10n.waitingForYouTitle, key: const ValueKey('invites-waiting-title')),
            const SizedBox(height: 6),
            for (final v in waiting)
              Padding(
                key: ValueKey('invite-${v.invite.id}'),
                padding: const EdgeInsets.only(bottom: 6),
                child: WaitingForYouRow(
                  orchard: widget.orchard,
                  view: v,
                  roleLabel: roleOf(v),
                  busy: _busyId == v.invite.id,
                  onReview: v.invite.acceptedKeys != null && _busyId == null &&
                          (v.invite.byCode || v.invite.acceptedRulesUnmet.isEmpty)
                      ? () => _review(v)
                      : null,
                  onWithdraw: _busyId == null ? () => _withdraw(v.invite) : null,
                ),
              ),
          ],
          if (invited.isNotEmpty) ...[
            const SizedBox(height: 6),
            ZestSectionLabel(l10n.invitedSectionTitle, key: const ValueKey('invites-invited-title')),
            const SizedBox(height: 2),
            for (final v in invited)
              _InviteRow(
                key: ValueKey('invite-${v.invite.id}'),
                invite: v.invite,
                roleLabel: roleOf(v),
                crates: offeredCrateCount(v.invite.role, v.invite.grants, widget.orchard, roles),
                busy: _busyId == v.invite.id,
                onResend: !v.invite.byCode && !v.invite.expired && _busyId == null ? () => _resend(v.invite) : null,
                onCodeInstead: !v.invite.byCode && !v.invite.expired && _busyId == null
                    ? () => _codeInstead(v.invite)
                    : null,
                onWithdraw: _busyId == null ? () => _withdraw(v.invite) : null,
              ),
          ],
        ],
      ],
    );
  }

  /// A computer's Members page:
  /// "Waiting for you" and "Invited" as sections of the page, with how many
  /// each holds, a card a row.
  Widget _page(List<InviteView>? invites, String Function(InviteView) roleOf, AppLocalizations l10n) {
    if (invites == null) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))),
      );
    }
    final shown = [
      for (final v in invites)
        if (inviteMatches(v, roleOf(v), widget.filter)) v,
    ];
    final waiting = [...shown.where((v) => v.waiting)];
    final invited = [...shown.where((v) => !v.waiting)];
    if (waiting.isEmpty && invited.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (waiting.isNotEmpty) ...[
          ZestSectionHeader(
              label: l10n.waitingForYouTitle, count: waiting.length, key: const ValueKey('invites-waiting-title')),
          for (final v in waiting)
            Padding(
              key: ValueKey('invite-${v.invite.id}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: WaitingForYouRow(
                orchard: widget.orchard,
                view: v,
                roleLabel: roleOf(v),
                page: true,
                selected: widget.reviewing == v.invite.id,
                busy: _busyId == v.invite.id,
                onReview: _busyId == null ? () => _review(v) : null,
                onWithdraw: null,
              ),
            ),
          const SizedBox(height: 18),
        ],
        if (invited.isNotEmpty) ...[
          ZestSectionHeader(
            label: l10n.invitedSectionTitle,
            count: invited.length,
            key: const ValueKey('invites-invited-title'),
            // Every code no one has used yet, gone in one step.
            trailing: invited.any((v) => v.invite.byCode && !v.invite.expired)
                ? TextButton(
                    key: const ValueKey('invites-withdraw-codes'),
                    onPressed: _busyId == null
                        ? () => _withdrawMany([
                              for (final v in invited)
                                if (v.invite.byCode && !v.invite.expired) v.invite,
                            ])
                        : null,
                    child: Text(l10n.invitesWithdrawCodes),
                  )
                : null,
          ),
          // Ticked ones: how many, and Withdraw them.
          if (invited.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                key: const ValueKey('invites-picked-bar'),
                children: [
                  Checkbox(
                    key: const ValueKey('invites-pick-all'),
                    tristate: true,
                    value: _picked.isEmpty
                        ? false
                        : invited.every((v) => _picked.contains(v.invite.id))
                            ? true
                            : null,
                    onChanged: _busyId != null
                        ? null
                        : (_) => setState(() {
                              final all = invited.every((v) => _picked.contains(v.invite.id));
                              _picked.clear();
                              if (!all) _picked.addAll(invited.map((v) => v.invite.id));
                            }),
                  ),
                  Expanded(
                    child: Text(
                      _picked.isEmpty ? l10n.invitesSelectAll : l10n.invitesSelected(_picked.length),
                      style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary),
                    ),
                  ),
                  if (_picked.isNotEmpty)
                    teamButton(
                      key: const ValueKey('invites-withdraw-picked'),
                      kind: TeamButtonKind.danger,
                      icon: LucideIcons.x,
                      label: l10n.invitesWithdrawN(_picked.length),
                      onPressed: _busyId == null
                          ? () => _withdrawMany([
                                for (final v in invited)
                                  if (_picked.contains(v.invite.id)) v.invite,
                              ])
                          : null,
                    ),
                ],
              ),
            ),
          for (final v in invited)
            Padding(
              key: ValueKey('invite-${v.invite.id}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: _PageInviteRow(
                picked: invited.length > 1 ? _picked.contains(v.invite.id) : null,
                onPick: _busyId != null
                    ? null
                    : (on) => setState(() => on ? _picked.add(v.invite.id) : _picked.remove(v.invite.id)),
                invite: v.invite,
                roleLabel: roleOf(v),
                busy: _busyId == v.invite.id,
                onResend: !v.invite.byCode && !v.invite.expired && _busyId == null ? () => _resend(v.invite) : null,
                onCodeInstead: !v.invite.byCode && !v.invite.expired && _busyId == null
                    ? () => _codeInstead(v.invite)
                    : null,
                onWithdraw: _busyId == null ? () => _withdraw(v.invite) : null,
              ),
            ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

/// An invitation not accepted yet, on a computer's Members page: the
/// address (or "Invite code") with the role offered, where it stands, and
/// Resend, Send a code instead and the rest in a menu.
class _PageInviteRow extends ConsumerWidget {
  const _PageInviteRow({
    this.picked,
    this.onPick,
    required this.invite,
    required this.roleLabel,
    required this.busy,
    required this.onResend,
    required this.onCodeInstead,
    required this.onWithdraw,
  });

  /// Ticked to withdraw with others; null where there is nothing to tick
  /// it with (one invitation alone).
  final bool? picked;
  final ValueChanged<bool>? onPick;
  final OrchardInvite invite;
  final String roleLabel;
  final bool busy;
  final VoidCallback? onResend;
  final VoidCallback? onCodeInstead;
  final VoidCallback? onWithdraw;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final team = invite.code;
    final status = invite.expired
        ? l10n.orchardInviteStatusLapsed
        : team != null && team.usesMax > 1
            ? l10n.inviteTeamCodeUsed(team.uses, team.usesMax)
        : invite.byCode
            ? l10n.inviteCodeRowBody(
                Redactable.account(invite.invitedBy ?? '').displayIn(ref),
                DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).add_jm().formatPlain(invite.expiresAt.toLocal()),
              )
            : l10n.orchardInviteStatusSent;
    final withdraw = invite.byCode ? l10n.inviteCodeCancel : l10n.orchardInviteWithdraw;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      // Its buttons beside what it is where that keeps its room, under it
      // where it would not (on a narrow page they ran past the row).
      child: BesideOrUnder(
        minWordsWidth: 220,
        gap: 8,
        underGap: 10,
        words: Row(
          children: [
            if (picked != null) ...[
              Checkbox(
                key: ValueKey('invite-pick-${invite.id}'),
                value: picked,
                onChanged: onPick == null ? null : (v) => onPick!(v ?? false),
              ),
              const SizedBox(width: 4),
            ],
            TeamIconTile(icon: invite.byCode ? LucideIcons.qrCode : LucideIcons.mail),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (invite.byCode)
                        Text(l10n.inviteCodeLabel,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary))
                      else
                        RedactedText(
                          Redactable.account(invite.email),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      TeamRolePill(roleLabel),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(status,
                      style: TextStyle(
                          fontSize: 12,
                          color: invite.expired ? ZestTokens.textTertiary : ZestTokens.textSecondary)),
                ],
              ),
            ),
          ],
        ),
        control: busy
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
              )
            : Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (onResend != null)
                    teamButton(
                      key: ValueKey('invite-resend-${invite.id}'),
                      icon: LucideIcons.send,
                      label: l10n.inviteResend,
                      onPressed: onResend,
                    ),
                  if (onCodeInstead != null) ...[
                    const SizedBox(width: 6),
                    teamButton(
                      key: ValueKey('invite-code-instead-${invite.id}'),
                      icon: LucideIcons.qrCode,
                      label: l10n.inviteSendCodeInstead,
                      onPressed: onCodeInstead,
                    ),
                  ],
                  const SizedBox(width: 4),
                  PopupMenuButton<int>(
                    key: ValueKey('invite-more-${invite.id}'),
                    enabled: onWithdraw != null,
                    tooltip: l10n.orchardMemberActions,
                    icon: Icon(LucideIcons.moreHorizontal, size: 16, color: ZestTokens.textSecondary),
                    onSelected: (_) => onWithdraw?.call(),
                    itemBuilder: (context) => [
                      PopupMenuItem<int>(
                        key: ValueKey('invite-withdraw-${invite.id}'),
                        value: 0,
                        height: 36,
                        child: Row(
                          children: [
                            Icon(LucideIcons.x, size: 14, color: ZestTokens.statusCritical),
                            const SizedBox(width: 10),
                            Flexible(child: Text(withdraw, style: TextStyle(fontSize: 13, color: ZestTokens.statusCritical))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _InviteRow extends ConsumerWidget {
  const _InviteRow({
    super.key,
    required this.invite,
    required this.roleLabel,
    required this.crates,
    required this.busy,
    required this.onResend,
    required this.onCodeInstead,
    required this.onWithdraw,
  });

  final OrchardInvite invite;

  /// The role offered, by name.
  final String roleLabel;

  /// How many Crates the offer opens.
  final int crates;
  final bool busy;
  final VoidCallback? onResend;
  final VoidCallback? onCodeInstead;
  final VoidCallback? onWithdraw;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final (status, color) = invite.expired
        ? (l10n.orchardInviteStatusLapsed, AppColors.v3TextTertiary)
        : invite.byCode
            ? (
                l10n.inviteCodeRowBody(
                  Redactable.account(invite.invitedBy ?? '').displayIn(ref),
                  DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
                      .add_jm()
                      .formatPlain(invite.expiresAt.toLocal()),
                ),
                AppColors.v3TextSecondary,
              )
            : (l10n.orchardInviteStatusSent, AppColors.v3TextSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      // Its buttons beside the address where it keeps its room, under it
      // where it would not (on a phone the address broke mid-word, or was
      // cut, beside "Send a code instead").
      child: BesideOrUnder(
        minWordsWidth: 200,
        gap: 8,
        underGap: 6,
        words: Row(
          children: [
            Icon(invite.byCode ? LucideIcons.qrCode : LucideIcons.mail, size: 16, color: AppColors.v3TextSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (invite.byCode)
                    Text(l10n.inviteCodeLabel,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary))
                  else
                    RedactedText(
                      Redactable.account(invite.email),
                      key: ValueKey('invite-address-${invite.id}'),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 2),
                  Text(l10n.orchardInviteSummary(roleLabel, crates),
                      style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
                  const SizedBox(height: 2),
                  Text(status, style: TextStyle(fontSize: 11.5, color: color)),
                ],
              ),
            ),
          ],
        ),
        control: busy
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
            : Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (onResend != null)
                    teamButton(
                      key: ValueKey('invite-resend-${invite.id}'),
                      icon: LucideIcons.send,
                      label: l10n.inviteResend,
                      onPressed: onResend,
                    ),
                  if (onCodeInstead != null)
                    OutlinedButton.icon(
                      key: ValueKey('invite-code-instead-${invite.id}'),
                      onPressed: onCodeInstead,
                      icon: const Icon(LucideIcons.qrCode, size: 14),
                      label: Text(l10n.inviteSendCodeInstead),
                    ),
                  IconButton(
                    key: ValueKey('invite-withdraw-${invite.id}'),
                    tooltip: invite.byCode ? l10n.inviteCodeCancel : l10n.orchardInviteWithdraw,
                    icon: const Icon(LucideIcons.x, size: 16),
                    onPressed: onWithdraw,
                  ),
                ],
              ),
      ),
    );
  }
}

// ── The switchers' dot ──────────────────────────────────────────────────

/// Whether the space switcher should draw the eye: an invitation this
/// account has not answered, or someone who accepted one of its Orchards'
/// invitations and waits to be added.
bool spacesNeedAttention(WidgetRef ref) {
  if (ref.watch(myInvitesProvider).any((i) => !i.accepted)) return true;
  final orchards = ref.watch(orchardSummariesProvider).valueOrNull ?? const <OrchardSummary>[];
  return orchards.any((o) => o.invitesWaiting > 0);
}

/// The small dot the switchers show when [spacesNeedAttention].
class SpacesAttentionDot extends StatelessWidget {
  const SpacesAttentionDot({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
        label: AppLocalizations.of(context)!.orchardInvitesTitle,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: AppColors.v3AccentPrimary, shape: BoxShape.circle),
        ),
      );
}

// ── My invitations ──────────────────────────────────────────────────────

/// The invitations to this account: accept or decline, and once accepted,
/// this account's fingerprint to read out to whoever adds it.
Future<void> showMyInvitations(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.mail,
    title: l10n.myInvitationsTitle,
    body: const MyInvitationsView(),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

class MyInvitationsView extends ConsumerStatefulWidget {
  const MyInvitationsView({super.key});

  @override
  ConsumerState<MyInvitationsView> createState() => _MyInvitationsViewState();
}

class _MyInvitationsViewState extends ConsumerState<MyInvitationsView> {
  String? _busyId;
  Uint8List? _fingerprint;

  /// The first answer from the server has not come yet.
  bool _asking = true;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final service = ref.read(orchardServiceProvider);
    try {
      final list = await service.myInvites();
      if (mounted) ref.read(myInvitesProvider.notifier).state = list;
    } catch (e) {
      AppLogger.info('Orchards: invitations could not be read ($e)');
    } finally {
      if (mounted && _asking) setState(() => _asking = false);
    }
    try {
      final me = await service.currentAuthor();
      if (me != null && mounted) {
        final fingerprint = accountKeysFingerprint(
            signingKey: me.keys.signingPublicKey, encryptionKey: me.keys.encryption.publicKey);
        setState(() => _fingerprint = fingerprint);
      }
    } catch (_) {
      // Shown once the keys are on this device.
    }
  }

  Future<void> _answer(MyInvite invite, {required bool accept}) async {
    // One answer at a time: a tap while one works is not a second answer
    // (three taps said the same error three times).
    if (_busyId != null) return;
    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(orchardServiceProvider);
    setState(() => _busyId = invite.id);
    try {
      if (accept) {
        // The team keys first: made here where that is all it takes, or
        // what stands in the way said with the way out.
        if (!await readyToJoin(context, ref) || !mounted) return;
        // With this device, offered for approval as they are let in.
        await service.acceptInvite(invite.id, orchardId: invite.orchardId);
        // The line opens, so the Orchard arrives the moment they add you.
        unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
      } else {
        await service.declineInvite(invite.id);
        if (mounted) showTopSnackBar(context, l10n.myInvitationDeclined);
      }
    } catch (e) {
      AppLogger.warning('Orchards: an invitation was not answered ($e)');
      if (mounted) showTopSnackBar(context, inviteErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      // (Gone where setting sync up closed the invitations.)
      if (mounted) {
        setState(() => _busyId = null);
        await _reload();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final invites = ref.watch(myInvitesProvider);
    if (invites.isEmpty && _asking) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))),
      );
    }
    if (invites.isEmpty) {
      return Text(l10n.myInvitationsEmpty,
          style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final i in invites)
          Padding(
            key: ValueKey('my-invite-${i.id}'),
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RedactedText(
                  Redactable.account(
                      i.invitedBy == null ? l10n.myInvitationFromSomeone : l10n.myInvitationFrom(i.invitedBy!)),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  l10n.myInvitationDetails(orchardRoleLabel(i.role, l10n), i.crates, i.expiresAt.toLocal()),
                  style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
                ),
                // When the access offered would end (a guest's always
                // does), apart from when the invitation itself lapses.
                if (i.endsAt case final ends?) ...[
                  const SizedBox(height: 2),
                  Text(
                    l10n.myInvitationAccessEnds(secondsAsDate(ends)),
                    key: ValueKey('my-invite-ends-${i.id}'),
                    style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
                  ),
                ],
                // What the team records, before they decide.
                const SizedBox(height: 6),
                Row(
                  key: ValueKey('my-invite-tracking-${i.id}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(i.tracking.isNone ? LucideIcons.eyeOff : LucideIcons.eye,
                          size: 14, color: AppColors.v3TextTertiary),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        i.tracking.isNone
                            ? l10n.myInvitationRecordsNothing
                            : l10n.myInvitationRecords(trackingOnNames(i.tracking, l10n).join(l10n.listSeparator)),
                        style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextSecondary),
                      ),
                    ),
                  ],
                ),
                if (i.exported) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n.myInvitationExported,
                    key: ValueKey('my-invite-exported-${i.id}'),
                    style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextSecondary),
                  ),
                ],
                if (i.sessionLogs > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n.myInvitationSessionLogs(i.sessionLogs),
                    key: ValueKey('my-invite-session-logs-${i.id}'),
                    style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextSecondary),
                  ),
                ],
                if (i.watched > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n.myInvitationWatched(i.watched),
                    key: ValueKey('my-invite-watched-${i.id}'),
                    style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextSecondary),
                  ),
                ],
                if (!i.accepted && i.rulesUnmet.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.myInvitationRulesUnmet(orchardRuleNames(i.rulesUnmet, l10n)),
                    key: ValueKey('my-invite-rules-${i.id}'),
                    style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3Warning),
                  ),
                ],
                const SizedBox(height: 8),
                if (_busyId == i.id)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6)),
                  )
                else if (!i.accepted)
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        key: ValueKey('my-invite-decline-${i.id}'),
                        onPressed: _busyId == null ? () => _answer(i, accept: false) : null,
                        child: Text(l10n.myInvitationDecline),
                      ),
                      FilledButton(
                        key: ValueKey('my-invite-accept-${i.id}'),
                        onPressed: _busyId == null ? () => _answer(i, accept: true) : null,
                        child: Text(l10n.myInvitationAccept),
                      ),
                    ],
                  )
                else if (i.byCode)
                  // An invite code checked both sides' keys: nobody compares
                  // fingerprints, its maker only lets them in.
                  Text(
                    l10n.joinedBody(Redactable.account(i.invitedBy ?? l10n.myInvitationFromSomeone).displayIn(ref)),
                    key: ValueKey('my-invite-code-${i.id}'),
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextPrimary),
                  )
                else ...[
                  Text(l10n.myInvitationAcceptedNote,
                      style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextPrimary)),
                  if (_fingerprint != null) ...[
                    const SizedBox(height: 8),
                    FingerprintBox(
                      fingerprint: _fingerprint!,
                      key: ValueKey('my-invite-fingerprint-${i.id}'),
                    ),
                  ],
                ],
              ],
            ),
          ),
      ],
    );
  }
}
