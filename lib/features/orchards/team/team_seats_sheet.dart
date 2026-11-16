import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/billing/seat_purchase_watch.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_sync_offer.dart' show offerTeamSync;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/time_text.dart';

// Buying seats from inside ZestSSH on a computer (before,
// Buy seats opened the website, which made them sign in again). The sheet
// keeps to the website's page and what the server holds a team to
// (OrchardBilling): the price, how many may be bought, by card or by invoice,
// Business, billing, a code. No card is ever typed here: a card payment, a
// subscription and billing open Stripe's own pages in the browser. Nothing is
// bought, or pointed to, on a phone or tablet.

/// Opens the seats sheet of [orchardId] on a computer: with [need], ready to
/// buy that many; with [atBusiness], at its Business. Nothing on a phone or
/// tablet. Once seats came while it was open, a device with sync off is told
/// that the team includes it.
Future<void> openSeatsSheet(BuildContext context, WidgetRef ref, String orchardId,
    {int? need, bool atBusiness = false}) async {
  if (!ref.read(billingOnThisDeviceProvider)) return;
  var arrived = false;
  // What came in once is said once: not again the next time this opens.
  ref.read(billingArrivalProvider(orchardId).notifier).state = null;
  final sheet = GlobalKey<_SeatsSheetState>();
  await showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    barrierDismissible: false,
    // Not while something is under way: what comes of it is said here.
    onDismissAttempt: () async => !(sheet.currentState?.doing ?? false),
    child: SeatsSheet(
        key: sheet, orchardId: orchardId, need: need, atBusiness: atBusiness, onSeatsArrived: () => arrived = true),
  );
  if (arrived && context.mounted) await offerTeamSync(context, ref, orchardId, owner: true);
}

/// A price in dollars as the language writes it, cents only where there are
/// some.
String _money(int cents, AppLocalizations l10n) => NumberFormat.simpleCurrency(
      locale: l10n.localeName,
      name: 'USD',
      decimalDigits: cents % 100 == 0 ? 0 : 2,
    ).format(cents / 100);

/// A count as the language writes it (1,000).
String _count(int n, AppLocalizations l10n) => NumberFormat.decimalPattern(l10n.localeName).format(n);

/// What is said of a purchase ZestSSH Cloud did not take, or could not be
/// asked for: what to do next, in the person's language. [billing] for the
/// numbers it does not say.
String seatPurchaseProblem(Object error, AppLocalizations l10n, {OrchardBilling? billing}) {
  if (error is OrchardServerException) {
    final refused = error is SeatPurchaseRefused ? error : null;
    final min = billing?.teamMinSeats ?? kTeamMinSeats;
    final max = billing?.teamMaxSeats ?? kTeamMaxSeats;
    switch (error.code) {
      case 'owners-only':
        return l10n.teamSeatsAskOwner;
      case 'seats-maximum':
        return l10n.seatsSheetTooMany;
      case 'seats-minimum':
        return l10n.seatsSheetAtLeast(refused?.minimum ?? min, min);
      case 'business-needed-for-seats':
        return l10n.seatsSheetNeedsBusiness(refused?.maximum ?? max);
      case 'seats-waiting':
        final waiting = refused?.waiting ?? 0;
        final until = refused?.waitingUntil;
        final first = refused?.waitingOnInvoice == true
            ? (until == null
                ? l10n.seatsSheetWaitingInvoice(waiting)
                : l10n.seatsSheetWaitingInvoiceDue(waiting, DateFormat.yMMMd(l10n.localeName).format(until.toLocal())))
            : l10n.seatsSheetWaitingCheckout(waiting);
        final more = refused?.canBuy ?? 0;
        return '$first ${more <= 0 ? l10n.seatsSheetCanBuyNone : l10n.seatsSheetCanBuy(more)}';
      case 'seats-first':
        return l10n.seatsSheetSeatsFirst(min);
      case 'business-services-exists':
        return l10n.seatsSheetBusinessExists;
      case 'no-billing':
        return l10n.seatsSheetNoBilling;
      case 'billing-unavailable':
        return l10n.seatsSheetUnavailable;
      case 'invoice-address':
        return l10n.seatsSheetInvoiceAddress;
      case 'invoice-open':
        return l10n.seatsSheetInvoiceOpen;
      case 'not-stripe':
        return l10n.seatsSheetNotStripe;
      case 'invalid-request':
        if (billing != null) return l10n.seatsSheetChooseBetween(billing.seatsMinimum, billing.seatsMaximum);
    }
  }
  return orchardChangeErrorMessage(error, l10n);
}

/// A purchase order number as ZestSSH Cloud takes one (the route's PO_NUMBER).
final _poNumber = RegExp(r'^[A-Za-z0-9 ._/#-]{1,40}$');

/// An address as ZestSSH Cloud takes one for an invoice (INVOICE_EMAIL).
final _invoiceAddress = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

class SeatsSheet extends ConsumerStatefulWidget {
  const SeatsSheet({super.key, required this.orchardId, this.need, this.atBusiness = false, this.onSeatsArrived});

  final String orchardId;

  /// What an invitation said it needs.
  final int? need;

  /// Opens at Business (the Seats page's See Business).
  final bool atBusiness;

  final VoidCallback? onSeatsArrived;

  @override
  ConsumerState<SeatsSheet> createState() => _SeatsSheetState();
}

/// What is under way: only one at a time.
enum _Doing { card, invoice, business, portal, check }

class _SeatsSheetState extends ConsumerState<SeatsSheet> {
  int? _picked;
  _Doing? _doing;

  /// Something is under way: nothing closes this meanwhile.
  bool get doing => _doing != null;

  /// What the last action failed with, shown at the top with its details.
  ({String said, Object cause})? _failure;

  /// A check that found nothing yet.
  bool _notYet = false;

  bool _invoiceOpen = false;
  final _invoiceTo = TextEditingController();
  final _invoicePo = TextEditingController();
  String? _toProblem;
  String? _poProblem;
  SeatInvoice? _sent;

  bool _yearly = true;
  final _business = GlobalKey();

  /// The top of the sheet, where what happened is said.
  final _top = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.atBusiness) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBusiness());
    }
  }

  @override
  void dispose() {
    _invoiceTo.dispose();
    _invoicePo.dispose();
    super.dispose();
  }

  /// The seats are read after this opens: Business comes into view once it
  /// is there.
  void _scrollToBusiness({int tries = 8}) {
    if (!mounted) return;
    final at = _business.currentContext;
    if (at != null) {
      unawaited(Scrollable.ensureVisible(at, duration: const Duration(milliseconds: 180), alignment: 0.05));
    } else if (tries > 0) {
      Timer(const Duration(milliseconds: 150), () => _scrollToBusiness(tries: tries - 1));
    }
  }

  /// Brings the top of the sheet into view once it is drawn: the button that
  /// led here may be far down it.
  void _showTop() => WidgetsBinding.instance.addPostFrameCallback((_) {
        final at = _top.currentContext;
        if (mounted && at != null) {
          unawaited(Scrollable.ensureVisible(at, duration: const Duration(milliseconds: 180)));
        }
      });

  /// Runs [action] with the sheet busy: what it throws is said at the top.
  Future<void> _run(_Doing doing, AppLocalizations l10n, OrchardBilling billing, Future<void> Function() action) async {
    if (_doing != null) return;
    setState(() {
      _doing = doing;
      _failure = null;
      _notYet = false;
    });
    try {
      await action();
    } catch (e) {
      AppLogger.warning('Seats: not done ($e)');
      if (mounted) {
        setState(() => _failure = (said: seatPurchaseProblem(e, l10n, billing: billing), cause: e));
        _showTop();
      }
    } finally {
      if (mounted) setState(() => _doing = null);
    }
  }

  /// Opens [page] in the browser.
  Future<void> _open(Uri page) => ref.read(seatsPageOpenerProvider)(page);

  Future<void> _payByCard(AppLocalizations l10n, OrchardBilling billing, int quantity) async {
    // Read again first: an invoice may have gone out from another device since
    // this sheet read the seats. What stops the read is said, as for the rest.
    OrchardBilling? read;
    await _run(_Doing.card, l10n, billing, () async {
      read = await ref.read(orchardBillingApiProvider).get(widget.orchardId);
    });
    final now = read;
    if (now == null || !mounted) return;
    // An invoice can still be paid, past its due date too: paying by card as
    // well is the person's choice, and said before it is made.
    final invoice = now.held.where((h) => h.invoice).firstOrNull;
    if (invoice != null) {
      if (!billing.held.any((h) => h.invoice)) ref.invalidate(orchardBillingProvider(widget.orchardId));
      final sure = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.warning,
        title: l10n.seatsSheetCardWithInvoiceTitle,
        // Paid twice, charged twice: the whole of it warns.
        body: '',
        warning: l10n.seatsSheetCardWithInvoiceBody(invoice.seats, _day(invoice.until, l10n)),
        confirmLabel: l10n.seatsSheetPayCard,
      );
      if (sure != true || !mounted) return;
    }
    await _run(_Doing.card, l10n, billing, () async {
        final page = await ref.read(orchardBillingApiProvider).buySeats(widget.orchardId, quantity);
        ref.read(seatPurchaseWatchProvider).started(
              widget.orchardId,
              BillingWaiting(
                page: page,
                quantity: quantity,
                boughtBefore: now.seats.bought,
                until: DateTime.now().add(kBillingWaitLimit),
              ),
            );
        ref.read(billingArrivalProvider(widget.orchardId).notifier).state = null;
        _showTop();
        await _openOrSay(page, l10n);
      });
  }

  String _day(DateTime at, AppLocalizations l10n) => DateFormat.yMMMd(l10n.localeName).format(at.toLocal());

  /// Opens [page]; a browser that does not open is said, with the panel's
  /// Copy the link beside it.
  Future<void> _openOrSay(Uri page, AppLocalizations l10n) async {
    try {
      await _open(page);
    } catch (e) {
      AppLogger.warning('Seats: the browser did not open');
      if (mounted) {
        setState(() => _failure = (said: l10n.seatsSheetNoBrowser, cause: e));
        _showTop();
      }
    }
  }

  Future<void> _subscribe(AppLocalizations l10n, OrchardBilling billing) => _run(_Doing.business, l10n, billing, () async {
        Uri? page;
        // Starting a subscription wants a recent sign-in (the route's own).
        final done = await withRecentSignIn(context, ref, () async {
          page = await ref.read(orchardBillingApiProvider).subscribeBusiness(widget.orchardId, yearly: _yearly);
        }, summary: (what: l10n.seatsSheetStepUpBusiness, effects: const []));
        final opened = page;
        if (!done || opened == null || !mounted) return;
        ref.read(seatPurchaseWatchProvider).started(
              widget.orchardId,
              BillingWaiting(
                page: opened,
                business: true,
                boughtBefore: billing.seats.bought,
                until: DateTime.now().add(kBillingWaitLimit),
              ),
            );
        ref.read(billingArrivalProvider(widget.orchardId).notifier).state = null;
        _showTop();
        await _openOrSay(opened, l10n);
      });

  Future<void> _openPortal(AppLocalizations l10n, OrchardBilling billing) => _run(_Doing.portal, l10n, billing, () async {
        Uri? page;
        final done = await withRecentSignIn(context, ref, () async {
          page = await ref.read(orchardBillingApiProvider).billingPortal(widget.orchardId);
        }, summary: (what: l10n.seatsSheetStepUpPortal, effects: const []));
        final opened = page;
        if (done && opened != null && mounted) await _openOrSay(opened, l10n);
      });

  Future<void> _sendInvoice(AppLocalizations l10n, OrchardBilling billing, int quantity) async {
    final to = _invoiceTo.text.trim();
    final po = _invoicePo.text.trim();
    final badTo = to.isNotEmpty && (to.length > 254 || !_invoiceAddress.hasMatch(to));
    final badPo = po.isNotEmpty && !_poNumber.hasMatch(po);
    setState(() {
      _toProblem = badTo ? l10n.seatsSheetInvoiceBadAddress : null;
      _poProblem = badPo ? l10n.seatsSheetInvoiceBadPo : null;
    });
    if (badTo || badPo) return;
    await _run(_Doing.invoice, l10n, billing, () async {
      final sent = await ref.read(orchardBillingApiProvider).sendSeatInvoice(
            widget.orchardId,
            quantity,
            email: to.isEmpty ? null : to,
            po: po.isEmpty ? null : po,
          );
      if (mounted) {
        // The server let any card page lapse for it: nothing is left to pay
        // there, and nothing to wait for.
        ref.read(seatPurchaseWatchProvider).forget(widget.orchardId, business: false);
        ref.invalidate(orchardBillingProvider(widget.orchardId));
        setState(() {
          _sent = sent;
          _invoiceOpen = false;
        });
      }
    });
  }

  Future<void> _checkNow(AppLocalizations l10n, OrchardBilling billing) => _run(_Doing.check, l10n, billing, () async {
        // Asked for: what stops it is said, and not taken for nothing yet.
        final came = await ref.read(seatPurchaseWatchProvider).read(widget.orchardId, strict: true);
        if (!came && mounted) setState(() => _notYet = true);
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final read = ref.watch(orchardBillingProvider(widget.orchardId));
    final orchard =
        ref.watch(orchardSummariesProvider).valueOrNull?.where((o) => o.id == widget.orchardId).firstOrNull;
    // What came in while this was open: said here, and the rest follows once
    // it closes.
    ref.listen(billingArrivalProvider(widget.orchardId), (_, came) {
      if (came == null) return;
      if (came.seats > 0) widget.onSeatsArrived?.call();
      if (mounted) {
        setState(() {
          _failure = null;
          _notYet = false;
        });
        _showTop();
      }
    });
    final Widget body = read.when(
      skipLoadingOnRefresh: !read.hasError,
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (error, _) => _NotRead(
        error: error,
        retrying: read.isLoading,
        onRetry: () => ref.invalidate(orchardBillingProvider(widget.orchardId)),
      ),
      data: (billing) => _body(l10n, billing),
    );
    return SeatsFocusRefresh(
      orchardId: widget.orchardId,
      child: ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.info,
        icon: LucideIcons.armchair,
        title: l10n.seatsSheetTitle,
        subtitle: orchard == null ? null : Redactable.account(orchardDisplayName(orchard.name, l10n)).displayIn(ref),
        body: body,
        onClose: doing ? () {} : null,
        secondaryAction: (label: l10n.close, onPressed: doing ? null : () => Navigator.of(context).pop()),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, OrchardBilling billing) {
    if (!billing.isOwner) return _notOwner(l10n, billing);
    final seats = billing.seats;
    final waits = ref.watch(billingWaitingProvider(widget.orchardId));
    final came = ref.watch(billingArrivalProvider(widget.orchardId));
    final max = billing.seatsMaximum;
    final min = billing.seatsMinimum;
    final quantity = max <= 0 ? 0 : (_picked ?? billing.seatsSuggested(widget.need)).clamp(min, max);
    final failure = _failure;
    return Column(
      key: const ValueKey('seats-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(key: _top, height: 0),
        if (came != null) ...[
          TeamCallout(
            key: const ValueKey('seats-sheet-arrived'),
            tone: TeamTone.success,
            icon: LucideIcons.checkCircle2,
            title: [
              if (came.seats > 0) came.paid ? l10n.seatsSheetArrived(came.seats) : l10n.teamSeatsCodeAdded(came.seats),
              if (came.business) l10n.seatsSheetBusinessArrived,
            ].join(' '),
          ),
          const SizedBox(height: 12),
        ],
        if (failure != null) ...[
          _Failure(said: failure.said, cause: failure.cause),
          const SizedBox(height: 12),
        ],
        for (final waiting in waits) ...[
          _WaitingPanel(
            key: ValueKey(waiting.business ? 'seats-sheet-waiting-business' : 'seats-sheet-waiting'),
            waiting: waiting,
            checking: _doing == _Doing.check,
            // One check reads for both: said once.
            notYet: _notYet && identical(waiting, waits.first),
            onOpenAgain: () => _openOrSay(waiting.page, l10n),
            onCheck: () => _checkNow(l10n, billing),
          ),
          const SizedBox(height: 12),
        ],
        _Figures(seats: seats),
        const SizedBox(height: 16),
        _section(
          l10n.teamSeatsBuy,
          child: _buy(l10n, billing, quantity, waits),
        ),
        const SizedBox(height: 18),
        KeyedSubtree(key: _business, child: _section(l10n.teamServicesTitle, child: _businessCard(l10n, billing))),
        const SizedBox(height: 18),
        _section(
          l10n.seatsSheetBillingTitle,
          child: TeamCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.seatsSheetBillingBody, style: _bodyStyle()),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    teamButton(
                      key: const ValueKey('seats-sheet-portal'),
                      label: l10n.seatsSheetManageBilling,
                      icon: LucideIcons.externalLink,
                      busy: _doing == _Doing.portal,
                      onPressed: _doing != null ? null : () => _openPortal(l10n, billing),
                    ),
                    teamButton(
                      key: const ValueKey('seats-sheet-redeem'),
                      label: l10n.settingsMobRedeemCode,
                      icon: LucideIcons.gift,
                      onPressed: _doing != null ? null : () => redeemSeatCodeFor(context, ref, widget.orchardId),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _foot(l10n),
      ],
    );
  }

  /// For someone who is no owner (they became no owner since the sheet was
  /// offered): the figures and how Business stands, and nothing that buys, which
  /// ZestSSH Cloud would refuse.
  Widget _notOwner(AppLocalizations l10n, OrchardBilling billing) => Column(
        key: const ValueKey('seats-sheet-not-owner'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Figures(seats: billing.seats),
          const SizedBox(height: 10),
          Text(l10n.teamSeatsAskOwner, key: const ValueKey('seats-sheet-ask-owner'), style: _bodyStyle()),
          const SizedBox(height: 18),
          _section(
            l10n.teamServicesTitle,
            child: TeamCard(
              key: const ValueKey('seats-sheet-business'),
              child: Text(teamServicesLine(billing.services, l10n),
                  key: const ValueKey('seats-sheet-business-line'), style: _bodyStyle()),
            ),
          ),
        ],
      );

  TextStyle _bodyStyle() => TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary);

  Widget _section(String label, {required Widget child}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestSectionHeader(label: label),
          const SizedBox(height: 8),
          child,
        ],
      );

  Widget _buy(AppLocalizations l10n, OrchardBilling billing, int quantity, List<BillingWaiting> waits) {
    final seatCents = billing.seatPriceCents;
    final min = billing.seatsMinimum;
    final max = billing.seatsMaximum;
    final needed = billing.seatsNeeded(widget.need);
    final sent = _sent;
    final price = l10n.seatsSheetPrice(
      _money(seatCents, l10n),
      _count(billing.teamMinSeats, l10n),
      _count(billing.teamMaxSeats, l10n),
    );
    return TeamCard(
      key: const ValueKey('seats-sheet-buy'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(price, key: const ValueKey('seats-sheet-price'), style: _bodyStyle()),
          if ((widget.need ?? 0) > 0) ...[
            const SizedBox(height: 10),
            TeamCallout(
              key: const ValueKey('seats-sheet-need'),
              tone: TeamTone.info,
              icon: LucideIcons.userPlus,
              title: l10n.seatsSheetNeed(widget.need!),
            ),
          ],
          const SizedBox(height: 12),
          if (max <= 0)
            Text(
              billing.businessOn ? l10n.seatsSheetTooMany : l10n.seatsSheetNeedsBusiness(billing.teamMaxSeats),
              key: const ValueKey('seats-sheet-full'),
              style: _bodyStyle(),
            )
          else ...[
            Wrap(
              spacing: 16,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _SeatStepper(
                  value: quantity,
                  min: min,
                  max: max,
                  enabled: _doing == null,
                  onChanged: (n) => setState(() => _picked = n),
                ),
                Text(
                  l10n.seatsSheetTotal(quantity, _money(seatCents * quantity, l10n)),
                  key: const ValueKey('seats-sheet-total'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // The least, what is needed, and the most: a tap sets it.
            Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Quick(
                  key: const ValueKey('seats-sheet-least'),
                  label: l10n.seatsSheetLeast(min),
                  onTap: _doing != null ? null : () => setState(() => _picked = min),
                ),
                if (needed > 0 && needed != min && needed <= max)
                  _Quick(
                    key: const ValueKey('seats-sheet-needed'),
                    label: l10n.seatsSheetNeeded(needed),
                    onTap: _doing != null ? null : () => setState(() => _picked = needed),
                  ),
                _Quick(
                  key: const ValueKey('seats-sheet-most'),
                  label: l10n.seatsSheetMost(max),
                  onTap: _doing != null ? null : () => setState(() => _picked = max),
                ),
              ],
            ),
            ..._heldLines(l10n, billing, waits),
            if (billing.services.state == BusinessServicesState.active && billing.services.subscribed) ...[
              const SizedBox(height: 10),
              Text(l10n.seatsSheetBuyRaisesBusiness,
                  key: const ValueKey('seats-sheet-raises-business'),
                  style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                teamButton(
                  key: const ValueKey('seats-sheet-card'),
                  label: _doing == _Doing.card ? l10n.seatsSheetOpening : l10n.seatsSheetPayCard,
                  icon: LucideIcons.creditCard,
                  kind: TeamButtonKind.primary,
                  busy: _doing == _Doing.card,
                  onPressed: _doing != null ? null : () => _payByCard(l10n, billing, quantity),
                ),
                teamButton(
                  key: const ValueKey('seats-sheet-invoice'),
                  label: l10n.seatsSheetPayInvoice,
                  icon: LucideIcons.fileText,
                  onPressed: _doing != null
                      ? null
                      : () async {
                          if (_invoiceOpen) return setState(() => _invoiceOpen = false);
                          // An address typed is on screen: asked first while the
                          // screen is recorded.
                          if (!await confirmRevealWhileRecording(context, ref) || !mounted) return;
                          setState(() {
                            _invoiceOpen = true;
                            _sent = null;
                          });
                        },
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (!waits.any((w) => !w.business))
              Text(
                l10n.seatsSheetHoldNote(kSeatCheckoutMinutes),
                key: const ValueKey('seats-sheet-hold'),
                style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary),
              ),
            if (_invoiceOpen) ...[
              const SizedBox(height: 14),
              _invoiceForm(l10n, billing, quantity),
            ],
          ],
          if (sent != null) ...[
            const SizedBox(height: 12),
            _InvoiceSent(sent: sent, onOpen: sent.page == null ? null : () => _openOrSay(sent.page!, l10n)),
          ],
        ],
      ),
    );
  }

  /// What holds seats now, from anywhere: a checkout this device started says
  /// so in its own panel. An invoice past its due date holds nothing any more
  /// and can still be paid, and is said as that.
  List<Widget> _heldLines(AppLocalizations l10n, OrchardBilling billing, List<BillingWaiting> waits) {
    final mine = waits.any((w) => !w.business);
    final lines = [
      for (final h in billing.held)
        if (h.invoice)
          (
            const ValueKey('seats-sheet-held-invoice'),
            h.until.isAfter(DateTime.now())
                ? l10n.seatsSheetHeldByInvoice(h.seats, _day(h.until, l10n))
                : l10n.seatsSheetInvoicePastDue(h.seats, _day(h.until, l10n)),
          )
        else if (!mine)
          (
            const ValueKey('seats-sheet-held-checkout'),
            l10n.seatsSheetHeldByCheckout(h.seats, DateFormat.jm(l10n.localeName).formatPlain(h.until.toLocal())),
          ),
    ];
    return [
      for (final (key, words) in lines) ...[
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LucideIcons.hourglass, size: 14, color: ZestTokens.statusWarning),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(words, key: key, style: _bodyStyle())),
          ],
        ),
      ],
    ];
  }

  Widget _invoiceForm(AppLocalizations l10n, OrchardBilling billing, int quantity) {
    final mine = ref.watch(currentUserProvider)?.email;
    return Container(
      key: const ValueKey('seats-sheet-invoice-form'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.seatsSheetInvoiceBody(quantity, _money(billing.seatPriceCents * quantity, l10n)),
            key: const ValueKey('seats-sheet-invoice-body'),
            style: _bodyStyle(),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l10n.seatsSheetInvoiceTo),
          const SizedBox(height: 4),
          TeamField(
            key: const ValueKey('seats-sheet-invoice-to'),
            controller: _invoiceTo,
            hint: mine == null ? null : Redactable.account(mine).displayIn(ref),
            wrong: _toProblem != null,
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) {
              if (_toProblem != null) setState(() => _toProblem = null);
            },
          ),
          TeamFieldNote(help: l10n.seatsSheetInvoiceToHelp, problem: _toProblem),
          const SizedBox(height: 10),
          _FieldLabel(l10n.seatsSheetInvoicePo),
          const SizedBox(height: 4),
          TeamField(
            key: const ValueKey('seats-sheet-invoice-po'),
            controller: _invoicePo,
            wrong: _poProblem != null,
            onChanged: (_) {
              if (_poProblem != null) setState(() => _poProblem = null);
            },
          ),
          TeamFieldNote(problem: _poProblem),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              teamButton(
                key: const ValueKey('seats-sheet-invoice-send'),
                label: _doing == _Doing.invoice ? l10n.seatsSheetSending : l10n.seatsSheetInvoiceSend,
                icon: LucideIcons.send,
                kind: TeamButtonKind.primary,
                busy: _doing == _Doing.invoice,
                onPressed: _doing != null ? null : () => _sendInvoice(l10n, billing, quantity),
              ),
              teamButton(
                key: const ValueKey('seats-sheet-invoice-cancel'),
                label: l10n.cancel,
                onPressed: _doing != null ? null : () => setState(() => _invoiceOpen = false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _businessCard(AppLocalizations l10n, OrchardBilling billing) {
    final services = billing.services;
    final total = billing.seats.total;
    final perSeat = _yearly ? billing.servicesYearCents : billing.servicesMonthCents;
    final (kind, stateLabel) = switch (services.state) {
      BusinessServicesState.active => (ZestStatusKind.healthy, l10n.teamServicesStateActive),
      BusinessServicesState.grace => (ZestStatusKind.warning, l10n.teamServicesStateGrace),
      BusinessServicesState.off => (ZestStatusKind.neutral, l10n.teamServicesStateOff),
    };
    return TeamCard(
      key: const ValueKey('seats-sheet-business'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ZestStatusPill(key: const ValueKey('seats-sheet-business-state'), kind: kind, label: stateLabel),
          ),
          const SizedBox(height: 8),
          Text(l10n.teamServicesAbout, style: _bodyStyle()),
          if (services.state != BusinessServicesState.off) ...[
            const SizedBox(height: 8),
            Text(teamServicesLine(services, l10n), key: const ValueKey('seats-sheet-business-line'), style: _bodyStyle()),
          ],
          const SizedBox(height: 12),
          if (services.notOver) ...[
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: teamButton(
                key: const ValueKey('seats-sheet-business-manage'),
                label: services.state == BusinessServicesState.grace ? l10n.seatsSheetPayDue : l10n.seatsSheetManageBusiness,
                icon: LucideIcons.externalLink,
                busy: _doing == _Doing.portal,
                onPressed: _doing != null ? null : () => _openPortal(l10n, billing),
              ),
            ),
            const SizedBox(height: 8),
            Text(l10n.seatsSheetBusinessFollows,
                key: const ValueKey('seats-sheet-business-follows'),
                style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
          ] else if (total >= billing.teamMinSeats) ...[
            _IntervalChoice(
              yearly: _yearly,
              yearPrice: l10n.seatsSheetYearPrice(_money(billing.servicesYearCents, l10n)),
              monthPrice: l10n.seatsSheetMonthPrice(_money(billing.servicesMonthCents, l10n)),
              onChanged: (v) => setState(() => _yearly = v),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _yearly
                      ? l10n.seatsSheetBusinessTotalYear(total, _money(perSeat * total, l10n))
                      : l10n.seatsSheetBusinessTotalMonth(total, _money(perSeat * total, l10n)),
                  key: const ValueKey('seats-sheet-business-total'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
                teamButton(
                  key: const ValueKey('seats-sheet-subscribe'),
                  label: _doing == _Doing.business ? l10n.seatsSheetOpening : l10n.seatsSheetSubscribe,
                  icon: LucideIcons.externalLink,
                  kind: TeamButtonKind.primary,
                  busy: _doing == _Doing.business,
                  onPressed: _doing != null ? null : () => _subscribe(l10n, billing),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l10n.seatsSheetBusinessFollows,
                key: const ValueKey('seats-sheet-business-follows'),
                style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
            if (services.graceOwedDays > 0) ...[
              const SizedBox(height: 4),
              Text(l10n.seatsSheetFirstInvoiceGrace(services.graceOwedDays),
                  key: const ValueKey('seats-sheet-first-invoice-grace'),
                  style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
            ],
          ] else
            Text(
              l10n.seatsSheetSeatsFirst(billing.teamMinSeats),
              key: const ValueKey('seats-sheet-seats-first'),
              style: _bodyStyle(),
            ),
        ],
      ),
    );
  }

  Widget _foot(AppLocalizations l10n) {
    final style = TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary);
    Widget link(String key, String label, Uri page) => TextButton(
          key: ValueKey(key),
          onPressed: () => unawaited(_openOrSay(page, l10n)),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            minimumSize: const Size(0, 26),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label, style: const TextStyle(fontSize: 12)),
        );
    return Column(
      key: const ValueKey('seats-sheet-foot'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.seatsSheetFoot, style: style),
        const SizedBox(height: 4),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(l10n.seatsSheetAgree, style: style),
            link('seats-sheet-terms', l10n.settingsDesktopTermsOfService, Uri.parse(kZestTermsUrl)),
            link('seats-sheet-privacy', l10n.settingsDesktopPrivacyPolicy, Uri.parse(kZestPrivacyUrl)),
          ],
        ),
        link('seats-sheet-website', l10n.seatsSheetWebsite, orchardSeatsPage(widget.orchardId, need: widget.need)),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary));
}

/// "3 of 5 seats in use", and how many are open.
class _Figures extends StatelessWidget {
  const _Figures({required this.seats});

  final OrchardSeats seats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${l10n.teamSeatsInUse(seats.used, seats.total)} · ${l10n.teamSeatsOpenCount(seats.free)}',
          key: const ValueKey('seats-sheet-figures'),
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
        ),
        if (seats.over) ...[
          const SizedBox(height: 4),
          Text(l10n.teamSeatsOver,
              key: const ValueKey('seats-sheet-over'),
              style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusWarning)),
        ],
      ],
    );
  }
}

/// A short word that sets the stepper.
class _Quick extends StatelessWidget {
  const _Quick({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          minimumSize: const Size(0, 26),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );
}

/// How many seats: a minus, the number, a plus. A number typed is held to the
/// least and the most at once, and shown as held once the field is left.
class _SeatStepper extends StatefulWidget {
  const _SeatStepper({
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  State<_SeatStepper> createState() => _SeatStepperState();
}

class _SeatStepperState extends State<_SeatStepper> {
  late final _text = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _text.text != '${widget.value}') _text.text = '${widget.value}';
    });
  }

  @override
  void didUpdateWidget(_SeatStepper old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _text.text != '${widget.value}') _text.text = '${widget.value}';
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _step(int by) {
    final next = (widget.value + by).clamp(widget.min, widget.max);
    _text.text = '$next';
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget button(String key, IconData icon, String tip, VoidCallback? onPressed) => SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            key: ValueKey(key),
            tooltip: tip,
            padding: EdgeInsets.zero,
            icon: Icon(icon, size: 16),
            onPressed: onPressed,
          ),
        );
    return Container(
      key: const ValueKey('seats-sheet-stepper'),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button('seats-sheet-minus', LucideIcons.minus, l10n.seatsSheetFewer,
              widget.enabled && widget.value > widget.min ? () => _step(-1) : null),
          SizedBox(
            width: 64,
            child: Semantics(
              label: l10n.seatsSheetStepperLabel,
              child: TextField(
                key: const ValueKey('seats-sheet-count'),
                controller: _text,
                focusNode: _focus,
                enabled: widget.enabled,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: ZestTokens.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (typed) {
                  final n = int.tryParse(typed);
                  if (n != null) widget.onChanged(n.clamp(widget.min, widget.max));
                },
                onSubmitted: (_) => _text.text = '${widget.value}',
              ),
            ),
          ),
          button('seats-sheet-plus', LucideIcons.plus, l10n.seatsSheetMore,
              widget.enabled && widget.value < widget.max ? () => _step(1) : null),
        ],
      ),
    );
  }
}

/// Yearly or monthly, side by side where they fit.
class _IntervalChoice extends StatelessWidget {
  const _IntervalChoice({required this.yearly, required this.yearPrice, required this.monthPrice, required this.onChanged});

  final bool yearly;
  final String yearPrice;
  final String monthPrice;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget choice(String key, bool on, String name, String price, String note, VoidCallback onTap) {
      final brand = ZestTokens.brand;
      return Semantics(
        selected: on,
        button: true,
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: on ? brand.withValues(alpha: 0.08) : ZestTokens.surfaceRaisedAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? brand.withValues(alpha: 0.55) : ZestTokens.borderSubtle),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(on ? LucideIcons.circleDot : LucideIcons.circle,
                      size: 16, color: on ? ZestTokens.brandInk : ZestTokens.textTertiary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      const SizedBox(height: 2),
                      Text(price, style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textPrimary)),
                      Text(note, style: TextStyle(fontSize: 11.5, height: 1.35, color: ZestTokens.textTertiary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final year = choice('seats-sheet-yearly', yearly, l10n.seatsSheetYearly, yearPrice, l10n.seatsSheetYearlyNote, () => onChanged(true));
    final month = choice('seats-sheet-monthly', !yearly, l10n.seatsSheetMonthly, monthPrice, l10n.seatsSheetMonthlyNote, () => onChanged(false));
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < 420
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [year, const SizedBox(height: 8), month])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: year),
              const SizedBox(width: 10),
              Expanded(child: month),
            ]),
    );
  }
}

/// The page is open in the browser: what is held, for how long, and what to
/// do once it is paid.
class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel({
    super.key,
    required this.waiting,
    required this.checking,
    required this.notYet,
    required this.onOpenAgain,
    required this.onCheck,
  });

  final BillingWaiting waiting;
  final bool checking;
  final bool notYet;
  final VoidCallback onOpenAgain;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TeamCallout(
      tone: TeamTone.warning,
      icon: LucideIcons.hourglass,
      title: l10n.seatsSheetWaitingTitle,
      body: waiting.business
          ? l10n.seatsSheetBusinessWaiting
          : '${l10n.seatsSheetHeld(waiting.quantity, kSeatCheckoutMinutes)} ${l10n.seatsSheetComeBack}',
      below: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (notYet) ...[
            Text(l10n.seatsSheetNotYet,
                key: const ValueKey('seats-sheet-not-yet'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              teamButton(
                key: const ValueKey('seats-sheet-check'),
                label: l10n.seatsSheetCheckNow,
                icon: LucideIcons.refreshCw,
                busy: checking,
                onPressed: checking ? null : onCheck,
              ),
              teamButton(
                key: const ValueKey('seats-sheet-open-again'),
                label: l10n.seatsSheetOpenAgain,
                icon: LucideIcons.externalLink,
                onPressed: onOpenAgain,
              ),
              teamButton(
                key: const ValueKey('seats-sheet-copy-link'),
                label: l10n.seatsSheetCopyLink,
                icon: LucideIcons.copy,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: waiting.page.toString()));
                  if (context.mounted) showTopSnackBar(context, l10n.teamAdminValueCopied, isSuccess: true);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// An invoice went out: its number, where to, and Stripe's page for it.
class _InvoiceSent extends ConsumerWidget {
  const _InvoiceSent({required this.sent, this.onOpen});

  final SeatInvoice sent;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return TeamCallout(
      key: const ValueKey('seats-sheet-invoice-sent'),
      tone: TeamTone.success,
      icon: LucideIcons.checkCircle2,
      title: l10n.seatsSheetInvoiceSent(sent.number, Redactable.account(sent.sentTo).displayIn(ref)),
      below: onOpen == null
          ? null
          : teamButton(
              key: const ValueKey('seats-sheet-invoice-page'),
              label: l10n.seatsSheetInvoiceOpenPage,
              icon: LucideIcons.externalLink,
              onPressed: onOpen,
            ),
    );
  }
}

/// A purchase that did not go: what to do next, and the details to copy.
class _Failure extends StatelessWidget {
  const _Failure({required this.said, required this.cause});

  final String said;
  final Object cause;

  @override
  Widget build(BuildContext context) {
    return TeamCallout(
      key: const ValueKey('seats-sheet-failure'),
      tone: TeamTone.critical,
      icon: LucideIcons.alertCircle,
      title: said,
      below: CopyDetailsButton(detail: ErrorReport.build(what: said, where: 'Buying team seats', error: cause)),
    );
  }
}

/// The seats could not be read: said as how ZestSSH Cloud stands, trying
/// again, and the details to copy. Nothing about the team's hosts is touched.
class _NotRead extends StatelessWidget {
  const _NotRead({required this.error, required this.retrying, required this.onRetry});

  final Object error;
  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final said = orchardErrorMessage(error, l10n);
    return Column(
      key: const ValueKey('seats-sheet-not-read'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.teamSeatsError, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
        const SizedBox(height: 4),
        SelectableText(said, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
        const SizedBox(height: 4),
        Text(l10n.seatsSheetHostsStillWork, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            teamButton(
              key: const ValueKey('seats-sheet-retry'),
              label: l10n.retry,
              icon: LucideIcons.refreshCw,
              busy: retrying,
              onPressed: onRetry,
            ),
            CopyDetailsButton(detail: ErrorReport.build(what: said, where: 'Reading team seats', error: error)),
          ],
        ),
      ],
    );
  }
}
