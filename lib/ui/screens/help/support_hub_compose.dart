import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/public_reports.dart';
import 'package:zestssh/features/tickets/support_diagnostics.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/help_form_parts.dart';
import 'package:zestssh/ui/screens/help/public_text_preview.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart';
import 'package:zestssh/ui/screens/help/support_hub_parts.dart';
import 'package:zestssh/ui/screens/help/support_hub_reports.dart';
import 'package:zestssh/ui/widgets/recording_masked_controller.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/help_links.dart';

/// What was typed, kept for the life of the process, so that closing the hub
/// to look at something and coming back loses nothing. One for all three
/// kinds: changing one's mind keeps the words. Cleared when it is sent or
/// discarded. Text and choices only (a screenshot is cheap to retake and
/// expensive to keep), and never written to disk.
class _Draft {
  const _Draft({
    required this.title,
    required this.body,
    required this.email,
    required this.includeAccount,
    required this.private,
  });

  final String title, body, email;
  final bool includeAccount;
  final bool private;

  bool get isEmpty => title.isEmpty && body.isEmpty && email.isEmpty && !includeAccount;
}

_Draft? _draft;

/// The form on screen, if any.
_SupportHubComposeState? _formOnScreen;

/// A Send on its way: the page can be closed while it is out, and opened again
/// (it was posted, nothing was said, and the form came back ready to send it
/// again: found in a code review).
Future<void>? _sendOut;

/// Forgets what the New report was keeping. For tests.
@visibleForTesting
void resetSupportHubDraft() => forgetSupportHubDraft();

/// What was typed and not sent is a person's words: it goes at a change of profile.
void forgetSupportHubDraft() {
  _draft = null;
  _sendOut = null;
}

/// How a Send ended.
class _SendEnd {
  /// It left the form: said in [message], and in the list under [nonce].
  const _SendEnd.left(this.message, this.nonce, {this.sent = true})
      : refused = false,
        forAttachments = false;

  /// It did not go, and why: the words stay in the form. [forAttachments]:
  /// for what was attached, not for the words, which can go without it.
  const _SendEnd.refused(this.message, {this.forAttachments = false})
      : refused = true,
        nonce = null,
        sent = false;

  final String message;
  final String? nonce;
  final bool sent;
  final bool refused;
  final bool forAttachments;
}

/// What a Send that [end]ed comes to, whether or not the page is still open.
void _sendEnded(_SendEnd end, BuildContext root, ProviderContainer container) {
  final form = _formOnScreen;
  if (end.refused) {
    if (form != null) {
      form._refused(end.message, forAttachments: end.forAttachments);
    } else if (root.mounted) {
      showTopSnackBar(root, end.message, isError: true);
    }
    return;
  }
  // Nothing is kept of it, the form that may have been opened again included.
  form?._clear();
  _draft = null;
  container.read(supportHubTicketProvider.notifier).state = end.nonce;
  container.read(supportHubComposeProvider.notifier).state = null;
  if (root.mounted) showTopSnackBar(root, end.message, isSuccess: end.sent, isWarning: !end.sent);
}

/// What the server takes out of what it is sent (lib/clean_text.js).
final RegExp _serverStrips =
    RegExp('[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff]');

/// A Discord name as the server takes it (routes/feedback.js, parseContact: a
/// leading @ goes, the bot puts its own). Null for anything else, which it drops.
String? discordHandleOf(String typed) {
  final handle = typed.replaceAll(_serverStrips, '').replaceAll(RegExp(r'[\r\n]+'), ' ').trim().replaceFirst(RegExp(r'^@+'), '').trim();
  return RegExp(r'^[A-Za-z0-9._-]{2,32}$').hasMatch(handle) ? handle : null;
}

final RegExp _emailShape = RegExp(r'^[^\s@<>"]{1,64}@[^\s@<>"]{1,190}$');

const _noFacts = FeedbackContext(
  appVersion: '',
  build: 0,
  platform: '',
  osVersion: '',
  locale: '',
  tier: '',
);

/// How long the title rests before "Might already be reported" asks the server.
const Duration kSimilarPause = Duration(milliseconds: 450);

/// A new ticket or report in the Support Hub:
/// Get help, Report a bug or Suggest an idea, one switch that keeps what
/// was typed; as the title is typed, everyone's listed reports that look the
/// same, with Me too; a redacted screenshot and diagnostics, with exactly what
/// is sent a click away; and who can see it, Public with names removed or
/// Private.
///
/// It keeps what the forms of the Help panel promise: nothing leaves until Send
/// is pressed, a screenshot is the person's choice and is taken redacted, a
/// name or an address is typed by hand, and the text is never lost.
class SupportHubCompose extends ConsumerStatefulWidget {
  const SupportHubCompose({
    super.key,
    required this.kind,
    required this.captureScreenshot,
    required this.onClose,
  });

  final TicketType kind;

  /// Null where no picture can be taken (a phone): none is offered.
  final ScreenshotCapture? captureScreenshot;
  final VoidCallback onClose;

  @override
  ConsumerState<SupportHubCompose> createState() => _SupportHubComposeState();
}

class _SupportHubComposeState extends ConsumerState<SupportHubCompose> {
  // (While the screen is recorded they draw as bullets.)
  final _title = RecordingMaskedController();
  final _body = RecordingMaskedController();
  final _email = RecordingMaskedController();
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();
  final _emailFocus = FocusNode();

  bool _includeAccount = false;
  bool _private = false;

  /// "Include diagnostics" as the person set it for this kind and choice of
  /// who sees it; null until they do. Off by default, but for a Private bug
  /// report, where it helps support (a 3.4 security review). Not kept:
  /// changing the kind or who sees it goes back to the default.
  bool? _diagnosticsSet;
  bool get _diagnostics => _diagnosticsSet ?? (_isBug && _private);
  bool _signedIn = false;
  bool _sending = false;
  bool _capturing = false;
  bool _submitted = false;
  Uint8List? _screenshot;
  FeedbackContext? _context;

  /// Everyone's listed reports that look like the title, and the words they
  /// were found for.
  List<PublicReport> _similar = const [];
  String _similarFor = '';
  Timer? _similarTimer;

  /// Why the last Send did not go through.
  String? _failure;

  List<RecordingMaskedController> get _controllers => [_title, _body, _email];

  TicketType get _kind => widget.kind;
  bool get _isHelp => _kind == TicketType.support;
  bool get _isBug => _kind == TicketType.bug;

  @override
  void initState() {
    super.initState();
    _formOnScreen = this;
    // Opened again with a Send still out: what it says of it is said here.
    _sending = _sendOut != null;
    final d = _draft;
    if (d != null) {
      _title.text = d.title;
      _body.text = d.body;
      _email.text = d.email;
      _includeAccount = d.includeAccount;
      _private = d.private;
    }
    for (final c in _controllers) {
      c.addListener(_onEdit);
    }
    _title.addListener(_titleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collectContext();
      _titleChanged();
    });
  }

  @override
  void didUpdateWidget(SupportHubCompose old) {
    super.didUpdateWidget(old);
    if (old.kind != widget.kind) {
      _diagnosticsSet = null;
      _similar = const [];
      _similarFor = '';
      _titleChanged();
    }
  }

  @override
  void dispose() {
    _similarTimer?.cancel();
    if (_formOnScreen == this) _formOnScreen = null;
    final d = _Draft(
      title: _title.text,
      body: _body.text,
      email: _email.text,
      includeAccount: _includeAccount,
      private: _private,
    );
    _draft = d.isEmpty ? null : d;
    for (final c in _controllers) {
      c.dispose();
    }
    _titleFocus.dispose();
    _bodyFocus.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (mounted) setState(() {});
  }

  /// "Might already be reported": asked of the server once the title rests,
  /// for a bug report or an idea only. Nothing typed goes with it but the
  /// title's words, and only while the person is writing a public one.
  void _titleChanged() {
    _similarTimer?.cancel();
    // A private one's title is never sent to look it up (it would sit in a
    // web address: the 3.4 security review, L15).
    if (_isHelp || _private) return;
    final words = _title.text.trim();
    if (words == _similarFor) return;
    if (words.length < 3) {
      if (_similar.isNotEmpty && mounted) setState(() => _similar = const []);
      _similarFor = words;
      return;
    }
    _similarTimer = Timer(kSimilarPause, () => unawaited(_findSimilar(words)));
  }

  Future<void> _findSimilar(String words) async {
    List<PublicReport> found;
    try {
      found = await ref.read(publicReportsServiceProvider).similar(words, _kind);
    } catch (_) {
      // The lists are a help, not a gate: unreachable, nothing is offered.
      found = const [];
    }
    if (!mounted || _title.text.trim() != words || _private) return;
    if (found.isNotEmpty && !ref.read(reportVotesProvider).loaded) {
      unawaited(ref.read(reportVotesProvider.notifier).load());
    }
    setState(() {
      _similar = found;
      _similarFor = words;
    });
  }

  Future<void> _collectContext() async {
    final found = await collectFeedbackContext(context, ref);
    if (found == null || !mounted) return;
    setState(() {
      _context = found.$1;
      _signedIn = found.$2;
    });
  }

  // ── What is sent ─────────────────────────────────────────────────────

  String? get _diagnosticsText => _diagnostics && _context != null ? supportDiagnostics(_context!) : null;

  /// A public bug report or idea.
  FeedbackReport _report({String? diagnostics, String? title, String? body}) => FeedbackReport(
        type: _isBug ? FeedbackType.bug : FeedbackType.suggestion,
        title: title ?? _title.text,
        body: body ?? _body.text,
        context: _context ?? _noFacts,
        screenshotPng: _isBug ? _screenshot : null,
        diagnostics: diagnostics,
      );

  TicketContact? get _emailContact => _email.text.trim().isEmpty ? null : TicketContact.email(_email.text.trim());

  /// The request as it would go, the screenshot said as its size and the
  /// ticket's key named, not shown; diagnostics are shown on their own.
  String _payload() {
    if (!_isHelp && !_private) return _report().toPreviewJson();
    return TicketService.previewOf(TicketService.supportRequest(
      type: _kind,
      title: _title.text,
      body: _body.text,
      context: _context ?? _noFacts,
      contact: _isHelp ? _emailContact : null,
      includeAccount: _isHelp && _includeAccount && _signedIn,
      nonce: '<a random id for this ticket>',
      token: TicketToken.preview,
      screenshot: _isBug ? _screenshot : null,
    ));
  }

  Future<void> _showSent() => showDiagnosticsText(context, _diagnosticsText ?? '', before: _payload());

  String _asText() {
    if (!_isHelp) return _report().toClipboardText();
    final c = _context;
    final b = StringBuffer()
      ..writeln(_title.text.trim())
      ..writeln()
      ..writeln(_body.text.trim());
    if (c != null) {
      b
        ..writeln()
        ..writeln('App ${c.appVersion} (${c.build}) on ${c.platform} ${c.osVersion}, ${c.locale}, ${c.tier}');
    }
    if (_email.text.trim().isNotEmpty) b.writeln(_email.text.trim());
    return b.toString().trimRight();
  }

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: _asText()));
    if (mounted) showTopSnackBar(context, l10n.reportCopied, isSuccess: true);
  }

  // ── The screenshot ───────────────────────────────────────────────────

  /// Always redacted here. The person's own choice all the same, and looked at
  /// before it goes: terminal output is not masked.
  Future<void> _capture() async {
    final capture = widget.captureScreenshot;
    if (capture == null) return;
    setState(() => _capturing = true);
    Uint8List? png;
    try {
      png = await capture(redacted: true);
    } catch (_) {
      png = null;
    }
    if (!mounted) return;
    if (png != null && png.length > FeedbackLimits.screenshotMaxBytes) png = null;
    setState(() {
      _capturing = false;
      // A retake that fails keeps the picture there was.
      _screenshot = png ?? _screenshot;
    });
    if (png == null) {
      showTopSnackBar(context, AppLocalizations.of(context)!.recModeCopyScreenshotFailed, isError: true);
    }
  }

  // ── Send ─────────────────────────────────────────────────────────────

  bool get _titleMissing => _submitted && _title.text.trim().isEmpty;
  bool get _bodyMissing => _submitted && _body.text.trim().isEmpty;
  bool get _emailBad =>
      _submitted && _isHelp && _email.text.trim().isNotEmpty && !_emailShape.hasMatch(_email.text.trim());

  /// Send stays enabled: pressing it on an incomplete form names the first
  /// thing missing and puts the cursor there.
  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _submitted = true;
      _failure = null;
    });
    if (_titleMissing) {
      _titleFocus.requestFocus();
      return;
    }
    if (_bodyMissing) {
      _bodyFocus.requestFocus();
      return;
    }
    if (_emailBad) {
      _emailFocus.requestFocus();
      return;
    }
    if (_context == null) return;
    final public = !_isHelp && !_private;
    var title = _title.text;
    var body = _body.text;
    if (public) {
      // Everyone reads a public one, in the app and on Discord, as it is
      // sent: its words go through the same scrubbing as diagnostics, and
      // the person sees exactly what goes, with what was taken out marked,
      // before it does (a 3.4 security review).
      final l10n = AppLocalizations.of(context)!;
      final shown = await confirmPublicText(context, [
        (label: _isBug ? l10n.supportHubWhatsWrong : l10n.supportHubWhatsIdea, text: title),
        (label: _isBug ? l10n.supportHubWhatHappened : l10n.supportHubWhyIdea, text: body),
      ]);
      if (shown == null || !mounted || _sending) return;
      title = shown[0];
      body = shown[1];
    }
    setState(() => _sending = true);
    // The page can be closed before the answer comes: what the answer comes to
    // does not depend on it ([_sendEnded]).
    final root = Navigator.of(context, rootNavigator: true).context;
    final container = ProviderScope.containerOf(context, listen: false);
    final diagnostics = _diagnosticsText;
    final out = (public ? _postReport(diagnostics, title: title, body: body) : _postTicket(diagnostics)).then((end) {
      _sendOut = null;
      // ignore: use_build_context_synchronously
      _sendEnded(end, root, container); // (it asks whether root is still there)
    });
    _sendOut = out;
    await out;
  }

  Future<_SendEnd> _postTicket(String? diagnostics) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await ref.read(ticketServiceProvider).createPrivate(
          type: _kind,
          title: _title.text,
          body: _body.text,
          context: _context!,
          contact: _isHelp ? _emailContact : null,
          includeAccount: _isHelp && _includeAccount && _signedIn,
          diagnostics: diagnostics,
          screenshot: _isBug ? _screenshot : null,
        );
    if (result.attachments case final why?) {
      return _SendEnd.refused(attachmentsRefusalSaid(l10n, why, result.retryMinutes), forAttachments: true);
    }
    return switch (result.outcome) {
      // "Sent" only with the server's own ticket, and its number as the proof.
      TicketSendOutcome.sent => _SendEnd.left(
          result.number == null ? l10n.supportSent : l10n.supportSentNumbered(result.number!), result.nonce),
      TicketSendOutcome.queued => _SendEnd.left(l10n.supportQueued, result.nonce),
      TicketSendOutcome.rateLimited => _SendEnd.refused(l10n.supportRateLimited(result.retryMinutes ?? 60)),
      TicketSendOutcome.blocked => _SendEnd.refused(l10n.supportBlocked),
      TicketSendOutcome.needsSignIn => _SendEnd.refused(l10n.supportNeedsSignIn),
      TicketSendOutcome.tooManyWaiting => _SendEnd.refused(l10n.supportTooManyWaiting),
      TicketSendOutcome.closed || TicketSendOutcome.gone || TicketSendOutcome.rejected => _SendEnd.refused(l10n.supportFailed),
    };
  }

  Future<_SendEnd> _postReport(String? diagnostics, {required String title, required String body}) async {
    final l10n = AppLocalizations.of(context)!;
    final report = _report(diagnostics: diagnostics, title: title, body: body);
    final result = await ref.read(feedbackServiceProvider).send(report);
    if (result.attachments case final why?) {
      return _SendEnd.refused(attachmentsRefusalSaid(l10n, why, result.retryMinutes), forAttachments: true);
    }
    return switch (result.outcome) {
      FeedbackOutcome.sent => _SendEnd.left(l10n.feedbackSentAnon, report.nonce),
      // Kept and sent by itself: it is out of the form's hands, and in the
      // list, and a second press here would post it twice.
      FeedbackOutcome.queued => _SendEnd.left(l10n.feedbackFailedQueued, report.nonce, sent: false),
      FeedbackOutcome.rateLimited => _SendEnd.refused(l10n.feedbackRateLimited(result.retryMinutes ?? 5)),
      FeedbackOutcome.blocked => _SendEnd.refused(l10n.feedbackBlocked),
      FeedbackOutcome.rejected => _SendEnd.refused(l10n.reportFailed),
    };
  }

  /// A Send did not go: why, under the form. [forAttachments]: for the
  /// screenshot or the diagnostics, so the words are offered to go alone.
  void _refused(String message, {bool forAttachments = false}) {
    setState(() {
      _sending = false;
      _failure = message;
      _failedForAttachments = forAttachments;
    });
  }

  bool _failedForAttachments = false;

  /// Send without the screenshot and the diagnostics, the words kept.
  Future<void> _sendWithoutAttachments() async {
    setState(() {
      _screenshot = null;
      _diagnosticsSet = false;
      _failedForAttachments = false;
    });
    await _send();
  }

  void _clear() {
    for (final c in _controllers) {
      c.clear();
    }
    _includeAccount = false;
    _private = false;
    _diagnosticsSet = null;
    _failedForAttachments = false;
    _screenshot = null;
    _draft = null;
  }

  bool get _hasWords => _controllers.any((c) => c.text.trim().isNotEmpty) || _screenshot != null;

  /// Cancel: what was typed is asked about first, then goes.
  Future<void> _discard() async {
    final l10n = AppLocalizations.of(context)!;
    if (_hasWords) {
      final ok = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.destructive,
        title: l10n.supportHubDiscardTitle,
        body: l10n.supportHubDiscardBody,
        confirmLabel: l10n.supportHubDiscard,
      );
      if (ok != true || !mounted) return;
    }
    _clear();
    ref.read(supportHubComposeProvider.notifier).state = null;
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.maskWhileRecording(_controllers);
    return Column(
      key: const ValueKey('hub-compose'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            children: [
              Align(
                alignment: AlignmentDirectional.topStart,
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780), child: _form(l10n)),
              ),
            ],
          ),
        ),
        _footer(l10n),
      ],
    );
  }

  Widget _form(AppLocalizations l10n) {
    final titleLabel = _isHelp ? l10n.supportHubWhatHelp : (_isBug ? l10n.supportHubWhatsWrong : l10n.supportHubWhatsIdea);
    final bodyLabel = _isHelp ? l10n.supportMessageLabel : (_isBug ? l10n.supportHubWhatHappened : l10n.supportHubWhyIdea);
    final bodyHint = _isHelp ? null : (_isBug ? l10n.supportHubWhatHappenedHint : l10n.supportHubWhyIdeaHint);
    final titleMax = _isHelp ? TicketLimits.titleMax : FeedbackLimits.titleMax;
    final bodyMax = _isHelp ? TicketLimits.bodyMax : FeedbackLimits.bodyMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KindSwitch(
          kind: _kind,
          onChanged: (k) {
            ref.read(supportHubComposeProvider.notifier).state = k;
            setState(() {
              _submitted = false;
              _failure = null;
            });
          },
        ),
        const SizedBox(height: 18),
        _label(titleLabel),
        TextField(
          key: const ValueKey('hub-title'),
          controller: _title,
          focusNode: _titleFocus,
          maxLength: titleMax,
          scrollPadding: kHelpFieldScrollPadding,
          style: const TextStyle(fontSize: 14.5),
          buildCounter: helpFormCounter,
          decoration: helpFormDecoration(
            hint: _isHelp ? l10n.supportSubjectLabel : l10n.reportTitleHint,
            errorText: _titleMissing ? (_isHelp ? l10n.supportMissingSubject : l10n.supportHubMissingTitle) : null,
          ),
        ),
        if (!_isHelp && _similar.isNotEmpty) ...[
          const SizedBox(height: 4),
          _Duplicates(kind: _kind, reports: _similar),
        ],
        const SizedBox(height: 14),
        _label(bodyLabel),
        HelpFormField(
          key: const ValueKey('hub-body'),
          controller: _body,
          focusNode: _bodyFocus,
          maxLength: bodyMax,
          minLines: 4,
          maxLines: 12,
          hint: bodyHint,
          errorText: _bodyMissing ? (_isHelp ? l10n.supportMissingMessage : l10n.reportSendMissingBody) : null,
        ),
        if (_isHelp) ...[
          const SizedBox(height: 12),
          // The account: a box the person ticks, never ticked for them, and
          // only offered when there is an account to include.
          if (_signedIn) ...[
            HelpCheckRow(
              key: const ValueKey('hub-include-account'),
              value: _includeAccount,
              label: l10n.supportIncludeAccount,
              subtitle: l10n.supportIncludeAccountDesc,
              onChanged: (v) => setState(() => _includeAccount = v ?? false),
            ),
            const SizedBox(height: 10),
          ],
          _label(l10n.supportEmailLabel),
          HelpFormField(
            key: const ValueKey('hub-email'),
            controller: _email,
            focusNode: _emailFocus,
            maxLength: TicketLimits.contactMax,
            keyboardType: TextInputType.emailAddress,
            hint: 'name@example.com',
            errorText: _emailBad ? l10n.supportEmailInvalid : null,
          ),
          const SizedBox(height: 2),
          Text(l10n.supportEmailDesc, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
        ],
        const SizedBox(height: 16),
        _label(l10n.supportHubAttachments),
        _attachments(l10n),
        if (!_isHelp) ...[
          const SizedBox(height: 18),
          _label(l10n.supportHubWhoCanSee),
          _WhoCanSee(
            bug: _isBug,
            private: _private,
            onChanged: (v) {
              setState(() {
                _private = v;
                _diagnosticsSet = null;
                // Nothing of a private one is looked up in everyone's lists.
                if (v) {
                  _similarTimer?.cancel();
                  _similar = const [];
                  _similarFor = '';
                }
              });
              if (!v) _titleChanged();
            },
          ),
        ],
        if (_failure != null) ...[
          const SizedBox(height: 14),
          HelpFailureBox(
            key: const ValueKey('hub-failure'),
            message: _failure!,
            actions: [
              if (_failedForAttachments)
                OutlinedButton.icon(
                  key: const ValueKey('hub-send-without-attachments'),
                  onPressed: _sending ? null : _sendWithoutAttachments,
                  icon: const Icon(LucideIcons.send, size: 14),
                  label: Text(l10n.supportSendWithoutAttachments, style: const TextStyle(fontSize: 12)),
                ),
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(LucideIcons.copy, size: 14),
                label: Text(l10n.supportHubCopyAsText, style: const TextStyle(fontSize: 12)),
              ),
              if (_isHelp && kZestSupportMailto != '')
                OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse(kZestSupportMailto), mode: LaunchMode.externalApplication),
                  icon: const Icon(LucideIcons.mail, size: 14),
                  label: Text(l10n.helpEmail, style: const TextStyle(fontSize: 12)),
                )
              else if (!_isHelp && kZestDiscordUrl != '')
                OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse(kZestDiscordUrl), mode: LaunchMode.externalApplication),
                  icon: const Icon(LucideIcons.externalLink, size: 14),
                  label: Text(l10n.helpOpenDiscord, style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.v3TextPrimary)),
      );

  /// The screenshot (a bug report's, where one can be taken) and diagnostics,
  /// with what each holds said right there.
  Widget _attachments(AppLocalizations l10n) {
    final canShoot = _isBug && widget.captureScreenshot != null;
    final shot = _screenshot;
    final small = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.v3TextPrimary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (canShoot && shot != null) ...[
          HubShotThumb(key: const ValueKey('hub-screenshot'), png: shot, width: 150, height: 84),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (canShoot) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      key: ValueKey(shot == null ? 'hub-screenshot-add' : 'hub-screenshot-retake'),
                      onPressed: _capturing ? null : _capture,
                      // 32 high to a pointer (the desktop's compact density
                      // took it to 24).
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          visualDensity: VisualDensity.standard,
                          padding: const EdgeInsets.symmetric(horizontal: 11)),
                      icon: Icon(LucideIcons.crop, size: 14, color: AppColors.v3TextPrimary),
                      label: Text(shot == null ? l10n.supportHubAddScreenshot : l10n.feedbackAttachRetake, style: small),
                    ),
                    if (shot != null)
                      TextButton(
                        key: const ValueKey('hub-screenshot-remove'),
                        onPressed: () => setState(() => _screenshot = null),
                        child: Text(l10n.reportScreenshotRemove, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // The box and its words, one stop to a screen reader, 32
                  // high (it was a checkbox of nothing, 28 high).
                  MergeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: Checkbox(
                            key: const ValueKey('hub-diagnostics'),
                            value: _diagnostics,
                            onChanged: (v) => setState(() => _diagnosticsSet = v ?? false),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        Text(l10n.supportHubIncludeDiagnostics, style: small),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const ValueKey('hub-see-sent'),
                    onPressed: _context == null ? null : _showSent,
                    style: TextButton.styleFrom(
                      foregroundColor: ZestTokens.brandInk,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(l10n.supportHubSeeWhatsSent, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                l10n.supportHubDiagnosticsNote(kDiagnosticsLogLines),
                style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _footer(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: AppColors.v3BorderSubtle))),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        spacing: 12,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              _isHelp ? l10n.supportHubFooterHelp : l10n.supportHubFooterHint,
              style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ZestButton(
                key: const ValueKey('hub-discard'),
                label: l10n.cancel,
                onPressed: _discard,
              ),
              const SizedBox(width: 8),
              ZestButton(
                key: const ValueKey('hub-send'),
                label: _isHelp || _private ? l10n.supportHubSendTicket : l10n.supportHubSendReport,
                icon: LucideIcons.send,
                variant: ZestButtonVariant.primary,
                isLoading: _sending,
                onPressed: _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Get help, Report a bug, Suggest an idea: one switch across the form.
class _KindSwitch extends StatelessWidget {
  const _KindSwitch({required this.kind, required this.onChanged});

  final TicketType kind;
  final ValueChanged<TicketType> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, box) => _build(l10n, icons: box.maxWidth >= 480));
  }

  /// [icons] where there is room for them beside the words (not a phone).
  Widget _build(AppLocalizations l10n, {required bool icons}) {
    Widget segment(TicketType t, IconData icon, String label) {
      final on = t == kind;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey('hub-kind-${t.wire}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(t),
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: on ? ZestTokens.surfaceChipStrong : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icons) ...[
                      Icon(icon, size: 15, color: on ? AppColors.v3TextPrimary : AppColors.v3TextSecondary),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                          color: on ? AppColors.v3TextPrimary : AppColors.v3TextSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      key: const ValueKey('hub-kind'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        children: [
          segment(TicketType.support, LucideIcons.lifeBuoy, l10n.helpSupport),
          segment(TicketType.bug, LucideIcons.bug, l10n.helpReportBug),
          segment(TicketType.suggestion, LucideIcons.lightbulb, l10n.supportHubSuggestIdea),
        ],
      ),
    );
  }
}

/// "Might already be reported": everyone's listed reports that look like the
/// title, with how many have it and Me too.
class _Duplicates extends ConsumerWidget {
  const _Duplicates({required this.kind, required this.reports});

  final TicketType kind;
  final List<PublicReport> reports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final votes = ref.watch(reportVotesProvider);
    return Container(
      key: const ValueKey('hub-similar'),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                Icon(LucideIcons.search, size: 14, color: ZestTokens.brandInk),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    kind == TicketType.bug ? l10n.supportHubMightBeReported : l10n.supportHubMightBeSuggested,
                    style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary),
                  ),
                ),
              ],
            ),
          ),
          for (final raw in reports) ...[
            Divider(height: 1, color: AppColors.v3BorderSubtle),
            Builder(builder: (context) {
              final r = votes.over(raw);
              return Padding(
                key: ValueKey('hub-similar-${r.id}'),
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Redactable.freeText(r.title).displayIn(ref),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.v3TextPrimary),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ReportStatePill(state: r.state, version: r.stateVersion, closed: r.closed),
                              Text(
                                kind == TicketType.bug ? l10n.supportHubPeopleHaveThis(r.votes) : l10n.supportHubPeopleWantThis(r.votes),
                                style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    MeTooButton(report: r),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

/// Who can see it: Public with names removed, or Private.
class _WhoCanSee extends StatelessWidget {
  const _WhoCanSee({required this.bug, required this.private, required this.onChanged});

  final bool bug;
  final bool private;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final public = _Choice(
      key: const ValueKey('hub-visibility-public'),
      selected: !private,
      icon: LucideIcons.globe,
      title: l10n.supportHubPublicNamesRemoved,
      text: bug ? l10n.supportHubPublicSubBug : l10n.supportHubPublicSubIdea,
      onTap: () => onChanged(false),
    );
    final mine = _Choice(
      key: const ValueKey('hub-visibility-private'),
      selected: private,
      icon: LucideIcons.lock,
      title: l10n.supportHubPrivate,
      text: l10n.supportHubPrivateSub,
      onTap: () => onChanged(true),
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < 520
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [public, const SizedBox(height: 8), mine])
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Expanded(child: public), const SizedBox(width: 12), Expanded(child: mine)],
              ),
            ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.text,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            decoration: BoxDecoration(
              color: selected ? ZestTokens.brand.withValues(alpha: 0.07) : AppColors.v3Surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: selected ? ZestTokens.brand : AppColors.v3BorderDefault),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(top: 1),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: selected ? ZestTokens.brand : AppColors.v3BorderDefault, width: 2),
                  ),
                  child: selected
                      ? Container(width: 8, height: 8, decoration: BoxDecoration(color: ZestTokens.brand, shape: BoxShape.circle))
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(icon, size: 14, color: AppColors.v3TextPrimary),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.v3TextPrimary)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
