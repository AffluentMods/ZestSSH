import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart' show deviceCode;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/features/orchards/widgets/invite_people_dialog.dart'
    show InviteOffer, ZestSectionLabel, roleLevelIn;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show accessThrough, crateLevelName;
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart'
    show inviteErrorMessage, orchardInvitesVersionProvider;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

// Letting in whoever accepted: the
// Members page's "Waiting for you", the Overview's "Needs attention" row for
// a used invite code, and the review panel both open. An invite code for one
// person checks the person's keys on a device of its maker
// (OrchardService.checkInviteCode): then letting them in needs no fingerprint
// comparison, but it is still this account's "Let them in". Unchecked (a team
// code, another device, another admin, or anything that does not match), it
// falls back to comparing fingerprints, as for an invitation to an address;
// an offer the maker did not sign lets nobody in. Turning them away withdraws
// the invitation: nothing was shared with them, and the seat opens up again.
//
// In a team that lets in approved devices only, the device they accepted on is
// offered beside Let them in, ticked, with its
// code and platform: where its statement checks out with the keys compared and
// this account may approve their devices from here
// (OrchardService.joinDeviceOffer). One confirmation and one recent sign-in
// then cover both. Someone who accepted on a computer that is not theirs is
// let in with it unticked, and their own device asks as before.

/// An invitation, with what this device found of an invite code's check, and
/// the device to offer for approval as they are let in.
class InviteView {
  const InviteView(this.invite, [this.check, this.deviceOffer]);

  final OrchardInvite invite;
  final InviteCodeCheck? check;

  /// The key of the device they accepted on, to approve with them; null
  /// where none is offered here.
  final String? deviceOffer;

  bool get checked => check?.checked ?? false;

  /// Someone accepted and waits to be let in.
  bool get waiting => invite.accepted && !invite.expired;
}

/// An Orchard's invitations (those who may invite), each used code checked
/// on this device. Read again when an invitation is made or answered here
/// ([orchardInvitesVersionProvider]) and when the server says someone waits.
final teamInvitesProvider = FutureProvider.autoDispose.family<List<InviteView>, String>((ref, orchardId) async {
  ref.watch(orchardInvitesVersionProvider);
  ref.watch(orchardSummariesProvider
      .select((s) => s.valueOrNull?.where((o) => o.id == orchardId).firstOrNull?.invitesWaiting));
  final service = ref.read(orchardServiceProvider);
  return checkedInvites(service, orchardId, await service.invites(orchardId));
});

/// How many wait to join [orchard]: invitations to an address that are
/// still open and invite codes someone used, for those who may invite (who
/// can read them); for anyone else what the server says waits.
int teamJoiningCount(WidgetRef ref, OrchardSummary orchard) {
  if (!orchard.canInvite || !orchard.active) return orchard.invitesWaiting;
  final invites = ref.watch(teamInvitesProvider(orchard.id)).valueOrNull;
  if (invites == null) return orchard.invitesWaiting;
  return invites.where(isJoining).length;
}

/// Someone waits to join through [v]: an open invitation to an address, or
/// an invite code they used (a code nobody used yet names nobody).
bool isJoining(InviteView v) => !v.invite.expired && (v.invite.accepted || !v.invite.byCode);

/// [invites], each used code checked on this device, and each device offered
/// with an invitation checked for approval from here.
Future<List<InviteView>> checkedInvites(OrchardService service, String orchardId, List<OrchardInvite> invites) async {
  final out = <InviteView>[];
  for (final i in invites) {
    InviteCodeCheck? check;
    if (i.byCode && i.accepted) {
      try {
        check = await service.checkInviteCode(orchardId, i);
      } catch (e) {
        AppLogger.info('Orchards: an invite code could not be checked here (${errorKind(e)})');
        check = const InviteCodeCheck(checked: false);
      }
    } else if (i.accepted) {
      // An invitation to an address this device made, listed with another
      // offer: nobody is let in on it from here.
      try {
        if (await service.inviteOfferChanged(orchardId, i)) check = const InviteCodeCheck(checked: false, offerChanged: true);
      } catch (e) {
        AppLogger.info('Orchards: what an invitation offered could not be read here (${errorKind(e)})');
      }
    }
    final device = i.accepted && i.acceptedDevice != null ? await service.joinDeviceOffer(orchardId, i) : null;
    out.add(InviteView(i, check, device));
  }
  return out;
}

/// The short name an address stands for in a button ("Let sam in").
String personShortName(String email) {
  final at = email.indexOf('@');
  return at > 0 ? email.substring(0, at) : email;
}

/// The words for a platform a session reports.
String platformWords(String? platform, AppLocalizations l10n) => switch (platform) {
      'android' => l10n.platformAndroid,
      'ios' => l10n.platformIos,
      'windows' => l10n.platformWindows,
      'macos' => l10n.platformMac,
      'linux' => l10n.platformLinux,
      _ => l10n.platformUnknown,
    };

/// The platform's own name, in "ZestSSH for Android" and the like.
const Map<String, String> _platformNames = {
  'android': 'Android',
  'ios': 'iOS',
  'windows': 'Windows',
  'macos': 'macOS',
  'linux': 'Linux',
};

/// Names of the sign-in providers, as they call themselves.
const Map<String, String> _providerNames = {
  'google.com': 'Google',
  'apple.com': 'Apple',
  'github.com': 'GitHub',
  'microsoft.com': 'Microsoft',
};

String? _providerWords(String? provider, AppLocalizations l10n) {
  if (provider == null) return null;
  if (provider == 'password') return l10n.reviewProviderPassword;
  if (provider.startsWith('saml.') || provider.startsWith('oidc.')) return l10n.reviewProviderCompany;
  return _providerNames[provider] ?? provider;
}

/// Lets in whoever accepted [invite]: where [compare], their fingerprint is
/// compared first (an invitation to an address, or a code this device could
/// not check); then the member.add, after a recent sign-in. True once they
/// are in.
///
/// The device they accepted on, as InviteView.deviceOffer gives it:
/// [approveDevice] where the review panel already asked (its box ticked), or
/// [offerDevice] to ask with a ticked box under the fingerprint. Approved in
/// the same step as they are let in, under the same recent sign-in.
Future<bool> letInvitedIn(BuildContext context, WidgetRef ref, OrchardSummary orchard, OrchardInvite invite,
    {required bool compare, String? approveDevice, String? offerDevice}) async {
  final l10n = AppLocalizations.of(context)!;
  final keys = invite.acceptedKeys;
  if (keys == null) return false;
  var approve = approveDevice;
  if (compare) {
    var tick = offerDevice != null;
    final matched = await ZestDialogShell.showModal<bool>(
      context,
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.fingerprint,
      title: l10n.orchardInviteConfirmTitle(invite.email),
      body: StatefulBuilder(
        builder: (context, setTick) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.orchardInviteConfirmBody(invite.email),
                style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
            const SizedBox(height: 14),
            FingerprintBox(fingerprint: keys.fingerprint, key: const ValueKey('invitee-fingerprint')),
            // What they get, as listed: signed into the member.add as it is
            // here, so it is read before it is confirmed, on every platform
            // (found in a security review).
            const SizedBox(height: 14),
            ZestSectionLabel(l10n.reviewTheyGet),
            const SizedBox(height: 4),
            InviteOfferLines(orchard: orchard, invite: invite),
            if (offerDevice != null) ...[
              const SizedBox(height: 12),
              JoinDeviceTick(
                invite: invite,
                deviceKey: offerDevice,
                value: tick,
                onChanged: (v) => setTick(() => tick = v),
              ),
            ],
          ],
        ),
      ),
      primaryAction: (
        label: l10n.orchardInviteConfirmMatch,
        onPressed: () => Navigator.of(context).pop(true),
        icon: LucideIcons.check,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
    );
    if (matched != true || !context.mounted) return false;
    if (offerDevice != null && tick) approve = offerDevice;
  }
  try {
    // Adding someone needs a recent sign-in; it covers approving the
    // device they accepted on too, which goes in the same step.
    var deviceLeftOut = false;
    final added = await withRecentSignIn(context, ref, () async {
      deviceLeftOut =
          await ref.read(orchardServiceProvider).confirmInvite(orchard.id, invite, approveDevice: approve);
    },
        summary: (
          what: l10n.stepUpAdd(invite.email, orchardDisplayName(orchard.name, l10n)),
          effects: [l10n.stepUpEffectAddKeys],
        ));
    if (!added || !context.mounted) return false;
    // The device ticked to be approved with them was left out after all
    // said, not only logged.
    if (deviceLeftOut) {
      showTopSnackBar(context, l10n.orchardInviteDeviceNotApproved(invite.email), isWarning: true);
    } else {
      showTopSnackBar(context, l10n.orchardInviteConfirmed(invite.email), isSuccess: true);
    }
    ref.read(orchardListVersionProvider.notifier).state++;
    return true;
  } catch (e) {
    AppLogger.warning('Orchards: a person was not added (${errorKind(e)})');
    if (context.mounted) showTopSnackBar(context, inviteErrorMessage(e, l10n), isError: true, details: '$e');
    return false;
  } finally {
    ref.read(orchardInvitesVersionProvider.notifier).state++;
  }
}

/// Turns away whoever accepted [invite]: the invitation goes, and with it
/// the seat; nothing was shared with them.
Future<bool> turnAwayInvited(BuildContext context, WidgetRef ref, OrchardSummary orchard, OrchardInvite invite) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await ref.read(orchardServiceProvider).withdrawInvite(orchard.id, invite.id);
    if (context.mounted) {
      showTopSnackBar(context, l10n.reviewTurnedAway(Redactable.account(invite.email).displayIn(ref)));
    }
    return true;
  } catch (e) {
    AppLogger.warning('Orchards: someone was not turned away (${errorKind(e)})');
    if (context.mounted) showTopSnackBar(context, inviteErrorMessage(e, l10n), isError: true, details: '$e');
    return false;
  } finally {
    ref.read(orchardInvitesVersionProvider.notifier).state++;
  }
}

/// The review of whoever used an invite code (or accepted an invitation):
/// a panel on the right on a computer, a sheet on a phone.
Future<void> showJoinReview(BuildContext context, WidgetRef ref, OrchardSummary orchard, InviteView view) {
  final wide = MediaQuery.sizeOf(context).width >= 900;
  if (!wide) {
    return showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: JoinReviewPanel(orchard: orchard, view: view),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: ZestTokens.surfaceElevated,
        elevation: 8,
        child: SizedBox(
          width: 420,
          height: double.infinity,
          child: SafeArea(child: JoinReviewPanel(orchard: orchard, view: view)),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

/// "Someone wants to join": who, whether the code checked their keys, the
/// device they used it on, what they get, the seat, and Turn away / Let in.
class JoinReviewPanel extends ConsumerStatefulWidget {
  const JoinReviewPanel({super.key, required this.orchard, required this.view, this.onClose});

  final OrchardSummary orchard;
  final InviteView view;

  /// Set where the review sits beside the Members list (a computer): it is
  /// a panel there, and this closes it (also once they are let in or turned
  /// away). Null for the dialog or sheet, which closes itself.
  final VoidCallback? onClose;

  @override
  ConsumerState<JoinReviewPanel> createState() => _JoinReviewPanelState();
}

class _JoinReviewPanelState extends ConsumerState<JoinReviewPanel> {
  bool _busy = false;

  /// The device they accepted on is approved with them: ticked until
  /// its person unticks it.
  bool _approveDevice = true;

  Future<void> _letIn() async {
    setState(() => _busy = true);
    final offer = widget.view.deviceOffer;
    final done = await letInvitedIn(context, ref, widget.orchard, widget.view.invite,
        compare: !widget.view.checked, approveDevice: offer != null && _approveDevice ? offer : null);
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) _close();
  }

  Future<void> _turnAway() async {
    setState(() => _busy = true);
    final done = await turnAwayInvited(context, ref, widget.orchard, widget.view.invite);
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) _close();
  }

  void _close() => widget.onClose != null ? widget.onClose!() : Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final invite = widget.view.invite;
    final code = invite.code;
    final email = Redactable.account(invite.email).displayIn(ref);
    final short = Redactable.account(personShortName(invite.email)).displayIn(ref);
    final provider = _providerWords(invite.acceptedProvider, l10n);
    final seats = ref.watch(orchardBillingProvider(widget.orchard.id)).valueOrNull?.seats;
    // An offer changed on the way lets nobody in: turned away, and a
    // new code made.
    final offerChanged = widget.view.check?.offerChanged ?? false;
    final canLetIn =
        invite.acceptedKeys != null && invite.acceptedRulesUnmet.isEmpty && !invite.expired && !offerChanged;
    // Beside Let them in, where there is one to approve with them.
    final device = widget.view.deviceOffer;
    final deviceTick = device == null || !canLetIn
        ? null
        : JoinDeviceTick(
            invite: invite,
            deviceKey: device,
            value: _approveDevice,
            onChanged: _busy ? null : (v) => setState(() => _approveDevice = v),
          );
    final secondary = TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary);
    final inline = widget.onClose != null;
    // A section's name: with its hairline beside the list, as on the page
    // around it; the dialog's own short mark elsewhere.
    Widget section(String label) => inline
        ? ZestSectionHeader(label: label)
        : Padding(padding: const EdgeInsets.only(bottom: 4), child: ZestSectionLabel(label));
    String used(DateTime at) => timeAgoWords(l10n, at.toLocal(), now: DateTime.now());
    final header = Row(
      children: [
        _Initials(email: invite.email),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.reviewTitle(email),
                  key: const ValueKey('review-title'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
              const SizedBox(height: 2),
              Text(provider == null ? email : l10n.reviewSignedInWith(email, provider), style: secondary),
            ],
          ),
        ),
        if (inline)
          IconButton(
            key: const ValueKey('review-close'),
            tooltip: l10n.close,
            icon: Icon(LucideIcons.x, size: 16, color: ZestTokens.textSecondary),
            onPressed: widget.onClose,
          ),
      ],
    );
    final details = <Widget>[
      if (code != null)
        _CheckBox(
          checked: widget.view.checked,
          title: widget.view.checked ? l10n.reviewKeysChecked : l10n.reviewKeysNotChecked,
          body: widget.view.checked
              ? l10n.reviewKeysCheckedBody(widget.view.check?.code == null
                  ? l10n.inviteCodeLabel
                  : reviewCodeStart(widget.view.check!.code!))
              : offerChanged
                  ? l10n.orchardInviteOfferChanged
                  : (widget.view.check?.teamCode ?? false)
                      ? l10n.reviewKeysTeamCodeBody
                      : l10n.reviewKeysNotCheckedBody,
        ),
      // An invitation to an address this device made, listed with another
      // offer.
      if (code == null && offerChanged) ...[
        Text(l10n.orchardInviteOfferChangedAddress,
            key: const ValueKey('review-offer-changed'),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusWarning)),
        const SizedBox(height: 10),
      ],
      if (invite.acceptedRulesUnmet.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(l10n.orchardInviteAcceptedRulesUnmet(orchardRuleNames(invite.acceptedRulesUnmet, l10n)),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusWarning)),
      ],
      if (code != null) ...[
        const SizedBox(height: 18),
        section(l10n.reviewDevice),
        _ReviewLine(label: l10n.reviewDevice, value: platformWords(code.usedPlatform, l10n)),
        if (_platformNames[code.usedPlatform] case final name?)
          _ReviewLine(label: l10n.reviewApp, value: l10n.reviewAppValue(name)),
        if (code.usedAt case final at?) _ReviewLine(label: l10n.reviewUsedCode, value: used(at)),
      ],
      const SizedBox(height: 18),
      section(l10n.reviewTheyGet),
      InviteOfferLines(orchard: widget.orchard, invite: invite),
      if (code != null) ...[
        const SizedBox(height: 18),
        section(l10n.reviewSeat),
        Text(seats == null ? l10n.reviewSeatHeldPlain : l10n.reviewSeatHeld(seats.used, seats.total),
            style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary)),
      ],
      const SizedBox(height: 14),
      Text(l10n.reviewNotExpected, style: secondary),
    ];
    if (inline) {
      // Beside the Members list on a computer:
      // who, then the rest scrolling, then Turn away and Let
      // them in at its foot.
      return Container(
        key: ValueKey('review-panel-${invite.id}'),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          border: Border(left: BorderSide(color: ZestTokens.borderSubtle)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
            Padding(padding: const EdgeInsets.fromLTRB(20, 14, 8, 14), child: header),
            Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                children: details,
              ),
            ),
            Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
            if (deviceTick != null) Padding(padding: const EdgeInsets.fromLTRB(12, 8, 20, 0), child: deviceTick),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                children: [
                  teamButton(
                    key: const ValueKey('review-turn-away'),
                    kind: TeamButtonKind.danger,
                    label: l10n.reviewTurnAway,
                    onPressed: _busy ? null : _turnAway,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: teamButton(
                      key: const ValueKey('review-let-in'),
                      kind: TeamButtonKind.primary,
                      icon: LucideIcons.check,
                      label: l10n.reviewLetIn(short),
                      onPressed: _busy || !canLetIn ? null : _letIn,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        const SizedBox(height: 16),
        ...details,
        if (deviceTick != null) ...[const SizedBox(height: 12), deviceTick],
      ],
    );
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      title: l10n.reviewTitle(email),
      body: body,
      onClose: () => Navigator.of(context).pop(),
      primaryKey: const ValueKey('review-let-in'),
      primaryAction: (
        label: l10n.reviewLetIn(short),
        onPressed: _busy || !canLetIn ? null : _letIn,
        icon: LucideIcons.check,
      ),
      secondaryKey: const ValueKey('review-turn-away'),
      secondaryAction: (label: l10n.reviewTurnAway, onPressed: _busy ? null : _turnAway),
      secondaryDanger: true,
    );
  }
}

/// The ticked box that approves the device whose key is [deviceKey], which
/// whoever accepted [invite] used, as they are let in: its code, the
/// words for its platform where the server named one, and why someone would
/// untick it. [onChanged] null while it cannot change.
class JoinDeviceTick extends StatelessWidget {
  const JoinDeviceTick({
    super.key,
    required this.invite,
    required this.deviceKey,
    required this.value,
    required this.onChanged,
  });

  final OrchardInvite invite;
  final String deviceKey;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final code = deviceCode(deviceKey);
    final platform = invite.acceptedDevice?.platform;
    final label = _platformNames.containsKey(platform)
        ? l10n.joinApproveDevice(code, platformWords(platform, l10n))
        : l10n.joinApproveDeviceNoPlatform(code);
    return CheckboxListTile(
      key: const ValueKey('review-approve-device'),
      value: value,
      onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label, style: TextStyle(fontSize: 13, height: 1.4, color: ZestTokens.textPrimary)),
      subtitle: Text(l10n.joinApproveDeviceHint,
          style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary)),
    );
  }
}

/// What [invite] offers, as listed: the role, each vault of [orchard] that
/// is not owners-only with how far the offer goes in it, and when the access
/// ends. In the review and in the fingerprint comparison before someone is let
/// in.
class InviteOfferLines extends ConsumerWidget {
  const InviteOfferLines({super.key, required this.orchard, required this.invite});

  final OrchardSummary orchard;
  final OrchardInvite invite;

  /// How far [offer] goes in vault [crateId]: its role's level there, or
  /// more where more was offered; null for nothing.
  static CrateLevel? _offered(InviteOffer offer, String crateId, List<OrchardRoleView> roles, RecordAdminRole? admin) {
    final own = roleLevelIn(offer.role, crateId, roles, admin: admin);
    final extra = offer.extra[crateId];
    return own == null ? extra : (extra != null && extra.index > own.index ? extra : own);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final roles = ref.watch(orchardRolesProvider(orchard.id)).valueOrNull ?? const <OrchardRoleView>[];
    final role = orchardRoleLabel(invite.role, l10n, names: {for (final r in roles) r.id: r.name});
    final offer = InviteOffer(
      role: invite.role,
      extra: {for (final g in invite.grants.entries) g.key: ?levelOf(g.value)},
      endsAt: invite.endsAt,
    );
    return Column(
      key: ValueKey('invite-offer-${invite.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ReviewLine(label: l10n.orchardInviteRoleLabel, value: role),
        if (invite.role != FixedRoles.admin || orchard.adminRole != null)
          for (final c in orchard.crates)
            if (!c.ownersOnly)
              _ReviewLine(
                label: Redactable.group(crateDisplayName(c, l10n)).displayIn(ref),
                value: switch (_offered(offer, c.id, roles, orchard.adminRole)) {
                  null => l10n.crateLevelNone,
                  final level => crateLevelName(level, l10n),
                },
                muted: _offered(offer, c.id, roles, orchard.adminRole) == null,
              ),
        _ReviewLine(
          label: l10n.inviteAccessEnds,
          value: invite.endsAt == null ? l10n.inviteAccessNever : accessThrough(invite.endsAt!, context),
        ),
      ],
    );
  }
}

/// A line of the review: what it is, and its value at the end ([muted] for
/// nothing), over a hairline.
class _ReviewLine extends StatelessWidget {
  const _ReviewLine({required this.label, required this.value, this.muted = false});

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZestTokens.borderSubtle))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(label, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                fontWeight: muted ? FontWeight.w400 : FontWeight.w500,
                color: muted ? ZestTokens.textTertiary : ZestTokens.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ZEST-4F7Q-… of a code in its normal form.
String reviewCodeStart(String code) {
  final body = code.startsWith('ZEST') ? code.substring(4) : code;
  // No ellipsis: the sentence's full stop comes right after this, and "…. It"
  // read as a slip.
  return 'ZEST-${body.substring(0, body.length < 4 ? body.length : 4)}';
}

class _Initials extends StatelessWidget {
  const _Initials({required this.email, this.size = 36});

  final String email;
  final double size;

  @override
  Widget build(BuildContext context) => Consumer(
      builder: (context, ref, _) => TeamInitials(name: Redactable.account(personShortName(email)).displayIn(ref), size: size));
}

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.checked, required this.title, required this.body});

  final bool checked;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tone = checked ? ZestTokens.statusHealthy : ZestTokens.statusWarning;
    return Container(
      key: ValueKey(checked ? 'review-keys-checked' : 'review-keys-unchecked'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(checked ? LucideIcons.shieldCheck : LucideIcons.fingerprint, size: 16, color: tone),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tone)),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A pill: "Keys checked" (green) or "Compare fingerprints".
class KeysCheckedPill extends StatelessWidget {
  const KeysCheckedPill({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tone = checked ? ZestTokens.statusHealthy : ZestTokens.statusWarning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(checked ? LucideIcons.shieldCheck : LucideIcons.fingerprint, size: 12, color: tone),
          const SizedBox(width: 4),
          Text(checked ? l10n.keysCheckedPill : l10n.keysNotCheckedPill, style: TextStyle(fontSize: 11.5, color: tone)),
        ],
      ),
    );
  }
}

/// The line under a used code's name: where and when it was used.
String codeUsedWords(OrchardInvite invite, AppLocalizations l10n) {
  final code = invite.code;
  final when = code?.usedAt == null ? '' : timeAgoWords(l10n, code!.usedAt!.toLocal(), now: DateTime.now());
  return l10n.codeUsedRow(platformWords(code?.usedPlatform, l10n), when);
}

/// The Overview's "Needs attention" row for a used invite code: who, their
/// address, the device, the role they would get and when, with Turn away
/// and Review.
class CodeUsedAttentionRow extends ConsumerWidget {
  const CodeUsedAttentionRow({super.key, required this.orchard, required this.view, this.onReview});

  final OrchardSummary orchard;
  final InviteView view;

  /// Opens the review somewhere else (a computer's Members page, beside its
  /// list); by default [showJoinReview].
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final invite = view.invite;
    final email = Redactable.account(invite.email).displayIn(ref);
    final role = orchardRoleLabel(invite.role, l10n, names: orchardRoleNames(ref, orchard.id));
    final when = invite.code?.usedAt == null ? '' : timeAgoWords(l10n, invite.code!.usedAt!.toLocal(), now: DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          _Initials(email: invite.email),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.attnCodeUsed(Redactable.account(personShortName(invite.email)).displayIn(ref)),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.4, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(l10n.attnCodeUsedBody(email, platformWords(invite.code?.usedPlatform, l10n), role, when),
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Quiet beside Review, as the 4.0 design draws it
          // (it was red words): someone turned away can be invited again.
          teamButton(
            key: ValueKey('attn-turn-away-${invite.id}'),
            label: l10n.reviewTurnAway,
            kind: TeamButtonKind.ghost,
            onPressed: () => turnAwayInvited(context, ref, orchard, invite),
          ),
          const SizedBox(width: 4),
          teamButton(
            key: ValueKey('attn-review-${invite.id}'),
            label: l10n.teamReview,
            onPressed: onReview ?? () => showJoinReview(context, ref, orchard, view),
          ),
        ],
      ),
    );
  }
}

/// A row of "Waiting for you": who accepted, their role, how (a code, where
/// and when; or an invitation), whether their keys are checked, and the way
/// to review them.
class WaitingForYouRow extends ConsumerWidget {
  const WaitingForYouRow({
    super.key,
    required this.orchard,
    required this.view,
    required this.roleLabel,
    required this.onReview,
    required this.onWithdraw,
    this.busy = false,
    this.page = false,
    this.selected = false,
  });

  final OrchardSummary orchard;
  final InviteView view;
  final String roleLabel;
  final VoidCallback? onReview;
  final VoidCallback? onWithdraw;
  final bool busy;

  /// On a computer's Members page: a card of its own that opens the review
  /// beside the list (Turn away is there), with a chevron in place of the
  /// buttons.
  final bool page;

  /// Its review is open beside the list.
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final invite = view.invite;
    if (!page && isTouchLayout) return _touch(context, l10n);
    return Material(
      color: page ? (selected ? ZestTokens.surfaceRaisedAlt : ZestTokens.surfaceRaised) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onReview,
        child: Container(
          padding: page ? const EdgeInsets.fromLTRB(14, 12, 12, 12) : const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: !page || selected ? ZestTokens.brandBorder : ZestTokens.borderSubtle,
                width: page && selected ? 1.4 : 1),
          ),
          child: Row(
            children: [
              _Initials(email: invite.email, size: page ? 32 : 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        RedactedText(
                          Redactable.account(invite.email),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                        ),
                        TeamRolePill(roleLabel),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      invite.byCode ? codeUsedWords(invite, l10n) : l10n.orchardInviteStatusAccepted,
                      style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary),
                    ),
                    if (invite.acceptedRulesUnmet.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        l10n.orchardInviteAcceptedRulesUnmet(orchardRuleNames(invite.acceptedRulesUnmet, l10n)),
                        key: ValueKey('invite-rules-unmet-${invite.id}'),
                        style: TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.statusWarning),
                      ),
                    ],
                  ],
                ),
              ),
              if (busy)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
              else if (page) ...[
                if (invite.byCode) ...[KeysCheckedPill(checked: view.checked), const SizedBox(width: 10)],
                Icon(LucideIcons.chevronRight, size: 16, color: ZestTokens.textTertiary),
              ] else ...[
                if (invite.byCode) ...[KeysCheckedPill(checked: view.checked), const SizedBox(width: 6)],
                if (onReview != null)
                  TextButton(
                    key: ValueKey('invite-confirm-${invite.id}'),
                    onPressed: onReview,
                    child: Text(invite.byCode ? l10n.teamReview : l10n.orchardInviteConfirmAction),
                  ),
                IconButton(
                  key: ValueKey('invite-withdraw-${invite.id}'),
                  tooltip: l10n.reviewTurnAway,
                  icon: const Icon(LucideIcons.x, size: 16),
                  onPressed: onWithdraw,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The row on a phone and a tablet: the address whole on one line, cut
  /// with an ellipsis at its end where it is too long (it broke across two,
  /// "sam@example." and "com"), the role and how they came as plain text,
  /// and Review and Turn away beside it where they leave it room, under it
  /// where they would not (as the Invited rows). Keys checked is plain text;
  /// keys not checked yet keep their chip, as they need someone (3.0 quick
  /// wins).
  Widget _touch(BuildContext context, AppLocalizations l10n) {
    final invite = view.invite;
    final secondary = TextStyle(fontSize: 12, height: 1.35, color: ZestTokens.textSecondary);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onReview,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.brandBorder),
          ),
          child: Row(
            children: [
              _Initials(email: invite.email, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: BesideOrUnder(
                  minWordsWidth: 170,
                  gap: 8,
                  underGap: 4,
                  words: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(
                        Redactable.account(invite.email),
                        key: ValueKey('waiting-address-${invite.id}'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [roleLabel, invite.byCode ? codeUsedWords(invite, l10n) : l10n.orchardInviteStatusAccepted]
                            .join(' · '),
                        key: ValueKey('waiting-meta-${invite.id}'),
                        style: secondary,
                      ),
                      if (invite.byCode && view.checked) ...[
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.shieldCheck, size: 12, color: ZestTokens.statusHealthy),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(l10n.keysCheckedPill,
                                  key: ValueKey('waiting-keys-checked-${invite.id}'),
                                  style: secondary.copyWith(color: ZestTokens.statusHealthy)),
                            ),
                          ],
                        ),
                      ],
                      if (invite.acceptedRulesUnmet.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          l10n.orchardInviteAcceptedRulesUnmet(orchardRuleNames(invite.acceptedRulesUnmet, l10n)),
                          key: ValueKey('invite-rules-unmet-${invite.id}'),
                          style: TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.statusWarning),
                        ),
                      ],
                    ],
                  ),
                  control: busy
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
                      : Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (invite.byCode && !view.checked) ...[
                              KeysCheckedPill(checked: view.checked),
                              const SizedBox(width: 6),
                            ],
                            if (onReview != null)
                              TextButton(
                                key: ValueKey('invite-confirm-${invite.id}'),
                                onPressed: onReview,
                                child: Text(invite.byCode ? l10n.teamReview : l10n.orchardInviteConfirmAction),
                              ),
                            IconButton(
                              key: ValueKey('invite-withdraw-${invite.id}'),
                              tooltip: l10n.reviewTurnAway,
                              icon: const Icon(LucideIcons.x, size: 16),
                              onPressed: onWithdraw,
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The banner at the top of a computer's Members page while people wait to be
/// let in (before, a new team member could not easily be reviewed and
/// accepted): who, and how long ago, in the accent, with Review for the
/// first. Several: how many, Review for the first, the rest listed under it.
class WaitingBanner extends ConsumerWidget {
  const WaitingBanner({super.key, required this.waiting, required this.onReview});

  /// Those waiting, first the one Review opens.
  final List<InviteView> waiting;
  final void Function(InviteView view) onReview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (waiting.isEmpty) return const SizedBox.shrink();
    final first = waiting.first.invite;
    final name = Redactable.account(personShortName(first.email)).displayIn(ref);
    final when = first.code?.usedAt == null
        ? null
        : timeAgoWords(l10n, first.code!.usedAt!.toLocal(), now: DateTime.now());
    final title = waiting.length > 1
        ? l10n.waitingBannerMany(waiting.length)
        : first.byCode
            ? l10n.attnCodeUsed(name)
            : l10n.waitingBannerAccepted(name);
    final body = waiting.length > 1 ? l10n.waitingBannerBodyMany : l10n.waitingBannerBody;
    return Container(
      key: const ValueKey('members-waiting-banner'),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: ZestTokens.brandSubtle,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.brandBorder),
      ),
      child: Row(
        children: [
          _Initials(email: first.email, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.35, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  [body, if (waiting.length == 1 && when != null && when.isNotEmpty) when].join(' · '),
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          teamButton(
            key: const ValueKey('members-waiting-review'),
            label: l10n.teamReview,
            onPressed: () => onReview(waiting.first),
          ),
        ],
      ),
    );
  }
}
