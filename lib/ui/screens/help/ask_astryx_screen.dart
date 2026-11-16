import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/assistant/assistant_service.dart';
import 'package:zestssh/features/help/guides/guide_entry.dart';
import 'package:zestssh/features/help/guides/guide_markdown.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/screens/help/guide_markdown_view.dart';
import 'package:zestssh/ui/screens/help/help_form_parts.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart' show ScreenshotCapture;
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/recording_masked_controller.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// Ask Astryx (4.0, a named preview): a question to Astryx, ZestSSH's help
/// assistant, answered from the docs with links to the pages it used.
///
/// What it promises, and keeps:
///   * Paid plans and team members only, decided by ZestSSH Cloud; the panel
///     shows whatever the server says (signed out, free, today's questions
///     used, paused for the month, switched off) with what still works.
///   * The person sends a question by pressing Ask, never anything else. What
///     goes is shown under "See exactly what is sent", after the app's own
///     redaction (ReportScrub), and a screenshot is the redacted capture the
///     tickets use, shown before it goes. Phones take no screenshot.
///   * The question goes through ZestSSH to Anthropic (Claude); ZestSSH keeps
///     neither. The conversation lives in this panel and goes with it.
///   * "Open a ticket with this" fills a private support ticket with the
///     question and the answer, both editable; nothing is sent until the
///     person sends it.
///   * Nothing here stands between anyone and SSH: it is a help panel.
class AskAstryxScreen extends ConsumerStatefulWidget {
  const AskAstryxScreen({
    super.key,
    this.embedded = false,
    this.captureScreenshot,
    required this.onOpenTicket,
    this.onSearchGuides,
    this.onContactSupport,
    this.onOpenGuide,
  });

  /// A level inside the desktop Help panel; else a phone screen of its own.
  final bool embedded;

  /// The app's redacted screenshot (computers); null where there is none.
  final ScreenshotCapture? captureScreenshot;

  /// The support form, after [seedContactSupportFromAstryx] filled it in.
  final VoidCallback onOpenTicket;
  final VoidCallback? onSearchGuides;
  final VoidCallback? onContactSupport;

  /// A link in an answer to a guide the app has: open it in the reader.
  final ValueChanged<String>? onOpenGuide;

  @override
  ConsumerState<AskAstryxScreen> createState() => _AskAstryxScreenState();
}

/// One question and what came of it.
class _Exchange {
  _Exchange({required this.question, required this.sent, required this.screenshots});

  /// As typed (shown back, masked in recording mode).
  final String question;

  /// As it went, after ReportScrub (what a ticket is filled in with).
  final String sent;
  final int screenshots;
  AssistantAnswer? answer;
}

class _AskAstryxScreenState extends ConsumerState<AskAstryxScreen> {
  final _question = RecordingMaskedController();
  final _questionFocus = FocusNode();
  final _scroll = ScrollController();
  final List<_Exchange> _exchanges = [];

  Uint8List? _screenshot;
  bool _capturing = false;
  bool _asking = false;
  bool _showPayload = false;
  bool _submitted = false;
  AssistantFailure? _failure;
  int? _leftToday;
  int? _dailyLimit;

  @override
  void initState() {
    super.initState();
    _question.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _question.dispose();
    _questionFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<AssistantTurn> get _history => [
        for (final e in _exchanges)
          if (e.answer != null && e.answer!.kind == AssistantAnswerKind.ok) ...[
            AssistantTurn.user(e.question),
            AssistantTurn.astryx(e.answer!.text),
          ],
      ];

  Map<String, dynamic> _request() => AssistantService.request(
        question: _question.text,
        history: _history,
        images: [?_screenshot],
      );

  Future<void> _capture() async {
    final cap = widget.captureScreenshot;
    if (cap == null) return;
    final l10n = AppLocalizations.of(context)!;
    final max = ref.read(assistantStatusProvider).valueOrNull?.imageMaxBytes ?? 2621440;
    setState(() => _capturing = true);
    Uint8List? png;
    try {
      // Always the redacted one: a secret on screen must not go to Anthropic.
      png = await cap(redacted: true);
    } catch (_) {
      png = null;
    }
    if (!mounted) return;
    if (png != null && png.length > max) png = null;
    setState(() {
      _capturing = false;
      _screenshot = png;
    });
    if (png == null) showTopSnackBar(context, l10n.recModeCopyScreenshotFailed);
  }

  Future<void> _ask() async {
    if (_asking) return;
    final l10n = AppLocalizations.of(context)!;
    final typed = _question.text.trim();
    setState(() {
      _submitted = true;
      _failure = null;
    });
    if (typed.isEmpty && _screenshot == null) {
      _questionFocus.requestFocus();
      return;
    }
    final images = [?_screenshot];
    final exchange = _Exchange(
      question: typed,
      sent: ReportScrub.scrub(typed),
      screenshots: images.length,
    );
    final history = _history;
    setState(() => _asking = true);
    zestAnnounce(context, l10n.astryxThinking);
    try {
      final answer = await ref.read(assistantServiceProvider).ask(question: typed, history: history, images: images);
      if (!mounted) return;
      exchange.answer = answer;
      setState(() {
        _exchanges.add(exchange);
        _asking = false;
        _submitted = false;
        _screenshot = null;
        _showPayload = false;
        _question.clear();
        if (answer.leftToday != null) _leftToday = answer.leftToday;
        if (answer.dailyLimit != null) _dailyLimit = answer.dailyLimit;
      });
      zestAnnounce(
        context,
        answer.kind == AssistantAnswerKind.degraded
            ? l10n.astryxNotAnsweringTitle
            : '${l10n.astryxAnswered} ${answer.text}',
      );
      _scrollToEnd();
    } on AssistantFailure catch (f) {
      if (!mounted) return;
      setState(() {
        _asking = false;
        _failure = f;
        if (f.block == AssistantBlock.dailyLimit) _leftToday = 0;
      });
      zestAnnounce(context, _failureTitle(l10n, f));
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: zestMotion(context, const Duration(milliseconds: 220)),
        curve: Curves.easeOut,
      );
    });
  }

  void _newQuestion() {
    setState(() {
      _exchanges.clear();
      _failure = null;
      _screenshot = null;
      _submitted = false;
      _question.clear();
    });
    _questionFocus.requestFocus();
  }

  /// "Open a ticket with this": the support form, filled in.
  void _openTicket(_Exchange e) {
    final l10n = AppLocalizations.of(context)!;
    final firstLine = e.sent.split('\n').first.trim();
    final subject = firstLine.length > 120 ? '${firstLine.substring(0, 117)}...' : firstLine;
    final answer = e.answer;
    final b = StringBuffer(e.sent);
    if (answer != null && answer.kind == AssistantAnswerKind.ok && answer.text.isNotEmpty) {
      b
        ..write('\n\n')
        ..writeln(l10n.astryxTicketAnswerHeading(_modelName(answer.model)))
        ..write(answer.text);
    }
    b
      ..write('\n\n')
      ..write(l10n.astryxTicketTriedHeading)
      ..write(' ');
    seedContactSupportFromAstryx(
      subject: subject.isEmpty ? l10n.astryxTitle : subject,
      message: b.toString(),
    );
    widget.onOpenTicket();
  }

  Future<void> _copyAnswer(String text) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showTopSnackBar(context, l10n.astryxCopied, isSuccess: true);
  }

  void _openLink(String url) {
    // ignore: discarded_futures
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.maskWhileRecording([_question]);
    final status = ref.watch(assistantStatusProvider);
    final s = status.valueOrNull;
    final left = _leftToday ?? s?.leftToday;
    final limit = _dailyLimit ?? s?.dailyLimit;

    // What the panel can do now: a state that stops it, or the conversation.
    Widget? stopped;
    if (status.hasError) {
      final e = status.error;
      stopped = _stateFor(l10n, e is AssistantFailure ? e : const AssistantFailure(AssistantFailureKind.cloud),
          retry: () => ref.invalidate(assistantStatusProvider), error: e);
    } else if (s != null && !s.available && _exchanges.isEmpty) {
      stopped = _stateFor(l10n, AssistantFailure(AssistantFailureKind.blocked, block: s.block, resetsAt: s.capResetsAt),
          retry: () => ref.invalidate(assistantStatusProvider));
    }
    final blockedNow = _failure?.kind == AssistantFailureKind.blocked || _failure?.kind == AssistantFailureKind.notSignedIn;
    final canAsk = s != null && s.available && stopped == null && !blockedNow;

    final body = <Widget>[
      if (left != null && limit != null && stopped == null)
        Semantics(
          liveRegion: true,
          child: Row(
            children: [
              Icon(LucideIcons.sparkles, size: 15, color: ZestTokens.brand),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l10n.astryxLeftToday(left, limit),
                    style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
              ),
              if (widget.embedded && _exchanges.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('astryx-new'),
                  onPressed: _asking ? null : _newQuestion,
                  icon: const Icon(LucideIcons.plus, size: 14),
                  label: Text(l10n.astryxNewQuestion, style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
      if (_exchanges.isEmpty) ...[
        const SizedBox(height: 10),
        Text(l10n.astryxIntro, style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.v3TextSecondary)),
      ],
      if (status.isLoading && s == null) ...[
        const SizedBox(height: 20),
        const Center(child: SizedBox(width: 18, height: 18, child: ButtonSpinner())),
      ],
      if (stopped != null) ...[const SizedBox(height: 14), stopped],
      for (final e in _exchanges) ...[const SizedBox(height: 12), _exchangeView(l10n, e)],
      if (_exchanges.isNotEmpty && !_asking && _exchanges.last.answer?.kind == AssistantAnswerKind.ok) ...[
        const SizedBox(height: 12),
        _StillStuck(onOpen: () => _openTicket(_exchanges.last)),
      ],
      if (_asking) ...[
        const SizedBox(height: 14),
        Row(children: [
          const SizedBox(width: 14, height: 14, child: ButtonSpinner()),
          const SizedBox(width: 10),
          Expanded(child: Text(l10n.astryxThinking, style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary))),
        ]),
      ],
      if (_failure != null) ...[
        const SizedBox(height: 14),
        _stateFor(l10n, _failure!, retry: blockedNow ? null : _ask, error: _failure, inline: true),
      ],
      if (canAsk && _exchanges.isEmpty) ...[
        const SizedBox(height: 14),
        _compose(l10n),
      ],
      if (canAsk && _exchanges.isNotEmpty && _showPayload) ...[
        const SizedBox(height: 12),
        _payload(l10n),
      ],
    ];

    final footer = canAsk ? _footer(l10n) : null;
    final list = ListView(
      controller: _scroll,
      padding: widget.embedded ? const EdgeInsets.fromLTRB(16, 12, 16, 16) : const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: body,
    );
    final column = Column(
      children: [
        Expanded(child: list),
        if (footer != null)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: AppColors.v3BorderSubtle))),
            child: SafeArea(top: false, child: footer),
          ),
      ],
    );
    if (widget.embedded) return column;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(l10n.astryxTitle)),
          const SizedBox(width: 8),
          const AstryxPreviewBadge(),
        ]),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_exchanges.isNotEmpty)
            IconButton(
              tooltip: l10n.astryxNewQuestion,
              icon: const Icon(LucideIcons.plus),
              onPressed: _newQuestion,
            ),
        ],
      ),
      body: column,
    );
  }

  Widget _compose(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        helpFormLabel(l10n.astryxQuestionLabel),
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true): _ask,
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): _ask,
          },
          child: HelpFormField(
            controller: _question,
            focusNode: _questionFocus,
            maxLength: AssistantService.questionMax,
            minLines: 4,
            maxLines: 10,
            hint: l10n.astryxQuestionHint,
            errorText: _submitted && _question.text.trim().isEmpty && _screenshot == null
                ? l10n.astryxQuestionMissing
                : null,
          ),
        ),
        const SizedBox(height: 10),
        if (widget.captureScreenshot != null) ...[
          if (_screenshot == null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const ValueKey('astryx-attach'),
                onPressed: _capturing ? null : _capture,
                icon: const Icon(LucideIcons.crop, size: 14),
                label: Text(l10n.astryxAttach, style: const TextStyle(fontSize: 12.5)),
              ),
            )
          else
            _screenshotCard(l10n),
          const SizedBox(height: 12),
        ] else ...[
          Text(l10n.astryxPhoneNoScreenshot, style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextTertiary)),
          const SizedBox(height: 12),
        ],
        HelpNoticeLine(icon: LucideIcons.lock, text: l10n.astryxPrivacy),
        const SizedBox(height: 10),
        HelpDisclosure(
          label: l10n.feedbackWhatIsSent,
          open: _showPayload,
          onToggle: () => setState(() => _showPayload = !_showPayload),
        ),
        if (_showPayload) _payload(l10n),
      ],
    );
  }

  Widget _payload(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.astryxWhatIsSentNote, style: TextStyle(fontSize: 11, height: 1.4, color: AppColors.v3TextSecondary)),
        const SizedBox(height: 6),
        Container(
          key: const ValueKey('astryx-payload'),
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: SelectableText(
            // Masked in recording mode, as the field above it is.
            Redactable.freeText(AssistantService.previewOf(_request())).displayIn(ref),
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _screenshotCard(AppLocalizations l10n) {
    return Container(
      key: const ValueKey('astryx-screenshot'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.astryxScreenshotRedacted, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(l10n.feedbackAttachRedacted, style: TextStyle(fontSize: 11, height: 1.35, color: AppColors.v3TextSecondary)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: Semantics(
                image: true,
                label: l10n.astryxScreenshotRedacted,
                child: Image.memory(_screenshot!, fit: BoxFit.contain, alignment: Alignment.centerLeft,
                    errorBuilder: (_, _, _) => const SizedBox(height: 40)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton.icon(
                onPressed: _capturing ? null : _capture,
                icon: const Icon(LucideIcons.refreshCw, size: 13),
                label: Text(l10n.feedbackAttachRetake, style: const TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _screenshot = null),
                child: Text(l10n.reportScreenshotRemove, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footer(AppLocalizations l10n) {
    if (_exchanges.isEmpty) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilledButton.icon(
          key: const ValueKey('astryx-ask'),
          onPressed: _asking ? null : _ask,
          icon: _asking
              ? const SizedBox(width: 14, height: 14, child: ButtonSpinner())
              : const Icon(LucideIcons.send, size: 14),
          label: Text(l10n.astryxTitle),
        ),
      );
    }
    // A follow-up: the same question field, one line, with what is sent a tap away.
    return Row(
      children: [
        IconButton(
          tooltip: l10n.feedbackWhatIsSent,
          isSelected: _showPayload,
          onPressed: () {
            setState(() => _showPayload = !_showPayload);
            if (_showPayload) _scrollToEnd();
          },
          icon: const Icon(LucideIcons.eye, size: 18),
        ),
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): _ask,
            },
            child: HelpFormField(
              controller: _question,
              focusNode: _questionFocus,
              maxLength: AssistantService.questionMax,
              hint: l10n.astryxFollowUpHint,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          key: const ValueKey('astryx-ask'),
          tooltip: l10n.astryxTitle,
          style: IconButton.styleFrom(backgroundColor: ZestTokens.brand, foregroundColor: ZestTokens.onBrand),
          onPressed: _asking ? null : _ask,
          icon: _asking
              ? const SizedBox(width: 16, height: 16, child: ButtonSpinner())
              : const Icon(LucideIcons.send, size: 18),
        ),
      ],
    );
  }

  Widget _exchangeView(AppLocalizations l10n, _Exchange e) {
    final a = e.answer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (e.question.isNotEmpty || e.screenshots > 0)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Semantics(
                label: l10n.astryxYouAsked,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  decoration: BoxDecoration(
                    color: AppColors.v3Elevated,
                    border: Border.all(color: AppColors.v3BorderSubtle),
                    borderRadius: const BorderRadiusDirectional.only(
                      topStart: Radius.circular(12),
                      topEnd: Radius.circular(12),
                      bottomStart: Radius.circular(12),
                      bottomEnd: Radius.circular(4),
                    ).resolve(Directionality.of(context)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (e.question.isNotEmpty)
                        SelectableText(Redactable.freeText(e.question).displayIn(ref),
                            style: const TextStyle(fontSize: 13.5, height: 1.45)),
                      if (e.screenshots > 0) ...[
                        const SizedBox(height: 4),
                        Text(l10n.astryxScreenshotRedacted,
                            style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        if (a != null) _answerView(l10n, e, a),
      ],
    );
  }

  Widget _answerView(AppLocalizations l10n, _Exchange e, AssistantAnswer a) {
    if (a.kind == AssistantAnswerKind.degraded) {
      return _StateCard(
        icon: LucideIcons.alertCircle,
        tone: _Tone.warn,
        title: l10n.astryxNotAnsweringTitle,
        body: l10n.astryxDocsInstead,
        code: ErrorCodes.assistantNotAnswering,
        links: [for (final d in a.docs) d],
        onLink: _openLink,
        actions: [
          FilledButton.icon(
            onPressed: _asking
                ? null
                : () {
                    setState(() {
                      _exchanges.remove(e);
                      _question.text = e.question;
                    });
                    _ask();
                  },
            icon: const Icon(LucideIcons.refreshCw, size: 14),
            label: Text(l10n.astryxTryAgain),
          ),
          OutlinedButton.icon(
            onPressed: () => _openTicket(e),
            icon: const Icon(LucideIcons.messageSquare, size: 14),
            label: Text(l10n.astryxOpenTicket),
          ),
        ],
      );
    }
    final model = _modelName(a.model);
    return Container(
      key: const ValueKey('astryx-answer'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        border: Border.all(color: AppColors.v3BorderSubtle),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (a.kind == AssistantAnswerKind.ok)
            Row(children: [
              Icon(LucideIcons.sparkles, size: 13, color: ZestTokens.brand),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  a.imagesRead ? '${l10n.astryxAnsweredBy(model)} · ${l10n.astryxReadScreenshot}' : l10n.astryxAnsweredBy(model),
                  style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary),
                ),
              ),
            ]),
          if (a.kind == AssistantAnswerKind.ok) const SizedBox(height: 6),
          for (final note in [a.imageNote, ...a.imagesRefused])
            if (note.isNotEmpty) ...[
              HelpNoticeLine(icon: LucideIcons.info, text: note),
              const SizedBox(height: 6),
            ],
          if (a.removedSecrets.isNotEmpty) ...[
            _Warning(text: l10n.astryxRemovedSecrets(a.removedSecrets.join(', '))),
            const SizedBox(height: 8),
          ],
          if (a.imageSecrets.isNotEmpty) ...[
            _Warning(text: l10n.astryxImageSecrets(a.imageSecrets.join(', '))),
            const SizedBox(height: 8),
          ],
          GuideMarkdownView(
            blocks: parseGuideMarkdown(a.text),
            slug: 'index',
            fontSize: 13.5,
            onOpenGuide: widget.onOpenGuide ?? (slug) => _openLink(guidePageUri(slug).toString()),
          ),
          if (a.sources.isNotEmpty) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: AppColors.v3BorderSubtle),
            const SizedBox(height: 8),
            Text(l10n.astryxFromTheDocs.toUpperCase(),
                style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: AppColors.v3TextTertiary)),
            const SizedBox(height: 4),
            for (final d in a.sources) _DocLink(doc: d, onOpen: _openLink),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: () => _copyAnswer(a.text),
                icon: const Icon(LucideIcons.copy, size: 14),
                label: Text(l10n.astryxCopyAnswer),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _failureTitle(AppLocalizations l10n, AssistantFailure f) => switch (f.kind) {
        AssistantFailureKind.notSignedIn => l10n.astryxSignInTitle,
        AssistantFailureKind.cloud => l10n.astryxCloudTitle,
        AssistantFailureKind.refused => l10n.astryxRefusedTitle,
        AssistantFailureKind.busy => l10n.astryxBusyTitle,
        AssistantFailureKind.notAnswering => l10n.astryxNotAnsweringTitle,
        AssistantFailureKind.blocked => switch (f.block) {
            AssistantBlock.paidOnly => l10n.astryxPaidTitle,
            AssistantBlock.dailyLimit => l10n.astryxLimitTitle,
            AssistantBlock.capReached => l10n.astryxCapTitle,
            AssistantBlock.planUnknown => l10n.astryxPlanUnknownTitle,
            AssistantBlock.off || null => l10n.astryxOffTitle,
          },
      };

  /// What the panel says for [f]: what happened, what still works, what to do.
  Widget _stateFor(AppLocalizations l10n, AssistantFailure f,
      {VoidCallback? retry, Object? error, bool inline = false}) {
    final guides = widget.onSearchGuides;
    final support = widget.onContactSupport;
    Widget guidesButton() => OutlinedButton.icon(
          onPressed: guides,
          icon: const Icon(LucideIcons.search, size: 14),
          label: Text(l10n.guidesSearchHint),
        );
    Widget supportButton() => OutlinedButton.icon(
          onPressed: support,
          icon: const Icon(LucideIcons.lifeBuoy, size: 14),
          label: Text(l10n.helpContactSupport),
        );
    Widget retryButton() => FilledButton.icon(
          onPressed: retry,
          icon: const Icon(LucideIcons.refreshCw, size: 14),
          label: Text(l10n.astryxTryAgain),
        );
    Widget details() => CopyDetailsButton(
          detail: ErrorReport.build(
            what: f.code == null ? 'Ask Astryx' : '${f.code!.code} ${f.code!.title}',
            where: 'Help > Ask Astryx',
            error: error ?? f,
          ),
        );
    final title = _failureTitle(l10n, f);
    switch (f.kind) {
      case AssistantFailureKind.notSignedIn:
        return _StateCard(
          icon: LucideIcons.user,
          title: title,
          body: l10n.astryxSignInBody,
          actions: [
            FilledButton(
              onPressed: () => ProfileScreen.openAccount(context, ref),
              child: Text(l10n.profileSignIn),
            ),
            if (guides != null) guidesButton(),
          ],
        );
      case AssistantFailureKind.cloud:
        return _StateCard(
          icon: LucideIcons.cloudOff,
          tone: _Tone.error,
          title: title,
          body: (f.cloud ?? cloudNoAnswerNow()).message(l10n),
          actions: [if (retry != null) retryButton(), details()],
        );
      case AssistantFailureKind.refused:
        return _StateCard(
          icon: LucideIcons.alertCircle,
          tone: _Tone.warn,
          title: title,
          body: ErrorCodes.withCode(l10n.astryxRefusedBody, ErrorCodes.assistantRefused),
          actions: [details()],
        );
      case AssistantFailureKind.busy:
        return _StateCard(
          icon: LucideIcons.clock,
          tone: _Tone.warn,
          title: title,
          body: ErrorCodes.withCode(l10n.astryxBusyBody, ErrorCodes.assistantBusy),
          actions: [if (retry != null) retryButton()],
        );
      case AssistantFailureKind.notAnswering:
        return _StateCard(
          icon: LucideIcons.alertCircle,
          tone: _Tone.warn,
          title: title,
          body: ErrorCodes.withCode(l10n.astryxNotAnsweringBody, ErrorCodes.assistantNotAnswering),
          actions: [
            if (retry != null) retryButton(),
            if (_question.text.trim().isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _openTicket(_Exchange(
                    question: _question.text.trim(), sent: ReportScrub.scrub(_question.text.trim()), screenshots: 0)),
                icon: const Icon(LucideIcons.messageSquare, size: 14),
                label: Text(l10n.astryxOpenTicket),
              ),
            details(),
          ],
        );
      case AssistantFailureKind.blocked:
        final (icon, tone, body, actions) = switch (f.block) {
          AssistantBlock.paidOnly => (
              LucideIcons.sparkles,
              _Tone.neutral,
              l10n.astryxPaidBody,
              [if (guides != null) guidesButton(), if (support != null) supportButton()],
            ),
          AssistantBlock.dailyLimit => (
              LucideIcons.clock,
              _Tone.warn,
              ErrorCodes.withCode(l10n.astryxLimitBody, ErrorCodes.assistantDailyLimit),
              [if (guides != null) guidesButton(), if (support != null) supportButton()],
            ),
          AssistantBlock.capReached => (
              LucideIcons.power,
              _Tone.neutral,
              ErrorCodes.withCode(l10n.astryxCapBody, ErrorCodes.assistantCapReached),
              [if (support != null) supportButton(), if (guides != null) guidesButton()],
            ),
          AssistantBlock.planUnknown => (
              LucideIcons.alertCircle,
              _Tone.warn,
              ErrorCodes.withCode(l10n.astryxPlanUnknownBody, ErrorCodes.assistantPlanUnknown),
              [retryButtonFor(l10n), details()],
            ),
          AssistantBlock.off || null => (
              LucideIcons.power,
              _Tone.neutral,
              ErrorCodes.withCode(l10n.astryxOffBody, ErrorCodes.assistantOff),
              [if (guides != null) guidesButton(), if (support != null) supportButton()],
            ),
        };
        return _StateCard(icon: icon, tone: tone, title: title, body: body, actions: actions);
    }
  }

  Widget retryButtonFor(AppLocalizations l10n) => FilledButton.icon(
        onPressed: () {
          setState(() => _failure = null);
          ref.invalidate(assistantStatusProvider);
        },
        icon: const Icon(LucideIcons.refreshCw, size: 14),
        label: Text(l10n.astryxTryAgain),
      );
}

/// Which model answered, as people know it.
String _modelName(String? model) => switch (model) {
      'sonnet' => 'Claude Sonnet',
      'haiku' => 'Claude Haiku',
      _ => 'Claude',
    };

/// The Preview label, the same everywhere Ask Astryx is named.
class AstryxPreviewBadge extends StatelessWidget {
  const AstryxPreviewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(color: ZestTokens.brandBadge, borderRadius: BorderRadius.circular(5)),
      child: Text(
        l10n.astryxPreview.toUpperCase(),
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.6,
          color: ZestTokens.brand,
        ),
      ),
    );
  }
}

class _StillStuck extends StatelessWidget {
  const _StillStuck({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        border: Border.all(color: AppColors.v3BorderSubtle),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.lifeBuoy, size: 16, color: AppColors.v3TextTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.astryxStillStuck, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(l10n.astryxStillStuckBody,
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('astryx-open-ticket'),
                  onPressed: onOpen,
                  icon: const Icon(LucideIcons.messageSquare, size: 14),
                  label: Text(l10n.astryxOpenTicket),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.v3Error.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.v3Error.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 15, color: AppColors.v3Error),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextPrimary))),
        ],
      ),
    );
  }
}

class _DocLink extends StatelessWidget {
  const _DocLink({required this.doc, required this.onOpen});

  final AssistantDoc doc;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return ZestPressable(
      link: true,
      onTap: () => onOpen(doc.url),
      semanticLabel: doc.name,
      excludeChildSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          children: [
            Icon(LucideIcons.bookOpen, size: 15, color: ZestTokens.brand),
            const SizedBox(width: 8),
            Expanded(
              child: Text(doc.name, style: TextStyle(fontSize: 13, color: ZestTokens.brand)),
            ),
            Icon(LucideIcons.externalLink, size: 13, color: AppColors.v3TextTertiary),
          ],
        ),
      ),
    );
  }
}

enum _Tone { neutral, warn, error }

/// A state that stops the panel, or a failure under the conversation.
class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.body,
    this.tone = _Tone.neutral,
    this.actions = const [],
    this.code,
    this.links = const [],
    this.onLink,
  });

  final IconData icon;
  final String title;
  final String body;
  final _Tone tone;
  final List<Widget> actions;
  final ErrorCode? code;
  final List<AssistantDoc> links;
  final ValueChanged<String>? onLink;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _Tone.neutral => AppColors.v3TextSecondary,
      _Tone.warn => AppColors.v3Warning,
      _Tone.error => AppColors.v3Error,
    };
    final text = code == null ? body : ErrorCodes.withCode(body, code!);
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('astryx-state'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          color: AppColors.v3Surface,
          border: Border.all(color: tone == _Tone.error ? AppColors.v3Error.withValues(alpha: 0.35) : AppColors.v3BorderSubtle),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(height: 10),
            Semantics(
              header: true,
              child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3)),
            ),
            const SizedBox(height: 6),
            SelectableText(text, style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.v3TextSecondary)),
            if (links.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final d in links) _DocLink(doc: d, onOpen: onLink ?? (_) {}),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
