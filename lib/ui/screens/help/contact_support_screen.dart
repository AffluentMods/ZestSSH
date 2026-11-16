import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/help/help_form_parts.dart';
import 'package:zestssh/ui/widgets/recording_masked_controller.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/help_links.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';

/// Write to support (tickets handoff, section 3): a private ticket, answered
/// in the app.
///
/// What it promises, and keeps:
///   * Private. It is read by support only and never posted in Discord. The
///     form says so, and says how long it is kept (until 90 days after it is
///     closed).
///   * No account by default. The ticket is tied to a random key kept on this
///     device, nothing else. "Include my account" is a box the person ticks,
///     for when support has to look up a licence; it is never ticked for
///     them.
///   * The same six facts as a report ride along, shown in the preview of
///     exactly what is sent. No logs, no host list, no settings.
///   * An email address is typed by hand or not given at all. It is never
///     filled in from the account.
///   * Text is never lost: with no network the ticket is kept and sent
///     later, a refusal leaves the form as it was, and the text can always
///     be copied.
///
/// On desktop it is a level inside the Help pane ([embedded]); on a phone a
/// full-screen route.
class ContactSupportScreen extends ConsumerStatefulWidget {
  const ContactSupportScreen({
    super.key,
    this.embedded = false,
    required this.onDone,
  });

  final bool embedded;

  /// The ticket was sent, or kept to be sent later: the nonce of its row,
  /// so the caller can show it.
  final ValueChanged<String> onDone;

  @override
  ConsumerState<ContactSupportScreen> createState() =>
      _ContactSupportScreenState();
}

/// What was typed, kept for the life of the process so that closing the
/// pane never loses it. Cleared when the ticket is sent. Never written to
/// disk.
class _SupportDraft {
  const _SupportDraft(this.subject, this.message, this.email, {this.fromAstryx = false});
  final String subject, message, email;

  /// Filled in from Ask Astryx ("Open a ticket with this"): the form says so.
  final bool fromAstryx;
  bool get isEmpty => subject.isEmpty && message.isEmpty && email.isEmpty;
}

_SupportDraft? _draft;

/// What was typed and not sent is a person's words: it goes at a change of profile.
void forgetContactSupportDraft() => _draft = null;

/// Ask Astryx's "Open a ticket with this": the next support form opens with
/// [subject] and [message] (the question and Astryx's answer), both editable,
/// and says where they came from. Nothing is sent until the person sends it.
/// Words already typed in the form and not sent are kept, after these.
void seedContactSupportFromAstryx({required String subject, required String message}) {
  final had = _draft;
  final before = had?.message.trim() ?? '';
  _draft = _SupportDraft(
    (had?.subject.trim().isNotEmpty ?? false) ? had!.subject : subject,
    before.isEmpty ? message : '$message\n\n$before',
    had?.email ?? '',
    fromAstryx: true,
  );
}

final RegExp _emailShape = RegExp(r'^[^\s@<>"]{1,64}@[^\s@<>"]{1,190}$');

class _ContactSupportScreenState extends ConsumerState<ContactSupportScreen> {
  // (While the screen is recorded they draw as bullets.)
  final _subject = RecordingMaskedController();
  final _message = RecordingMaskedController();
  final _email = RecordingMaskedController();
  final _subjectFocus = FocusNode();
  final _messageFocus = FocusNode();
  final _emailFocus = FocusNode();

  bool _includeAccount = false;
  bool _fromAstryx = false;
  bool _signedIn = false;
  bool _showPayload = false;
  bool _sending = false;
  bool _submitted = false;
  String? _failure;
  FeedbackContext? _context;

  // The preview names the id and the key; the ticket that is sent gets
  // real ones, made as it is sent.
  static const String _previewNonce = '<a random id for this ticket>';

  List<RecordingMaskedController> get _controllers => [_subject, _message, _email];

  @override
  void initState() {
    super.initState();
    final d = _draft;
    if (d != null) {
      _subject.text = d.subject;
      _message.text = d.message;
      _email.text = d.email;
      _fromAstryx = d.fromAstryx;
    }
    for (final c in _controllers) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _collectContext());
  }

  @override
  void dispose() {
    final d = _SupportDraft(_subject.text, _message.text, _email.text, fromAstryx: _fromAstryx);
    _draft = d.isEmpty ? null : d;
    for (final c in _controllers) {
      c.dispose();
    }
    _subjectFocus.dispose();
    _messageFocus.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  Future<void> _collectContext() async {
    final found = await collectFeedbackContext(context, ref);
    if (found == null || !mounted) return;
    setState(() {
      _context = found.$1;
      _signedIn = found.$2;
    });
  }

  String get _emailText => _email.text.trim();
  bool get _subjectMissing => _submitted && _subject.text.trim().isEmpty;
  bool get _messageMissing => _submitted && _message.text.trim().isEmpty;
  bool get _emailBad =>
      _submitted && _emailText.isNotEmpty && !_emailShape.hasMatch(_emailText);

  TicketContact? get _contact =>
      _emailText.isEmpty ? null : TicketContact.email(_emailText);

  static const _emptyContext = FeedbackContext(
    appVersion: '',
    build: 0,
    platform: '',
    osVersion: '',
    locale: '',
    tier: '',
  );

  /// The request as the preview shows it.
  String _preview() => TicketService.previewOf(TicketService.supportRequest(
        title: _subject.text,
        body: _message.text,
        context: _context ?? _emptyContext,
        contact: _contact,
        includeAccount: _includeAccount && _signedIn,
        nonce: _previewNonce,
        token: TicketToken.preview,
      ));

  String _clipboardText() {
    final c = _context;
    final b = StringBuffer()
      ..writeln(_subject.text.trim())
      ..writeln()
      ..writeln(_message.text.trim());
    if (c != null) {
      b
        ..writeln()
        ..writeln('App ${c.appVersion} (${c.build}) on ${c.platform} '
            '${c.osVersion}, ${c.locale}, ${c.tier}');
    }
    if (_emailText.isNotEmpty) b.writeln(_emailText);
    return b.toString().trimRight();
  }

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: _clipboardText()));
    if (mounted) showTopSnackBar(context, l10n.ticketCopied, isSuccess: true);
  }

  /// Send stays enabled: pressing it on an incomplete form names the first
  /// missing field and puts the cursor in it.
  Future<void> _send() async {
    if (_sending) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _submitted = true;
      _failure = null;
    });
    if (_subject.text.trim().isEmpty) {
      _subjectFocus.requestFocus();
      return;
    }
    if (_message.text.trim().isEmpty) {
      _messageFocus.requestFocus();
      return;
    }
    if (_emailBad) {
      _emailFocus.requestFocus();
      return;
    }
    final ctx = _context;
    if (ctx == null) return;
    setState(() => _sending = true);
    final result = await ref.read(ticketServiceProvider).createSupport(
          title: _subject.text,
          body: _message.text,
          context: ctx,
          contact: _contact,
          includeAccount: _includeAccount && _signedIn,
        );
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result.outcome) {
      case TicketSendOutcome.sent:
      case TicketSendOutcome.queued:
        // "Sent" only with the server's own ticket, and its number as the proof.
        final message = result.outcome != TicketSendOutcome.sent
            ? l10n.supportQueued
            : result.number == null
                ? l10n.supportSent
                : l10n.supportSentNumbered(result.number!);
        // It is out of the form's hands: nothing is left to keep.
        for (final c in _controllers) {
          c.clear();
        }
        _draft = null;
        final root = Navigator.of(context, rootNavigator: true).context;
        widget.onDone(result.nonce!);
        if (root.mounted) showTopSnackBar(root, message, isSuccess: true);
      case TicketSendOutcome.rateLimited:
        setState(() => _failure =
            l10n.supportRateLimited(result.retryMinutes ?? 60));
      case TicketSendOutcome.blocked:
        setState(() => _failure = l10n.supportBlocked);
      case TicketSendOutcome.needsSignIn:
        setState(() => _failure = l10n.supportNeedsSignIn);
      case TicketSendOutcome.tooManyWaiting:
        setState(() => _failure = l10n.supportTooManyWaiting);
      case TicketSendOutcome.closed:
      case TicketSendOutcome.gone:
      case TicketSendOutcome.rejected:
        setState(() => _failure = l10n.supportFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.maskWhileRecording(_controllers);
    final fields = _fields(l10n);
    final actions = Row(
      children: [
        Tooltip(
          message: l10n.supportCopyTooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: TextButton.icon(
            onPressed: _copy,
            icon: const Icon(LucideIcons.copy, size: 14),
            label: Text(l10n.copy, style: const TextStyle(fontSize: 12)),
          ),
        ),
        Expanded(
          // Shrinks to the room the row leaves it, its label wrapping (it ran
          // out of the row at a large text size).
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: ButtonSpinner())
                  : const Icon(LucideIcons.send, size: 14),
              label: Text(l10n.feedbackSend),
            ),
          ),
        ),
      ],
    );
    if (widget.embedded) {
      return Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: fields,
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
            ),
            child: actions,
          ),
        ],
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.supportWrite),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [fields, const SizedBox(height: 16), actions],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fields(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_fromAstryx) ...[
          HelpNoticeLine(icon: LucideIcons.sparkles, text: l10n.astryxTicketFilledIn),
          const SizedBox(height: 10),
        ],
        helpFormLabel(l10n.supportSubjectLabel),
        HelpFormField(
          controller: _subject,
          focusNode: _subjectFocus,
          maxLength: TicketLimits.titleMax,
          hint: l10n.reportTitleHint,
          errorText: _subjectMissing ? l10n.supportMissingSubject : null,
        ),
        const SizedBox(height: 8),
        helpFormLabel(l10n.supportMessageLabel),
        HelpFormField(
          controller: _message,
          focusNode: _messageFocus,
          maxLength: TicketLimits.bodyMax,
          minLines: 5,
          maxLines: 12,
          errorText: _messageMissing ? l10n.supportMissingMessage : null,
        ),
        const SizedBox(height: 12),

        // Private, and for how long it is kept: said before sending.
        HelpNoticeLine(icon: LucideIcons.lock, text: l10n.supportPrivateNotice),
        const SizedBox(height: 14),

        // The account: a box the person ticks, never ticked for them, and
        // only offered when there is an account to include.
        if (_signedIn) ...[
          HelpCheckRow(
            value: _includeAccount,
            label: l10n.supportIncludeAccount,
            subtitle: l10n.supportIncludeAccountDesc,
            onChanged: (v) => setState(() => _includeAccount = v ?? false),
          ),
          const SizedBox(height: 10),
        ],

        // An address typed by hand, or none.
        helpFormLabel(l10n.supportEmailLabel),
        HelpFormField(
          controller: _email,
          focusNode: _emailFocus,
          maxLength: TicketLimits.contactMax,
          keyboardType: TextInputType.emailAddress,
          hint: 'name@example.com',
          errorText: _emailBad ? l10n.supportEmailInvalid : null,
        ),
        const SizedBox(height: 4),
        Text(l10n.supportEmailDesc,
            style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
        const SizedBox(height: 12),

        // Exactly what is sent.
        HelpDisclosure(
          label: l10n.feedbackWhatIsSent,
          open: _showPayload,
          onToggle: () => setState(() => _showPayload = !_showPayload),
        ),
        if (_showPayload) ...[
          Text(l10n.supportContextNote,
              style: TextStyle(
                  fontSize: 11, height: 1.4, color: AppColors.v3TextSecondary)),
          if (_signedIn) ...[
            const SizedBox(height: 4),
            Text(l10n.supportSignedInNote,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: AppColors.v3TextSecondary)),
          ],
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: SelectableText(
              // Masked in recording mode, as the fields above it are.
              Redactable.freeText(_preview()).displayIn(ref),
              style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11, height: 1.4),
            ),
          ),
        ],

        // A refusal: the form is as it was, and the text can go by another
        // way.
        if (_failure != null) ...[
          const SizedBox(height: 12),
          HelpFailureBox(
            message: _failure!,
            actions: [
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(LucideIcons.copy, size: 14),
                label: Text(l10n.copy, style: const TextStyle(fontSize: 12)),
              ),
              if (kZestSupportMailto != '')
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(kZestSupportMailto),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(LucideIcons.mail, size: 14),
                label: Text(l10n.helpEmail,
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
