import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/help/guides/guide_entry.dart';
import 'package:zestssh/features/help/guides/guide_providers.dart';
import 'package:zestssh/features/help/guides/guide_search.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/utils/help_links.dart';

/// Help > Guides (3.0): a search box over the feature guides and the guides
/// it finds, best first ("network" finds Networks and jump hosts, "bastion"
/// does too). The index is in the app, so the list and its search work
/// offline; a guide's words are fetched when it is opened.
///
/// [embedded] is the Help panel's level on a computer (no app bar of its
/// own); otherwise it is a page of its own on a phone or a tablet.
class GuidesScreen extends ConsumerStatefulWidget {
  const GuidesScreen({super.key, required this.onOpen, this.embedded = false, this.autofocus = false});

  final ValueChanged<String> onOpen;
  final bool embedded;
  final bool autofocus;

  @override
  ConsumerState<GuidesScreen> createState() => _GuidesScreenState();
}

class _GuidesScreenState extends ConsumerState<GuidesScreen> {
  late final TextEditingController _query = TextEditingController(text: ref.read(guidesQueryProvider));
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = ref.watch(guidesQueryProvider);
    final found = searchGuides(query);
    final english = Localizations.localeOf(context).languageCode == 'en';
    final list = ListView(
      padding: EdgeInsets.fromLTRB(16, widget.embedded ? 12 : 4, 16, 20),
      children: [
        ZestListSearchField(
          controller: _query,
          focusNode: _focus,
          hintText: l10n.guidesSearchHint,
          onChanged: (v) => ref.read(guidesQueryProvider.notifier).state = v,
        ),
        if (!english)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                Icon(LucideIcons.languages, size: 14, color: ZestTokens.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(l10n.guidesEnglishOnly,
                      style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (found.isEmpty)
          _NoMatch(query: query.trim())
        else
          for (final g in found)
            _GuideRow(
              key: ValueKey('guide-row-${g.slug}'),
              guide: g,
              onTap: () => widget.onOpen(g.slug),
            ),
        const SizedBox(height: 16),
        Text(
          l10n.guidesFromDocs,
          style: TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.textTertiary),
        ),
      ],
    );
    if (widget.embedded) return list;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.helpGuides),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: list),
        ),
      ),
    );
  }
}

class _GuideRow extends StatefulWidget {
  const _GuideRow({super.key, required this.guide, required this.onTap});

  final GuideEntry guide;
  final VoidCallback onTap;

  @override
  State<_GuideRow> createState() => _GuideRowState();
}

class _GuideRowState extends State<_GuideRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            decoration: BoxDecoration(
              color: _hover ? AppColors.v3Hover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(LucideIcons.bookOpen, size: 16, color: ZestTokens.brand),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.guide.title,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.guide.summary,
                        style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(LucideIcons.chevronRight, size: 16, color: ZestTokens.textTertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Icon(LucideIcons.searchX, size: 28, color: ZestTokens.textTertiary),
          const SizedBox(height: 10),
          Text(
            l10n.guidesNoMatch(query),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.guidesNoMatchHint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
          ),
          if (kZestDocsUrl != '') ...[
            const SizedBox(height: 10),
            TextButton.icon(
              key: const ValueKey('guides-all-docs'),
              onPressed: () => launchUrl(Uri.parse(kZestDocsUrl), mode: LaunchMode.externalApplication),
              icon: const Icon(LucideIcons.externalLink, size: 14),
              label: Text(l10n.helpAllDocumentation),
            ),
          ],
        ],
      ),
    );
  }
}
