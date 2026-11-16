import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/help/guides/guide_entry.dart';
import 'package:zestssh/features/help/guides/guide_markdown.dart';
import 'package:zestssh/features/help/guides/guide_providers.dart';
import 'package:zestssh/features/help/guides/guide_repository.dart';
import 'package:zestssh/features/help/guides/guide_search.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/guide_markdown_view.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';

/// The title a guide is shown under: the index's, else its address.
String guideTitle(String slug) => guideBySlug(slug)?.title ?? slug;

/// One guide, read in the app (3.0, Help > Guides).
///
/// The guide's raw Markdown is fetched from the docs site each time it is
/// opened and kept on the device; while it comes, and when the site cannot
/// be reached, the copy kept from the last time is shown, with a line that
/// says so. With neither, the page says what went wrong, with its code, Try
/// again, Open in browser and the details to copy.
class GuideReaderScreen extends ConsumerStatefulWidget {
  const GuideReaderScreen({
    super.key,
    required this.slug,
    required this.onOpenGuide,
    this.embedded = false,
    this.onOpenOutside,
  });

  final String slug;

  /// A link to another guide.
  final ValueChanged<String> onOpenGuide;

  /// The Help panel's level on a computer (no app bar of its own).
  final bool embedded;

  /// Where a link outside opens; the browser when null (tests give their own).
  final GuideOutsideOpener? onOpenOutside;

  @override
  ConsumerState<GuideReaderScreen> createState() => _GuideReaderScreenState();
}

class _GuideReaderScreenState extends ConsumerState<GuideReaderScreen> {
  String? _markdown;
  List<GuideBlock> _blocks = const [];

  /// The copy kept on the device is what is shown (the site has not answered
  /// yet, or could not be reached).
  bool _fromSaved = false;
  GuideFetchFailure? _failure;
  Object? _otherError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // (Loading already: the state starts so.)
    // ignore: discarded_futures
    _fetch();
  }

  /// Try again: the guide fetched anew, what was shown kept meanwhile.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
      _otherError = null;
    });
    await _fetch();
  }

  Future<void> _fetch() async {
    final repo = ref.read(guideRepositoryProvider);
    if (_markdown == null) {
      final saved = await repo.saved(widget.slug);
      if (!mounted) return;
      if (saved != null) _show(saved.markdown, fromSaved: true);
    }
    try {
      final text = await repo.fetch(widget.slug);
      if (!mounted) return;
      _show(text, fromSaved: false);
    } on GuideFetchFailure catch (e) {
      if (!mounted) return;
      setState(() => _failure = e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _otherError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _show(String markdown, {required bool fromSaved}) {
    setState(() {
      _markdown = markdown;
      _blocks = parseGuideMarkdown(markdown);
      _fromSaved = fromSaved;
    });
  }

  void _openInBrowser() {
    final open = widget.onOpenOutside;
    final uri = kGuideSlug.hasMatch(widget.slug) ? guidePageUri(widget.slug) : Uri.parse('$kGuidesOrigin/guides/');
    if (open != null) {
      open(uri);
    } else {
      // ignore: discarded_futures
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  ErrorCode get _code => _failure?.code ?? ErrorCodes.guideUnreadable;

  String _message(AppLocalizations l10n) => ErrorCodes.withCode(
        _code == ErrorCodes.guideNotReached ? l10n.guideNotReached : l10n.guideUnreadable,
        _code,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final body = _body(context, l10n);
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(guideTitle(widget.slug)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            key: const ValueKey('guide-open-browser'),
            tooltip: l10n.guideOpenInBrowser,
            onPressed: _openInBrowser,
            icon: const Icon(LucideIcons.externalLink, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final english = Localizations.localeOf(context).languageCode == 'en';
    final failed = _failure != null || _otherError != null;
    if (_markdown == null) {
      if (_loading) {
        return Center(
          child: Semantics(
            label: l10n.guideLoading,
            child: const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        );
      }
      return _Failed(
        message: _message(l10n),
        details: ErrorReport.build(
          what: _message(l10n),
          where: 'Help > Guides, the guide ${widget.slug}',
          error: _failure ?? _otherError,
        ),
        onRetry: _load,
        onOpenInBrowser: _openInBrowser,
      );
    }
    final phone = !widget.embedded;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          key: ValueKey('guide-${widget.slug}'),
          padding: EdgeInsets.fromLTRB(16, widget.embedded ? 14 : 8, 16, 24),
          children: [
            if (_fromSaved && failed && !_loading)
              _Notice(
                key: const ValueKey('guide-saved-copy'),
                icon: LucideIcons.wifiOff,
                text: l10n.guideSavedCopy,
                action: TextButton(onPressed: _load, child: Text(l10n.guideTryAgain)),
              ),
            if (!english)
              _Notice(
                key: const ValueKey('guide-english-only'),
                icon: LucideIcons.languages,
                text: l10n.guidesEnglishOnly,
              ),
            if (_fromSaved && _loading) const LinearProgressIndicator(minHeight: 2),
            if (widget.embedded)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  guideTitle(widget.slug),
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
              ),
            GuideMarkdownView(
              blocks: _blocks,
              slug: widget.slug,
              onOpenGuide: widget.onOpenGuide,
              onOpenOutside: widget.onOpenOutside ?? _launch,
              fontSize: phone ? 15 : 13.5,
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('guide-open-browser-foot'),
                onPressed: _openInBrowser,
                icon: const Icon(LucideIcons.externalLink, size: 14),
                label: Text(l10n.guideOpenInBrowser),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static void _launch(Uri uri) {
    // ignore: discarded_futures
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: ZestTokens.textTertiary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary))),
          ?action,
        ],
      ),
    );
  }
}

/// No guide to show: what went wrong (with its code), Try again, Open in
/// browser, and the details to copy.
class _Failed extends StatelessWidget {
  const _Failed({required this.message, required this.details, required this.onRetry, required this.onOpenInBrowser});

  final String message;
  final String details;
  final VoidCallback onRetry;
  final VoidCallback onOpenInBrowser;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.wifiOff, size: 36, color: ZestTokens.textTertiary),
            const SizedBox(height: 12),
            Text(
              message,
              key: const ValueKey('guide-failed-message'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('guide-try-again'),
                  onPressed: onRetry,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: Text(l10n.guideTryAgain),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('guide-failed-browser'),
                  onPressed: onOpenInBrowser,
                  icon: const Icon(LucideIcons.externalLink, size: 16),
                  label: Text(l10n.guideOpenInBrowser),
                ),
              ],
            ),
            const SizedBox(height: 6),
            CopyDetailsButton(detail: details),
          ],
        ),
      ),
    );
  }
}
