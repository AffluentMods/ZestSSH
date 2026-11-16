import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Keeps the tickets on this device current while the app runs.
///
/// There is no push in the app, so it asks: once when the database opens,
/// when the app comes back to the front, and every few minutes while a
/// ticket here is open. A device that holds no ticket never asks anything
/// (the service makes no call then). Each round also sends what was written
/// offline: reports from the report queue, support tickets and follow-ups.
class TicketPoller {
  TicketPoller(
    this._tickets, {
    this.retryReports,
    this.onReplies,
    DateTime Function()? now,
    this.interval = const Duration(minutes: 3),
  }) : _now = now ?? DateTime.now;

  final TicketService _tickets;

  /// Sends the reports still in the report queue.
  final Future<void> Function()? retryReports;

  /// Told about tickets with an answer from support that is new.
  void Function(List<SupportTicketRow> replies)? onReplies;

  final DateTime Function() _now;

  /// How often it asks while a ticket is open and the app is in front.
  final Duration interval;

  /// Coming back to the front again and again asks at most this often.
  static const Duration minGap = Duration(seconds: 45);

  /// The report queue is tried again at most this often while the app runs
  /// (every try is a request per waiting report).
  static const Duration reportRetryGap = Duration(minutes: 15);

  Timer? _timer;
  bool _busy = false;
  bool _inFront = true;
  DateTime? _lastCheck;
  DateTime? _lastReportRetry;

  bool get running => _timer != null;

  /// The database is open: send what waits, ask how the tickets stand, and
  /// keep asking.
  void start() {
    stop();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
    unawaited(check(force: true));
  }

  /// The database is closed (the app locked): nothing may touch it.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void onBackground() => _inFront = false;

  void onForeground() {
    _inFront = true;
    if (running) unawaited(check());
  }

  Future<void> _tick() async {
    if (!_inFront) return;
    try {
      // Between a launch and a return to the front, only an open ticket or
      // something still to send is worth a call.
      if (!await _tickets.hasOpenTickets() && !await _tickets.hasWaiting()) {
        return;
      }
    } catch (_) {
      return;
    }
    await check();
  }

  /// One round. [force] skips the gap between rounds (a launch, or the
  /// person opening My tickets). Never throws.
  Future<void> check({bool force = false}) async {
    if (_busy) return;
    final now = _now();
    final last = _lastCheck;
    if (!force && last != null && now.difference(last) < minGap) return;
    _busy = true;
    _lastCheck = now;
    try {
      final reports = retryReports;
      final lastReports = _lastReportRetry;
      if (reports != null &&
          (lastReports == null ||
              now.difference(lastReports) >= reportRetryGap)) {
        _lastReportRetry = now;
        await reports();
      }
      if (await _tickets.hasWaiting()) await _tickets.retryPending();
      final result = await _tickets.refresh();
      if (result.replies.isNotEmpty) onReplies?.call(result.replies);
    } catch (e) {
      AppLogger.warning('Ticket check failed: ${errorKind(e)}');
    } finally {
      _busy = false;
    }
  }
}

/// The one poller. `app.dart` starts it when the database opens, stops it
/// when it closes, and sets what happens on an answer.
final ticketPollerProvider = Provider<TicketPoller>((ref) {
  final poller = TicketPoller(
    ref.watch(ticketServiceProvider),
    retryReports: () async {
      await ref.read(feedbackServiceProvider).retryQueued();
    },
  );
  ref.onDispose(poller.stop);
  return poller;
});
