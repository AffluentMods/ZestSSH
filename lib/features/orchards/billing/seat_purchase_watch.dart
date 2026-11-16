import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart' show seatsArrivedProvider;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/utils/logger.dart';

// Paying happens on Stripe's page, in the browser, and ZestSSH Cloud hears of
// it a moment after (the website's seats page waits the same). So a computer
// reads a team's seats again whenever the app comes back to the front, where
// its seats are on screen or a payment was started here, and a few times
// shortly after, as long as it waits for one. A read that fails changes
// nothing on screen, and has nothing to do with connecting to hosts. Seats
// that came another way (a code, another owner) are not the payment: the words
// for a payment are said only for what was paid for.

/// Something opened in the browser to pay for, and not seen paid yet.
class BillingWaiting {
  const BillingWaiting({
    required this.page,
    required this.boughtBefore,
    required this.until,
    this.quantity = 0,
    this.business = false,
  });

  /// The page in the browser: it can be opened again.
  final Uri page;

  /// The seats bought when it opened: at least [quantity] more than these, and
  /// its seats may have come.
  final int boughtBefore;

  /// When to stop waiting: Stripe's page has lapsed by then.
  final DateTime until;

  /// The seats held for it; 0 for Business.
  final int quantity;

  /// Business, not seats.
  final bool business;

  /// Its page has lapsed: nothing is paid on it now, though a payment made at
  /// the last moment may still be heard of.
  bool get pageOver => DateTime.now().isAfter(until.subtract(const Duration(minutes: _kHeardAfterPageMinutes)));
}

/// What came in while waiting: how many seats, Business, or both. [paid]: the
/// seats came while their page could be paid on. After that they may be the
/// payment heard of late or may have come another way, so nothing is said of a
/// payment.
typedef BillingArrival = ({int seats, bool business, bool paid});

/// Whose purchases these are: what one account waits for is nobody else's, so
/// another account signed in here starts with none of it.
final _purchasesOfProvider = Provider<String?>((ref) => ref.watch(currentUserProvider.select((u) => u?.uid)));

/// What [orchardId] waits for in the browser, seats and Business each at most
/// once.
final billingWaitingProvider = StateProvider.family<List<BillingWaiting>, String>((ref, orchardId) {
  ref.watch(_purchasesOfProvider);
  return const [];
});

/// What last came in for [orchardId]; a sheet that is open says so.
final billingArrivalProvider = StateProvider.family<BillingArrival?, String>((ref, orchardId) {
  ref.watch(_purchasesOfProvider);
  return null;
});

/// How long after coming back the seats are read again, as the website's page
/// does: Stripe tells ZestSSH Cloud a moment after it sends the browser back.
const kBillingPollAfterReturn = [Duration(milliseconds: 2500), Duration(seconds: 6), Duration(seconds: 12)];

const _kHeardAfterPageMinutes = 9;

/// How long a checkout is waited for: its page lasts 31 minutes
/// ([kSeatCheckoutMinutes]), and a payment made at the last moment is heard of
/// a little after.
const kBillingWaitLimit = Duration(minutes: kSeatCheckoutMinutes + _kHeardAfterPageMinutes);

/// The one watch of an account's purchases in the browser on this device.
final seatPurchaseWatchProvider = Provider<SeatPurchaseWatch>((ref) {
  ref.watch(_purchasesOfProvider);
  final watch = SeatPurchaseWatch(ref);
  ref.onDispose(watch.dispose);
  return watch;
});

class SeatPurchaseWatch {
  SeatPurchaseWatch(this._ref) {
    _life = AppLifecycleListener(onResume: cameBack);
  }

  final Ref _ref;
  late final AppLifecycleListener _life;

  /// How many things on screen show each team's seats.
  final _shown = <String, int>{};

  /// What each team waits for in the browser, with what ends the wait; and the
  /// reads that follow coming back.
  final _waiting = <({String orchardId, bool business}), Timer>{};
  final _polls = <Timer>[];

  /// A page or sheet with [orchardId]'s seats came on screen.
  void show(String orchardId) => _shown[orchardId] = (_shown[orchardId] ?? 0) + 1;

  /// It went.
  void hide(String orchardId) {
    final n = (_shown[orchardId] ?? 0) - 1;
    if (n <= 0) {
      _shown.remove(orchardId);
    } else {
      _shown[orchardId] = n;
    }
  }

  /// Something of [orchardId]'s was opened in the browser to pay for. It takes
  /// the place of what waits for the same (a new checkout lets the last lapse),
  /// and of nothing else: a Business checkout after seats waits beside them.
  void started(String orchardId, BillingWaiting waiting) {
    final state = _ref.read(billingWaitingProvider(orchardId).notifier);
    state.state = [
      ...state.state.where((w) => w.business != waiting.business),
      waiting,
    ];
    final key = (orchardId: orchardId, business: waiting.business);
    _waiting.remove(key)?.cancel();
    final left = waiting.until.difference(DateTime.now());
    _waiting[key] = Timer(left.isNegative ? Duration.zero : left, () => forget(orchardId, business: waiting.business));
  }

  /// Stops waiting for [orchardId]'s seats or Business: paid, lapsed, or the
  /// person went on.
  void forget(String orchardId, {required bool business}) {
    _waiting.remove((orchardId: orchardId, business: business))?.cancel();
    final state = _ref.read(billingWaitingProvider(orchardId).notifier);
    state.state = [...state.state.where((w) => w.business != business)];
    if (_waiting.isEmpty) _stopPolls();
  }

  void _stopPolls() {
    for (final t in _polls) {
      t.cancel();
    }
    _polls.clear();
  }

  /// The app came to the front.
  void cameBack() {
    for (final id in {..._shown.keys, for (final k in _waiting.keys) k.orchardId}) {
      unawaited(read(id));
    }
    if (_waiting.isEmpty) return;
    _stopPolls();
    for (final after in kBillingPollAfterReturn) {
      _polls.add(Timer(after, () {
        for (final id in {for (final k in _waiting.keys) k.orchardId}) {
          unawaited(read(id));
        }
      }));
    }
  }

  /// Reads [orchardId]'s seats: where they changed they are shown, and what it
  /// waited for is said once it came. True where it came. A failure (ZestSSH
  /// Cloud down, this device offline) changes nothing, and is thrown only where
  /// the person asked for this ([strict]). Seats that rose by less than were
  /// paid for, or while the checkout still holds its own, came another way (a
  /// code): shown, and the wait goes on.
  Future<bool> read(String orchardId, {bool strict = false}) async {
    final OrchardBilling fresh;
    try {
      fresh = await _ref.read(orchardBillingApiProvider).get(orchardId);
    } catch (e) {
      AppLogger.info('Seats: not read again ($e)');
      if (strict) rethrow;
      return false;
    }
    var seats = 0;
    var business = false;
    var paid = true;
    for (final waiting in _ref.read(billingWaitingProvider(orchardId))) {
      if (waiting.business) {
        // A subscription that is going: not the grace of one that is over, nor
        // free months from a code, with which Subscribe is on offer too.
        if (fresh.services.notOver && fresh.services.state != BusinessServicesState.off) {
          business = true;
          forget(orchardId, business: true);
        }
      } else if (fresh.seats.bought - waiting.boughtBefore >= waiting.quantity &&
          !fresh.held.any((h) => !h.invoice && h.seats == waiting.quantity)) {
        seats = waiting.quantity;
        paid = !waiting.pageOver;
        forget(orchardId, business: false);
      }
    }
    if (seats > 0 || business) {
      _ref.invalidate(orchardBillingProvider(orchardId));
      if (seats > 0) _ref.read(seatsArrivedProvider)();
      _ref.read(billingArrivalProvider(orchardId).notifier).state = (seats: seats, business: business, paid: paid);
      // Nothing of this team's on screen to say it: a notice.
      if (!_shown.containsKey(orchardId)) _tell(orchardId, seats, business, paid);
      return true;
    }
    if (_shown.containsKey(orchardId)) {
      final now = _ref.read(orchardBillingProvider(orchardId));
      final was = now.valueOrNull;
      if (now.hasError || was == null || _keyOf(was) != _keyOf(fresh)) {
        _ref.invalidate(orchardBillingProvider(orchardId));
      }
    }
    return false;
  }

  void _tell(String orchardId, int seats, bool business, bool paid) {
    final l10n = gl10n;
    _ref.read(notificationCenterProvider.notifier).show(AppNotification(
          id: 'billing-arrived-$orchardId',
          title: seats > 0
              ? (paid ? l10n.seatsSheetArrived(seats) : l10n.teamSeatsCodeAdded(seats))
              : l10n.seatsSheetBusinessArrived,
          body: seats > 0 && business ? l10n.seatsSheetBusinessArrived : null,
          severity: NotificationSeverity.success,
        ));
  }

  /// What a change of is worth showing: the figures, how Business stands, and
  /// what holds seats.
  static String _keyOf(OrchardBilling b) => [
        b.seats.bought,
        b.seats.included,
        b.seats.total,
        b.seats.used,
        b.seats.free,
        b.seats.over,
        b.services.state.name,
        b.services.status,
        b.services.quantity,
        b.services.yearly,
        b.services.paidThrough,
        b.services.endsAtPeriodEnd,
        b.services.compedUntil,
        for (final h in b.held) '${h.seats}:${h.invoice}:${h.until}',
      ].join('|');

  void dispose() {
    _life.dispose();
    for (final t in _waiting.values) {
      t.cancel();
    }
    _waiting.clear();
    _stopPolls();
  }
}

/// Keeps a team's seats up to date for as long as it is on screen: the watch
/// reads them again when the app comes back to the front.
class SeatsFocusRefresh extends ConsumerStatefulWidget {
  const SeatsFocusRefresh({super.key, required this.orchardId, required this.child});

  final String orchardId;
  final Widget child;

  @override
  ConsumerState<SeatsFocusRefresh> createState() => _SeatsFocusRefreshState();
}

class _SeatsFocusRefreshState extends ConsumerState<SeatsFocusRefresh> {
  late final SeatPurchaseWatch _watch = ref.read(seatPurchaseWatchProvider);

  @override
  void initState() {
    super.initState();
    _watch.show(widget.orchardId);
  }

  @override
  void didUpdateWidget(SeatsFocusRefresh old) {
    super.didUpdateWidget(old);
    if (old.orchardId != widget.orchardId) {
      _watch.hide(old.orchardId);
      _watch.show(widget.orchardId);
    }
  }

  @override
  void dispose() {
    _watch.hide(widget.orchardId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
