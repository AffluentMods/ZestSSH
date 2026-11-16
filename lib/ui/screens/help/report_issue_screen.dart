import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/help/help_form_parts.dart';
import 'package:zestssh/ui/screens/help/public_text_preview.dart';
import 'package:zestssh/ui/screens/help/support_hub_parts.dart' show attachmentsRefusalSaid;
import 'package:zestssh/ui/widgets/recording_masked_controller.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/help_links.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';

/// Renders the app window to a PNG. `redacted` asks for recording-mode
/// masking during the capture even when the mode is off (spec 3a: screenshots
/// are redacted by default, regardless of the mode).
typedef ScreenshotCapture = Future<Uint8List?> Function({required bool redacted});

/// What differs between the bug form and the suggestion form (fixes spec,
/// section 10): three labels and two switches. Everything else is one widget,
/// so a change to the counter, the notice or the radio group lands on both
/// without a second edit.
class ReportFormSpec {
  const ReportFormSpec({
    required this.type,
    required this.title,
    required this.bodyLabel,
    this.secondaryLabel,
    this.tertiaryLabel,
    required this.showCategory,
    required this.showScreenshot,
    required this.visibilityNotice,
  });

  final FeedbackType type;
  final String title;
  final String bodyLabel;

  /// "What you expected" (bug) or "Why" (suggestion).
  final String? secondaryLabel;

  /// "Steps to reproduce", bugs only.
  final String? tertiaryLabel;
  final bool showCategory;
  final bool showScreenshot;
  final String visibilityNotice;

  factory ReportFormSpec.of(FeedbackType type, AppLocalizations l10n) {
    switch (type) {
      case FeedbackType.bug:
        return ReportFormSpec(
          type: type,
          title: l10n.helpReportBug,
          bodyLabel: l10n.reportBugWhatHappened,
          secondaryLabel: l10n.reportBugWhatExpected,
          tertiaryLabel: l10n.reportBugSteps,
          showCategory: false,
          showScreenshot: true,
          visibilityNotice: l10n.feedbackPublicNotice,
        );
      case FeedbackType.suggestion:
        return ReportFormSpec(
          type: type,
          title: l10n.helpSuggest,
          bodyLabel: l10n.reportSuggestWhat,
          secondaryLabel: l10n.reportSuggestWhy,
          tertiaryLabel: null,
          showCategory: true,
          showScreenshot: false,
          visibilityNotice: l10n.feedbackPublicNotice,
        );
    }
  }
}

/// The bug / suggestion form (help/feedback/support spec, section 3).
///
/// What it promises the user, and keeps:
///   * Submitting needs no account. Only six facts ride along automatically
///     (version, build, platform, OS version, language, plan), shown in an
///     expandable preview of the exact payload. No logs, no host list, no
///     config, no install id.
///   * A screenshot is opt-in and redacted by default.
///   * Anonymous by default. A Discord handle is typed by hand, never
///     prefilled from the account, and the form says the post is public.
///   * Text is never lost: a failed send is queued and retried on launch, and
///     the whole report can be copied to the clipboard.
///
/// On desktop it is a level inside the Help pane ([embedded]); on mobile a
/// full-screen route.
class ReportIssueScreen extends ConsumerStatefulWidget {
  const ReportIssueScreen({
    super.key,
    this.initialType,
    this.captureScreenshot,
    this.embedded = false,
    this.onDone,
  });

  /// The type chosen by the row that opened the form. Null shows a picker.
  final FeedbackType? initialType;

  /// Desktop only: the shell supplies a window capture. Null hides the
  /// screenshot option.
  final ScreenshotCapture? captureScreenshot;

  /// Inside the Help pane: no app bar, a sticky footer with the actions.
  final bool embedded;

  /// Fired after a successful send (the pane closes itself).
  final VoidCallback? onDone;

  @override
  ConsumerState<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

/// What the user typed, kept per type for the life of the process so that
/// closing the pane, switching levels or navigating away never loses it
/// (spec 3b). Cleared on a successful send. Text only: a screenshot is
/// cheap to retake and expensive to keep. Never written to disk.
class _Draft {
  const _Draft({
    required this.title,
    required this.body,
    required this.secondary,
    required this.tertiary,
    required this.category,
    required this.anonymous,
    required this.contact,
  });

  final String title, body, secondary, tertiary, contact;
  final FeedbackCategory? category;
  final bool anonymous;

  bool get isEmpty =>
      title.isEmpty &&
      body.isEmpty &&
      secondary.isEmpty &&
      tertiary.isEmpty &&
      contact.isEmpty;
}

final Map<FeedbackType, _Draft> _drafts = {};

/// What was typed and not sent is a person's words: it goes at a change of profile.
void forgetReportIssueDrafts() => _drafts.clear();

class _ReportIssueScreenState extends ConsumerState<ReportIssueScreen> {
  late FeedbackType _type = widget.initialType ?? FeedbackType.bug;
  // (While the screen is recorded they draw as bullets.)
  final _title = RecordingMaskedController();
  final _body = RecordingMaskedController();
  final _secondary = RecordingMaskedController();
  final _tertiary = RecordingMaskedController();
  final _contact = RecordingMaskedController();
  final _bodyFocus = FocusNode();
  final _contactFocus = FocusNode();

  Uint8List? _screenshot;
  FeedbackCategory? _category;
  bool _screenshotRedacted = true;
  bool _capturing = false;
  bool _anonymous = true;
  // A signed-in account rides along as a bearer for rate limiting; the
  // preview says so (it is not in the payload the preview shows).
  bool _signedIn = false;
  bool _showPayload = false;
  bool _sending = false;
  bool _submitted = false;

  /// Set after a failed send so the fallback row (copy / Discord) shows.
  String? _failureMessage;

  /// The last Send was refused for its screenshot: Send without it is
  /// offered.
  bool _failedForScreenshot = false;

  FeedbackContext? _context;

  List<RecordingMaskedController> get _controllers =>
      [_title, _body, _secondary, _tertiary, _contact];

  @override
  void initState() {
    super.initState();
    _restoreDraft();
    for (final c in _controllers) {
      c.addListener(_onEdit);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _collectContext());
  }

  @override
  void dispose() {
    _storeDraft();
    for (final c in _controllers) {
      c.dispose();
    }
    _bodyFocus.dispose();
    _contactFocus.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (mounted) setState(() {});
  }

  void _restoreDraft() {
    final d = _drafts[_type];
    if (d == null) return;
    _title.text = d.title;
    _body.text = d.body;
    _secondary.text = d.secondary;
    _tertiary.text = d.tertiary;
    _contact.text = d.contact;
    _category = d.category;
    _anonymous = d.anonymous;
  }

  void _storeDraft() {
    final d = _Draft(
      title: _title.text,
      body: _body.text,
      secondary: _secondary.text,
      tertiary: _tertiary.text,
      category: _category,
      anonymous: _anonymous,
      contact: _contact.text,
    );
    if (d.isEmpty) {
      _drafts.remove(_type);
    } else {
      _drafts[_type] = d;
    }
  }

  Future<void> _collectContext() async {
    final found = await collectFeedbackContext(context, ref);
    if (found == null || !mounted) return;
    setState(() {
      _context = found.$1;
      _signedIn = found.$2;
    });
  }

  /// The report as it goes; [words] (title, body, the second and the third
  /// field) as the person saw them before it went, scrubbed.
  FeedbackReport _buildReport({List<String>? words}) {
    final isBug = _type == FeedbackType.bug;
    final w = words ?? [_title.text, _body.text, _secondary.text, _tertiary.text];
    return FeedbackReport(
      type: _type,
      title: w[0],
      body: w[1],
      expected: isBug ? w[2] : null,
      steps: isBug ? w[3] : null,
      why: isBug ? null : w[2],
      category: isBug ? null : _category,
      context: _context ??
          const FeedbackContext(
            appVersion: '',
            build: 0,
            platform: '',
            osVersion: '',
            locale: '',
            tier: '',
          ),
      contact: _anonymous || _contact.text.trim().isEmpty
          ? null
          : FeedbackContact.discord(_contact.text.trim()),
      screenshotPng: _screenshot,
      screenshotRedacted: _screenshotRedacted,
    );
  }

  bool get _bodyMissing => _submitted && _body.text.trim().isEmpty;
  bool get _contactMissing =>
      _submitted && !_anonymous && _contact.text.trim().isEmpty;

  // ── Screenshot ────────────────────────────────────────────────────

  Future<void> _capture({required bool redacted}) async {
    final cap = widget.captureScreenshot;
    if (cap == null) return;
    setState(() => _capturing = true);
    Uint8List? png;
    try {
      png = await cap(redacted: redacted);
    } catch (_) {
      png = null;
    }
    if (!mounted) return;
    if (png != null && png.length > FeedbackLimits.screenshotMaxBytes) {
      png = null;
    }
    setState(() {
      _capturing = false;
      _screenshot = png;
      _screenshotRedacted = redacted;
    });
    if (png == null) {
      showTopSnackBar(
          context, AppLocalizations.of(context)!.recModeCopyScreenshotFailed);
    }
  }

  // ── Send ──────────────────────────────────────────────────────────

  /// Send stays enabled (fixes spec, section 6): pressing it on an
  /// incomplete form names the first missing field inline and focuses it,
  /// which is one click to find out instead of a hunt.
  Future<void> _send() async {
    if (_sending) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _submitted = true;
      _failureMessage = null;
      _failedForScreenshot = false;
    });
    if (_body.text.trim().isEmpty) {
      _bodyFocus.requestFocus();
      return;
    }
    if (!_anonymous && _contact.text.trim().isEmpty) {
      _contactFocus.requestFocus();
      return;
    }
    if (_context == null) return;
    // A report is public, listed in every app and posted to Discord as it
    // is sent: its words go through the same scrubbing as diagnostics, and
    // the person sees exactly what goes, with what was taken out marked,
    // before it does (a 3.4 security review).
    final spec = ReportFormSpec.of(_type, l10n);
    final shown = await confirmPublicText(context, [
      (label: l10n.reportTitleLabel, text: _title.text),
      (label: spec.bodyLabel, text: _body.text),
      (label: spec.secondaryLabel ?? '', text: spec.secondaryLabel == null ? '' : _secondary.text),
      (label: spec.tertiaryLabel ?? '', text: spec.tertiaryLabel == null ? '' : _tertiary.text),
    ]);
    if (shown == null || !mounted || _sending) return;
    setState(() => _sending = true);
    final report = _buildReport(words: shown);
    final result = await ref.read(feedbackServiceProvider).send(report);
    if (!mounted) return;
    setState(() => _sending = false);
    if (result.attachments case final why?) {
      // Refused for the screenshot, not the words: they can go without it.
      setState(() {
        _failureMessage = attachmentsRefusalSaid(l10n, why, result.retryMinutes);
        _failedForScreenshot = true;
      });
      return;
    }
    switch (result.outcome) {
      case FeedbackOutcome.sent:
        final msg =
            report.isAnonymous ? l10n.feedbackSentAnon : l10n.feedbackSentNamed;
        // Sent: the draft has done its job. Clear the fields too, so the
        // dispose-time store keeps nothing.
        _drafts.remove(_type);
        for (final c in _controllers) {
          c.clear();
        }
        _category = null;
        final root = Navigator.of(context, rootNavigator: true).context;
        if (widget.embedded) {
          widget.onDone?.call();
        } else {
          Navigator.of(context).pop();
        }
        if (root.mounted) showTopSnackBar(root, msg, isSuccess: true);
      case FeedbackOutcome.queued:
        setState(() => _failureMessage = l10n.feedbackFailedQueued);
      case FeedbackOutcome.rateLimited:
        setState(() => _failureMessage =
            l10n.feedbackRateLimited(result.retryMinutes ?? 5));
      case FeedbackOutcome.blocked:
        setState(() => _failureMessage = l10n.feedbackBlocked);
      case FeedbackOutcome.rejected:
        setState(() => _failureMessage = l10n.reportFailed);
    }
  }

  Future<void> _copyToClipboard() async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(
        ClipboardData(text: _buildReport().toClipboardText()));
    if (mounted) showTopSnackBar(context, l10n.reportCopied, isSuccess: true);
  }

  Future<void> _openDiscord() => launchUrl(Uri.parse(kZestDiscordUrl),
      mode: LaunchMode.externalApplication);

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.maskWhileRecording(_controllers);
    final spec = ReportFormSpec.of(_type, l10n);
    final fields = _fields(context, l10n, spec);
    final actions = _actions(l10n);
    if (widget.embedded) {
      // The pane owns the header; the actions are a sticky footer.
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
              border:
                  Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
            ),
            child: actions,
          ),
        ],
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(spec.title),
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

  Widget _fields(
      BuildContext context, AppLocalizations l10n, ReportFormSpec spec) {
    final canScreenshot =
        spec.showScreenshot && widget.captureScreenshot != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Type picker only when the caller did not choose (spec 2: the row
        // that opened the form already said which).
        if (widget.initialType == null) ...[
          SegmentedButton<FeedbackType>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected)
                      ? AppColors.accentInk
                      : AppColors.v3TextSecondary),
            ),
            segments: [
              // Each word smaller where it does not fit its half of the row
              // ("Suggerimento" and "Предложение" were cut in two there).
              ButtonSegment(
                  value: FeedbackType.bug,
                  icon: const Icon(LucideIcons.bug, size: 14),
                  label: FittedBox(fit: BoxFit.scaleDown, child: Text(l10n.reportTypeBug, maxLines: 1))),
              ButtonSegment(
                  value: FeedbackType.suggestion,
                  icon: const Icon(LucideIcons.lightbulb, size: 14),
                  label: FittedBox(fit: BoxFit.scaleDown, child: Text(l10n.reportTypeSuggestion, maxLines: 1))),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 16),
        ],

        // Title (optional): the Discord thread name, derived from the body
        // when left empty, so it is never a blocker.
        _label(l10n.reportTitleLabel),
        _field(
          controller: _title,
          maxLength: FeedbackLimits.titleMax,
          hint: l10n.reportTitleHint,
        ),
        const SizedBox(height: 8),

        // Body: "What happened" / "What you want".
        _label(spec.bodyLabel),
        _field(
          controller: _body,
          focusNode: _bodyFocus,
          maxLength: FeedbackLimits.bodyMax,
          minLines: 4,
          maxLines: 10,
          errorText: _bodyMissing ? l10n.reportSendMissingBody : null,
        ),
        const SizedBox(height: 8),

        if (spec.secondaryLabel != null) ...[
          _label(spec.secondaryLabel!),
          _field(
            controller: _secondary,
            maxLength: FeedbackLimits.extraMax,
            minLines: 2,
            maxLines: 6,
          ),
          const SizedBox(height: 8),
        ],
        if (spec.tertiaryLabel != null) ...[
          _label(spec.tertiaryLabel!),
          _field(
            controller: _tertiary,
            maxLength: FeedbackLimits.extraMax,
            minLines: 2,
            maxLines: 8,
          ),
          const SizedBox(height: 8),
        ],

        // The suggestions forum's public tags (fixes spec, section 5): pills
        // like every other chip in the app, single-select, tapping the chosen
        // one clears it. Sent as a stable value the bot maps to the tag id.
        if (spec.showCategory) ...[
          _label(l10n.reportCategoryLabel),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in FeedbackCategory.values)
                ReportCategoryChip(
                  label: reportCategoryName(l10n, c),
                  selected: _category == c,
                  onTap: () =>
                      setState(() => _category = _category == c ? null : c),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),

        // Screenshot (desktop bug reports only), redacted by default.
        if (canScreenshot) ...[
          if (_screenshot == null)
            _checkRow(
              value: false,
              enabled: !_capturing,
              label: l10n.feedbackAttach,
              trailing: _capturing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
              onChanged: (_) => _capture(redacted: true),
            )
          else
            _screenshotCard(l10n),
          const SizedBox(height: 12),
        ],

        // The post is public (spec 3a), said before sending. A line, not a
        // card: the decision below it is the thing that deserves the weight.
        HelpNoticeLine(icon: LucideIcons.globe, text: spec.visibilityNotice),
        const SizedBox(height: 14),

        // Identity (spec 1): anonymous by default, a handle typed by hand.
        // Choosing to follow up reveals the handle field right underneath.
        RadioGroup<bool>(
          groupValue: _anonymous,
          onChanged: (anonymous) {
            if (anonymous != null) _pickAnonymous(anonymous);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _choiceRow(
                key: const ValueKey('report-anonymous'),
                value: true,
                title: l10n.feedbackAnonymous,
                subtitle: l10n.feedbackAnonymousDesc,
                onTap: () => _pickAnonymous(true),
              ),
              _choiceRow(
                key: const ValueKey('report-follow-up'),
                value: false,
                title: l10n.feedbackFollowUp,
                onTap: () => _pickAnonymous(false),
              ),
            ],
          ),
        ),
        if (!_anonymous)
          Padding(
            padding: const EdgeInsets.only(left: 30, top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(l10n.reportContactLabel),
                _field(
                  controller: _contact,
                  focusNode: _contactFocus,
                  maxLength: FeedbackLimits.contactMax,
                  hint: '@handle',
                  errorText: _contactMissing ? l10n.reportRequired : null,
                ),
                const SizedBox(height: 4),
                Text(l10n.reportContactDesc,
                    style: TextStyle(
                        fontSize: 11.5, color: AppColors.v3TextSecondary)),
              ],
            ),
          ),
        const SizedBox(height: 12),

        // Payload preview (spec 3a: the difference between this and
        // telemetry).
        HelpDisclosure(
          label: l10n.feedbackWhatIsSent,
          open: _showPayload,
          onToggle: () => setState(() => _showPayload = !_showPayload),
        ),
        if (_showPayload) ...[
          Text(l10n.reportContextNote,
              style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: AppColors.v3TextSecondary)),
          if (_signedIn) ...[
            const SizedBox(height: 4),
            Text(l10n.reportSignedInNote,
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
              Redactable.freeText(_buildReport().toPreviewJson()).displayIn(ref),
              style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11, height: 1.4),
            ),
          ),
        ],

        // Failure fallback (spec 3b): the text is never lost.
        if (_failureMessage != null) ...[
          const SizedBox(height: 12),
          HelpFailureBox(
            message: _failureMessage!,
            actions: [
              if (_failedForScreenshot)
                OutlinedButton.icon(
                  key: const ValueKey('report-send-without-attachments'),
                  onPressed: _sending
                      ? null
                      : () {
                          setState(() => _screenshot = null);
                          _send();
                        },
                  icon: const Icon(LucideIcons.send, size: 14),
                  label: Text(l10n.supportSendWithoutAttachments, style: const TextStyle(fontSize: 12)),
                ),
              OutlinedButton.icon(
                onPressed: _copyToClipboard,
                icon: const Icon(LucideIcons.copy, size: 14),
                label: Text(l10n.feedbackCopyToClipboard,
                    style: const TextStyle(fontSize: 12)),
              ),
              if (kZestDiscordUrl != '')
              OutlinedButton.icon(
                onPressed: _openDiscord,
                icon: const Icon(LucideIcons.externalLink, size: 14),
                label: Text(l10n.helpOpenDiscord,
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// The attached screenshot, stacked (the pane is 400px wide) with a line
  /// saying where it came from and a Retake for after the problem has been
  /// reproduced on screen.
  Widget _screenshotCard(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.reportScreenshotAttached,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Text(
                _screenshotRedacted
                    ? l10n.feedbackAttachRedacted
                    : l10n.feedbackAttachUnredact,
                style: TextStyle(
                    fontSize: 11,
                    color: _screenshotRedacted
                        ? AppColors.v3TextSecondary
                        : AppColors.warning),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: Image.memory(_screenshot!,
                  fit: BoxFit.contain, alignment: Alignment.centerLeft),
            ),
          ),
          const SizedBox(height: 6),
          Text(l10n.feedbackAttachSource,
              style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: AppColors.v3TextSecondary)),
          const SizedBox(height: 4),
          _checkRow(
            value: !_screenshotRedacted,
            enabled: !_capturing,
            dense: true,
            label: l10n.feedbackAttachUnredact,
            onChanged: (v) => _capture(redacted: !(v ?? false)),
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _capturing
                    ? null
                    : () => _capture(redacted: _screenshotRedacted),
                icon: const Icon(LucideIcons.refreshCw, size: 13),
                label: Text(l10n.feedbackAttachRetake,
                    style: const TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _screenshot = null),
                child: Text(l10n.reportScreenshotRemove,
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actions(AppLocalizations l10n) {
    return Row(
      children: [
        // Labelled, not a bare glyph (fixes spec, section 7): this is the
        // fallback when a send fails and a legitimate way to take the text
        // to Discord instead.
        Tooltip(
          message: l10n.reportCopyTooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: TextButton.icon(
            onPressed: _copyToClipboard,
            icon: const Icon(LucideIcons.copy, size: 14),
            label: Text(l10n.reportCopy, style: const TextStyle(fontSize: 12)),
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
  }

  Widget _label(String text) => helpFormLabel(text);

  /// One capped text field, with the counter every Help form shares.
  Widget _field({
    required TextEditingController controller,
    required int maxLength,
    FocusNode? focusNode,
    int minLines = 1,
    int maxLines = 1,
    String? hint,
    String? errorText,
  }) =>
      HelpFormField(
        controller: controller,
        maxLength: maxLength,
        focusNode: focusNode,
        minLines: minLines,
        maxLines: maxLines,
        hint: hint,
        errorText: errorText,
      );

  /// Anonymous, or a way to follow up: following up takes the contact field.
  void _pickAnonymous(bool anonymous) {
    setState(() => _anonymous = anonymous);
    if (!anonymous) _contactFocus.requestFocus();
  }

  /// One of two exclusive choices (anonymous / follow up), drawn as a radio
  /// row so the default reads as a choice, not a checkbox: the dot radio the
  /// dialogs have, in the RadioGroup around the two (it was a check in a
  /// circle, which is for where several
  /// can be picked).
  Widget _choiceRow({
    Key? key,
    required bool value,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    // One stop to a screen reader: the dot and its words, said chosen or not
    // (the dot was a radio of nothing, its words a second stop).
    return MergeSemantics(
      child: InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Radio<bool>(value: value),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.v3TextPrimary)),
                  if (subtitle != null)
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.v3TextSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _checkRow({
    required bool value,
    required String label,
    Widget? trailing,
    bool enabled = true,
    bool dense = false,
    required ValueChanged<bool?> onChanged,
  }) =>
      HelpCheckRow(
        value: value,
        label: label,
        trailing: trailing,
        enabled: enabled,
        dense: dense,
        onChanged: onChanged,
      );
}

/// What a suggestion's category is called.
String reportCategoryName(AppLocalizations l10n, FeedbackCategory c) => switch (c) {
      FeedbackCategory.uiUx => l10n.reportCategoryUiUx,
      FeedbackCategory.newFeature => l10n.reportCategoryNewFeature,
      FeedbackCategory.qualityOfLife => l10n.reportCategoryQol,
    };

/// A pill chip with an unmistakable selected state (fixes spec, section 5):
/// rest is the chip fill with a hairline, hover lifts one surface step, and
/// selected is the brand wash with a brand hairline and a check glyph, so the
/// state reads with the label covered.
class ReportCategoryChip extends StatefulWidget {
  const ReportCategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<ReportCategoryChip> createState() => _ReportCategoryChipState();
}

class _ReportCategoryChipState extends State<ReportCategoryChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fill = selected
        ? AppColors.brandOrange.withValues(alpha: 0.16)
        : _hover
            ? AppColors.v3Hover
            : AppColors.v3Surface;
    final line = selected
        ? AppColors.brandOrange.withValues(alpha: 0.7)
        : _hover
            ? AppColors.v3BorderDefault
            : AppColors.v3BorderSubtle;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        button: true,
        selected: selected,
        label: widget.label,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(LucideIcons.check,
                      size: 12, color: AppColors.accentInk),
                  const SizedBox(width: 5),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? AppColors.v3TextPrimary
                        : AppColors.v3TextSecondary,
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
