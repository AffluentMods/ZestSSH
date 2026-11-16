import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart' show FeedbackLimits;
import 'package:zestssh/features/tickets/support_diagnostics.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart' show ScreenshotCapture;
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/help_form_parts.dart';
import 'package:zestssh/ui/screens/help/support_hub_parts.dart';
import 'package:zestssh/ui/screens/help/ticket_actions.dart';
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/recording_masked_controller.dart';

/// One ticket (tickets handoff, section 3): what was sent, the answers from
/// support, and a box to write back.
///
/// The conversation is read from the server when the page opens and every
/// 45 seconds while it stays open and the app is in front; what was read
/// last is kept on the device, so the page still shows it with no network.
/// A follow-up written with no network waits in the conversation, marked as
/// waiting, until it is sent.
///
/// An answer counts as read when it has been on screen with the app in
/// front. While the window is behind another one the page neither asks nor
/// marks anything, so an answer that arrives then is still announced.
///
/// Who can read what is said plainly on the page: a support ticket is private
/// to the person and the staff; a bug report or a suggestion is a public
/// forum post, and so is every reply to it.
class TicketDetailScreen extends ConsumerStatefulWidget {
  const TicketDetailScreen({
    super.key,
    required this.nonce,
    this.embedded = false,
    this.hub = false,
    this.captureScreenshot,
    required this.onLeave,
    required this.onNewTicket,
  });

  /// The ticket, by the nonce it was sent with.
  final String nonce;
  final bool embedded;

  /// In the Support Hub (with [embedded]):
  /// its head, messages with their avatars and what was attached, and
  /// a composer with a fresh redacted screenshot, fresh diagnostics, "Fixed
  /// now, close it" and Send. What is read and sent is this page's, the same
  /// as everywhere else.
  final bool hub;

  /// The hub's picture of the app without the hub over it; null where none
  /// can be taken, and the composer offers none.
  final ScreenshotCapture? captureScreenshot;

  /// The ticket is no longer on this device (it was removed): go back.
  final VoidCallback onLeave;

  /// "New ticket", offered on a ticket that takes no more replies.
  final VoidCallback onNewTicket;

  @override
  ConsumerState<TicketDetailScreen> createState() =>
      _TicketDetailScreenState();
}

class _TicketDetailScreenState extends ConsumerState<TicketDetailScreen>
    with WidgetsBindingObserver {
  // (While the screen is recorded it draws as bullets.)
  final _reply = RecordingMaskedController();
  final _replyFocus = FocusNode();
  final _scroll = ScrollController();
  Timer? _timer;

  /// The service this page last told it is on screen, to tell it when it is
  /// not any more (the provider cannot be read while the page is going).
  TicketService? _toldViewing;

  bool _reading = false;
  bool _sending = false;
  bool _working = false;

  /// The last read did not reach the server.
  bool _stale = false;

  /// What stopped that read, for saying why.
  Object? _stopped;

  /// What happened to the last reply, said under the box.
  String? _notice;

  /// The last reply was refused for its screenshot or diagnostics, not its
  /// words: Send without them is offered under the box.
  bool _refusedForAttachments = false;

  /// What goes with the next reply in the hub (3.4): a fresh redacted
  /// screenshot, and whether fresh diagnostics go too.
  Uint8List? _shot;
  bool _capturing = false;
  bool _withDiagnostics = false;
  bool _closingFixed = false;

  /// How many entries the conversation had when it was last drawn, to bring
  /// a new one into view.
  int _shown = -1;

  static const Duration _readEvery = Duration(seconds: 45);

  /// The app is the window in front.
  bool get _inFront {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reply.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _read());
    _timer =
        Timer.periodic(_readEvery, (_) => unawaited(_read(quiet: true)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _tellViewing(null);
    _reply.dispose();
    _replyFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_read(quiet: true));
    } else {
      // Not in front: an answer that arrives now has not been seen.
      _tellViewing(null);
    }
  }

  /// Tells [service] this ticket is on screen (an answer on it is read here,
  /// so it is not announced as well), or, with null, that it no longer is.
  void _tellViewing(TicketService? service) {
    final told = _toldViewing;
    if (told != null && told != service && told.viewing == widget.nonce) {
      told.viewing = null;
    }
    service?.viewing = widget.nonce;
    _toldViewing = service;
  }

  /// Reads the conversation and marks it read. [quiet] is the timed check:
  /// it only asks while the ticket can still change, and shows no spinner.
  /// Nothing is asked, and nothing marked, while the app is not in front.
  /// Never throws: the database closes under the page when the app locks.
  Future<void> _read({bool quiet = false}) async {
    if (_reading || !mounted || !_inFront) return;
    var reached = false;
    Object? stopped;
    try {
      if (!ref.read(dbReadyProvider)) return;
      final service = ref.read(ticketServiceProvider);
      _tellViewing(service);
      final row = await service.ticket(widget.nonce);
      if (row == null || !row.isSent) return;
      if (quiet && !row.isOpen) {
        // Closed or gone: nothing new will come, but what is here was seen.
        await service.markSeen(widget.nonce);
        return;
      }
      _reading = true;
      reached = await service.open(widget.nonce);
      if (!reached) stopped = service.readStopped;
    } catch (e) {
      reached = false;
      stopped = e;
    } finally {
      _reading = false;
    }
    if (!mounted) return;
    setState(() {
      _stale = !reached;
      _stopped = stopped;
    });
  }

  /// The service, for something the person just asked for. Null while the
  /// app is locked.
  TicketService? get _service =>
      ref.read(dbReadyProvider) ? ref.read(ticketServiceProvider) : null;

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _reply.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _notice = null;
      _refusedForAttachments = false;
    });
    final service = _service;
    String? diagnostics;
    if (widget.hub && _withDiagnostics) {
      final facts = await collectFeedbackContext(context, ref);
      if (!mounted) return;
      if (facts != null) diagnostics = supportDiagnostics(facts.$1);
    }
    final result = service == null
        ? const TicketSendResult(TicketSendOutcome.queued)
        : await service.reply(widget.nonce, text,
            screenshot: widget.hub ? _shot : null, diagnostics: diagnostics);
    if (!mounted) return;
    if (service == null) {
      // Locked under the page: nothing was sent, the text stays in the box.
      setState(() {
        _sending = false;
        _notice = l10n.ticketReplyFailed;
      });
      return;
    }
    setState(() {
      _sending = false;
      if (result.attachments case final why?) {
        // The words can go without what was attached: offered, and kept.
        _notice = attachmentsRefusalSaid(l10n, why, result.retryMinutes);
        _refusedForAttachments = true;
        return;
      }
      switch (result.outcome) {
        case TicketSendOutcome.sent:
          _reply.clear();
          _shot = null;
          _withDiagnostics = false;
        case TicketSendOutcome.queued:
          _reply.clear();
          _shot = null;
          _withDiagnostics = false;
          _notice = result.leftBehind ? l10n.supportHubReplyQueuedWithout : l10n.ticketReplyQueued;
        case TicketSendOutcome.rateLimited:
          _notice = l10n.ticketReplyRateLimited(result.retryMinutes ?? 60);
        case TicketSendOutcome.tooManyWaiting:
          _notice = l10n.ticketReplyTooManyWaiting;
        case TicketSendOutcome.closed:
        case TicketSendOutcome.gone:
          // The page now says the ticket takes no more; the text stays in
          // the box so it can be copied.
          _notice = null;
        case TicketSendOutcome.blocked:
        case TicketSendOutcome.needsSignIn:
        case TicketSendOutcome.rejected:
          _notice = l10n.ticketReplyFailed;
      }
    });
  }

  /// Brings the end of the conversation into view: at once when the page
  /// opens ([jump]), with a short slide when an entry is added.
  void _toEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(end,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut);
      }
    });
  }

  Future<void> _tryNow() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await _service?.retryPending();
    } catch (_) {/* stays waiting */}
    if (mounted) setState(() => _working = false);
  }

  /// A ticket the server refused, once more because the person asked.
  Future<void> _retryRefused() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final service = _service;
      if (service != null && await service.retryRefused(widget.nonce)) {
        await service.retryPending();
      }
    } catch (_) {/* stays as it was */}
    if (mounted) setState(() => _working = false);
  }

  Future<void> _sendWithoutAccount() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final service = _service;
      if (service != null &&
          await service.retryWithoutAccount(widget.nonce)) {
        await service.retryPending();
      }
    } catch (_) {/* stays as it was */}
    if (mounted) setState(() => _working = false);
  }

  /// Send the reply again without its screenshot and diagnostics.
  Future<void> _sendWithoutAttachments() async {
    setState(() {
      _shot = null;
      _withDiagnostics = false;
      _refusedForAttachments = false;
    });
    await _send();
  }

  Future<void> _copy(String text) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showTopSnackBar(context, l10n.ticketCopied, isSuccess: true);
  }

  /// A fresh redacted screenshot for the next reply: the person's choice,
  /// taken redacted, shown before it goes, and taken back with its x.
  Future<void> _captureShot() async {
    final capture = widget.captureScreenshot;
    if (capture == null || _capturing) return;
    setState(() => _capturing = true);
    Uint8List? png;
    try {
      png = await capture(redacted: true);
    } catch (_) {
      png = null;
    }
    if (!mounted) return;
    // No larger than a new report's, which the server takes (a 3.4
    // security review).
    if (png != null && png.length > FeedbackLimits.screenshotMaxBytes) png = null;
    setState(() {
      _capturing = false;
      if (png != null) _shot = png;
    });
    if (png == null) {
      showTopSnackBar(context, AppLocalizations.of(context)!.recModeCopyScreenshotFailed, isError: true);
    }
  }

  /// "Fixed now, close it": closed, saying why, without asking first.
  Future<void> _closeFixed() async {
    final l10n = AppLocalizations.of(context)!;
    final service = _service;
    if (service == null || _closingFixed) return;
    setState(() => _closingFixed = true);
    final ok = await service.close(widget.nonce, fixed: true);
    if (!mounted) return;
    setState(() => _closingFixed = false);
    showTopSnackBar(context, ok ? l10n.supportHubClosedFixedSaid : l10n.ticketCloseFailed,
        isSuccess: ok, isError: !ok);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.maskWhileRecording([_reply]);
    final row = ref.watch(ticketProvider(widget.nonce));
    final waiting =
        ref.watch(ticketOutboxProvider(widget.nonce)).valueOrNull ?? const [];
    // An answer found by the background check while this page is open: read
    // it now.
    ref.listen(ticketProvider(widget.nonce), (prev, next) {
      final was = prev?.valueOrNull?.lastMessageId;
      final now = next.valueOrNull?.lastMessageId;
      if (now != null && now != was) {
        final known = next.valueOrNull?.cachedConversation?.messages
                .any((m) => m.id == now) ??
            false;
        if (!known) unawaited(_read(quiet: true));
      }
    });

    final t = row.valueOrNull;
    if (t != null) {
      final entries =
          (t.cachedConversation?.messages.length ?? 0) + waiting.length;
      if (entries != _shown) {
        final first = _shown < 0;
        _shown = entries;
        if (entries > 0) _toEnd(jump: first);
      }
    }
    final Widget body;
    if (t == null) {
      body = row.isLoading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.ticketNotHere,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: AppColors.v3TextSecondary)),
              ),
            );
    } else if (widget.hub) {
      body = LayoutBuilder(
        builder: (context, box) {
          final head = HubTicketHead(ticket: t, onRemoved: widget.onLeave);
          // In a short window the head goes up with the conversation, or the
          // conversation is left a slit between it and the reply box.
          final short = box.maxHeight < 560;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!short) head,
              Expanded(
                child: ListView(
                  key: const ValueKey('hub-thread'),
                  controller: _scroll,
                  children: [
                    if (short) head,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_stale) ...[
                            HelpNoticeLine(
                                icon: LucideIcons.wifiOff,
                                text: ticketsStaleText(l10n, _stopped)),
                            const SizedBox(height: 14),
                          ],
                          ..._hubConversation(l10n, t, waiting),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
                ),
                child: _bottom(l10n, t),
              ),
            ],
          );
        },
      );
    } else {
      body = Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                _Header(ticket: t),
                if (_stale) ...[
                  const SizedBox(height: 10),
                  HelpNoticeLine(
                      icon: LucideIcons.wifiOff,
                      text: ticketsStaleText(l10n, _stopped)),
                ],
                const SizedBox(height: 14),
                ..._conversation(context, l10n, t, waiting),
              ],
            ),
          ),
          Container(
            // The whole width whatever it holds: a short notice must not
            // shrink the bar and its hairline to the width of its text.
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
            ),
            child: _bottom(l10n, t),
          ),
        ],
      );
    }

    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(t == null
            ? l10n.ticketsTitle
            : ticketDetailTitle(l10n, t)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TicketMenuButton(nonce: widget.nonce, onRemoved: widget.onLeave),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: body,
          ),
        ),
      ),
    );
  }

  List<Widget> _conversation(BuildContext context, AppLocalizations l10n,
      SupportTicketRow t, List<TicketOutboxRow> waiting) {
    final c = t.cachedConversation;
    final opened = DateTime.fromMillisecondsSinceEpoch(t.createdAt);
    return [
      _Bubble(
        mine: true,
        who: l10n.ticketYou,
        when: opened,
        text: c?.body ?? '',
        extraLabel: c?.expected == null ? null : l10n.reportBugWhatExpected,
        extra: c?.expected,
      ),
      for (final m in c?.messages ?? const <TicketMessage>[])
        _Bubble(
          mine: !m.fromStaff,
          who: m.fromStaff
              ? (m.staffName == null
                  ? l10n.ticketSupportName
                  : '${m.staffName} · ${l10n.ticketSupportName}')
              : l10n.ticketYou,
          when: m.at.toLocal(),
          text: m.body,
        ),
      for (final w in waiting)
        _Bubble(
          mine: true,
          who: l10n.ticketYou,
          when: DateTime.fromMillisecondsSinceEpoch(w.createdAt),
          text: w.body,
          state: switch (w.error) {
            null => l10n.ticketStatusWaiting,
            'closed' => l10n.ticketReplyNotSentClosed,
            'gone' => l10n.ticketReplyNotSentGone,
            _ => l10n.ticketReplyNotSent,
          },
          failed: w.error != null,
          actions: [
            if (w.error != null)
              TextButton(
                onPressed: () => _copy(w.body),
                child: Text(l10n.copy, style: const TextStyle(fontSize: 12)),
              ),
            TextButton(
              onPressed: () => _service?.discardFollowUp(w.nonce),
              child: Text(l10n.delete, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
    ];
  }

  /// The conversation as the hub draws it: an avatar and a name for each,
  /// what the person attached under their words, when support took it up,
  /// and, while it waits on the person, when it closes by itself.
  List<Widget> _hubConversation(
      AppLocalizations l10n, SupportTicketRow t, List<TicketOutboxRow> waiting) {
    final c = t.cachedConversation;
    final messages = c?.messages ?? const <TicketMessage>[];
    final picked = t.standing.pickedUpAt?.toLocal();
    // Said where it happened: before the first word written after it.
    var pickedAt = messages.length;
    if (picked != null) {
      for (var i = 0; i < messages.length; i++) {
        if (messages[i].at.toLocal().isAfter(picked)) {
          pickedAt = i;
          break;
        }
      }
    }
    final pickedLine = picked == null
        ? null
        : HubEventLine(
            key: const ValueKey('hub-picked-up'),
            icon: LucideIcons.check,
            text: l10n.supportHubPickedUp(ticketStamp(context, picked)),
          );
    final quiet = t.isOpen && t.awaiting == 'user' && (t.isPrivate || t.standing.votes == 0);
    return [
      HubMessage(
        who: l10n.ticketYou,
        when: DateTime.fromMillisecondsSinceEpoch(t.createdAt),
        text: c?.body ?? '',
        extraLabel: c?.expected == null ? null : l10n.reportBugWhatExpected,
        extra: c?.expected,
        attachments: (c?.hasScreenshot ?? false) || c?.diagnostics != null
            ? HubAttachments(nonce: t.nonce, hasScreenshot: c?.hasScreenshot ?? false, diagnostics: c?.diagnostics)
            : null,
      ),
      for (var i = 0; i < messages.length; i++) ...[
        if (i == pickedAt) ?pickedLine,
        HubMessage(
          who: messages[i].fromStaff ? (messages[i].staffName ?? l10n.ticketSupportName) : l10n.ticketYou,
          fromSupport: messages[i].fromStaff,
          when: messages[i].at.toLocal(),
          text: messages[i].body,
          attachments: messages[i].hasScreenshot || messages[i].diagnostics != null
              ? HubAttachments(
                  nonce: t.nonce,
                  messageId: messages[i].id,
                  hasScreenshot: messages[i].hasScreenshot,
                  diagnostics: messages[i].diagnostics,
                )
              : null,
        ),
      ],
      if (pickedAt == messages.length) ?pickedLine,
      if (quiet)
        HubEventLine(
          key: const ValueKey('hub-quiet-close'),
          icon: LucideIcons.clock,
          text: l10n.supportHubWaitingOnYou14,
        ),
      for (final w in waiting)
        HubMessage(
          who: l10n.ticketYou,
          when: DateTime.fromMillisecondsSinceEpoch(w.createdAt),
          text: w.body,
          state: switch (w.error) {
            null => l10n.ticketStatusWaiting,
            'closed' => l10n.ticketReplyNotSentClosed,
            'gone' => l10n.ticketReplyNotSentGone,
            _ => l10n.ticketReplyNotSent,
          },
          failed: w.error != null,
          actions: [
            if (w.error != null)
              TextButton(
                onPressed: () => _copy(w.body),
                child: Text(l10n.copy, style: const TextStyle(fontSize: 12)),
              ),
            TextButton(
              onPressed: () => _service?.discardFollowUp(w.nonce),
              child: Text(l10n.delete, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
    ];
  }

  /// The hub's reply box: the box, and
  /// under it a fresh redacted screenshot, fresh diagnostics, "Fixed now, close
  /// it" and Send. Ctrl+Enter (Cmd on a Mac) sends.
  Widget _hubComposer(AppLocalizations l10n, SupportTicketRow t) {
    final keys = Platform.isMacOS ? 'Cmd+Enter' : 'Ctrl+Enter';
    void send() {
      if (!_sending && _reply.text.trim().isNotEmpty) unawaited(_send());
    }

    final small = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: AppColors.v3TextPrimary);
    final tools = <Widget>[
      if (widget.captureScreenshot != null)
        TextButton.icon(
          key: const ValueKey('hub-reply-screenshot'),
          onPressed: _capturing ? null : _captureShot,
          style: TextButton.styleFrom(foregroundColor: AppColors.v3TextPrimary),
          icon: _capturing
              ? const SizedBox(width: 13, height: 13, child: ButtonSpinner())
              : Icon(LucideIcons.crop, size: 14, color: AppColors.v3TextSecondary),
          label: Text(l10n.supportHubRedactedScreenshot, style: small),
        ),
      if (_shot != null)
        InputChip(
          key: const ValueKey('hub-reply-shot'),
          avatar: Icon(LucideIcons.image, size: 13, color: AppColors.v3Success),
          label: Text(l10n.supportHubNamesBlurred, style: const TextStyle(fontSize: 12)),
          onDeleted: () => setState(() => _shot = null),
          visualDensity: VisualDensity.compact,
        ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 30,
            child: Checkbox(
              key: const ValueKey('hub-reply-diagnostics'),
              value: _withDiagnostics,
              onChanged: (v) => setState(() => _withDiagnostics = v ?? false),
              visualDensity: VisualDensity.compact,
            ),
          ),
          Flexible(child: Text(l10n.supportHubAttachFreshDiagnostics, style: small)),
        ],
      ),
    ];
    final actions = <Widget>[
      if (t.isOpen || t.standing.closedReason == 'no_reply')
        OutlinedButton.icon(
          key: const ValueKey('hub-fixed-close'),
          onPressed: _closingFixed || !t.isOpen ? null : _closeFixed,
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32), padding: const EdgeInsets.symmetric(horizontal: 10)),
          icon: Icon(LucideIcons.checkCircle, size: 14, color: AppColors.v3TextPrimary),
          label: Text(l10n.supportHubFixedNowClose, style: small.copyWith(fontWeight: FontWeight.w600)),
        ),
      ZestButton(
        key: const ValueKey('hub-send-reply'),
        label: l10n.supportHubSendReply,
        icon: LucideIcons.send,
        variant: ZestButtonVariant.primary,
        isLoading: _sending,
        onPressed: _reply.text.trim().isEmpty ? null : send,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (t.isClosed && t.standing.closedReason == 'no_reply') ...[
          HelpNoticeLine(icon: LucideIcons.clock, text: l10n.supportHubClosedNoReplyNotice),
          const SizedBox(height: 8),
        ],
        if (!t.isPrivate) ...[
          HelpNoticeLine(icon: LucideIcons.globe, text: l10n.ticketReplyPublicNote),
          const SizedBox(height: 8),
        ],
        Container(
          decoration: BoxDecoration(
            color: AppColors.v3Surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.v3BorderDefault),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter, control: true): send,
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true): send,
                },
                child: TextField(
                  key: const ValueKey('hub-reply'),
                  controller: _reply,
                  focusNode: _replyFocus,
                  minLines: 2,
                  maxLines: 8,
                  maxLength: TicketLimits.bodyMax,
                  buildCounter: helpFormCounter,
                  scrollPadding: kHelpFieldScrollPadding,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    hintText: t.isPrivate ? l10n.supportHubReplyToSupport : l10n.ticketReplyHint,
                    hintStyle: TextStyle(fontSize: 13.5, color: AppColors.v3TextTertiary),
                    contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
                ),
                child: Tooltip(
                  message: l10n.supportHubSendKeys(keys),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 4,
                    children: [
                      Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: tools),
                      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 6),
          Text(_notice!, key: const ValueKey('ticket-reply-notice'), style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary)),
          if (_refusedForAttachments)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('ticket-send-without-attachments'),
                onPressed: _sending ? null : _sendWithoutAttachments,
                icon: const Icon(LucideIcons.send, size: 14),
                label: Text(l10n.supportSendWithoutAttachments, style: const TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ],
    );
  }

  /// What sits under the conversation: the reply box while the ticket takes
  /// replies, otherwise why it does not and what can be done instead.
  Widget _bottom(AppLocalizations l10n, SupportTicketRow t) {
    if (t.isWaiting) {
      return _State(
        text: l10n.ticketWaitingNotice,
        actions: [
          OutlinedButton(
            onPressed: _working ? null : _tryNow,
            child: Text(l10n.ticketTryNow, style: const TextStyle(fontSize: 12)),
          ),
        ],
      );
    }
    if (t.isRefused) {
      final account = t.sendError == 'account';
      // With its code, Copy details and Retry:
      // what stood in the way can have changed since.
      final text = ErrorCodes.withCode(
        switch (t.sendError) {
          'account' => l10n.ticketRefusedAccount,
          'blocked' => l10n.supportBlocked,
          _ => l10n.ticketRefusedRejected,
        },
        ticketNotSentCode(t),
      );
      return _State(
        text: text,
        actions: [
          if (t.pending != null)
            OutlinedButton(
              key: const ValueKey('ticket-retry'),
              onPressed: _working ? null : _retryRefused,
              child: Text(l10n.retry, style: const TextStyle(fontSize: 12)),
            ),
          if (account)
            OutlinedButton(
              onPressed: _working ? null : _sendWithoutAccount,
              child: Text(l10n.ticketSendWithoutAccount,
                  style: const TextStyle(fontSize: 12)),
            ),
          OutlinedButton(
            onPressed: () => _copy(t.cachedConversation?.body ?? ''),
            child: Text(l10n.copy, style: const TextStyle(fontSize: 12)),
          ),
          CopyDetailsButton(
            detail: ErrorReport.build(what: text, where: 'A support ticket that was not sent'),
          ),
        ],
      );
    }
    // Closed by itself for want of a reply: writing opens it again (3.4).
    if (widget.hub && t.isClosed && t.standing.closedReason == 'no_reply') return _hubComposer(l10n, t);
    if (t.isGone || t.isClosed) {
      final unsent = _reply.text.trim();
      return _State(
        text: t.isGone ? l10n.ticketGoneNotice : l10n.ticketClosedNotice,
        actions: [
          if (unsent.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => _copy(unsent),
              icon: const Icon(LucideIcons.copy, size: 13),
              label: Text(l10n.ticketCopyUnsent,
                  style: const TextStyle(fontSize: 12)),
            ),
          if (t.isPrivate)
            OutlinedButton(
              onPressed: widget.onNewTicket,
              child: Text(l10n.ticketNewTicket,
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      );
    }
    if (widget.hub) return _hubComposer(l10n, t);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!t.isPrivate) ...[
          HelpNoticeLine(
              icon: LucideIcons.globe, text: l10n.ticketReplyPublicNote),
          const SizedBox(height: 8),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: HelpFormField(
                controller: _reply,
                focusNode: _replyFocus,
                maxLength: TicketLimits.bodyMax,
                minLines: 1,
                maxLines: 6,
                hint: l10n.ticketReplyHint,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: l10n.feedbackSend,
              onPressed:
                  _sending || _reply.text.trim().isEmpty ? null : _send,
              style: IconButton.styleFrom(
                  backgroundColor: ZestTokens.brand,
                  // Named: the theme's icon colour would be given it otherwise.
                  foregroundColor: ZestTokens.onBrand),
              icon: _sending
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: ButtonSpinner())
                  : const Icon(LucideIcons.send, size: 15),
            ),
          ],
        ),
        if (_notice != null) ...[
          const SizedBox(height: 6),
          Text(_notice!,
              style:
                  TextStyle(fontSize: 12, color: AppColors.v3TextSecondary)),
        ],
      ],
    );
  }
}

/// The page title of a ticket: its number when it has one, else its kind.
String ticketDetailTitle(AppLocalizations l10n, SupportTicketRow t) =>
    t.number == null
        ? ticketTypeLabel(l10n, t.ticketType)
        : '${ticketTypeLabel(l10n, t.ticketType)} ${ticketNumberLabel(t.number)}';

/// The top of the page: the subject, where the ticket stands, and who can
/// read it.
class _Header extends ConsumerWidget {
  const _Header({required this.ticket});

  final SupportTicketRow ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final t = ticket;
    final standing = ticketStanding(l10n, t);
    // The page is open, so an answer is being read: say where the ticket
    // stands instead of "reply from support".
    final pill = t.hasUnreadReply
        ? (
            label: l10n.ticketAwaitingYou,
            tone: TicketTone.active,
            icon: null as IconData?,
          )
        : standing;
    final link = t.discordUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          Redactable.freeText(t.title).displayIn(ref),
          style: TextStyle(
              fontSize: 15,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: AppColors.v3TextPrimary),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TicketPill(label: pill.label, tone: pill.tone, icon: pill.icon),
            if (t.tagNames.isNotEmpty) TicketTags(tags: t.tagNames),
          ],
        ),
        const SizedBox(height: 10),
        HelpNoticeLine(
          icon: t.isPrivate ? LucideIcons.lock : LucideIcons.globe,
          text: t.isPrivate ? l10n.ticketPrivateLine : l10n.ticketPublicLine,
        ),
        if (link != null) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(link),
                mode: LaunchMode.externalApplication),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accentInk,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(LucideIcons.externalLink, size: 13),
            label: Text(l10n.ticketViewOnDiscord,
                style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ],
    );
  }
}

/// One entry of the conversation. The person's own sit on the right with the
/// brand wash; support's sit on the left on the surface colour.
class _Bubble extends ConsumerWidget {
  const _Bubble({
    required this.mine,
    required this.who,
    required this.when,
    required this.text,
    this.extraLabel,
    this.extra,
    this.state,
    this.failed = false,
    this.actions = const [],
  });

  final bool mine;
  final String who;
  final DateTime when;
  final String text;

  /// A second block under the text ("What you expected").
  final String? extraLabel;
  final String? extra;

  /// "Waiting to be sent" or why it was not sent.
  final String? state;
  final bool failed;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ink = TextStyle(
        fontSize: 13, height: 1.45, color: AppColors.v3TextPrimary);
    final quiet = TextStyle(fontSize: 11, color: AppColors.v3TextTertiary);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: 0.88,
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '$who · ${ticketStamp(context, when)}',
                  style: quiet,
                ),
              ),
              const SizedBox(height: 3),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                // A wash of the accent for the person's own, the raised
                // surface for support's, neither outlined (an edge only says
                // a reply was not sent); a small corner on the speaker's side.
                decoration: BoxDecoration(
                  color: mine
                      ? ZestTokens.brand.withValues(alpha: 0.14)
                      : ZestTokens.surfaceRaisedAlt,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(mine ? 16 : 4),
                    bottomRight: Radius.circular(mine ? 4 : 16),
                  ),
                  border: failed
                      ? Border.all(color: AppColors.v3Warning.withValues(alpha: 0.6))
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                        Redactable.freeText(text).displayIn(ref),
                        style: ink),
                    if (extra != null) ...[
                      const SizedBox(height: 8),
                      Text(extraLabel ?? '',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.v3TextSecondary)),
                      const SizedBox(height: 2),
                      SelectableText(
                          Redactable.freeText(extra!).displayIn(ref),
                          style: ink),
                    ],
                  ],
                ),
              ),
              if (state != null || actions.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state != null) ...[
                      Icon(
                          failed
                              ? LucideIcons.alertCircle
                              : LucideIcons.clock,
                          size: 11,
                          color: failed
                              ? AppColors.v3Warning
                              : AppColors.v3TextTertiary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(state!,
                            style: quiet.copyWith(
                                color: failed
                                    ? AppColors.v3Warning
                                    : AppColors.v3TextTertiary)),
                      ),
                    ],
                    ...actions,
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Why the ticket takes no reply, with what can be done instead.
class _State extends StatelessWidget {
  const _State({required this.text, this.actions = const []});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text,
            style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: AppColors.v3TextSecondary)),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: actions),
        ],
      ],
    );
  }
}

enum _TicketAction { details, copy, copyDetails, close, remove }

/// The ticket's menu: copy the conversation, close it, remove it from this
/// device. In the header of the pane on desktop and in the app bar on a
/// phone.
class TicketMenuButton extends ConsumerWidget {
  const TicketMenuButton({
    super.key,
    required this.nonce,
    required this.onRemoved,
  });

  final String nonce;

  /// The ticket was removed from this device.
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final t = ref.watch(ticketProvider(nonce)).valueOrNull;
    if (t == null) return const SizedBox.shrink();
    return PopupMenuButton<_TicketAction>(
      tooltip: l10n.ticketMenu,
      icon: const Icon(LucideIcons.moreHorizontal, size: 18),
      onSelected: (action) => _run(context, ref, t, action),
      itemBuilder: (_) => [
        PopupMenuItem(
          key: const ValueKey('ticket-menu-details'),
          value: _TicketAction.details,
          child: Text(l10n.supportHubDetails, style: const TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          key: const ValueKey('ticket-menu-copy-details'),
          value: _TicketAction.copyDetails,
          child: Text(l10n.desktopShellCopyDetails, style: const TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          value: _TicketAction.copy,
          child: Text(l10n.ticketCopyConversation,
              style: const TextStyle(fontSize: 13)),
        ),
        if (t.isOpen)
          PopupMenuItem(
            key: const ValueKey('ticket-menu-close'),
            value: _TicketAction.close,
            child:
                Text(l10n.ticketClose, style: const TextStyle(fontSize: 13)),
          ),
        PopupMenuItem(
          key: const ValueKey('ticket-menu-remove'),
          value: _TicketAction.remove,
          child:
              Text(l10n.ticketRemove, style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref, SupportTicketRow t,
      _TicketAction action) async {
    switch (action) {
      case _TicketAction.details:
        await _details(context);
      case _TicketAction.copyDetails:
        await copyTicketDetails(context, t);
      case _TicketAction.copy:
        await copyTicket(context, t);
      case _TicketAction.close:
        await closeTicketAsking(context, ref, t);
      case _TicketAction.remove:
        await forgetTicketAsking(context, ref, t, onRemoved: onRemoved);
    }
  }

  /// What is known of it, who sees it and what can be done to it.
  Future<void> _details(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      title: l10n.supportHubDetails,
      icon: LucideIcons.info,
      body: Consumer(
        builder: (context, ref, _) {
          // As it changes; once removed there is nothing left to show.
          final now = ref.watch(ticketProvider(nonce)).valueOrNull;
          if (now == null) return const SizedBox.shrink();
          return SingleChildScrollView(
            child: HubTicketDetails(
              ticket: now,
              onRemoved: () {
                Navigator.of(context).maybePop();
                onRemoved();
              },
            ),
          );
        },
      ),
    );
  }
}
