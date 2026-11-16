import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/billing/seat_purchase_watch.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show FixedRoles, MemberStatus;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart';
import 'package:zestssh/features/orchards/team/team_sync_offer.dart' show offerTeamSync, openAccountForSync;
import 'package:zestssh/providers/core_providers.dart' show syncSetupStateServiceProvider;
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart' show orchardInvitesVersionProvider;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart';

// An Orchard's seats and Business Services (3.0): how many seats
// it has and who holds them, and whether company sign-in and directory sync
// are paid for. Owners on a computer buy them from the seats sheet
// (team_seats_sheet.dart), which opens Stripe's pages in the browser, and
// redeem a code that gives the Orchard seats; on phones and tablets nothing
// is bought, redeemed or pointed to: plain words only.

/// Whether seats are bought from this device: a computer. Phones and
/// tablets say where it is done, with no link.
final billingOnThisDeviceProvider = Provider<bool>((ref) => isDesktopPlatform);

/// Opens a page in the browser: Stripe's, the website's seats page, the terms
/// (tests stand in). Throws where no browser took it.
final seatsPageOpenerProvider = Provider<Future<void> Function(Uri page)>(
    (ref) => (page) async {
          if (!await launchUrl(page, mode: LaunchMode.externalApplication)) {
            throw StateError('The browser did not open');
          }
        });

/// What is done once this device gave an Orchard seats: what waited here
/// for seats is sent (tests stand in).
final seatsArrivedProvider = Provider<void Function()>(
    (ref) => () => unawaited(ref.read(orchardSyncSchedulerProvider).syncAll()));

/// The most seats a team holds without Business (the backend's
/// TEAM_MAX_SEATS, lib/orchard_billing.js).
const kTeamSeatsWithoutBusiness = 25;

/// What is said, under the field, of a seat code that was not taken. On a phone
/// ([buysHere] false) nothing points to where Business is turned on.
String seatCodeRefusal(Object error, AppLocalizations l10n, {bool buysHere = true}) {
  if (error is OrchardServerException) {
    if (error.code == 'code-invalid') return l10n.teamSeatsCodeInvalid;
    if (error.code == 'personal-code') return l10n.teamSeatsCodePersonal;
    // A Business code a team may not take now, and a seat code that would
    // take a team past what it holds: each said as itself (they were "HTTP
    // 409, which this version does not expect" before).
    if (error.code == 'business-code-used') return l10n.teamSeatsCodeBusinessUsed;
    if (error.code == 'business-active') return l10n.teamSeatsCodeBusinessActive;
    if (error.code == 'business-paid-recently') return l10n.teamSeatsCodeBusinessPaidRecently;
    if (error.code == 'business-needed-for-seats') {
      return buysHere
          ? l10n.teamSeatsCodeNeedsBusiness(kTeamSeatsWithoutBusiness)
          : l10n.teamSeatsCodeNeedsBusinessElsewhere(kTeamSeatsWithoutBusiness);
    }
    if (error.code == 'seats-maximum') return l10n.teamSeatsCodeTooManySeats;
    // Too many wrong codes across ZestSSH: redeeming waits an hour.
    if (error.code == 'redeem-paused') return l10n.redeemPaused;
  }
  return orchardErrorMessage(error, l10n);
}

/// "Redeem a code" on an Orchard's Seats page: an owner enters a code that
/// gives the Orchard seats (whoever runs ZestSSH Cloud makes them: for a
/// team that paid another way, or one that is helped out). A code that is
/// not taken is said under the field, and the dialog stays for another
/// try. Once one is taken, what waited on this device for seats is sent,
/// the seats are read again, and a notice says how many came.
Future<void> redeemSeatCode(BuildContext context, WidgetRef ref, OrchardSummary orchard) =>
    redeemSeatCodeFor(context, ref, orchard.id);

/// [redeemSeatCode] for the Orchard [orchardId].
Future<void> redeemSeatCodeFor(BuildContext context, WidgetRef ref, String orchardId) async {
  final l10n = AppLocalizations.of(context)!;
  // Taken now: the page may be gone by the time the dialog closes.
  final api = ref.read(orchardBillingApiProvider);
  final arrived = ref.read(seatsArrivedProvider);
  SeatCodeRedeemed? redeemed;
  final entered = await showZestInputDialog(
    context: context,
    title: l10n.settingsMobRedeemCode,
    subtitle: l10n.teamSeatsRedeemBody,
    icon: LucideIcons.gift,
    // The shape of a code, the same in every language.
    hintText: 'ZEST-XXXX-XXXX-XXXX',
    confirmLabel: l10n.redeemDialogAction,
    busyLabel: l10n.redeemDialogBusy,
    inputFormatters: [
      LengthLimitingTextInputFormatter(128),
      // Capitals as they type, the form codes are kept in.
      TextInputFormatter.withFunction((oldValue, newValue) => newValue.copyWith(text: newValue.text.toUpperCase())),
    ],
    validator: (value) => value.trim().isEmpty ? l10n.redeemSvcEnterCode : null,
    onConfirm: (value) async {
      try {
        redeemed = await api.redeem(orchardId, value);
        return null;
      } catch (e) {
        return seatCodeRefusal(e, l10n);
      }
    },
  );
  final done = redeemed;
  if (entered == null || done == null) return;
  if (done.added > 0) arrived();
  if (!context.mounted) return;
  ref.invalidate(orchardBillingProvider(orchardId));
  showTopSnackBar(context, done.added > 0 ? l10n.teamSeatsCodeAdded(done.added) : l10n.teamSeatsCodeUsed);
  // The seats include ZestSSH Cloud sync: where it is off here, say so.
  if (done.added > 0 && context.mounted) await offerTeamSync(context, ref, orchardId, owner: true);
}

/// Where the team has a seat bought (so it includes ZestSSH Cloud sync) and
/// sync is off on this device: one line, with Set up sync. Nothing while
/// that is being found out, or where sync is on.
class _TeamSyncOffLine extends ConsumerStatefulWidget {
  const _TeamSyncOffLine({super.key});

  @override
  ConsumerState<_TeamSyncOffLine> createState() => _TeamSyncOffLineState();
}

class _TeamSyncOffLineState extends ConsumerState<_TeamSyncOffLine> {
  bool _off = false;

  @override
  void initState() {
    super.initState();
    unawaited(_look());
  }

  Future<void> _look() async {
    bool on;
    try {
      on = await ref.read(syncSetupStateServiceProvider).isSyncActive();
    } catch (_) {
      on = true;
    }
    if (mounted && !on) setState(() => _off = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_off) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: AppColors.v3AccentPrimary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.v3AccentPrimary.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.cloud, size: 16, color: AppColors.accentInk),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l10n.teamSeatsSyncOff,
                  style: TextStyle(fontSize: 13, height: 1.4, color: AppColors.v3TextPrimary)),
            ),
            const SizedBox(width: 10),
            ZestButton(
              key: const ValueKey('team-seats-set-up-sync'),
              label: l10n.joinSetUpSync,
              icon: LucideIcons.cloud,
              variant: ZestButtonVariant.secondary,
              onPressed: () => openAccountForSync(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}

/// The invitations that hold a seat in [orchardId] (live ones, accepted or
/// not), for those who may see them; null where they cannot be read.
final seatInvitesProvider = FutureProvider.autoDispose.family<List<OrchardInvite>?, String>((ref, orchardId) async {
  ref.watch(orchardInvitesVersionProvider);
  ref.watch(orchardListVersionProvider);
  try {
    final list = await ref.read(orchardServiceProvider).invites(orchardId);
    return [
      for (final i in list)
        if (!i.expired) i,
    ];
  } catch (_) {
    return null;
  }
});

/// How [seats] are taken, for the bar on the Seats page: members, people
/// invited who have not joined yet ([waiting], when known), and the seats
/// still open. The members are what the service counts less those
/// invited, so the three always add up to its figures.
({int members, int waiting, int open}) seatShares(OrchardSeats seats, {int? waiting}) {
  final w = (waiting ?? 0).clamp(0, seats.used);
  return (members: seats.used - w, waiting: w, open: seats.free);
}

class TeamSeatsView extends ConsumerWidget {
  const TeamSeatsView(
      {super.key, required this.orchard, this.actionsInHeader = false, this.onOpenMembers, this.onOpenReview});

  final OrchardSummary orchard;

  /// Buy seats and Redeem a code are in the page's header (a computer's Team
  /// page), not under the seats.
  final bool actionsInHeader;

  /// Opens the Members page (to review someone who accepted, or to manage a
  /// member); null where there is none to open.
  final VoidCallback? onOpenMembers;

  /// Opens the review of the invitation with this id, on the Members page
  /// (Review only opened the page before, and the
  /// person had to be found there); by default [onOpenMembers].
  final void Function(String inviteId)? onOpenReview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billing = ref.watch(orchardBillingProvider(orchard.id));
    // Read again when the app comes back to the front (seats bought in the
    // browser): the page stays as it is meanwhile, and a Retry shows it tries.
    return SeatsFocusRefresh(
      orchardId: orchard.id,
      child: billing.when(
        skipLoadingOnRefresh: !billing.hasError,
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
        ),
        error: (error, _) => _SeatsError(
          error: error,
          onRetry: () => ref.invalidate(orchardBillingProvider(orchard.id)),
        ),
        data: (b) => _SeatsBody(
            orchard: orchard,
            billing: b,
            actionsInHeader: actionsInHeader,
            onOpenMembers: onOpenMembers,
            onOpenReview: onOpenReview),
      ),
    );
  }
}

/// A price in dollars as the language writes it, cents only where there are
/// some.
String _dollars(int cents, AppLocalizations l10n) => NumberFormat.simpleCurrency(
      locale: l10n.localeName,
      name: 'USD',
      decimalDigits: cents % 100 == 0 ? 0 : 2,
    ).format(cents / 100);

class _SeatsBody extends ConsumerWidget {
  const _SeatsBody(
      {required this.orchard,
      required this.billing,
      required this.actionsInHeader,
      this.onOpenMembers,
      this.onOpenReview});

  final OrchardSummary orchard;
  final OrchardBilling billing;
  final bool actionsInHeader;
  final VoidCallback? onOpenMembers;
  final void Function(String inviteId)? onOpenReview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final seats = billing.seats;
    final here = ref.watch(billingOnThisDeviceProvider);
    final buys = orchard.isOwner && here;
    final invites = orchard.active && orchard.canInvite ? ref.watch(seatInvitesProvider(orchard.id)).valueOrNull : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SeatsPanel(
          orchard: orchard,
          seats: seats,
          waiting: invites?.length,
          // The price, the website's name for the team and the buttons only
          // where seats are bought: an owner on a computer.
          priceLine: buys ? l10n.teamSeatsBuyHint(_dollars(billing.seatPriceCents, l10n)) : null,
          where: buys ? null : (orchard.isOwner ? l10n.teamSeatsOnComputer : l10n.teamSeatsAskOwner),
          websiteId: buys ? orchardShortId(orchard.id) : null,
          actions: buys && !actionsInHeader
              ? [
                  ZestButton(
                    key: const ValueKey('team-seats-buy'),
                    label: l10n.teamSeatsBuy,
                    icon: LucideIcons.armchair,
                    variant: ZestButtonVariant.primary,
                    onPressed: () => openSeatsSheet(context, ref, orchard.id),
                  ),
                  ZestButton(
                    key: const ValueKey('team-seats-redeem'),
                    label: l10n.settingsMobRedeemCode,
                    icon: LucideIcons.gift,
                    variant: ZestButtonVariant.secondary,
                    onPressed: () => redeemSeatCode(context, ref, orchard),
                  ),
                ]
              : const [],
        ),
        if (seats.over) ...[
          const SizedBox(height: 12),
          _Note(
            key: const ValueKey('team-seats-over'),
            color: AppColors.v3Warning,
            icon: LucideIcons.alertTriangle,
            text: l10n.teamSeatsOver,
          ),
        ],
        // A seat bought includes ZestSSH Cloud sync for everyone in the team.
        if (seats.bought > 0) _TeamSyncOffLine(key: ValueKey('team-sync-off-${orchard.id}')),
        const SizedBox(height: 26),
        _SeatHolders(orchard: orchard, invites: invites, onOpenMembers: onOpenMembers, onOpenReview: onOpenReview),
        const SizedBox(height: 22),
        _ServicesPanel(
          services: billing.services,
          price: buys
              ? l10n.teamServicesPrice(_dollars(billing.servicesMonthCents, l10n), _dollars(billing.servicesYearCents, l10n))
              : null,
          onSee: buys ? () => openSeatsSheet(context, ref, orchard.id, atBusiness: true) : null,
        ),
      ],
    );
  }
}

class _SeatsPanel extends StatelessWidget {
  const _SeatsPanel({
    required this.orchard,
    required this.seats,
    required this.waiting,
    required this.priceLine,
    required this.where,
    required this.websiteId,
    required this.actions,
  });

  final OrchardSummary orchard;
  final OrchardSeats seats;

  /// People invited who have not joined yet; null where not known.
  final int? waiting;
  final String? priceLine;
  final String? where;
  final String? websiteId;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shares = seatShares(seats, waiting: waiting);
    final fill = seats.over ? ZestTokens.statusCritical : ZestTokens.brand;
    Widget figure(String key, String label, int value) => Text.rich(
          key: ValueKey(key),
          TextSpan(children: [
            TextSpan(text: '$label  ', style: TextStyle(color: ZestTokens.textSecondary)),
            TextSpan(
              text: '$value',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: ZestTokens.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ]),
          style: const TextStyle(fontSize: 13),
        );
    final id = websiteId;
    return TeamCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  l10n.teamSeatsInUse(seats.used, seats.total),
                  key: const ValueKey('team-seats-in-use'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                l10n.teamSeatsOpenCount(seats.free),
                key: const ValueKey('team-seats-free'),
                style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SeatsBar(
            members: shares.members,
            waiting: shares.waiting,
            open: shares.open,
            fill: fill,
          ),
          const SizedBox(height: 10),
          Wrap(
            key: const ValueKey('team-seats-legend'),
            spacing: 18,
            runSpacing: 6,
            children: [
              if (waiting == null)
                _Legend(color: fill, label: l10n.teamSeatsLegendInUse, value: shares.members, keyName: 'in-use')
              else ...[
                _Legend(color: fill, label: l10n.orchardMembers, value: shares.members, keyName: 'members'),
                _Legend(
                    color: fill.withValues(alpha: 0.5), label: l10n.teamSeatsLegendWaiting, value: shares.waiting, keyName: 'waiting'),
              ],
              _Legend(color: ZestTokens.surfaceChipStrong, label: l10n.teamSeatsLegendOpen, value: shares.open, keyName: 'open'),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
          const SizedBox(height: 14),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  figure('team-seats-bought', l10n.teamSeatsBought, seats.bought),
                  if (seats.included > 0) figure('team-seats-included', l10n.teamSeatsIncluded, seats.included),
                ],
              ),
              // The website knows the team by the start of its id: the same
              // here, so an owner of several can tell which one it shows.
              if (id != null) _WebsiteId(id: id),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            priceLine ?? where!,
            key: ValueKey(priceLine != null ? 'team-seats-buy-hint' : 'team-seats-where'),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: actions),
          ],
        ],
      ),
    );
  }
}

/// "On zestssh.com this team shows as 1f7f9c44.", the id in the code font,
/// with a button that copies it.
class _WebsiteId extends StatelessWidget {
  const _WebsiteId({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = l10n.teamSeatsWebsiteId(id);
    final at = words.indexOf(id);
    final style = TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text.rich(
            key: const ValueKey('team-seats-website-id'),
            at < 0
                ? TextSpan(text: words)
                : TextSpan(children: [
                    TextSpan(text: words.substring(0, at)),
                    TextSpan(
                      text: id,
                      style: TextStyle(fontFamily: 'JetBrainsMono', fontWeight: FontWeight.w700, color: ZestTokens.textPrimary),
                    ),
                    TextSpan(text: words.substring(at + id.length)),
                  ]),
            style: style,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            key: const ValueKey('team-seats-website-id-copy'),
            tooltip: l10n.copy,
            padding: EdgeInsets.zero,
            icon: Icon(LucideIcons.copy, size: 13, color: ZestTokens.textSecondary),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: id));
              if (context.mounted) showTopSnackBar(context, l10n.teamAdminValueCopied, isSuccess: true);
            },
          ),
        ),
      ],
    );
  }
}

/// The seats as a bar of three: members, people invited who have not
/// joined, and those still open, each as wide as its share.
class _SeatsBar extends StatelessWidget {
  const _SeatsBar({required this.members, required this.waiting, required this.open, required this.fill});

  final int members;
  final int waiting;
  final int open;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (members > 0) (members, fill, 'members'),
      if (waiting > 0) (waiting, fill.withValues(alpha: 0.5), 'waiting'),
      if (open > 0 || (members == 0 && waiting == 0)) (open > 0 ? open : 1, ZestTokens.surfaceChipStrong, 'open'),
    ];
    return SizedBox(
      key: const ValueKey('team-seats-bar'),
      height: 6,
      child: Row(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              key: ValueKey('team-seats-bar-${parts[i].$3}'),
              flex: parts[i].$1,
              child: Container(
                decoration: BoxDecoration(color: parts[i].$2, borderRadius: BorderRadius.circular(3)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, required this.value, required this.keyName});

  final Color color;
  final String label;
  final int value;
  final String keyName;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: ValueKey('team-seats-legend-$keyName'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 7),
        Text(label, style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
        const SizedBox(width: 6),
        Text('$value',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: ZestTokens.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ],
    );
  }
}

/// Who holds the seats: the team's members, and the people invited who have
/// not joined yet (for those who may invite), with what can be done about
/// each from here. Seats are counted for the team, not given to anyone, so
/// nothing here says whose seat came from where.
class _SeatHolders extends ConsumerStatefulWidget {
  const _SeatHolders({required this.orchard, required this.invites, this.onOpenMembers, this.onOpenReview});

  final OrchardSummary orchard;
  final List<OrchardInvite>? invites;
  final VoidCallback? onOpenMembers;
  final void Function(String inviteId)? onOpenReview;

  @override
  ConsumerState<_SeatHolders> createState() => _SeatHoldersState();
}

class _SeatHoldersState extends ConsumerState<_SeatHolders> {
  String? _busyId;

  Future<void> _withdraw(OrchardInvite invite) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busyId = invite.id);
    try {
      await ref.read(orchardServiceProvider).withdrawInvite(widget.orchard.id, invite.id);
      if (!mounted) return;
      showTopSnackBar(context, invite.byCode ? l10n.inviteCodeCancelled : l10n.orchardInviteWithdrawn);
      // A seat came free, and the Members page's list changed.
      ref.read(orchardInvitesVersionProvider.notifier).state++;
      ref.invalidate(orchardBillingProvider(widget.orchard.id));
    } catch (e) {
      AppLogger.warning('Orchards: an invitation was not withdrawn from Seats ($e)');
      if (mounted) showTopSnackBar(context, orchardErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = widget.orchard;
    final people = ref.watch(teamPeopleProvider(orchard.id)).valueOrNull;
    final record = ref.watch(teamRecordProvider(orchard.id)).valueOrNull;
    if (people == null) return const SizedBox.shrink();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final names = orchardRoleNames(ref, orchard.id);
    final members = [
      for (final m in people.members)
        if (m.status != MemberStatus.removed && !m.endedAt(now)) m,
    ];
    final invites = widget.invites ?? const <OrchardInvite>[];
    final rows = <Widget>[
      for (final m in members)
        Builder(builder: (context) {
          final since = people.record.members[m.uid]?.since;
          final seen = since == null ? null : record?.firstSeen[since];
          final owner = m.role == FixedRoles.owner;
          return _HolderRow(
            key: ValueKey('team-seat-member-${m.uid}'),
            name: m.email ?? m.uid,
            // The role as the Members page draws it, outlined (they were
            // filled here).
            badges: [
              if (m.isMe) TeamRolePill(l10n.teamYou),
              TeamRolePill(orchardRoleLabel(m.role, l10n, names: names), accent: owner),
            ],
            line: seen == null ? null : l10n.teamSeatsJoined(DateFormat.yMMMd(l10n.localeName).format(seen)),
            action: m.isMe || widget.onOpenMembers == null
                ? null
                : TeamIconAction(
                    key: ValueKey('team-seat-open-${m.uid}'),
                    icon: LucideIcons.chevronRight,
                    tooltip: l10n.teamSeatsOpenInMembers,
                    onPressed: widget.onOpenMembers,
                  ),
          );
        }),
      for (final i in invites)
        // An invite code nobody used yet has no address (it was a row with
        // no name: the 3.0 docs check): it is named as the Members page
        // names it, with the role it offers, and is cancelled as a code.
        if (i.byCode && !i.accepted)
          _HolderRow(
            key: ValueKey('team-seat-invite-${i.id}'),
            name: '',
            label: l10n.inviteCodeLabel,
            icon: LucideIcons.qrCode,
            invited: true,
            badges: [TeamRolePill(orchardRoleLabel(i.role, l10n, names: names))],
            line: l10n.inviteCodeWaitingTitle,
            action: _busyId == i.id
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))
                : TextButton(
                    key: ValueKey('team-seat-withdraw-${i.id}'),
                    onPressed: _busyId == null ? () => _withdraw(i) : null,
                    child: Text(l10n.inviteCodeCancel),
                  ),
          )
        else
          _HolderRow(
            key: ValueKey('team-seat-invite-${i.id}'),
            name: i.email,
            invited: !i.accepted,
            badges: [
              i.accepted
                  ? _Badge(text: l10n.teamSeatsWaitingForYou, strong: true)
                  : _Badge(text: l10n.teamSeatsInvitedBadge, strong: false),
            ],
            line: i.accepted ? l10n.orchardInviteStatusAccepted : l10n.orchardInviteStatusSent,
            action: i.accepted
                ? (widget.onOpenMembers == null
                    ? null
                    : teamButton(
                        key: ValueKey('team-seat-review-${i.id}'),
                        label: l10n.teamReview,
                        onPressed: widget.onOpenReview == null
                            ? widget.onOpenMembers
                            : () => widget.onOpenReview!(i.id),
                      ))
                : _busyId == i.id
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))
                    : TextButton(
                        key: ValueKey('team-seat-withdraw-${i.id}'),
                        // Red: the invitation is gone.
                        style: TextButton.styleFrom(foregroundColor: ZestTokens.statusCritical),
                        onPressed: _busyId == null ? () => _withdraw(i) : null,
                        child: Text(l10n.orchardInviteWithdraw),
                      ),
          ),
    ];
    return Column(
      key: const ValueKey('team-seat-holders'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(label: l10n.teamSeatsWhoHolds, count: rows.isEmpty ? null : rows.length),
        const SizedBox(height: 8),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One person who holds a seat: their initial (an envelope for someone
/// only invited), their address, their badges (their role as the Members
/// page draws it; where they stand, the accent's tint for the one that
/// matters), a line under it, and what can be done. A row that is
/// no person (an invite code nobody used) has a [label] of the app's own
/// words in place of an address, and its own [icon].
class _HolderRow extends ConsumerWidget {
  const _HolderRow({
    super.key,
    required this.name,
    required this.badges,
    this.label,
    this.icon,
    this.line,
    this.action,
    this.invited = false,
  });

  final String name;
  final String? label;
  final IconData? icon;
  final List<Widget> badges;
  final String? line;
  final Widget? action;
  final bool invited;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = Redactable.account(name).displayIn(ref);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            // Two letters, as the Members page has them.
            if (!invited)
              TeamInitials(name: shown.isEmpty ? '?' : shown, size: 34)
            else
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceChip,
                  shape: BoxShape.circle,
                  border: Border.all(color: ZestTokens.borderSubtle),
                ),
                child: Icon(icon ?? LucideIcons.mail, size: 14, color: ZestTokens.textSecondary),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (label != null)
                        Text(label!,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary))
                      else
                        RedactedText(
                          Redactable.account(name),
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ...badges,
                    ],
                  ),
                  if (line != null) ...[
                    const SizedBox(height: 3),
                    Text(line!, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary)),
                  ],
                ],
              ),
            ),
            if (action != null) ...[const SizedBox(width: 12), action!],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.strong});

  final String text;

  /// In the accent's tint (an owner, someone waiting for this account).
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: strong ? ZestTokens.brand.withValues(alpha: 0.14) : ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: strong ? ZestTokens.brand.withValues(alpha: 0.30) : ZestTokens.borderSubtle),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: strong ? ZestTokens.brandInk : ZestTokens.textSecondary)),
    );
  }
}

/// How the team's Business stands, in a sentence.
String teamServicesLine(OrchardBusinessServices services, AppLocalizations l10n) {
  String day(DateTime? at) => at == null ? '' : DateFormat.yMMMd(l10n.localeName).format(at.toLocal());
  final quantity = services.quantity ?? 0;
  // Free months from a Business code: until when, and what comes after;
  // never a bill or a renewal where nothing is subscribed (it said
  // "Billed monthly for 0 seats. Renews on ." before), nor where ZestSSH
  // Cloud gives no date or number to say it with: as it may to whoever is no
  // owner, who is told only that it is on.
  final comped = services.compedUntil;
  final compedNow = comped != null && comped.isAfter(DateTime.now());
  final compedLine = comped == null
      ? null
      : '${l10n.teamServicesComped(day(comped))} '
          '${services.graceAfterEnd == true ? l10n.teamServicesCompedThenGrace : l10n.teamServicesCompedThenStops}';
  final base = switch (services.state) {
    BusinessServicesState.active when compedLine != null && !services.subscribed => compedLine,
    BusinessServicesState.grace when comped != null && !services.subscribed =>
      l10n.teamServicesCompedGrace(day(services.worksUntil ?? comped.add(const Duration(days: 14)))),
    BusinessServicesState.active when services.paidThrough == null => l10n.teamServicesOn,
    BusinessServicesState.active when services.endsAtPeriodEnd => l10n.teamServicesEnds(day(services.paidThrough)),
    BusinessServicesState.active when !services.subscribed || quantity <= 0 => l10n.teamServicesOn,
    BusinessServicesState.active when services.yearly == true =>
      l10n.teamServicesRenewsYearly(quantity, day(services.paidThrough)),
    BusinessServicesState.active => l10n.teamServicesRenewsMonthly(quantity, day(services.paidThrough)),
    BusinessServicesState.grace when services.worksUntil == null => l10n.teamServicesGraceNoDate,
    BusinessServicesState.grace => l10n.teamServicesGraceText(day(services.worksUntil)),
    BusinessServicesState.off => l10n.teamServicesOffText,
  };
  // A subscription that follows free months: both are said.
  return compedNow && services.subscribed && services.state == BusinessServicesState.active
      ? '${l10n.teamServicesComped(day(comped))} $base'
      : base;
}

/// The team's Business: whether it is on, what it adds, what it costs (an
/// owner on a computer), and where it is seen.
class _ServicesPanel extends StatelessWidget {
  const _ServicesPanel({required this.services, this.price, this.onSee});

  final OrchardBusinessServices services;

  /// What it costs; null where nothing is bought.
  final String? price;

  /// Opens the seats sheet at Business; null where nothing is bought.
  final VoidCallback? onSee;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final line = teamServicesLine(services, l10n);
    final Widget state = switch (services.state) {
      BusinessServicesState.off => Text(
          l10n.teamServicesStateOff,
          key: const ValueKey('team-services-off'),
          style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary),
        ),
      BusinessServicesState.active =>
        _StatePill(key: const ValueKey('team-services-active'), text: l10n.teamServicesStateActive, color: AppColors.v3Success),
      BusinessServicesState.grace =>
        _StatePill(key: const ValueKey('team-services-grace'), text: l10n.teamServicesStateGrace, color: AppColors.v3Warning),
    };
    return TeamCard(
      key: const ValueKey('team-services'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l10n.teamServicesTitle,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                    ),
                    state,
                  ],
                ),
              ),
              if (onSee != null) ...[
                const SizedBox(width: 12),
                teamButton(
                  key: const ValueKey('team-services-see'),
                  icon: LucideIcons.briefcase,
                  label: l10n.teamSeeBusiness,
                  onPressed: onSee,
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l10n.teamServicesAbout,
            style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textPrimary),
          ),
          if (price != null) ...[
            const SizedBox(height: 6),
            Text(
              price!,
              key: const ValueKey('team-services-price'),
              style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textPrimary),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            line,
            key: const ValueKey('team-services-line'),
            style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.color, required this.icon, required this.text});

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textPrimary)),
          ),
        ],
      ),
    );
  }
}

/// The seats could not be read: what went wrong in plain words, trying
/// again, and the details to copy.
class _SeatsError extends StatelessWidget {
  const _SeatsError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('team-seats-error'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.teamSeatsError,
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
        ),
        const SizedBox(height: 4),
        SelectableText(
          orchardErrorMessage(error, l10n),
          style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestColors.textSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('team-seats-retry'),
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refreshCw, size: 14),
              label: Text(l10n.retry),
            ),
            CopyDetailsButton(detail: error.toString(), label: l10n.desktopShellCopyDetails),
          ],
        ),
      ],
    );
  }
}
