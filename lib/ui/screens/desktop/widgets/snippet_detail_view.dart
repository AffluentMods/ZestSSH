import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart' show snippetRelativeRun;
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

// ══════════════════════════════════════════════════════════════════
// The computer's Snippets page: a snippet's details.
// Read-only: Edit opens the editor
// (SnippetDetailEditor). Every run goes the one way a snippet runs
// (lib/features/snippets/run_snippet.dart): its variables asked, the
// dangerous-command check or its own "ask before running".
// ══════════════════════════════════════════════════════════════════

/// Matches every variable placeholder form the parser understands, so a
/// command can show each as a chip.
final RegExp _kVarSpan = RegExp(r'\$\[[^\]]+\]|\$\{\[[^\]]+\]\}|\$\{\w+(?::-[^}]*)?(?::(?:secret|password))?\}');

/// [command] as spans: its variable placeholders as small accent chips (the
/// placeholder's own text, as the app reads it), the rest in [style].
List<InlineSpan> snippetCommandChipSpans(String command, TextStyle style) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _kVarSpan.allMatches(command)) {
    if (m.start > last) spans.add(TextSpan(text: command.substring(last, m.start), style: style));
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: ZestTokens.brand.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: ZestTokens.brand.withValues(alpha: 0.28)),
        ),
        child: Text(m.group(0)!, style: style.copyWith(color: ZestTokens.brandInk)),
      ),
    ));
    last = m.end;
  }
  if (last < command.length) spans.add(TextSpan(text: command.substring(last), style: style));
  if (spans.isEmpty) spans.add(TextSpan(text: command, style: style));
  return spans;
}

/// The host a Run on the Snippets page goes to, and what it is called: the
/// snippet's default host while it still exists, else the session open now,
/// else the one session open where only one is. Null when there is none of
/// these (a Run then asks which host, the open sessions first).
({ConnectionWithDetails? host, SessionState? session, String name})? snippetRunTarget(WidgetRef ref, Snippet snippet) {
  final host = defaultHostOf(ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [], snippet.metadata);
  if (host != null) {
    final label = host.connection.label.isNotEmpty ? host.connection.label : host.connection.host;
    return (host: host, session: null, name: Redactable.host(label).displayIn(ref));
  }
  ref.watch(v3ActiveSessionTabProvider);
  ref.watch(activeSessionsProvider);
  final open = openSessionsByUse(ref.read);
  final session = currentSessionOf(ref.read) ?? (open.length == 1 ? open.single : null);
  if (session == null) return null;
  final label = session.connectionLabel.isNotEmpty ? session.connectionLabel : (session.host ?? '');
  return (host: null, session: session, name: Redactable.host(label).displayIn(ref));
}

/// Runs [snippet] from the Snippets page: on its default host, else in the
/// session open now or the one session open, else on a host picked first.
Future<void> runSnippetFromPage(BuildContext context, WidgetRef ref, Snippet snippet) async {
  final target = snippetRunTarget(ref, snippet);
  if (target?.host case final host?) {
    await runCommandOnHost(context, ref,
        host: host,
        command: snippet.command,
        label: snippet.label,
        confirmFirst: snippet.confirmBeforeRun,
        snippetId: snippet.id);
    return;
  }
  if (target?.session?.session case final session?) {
    await runCommandInSession(context, ref,
        sessionId: session.id,
        command: snippet.command,
        label: snippet.label,
        confirmFirst: snippet.confirmBeforeRun,
        snippetId: snippet.id);
    return;
  }
  await runSnippetOnPickedHost(context, ref, snippet);
}

/// "Run on…": on a host picked through the grouped picker, or in a new
/// terminal on this device, its first choice where the device has one.
Future<void> runSnippetOnPickedHost(BuildContext context, WidgetRef ref, Snippet snippet) async {
  final l10n = AppLocalizations.of(context)!;
  final result = await ConnectionPickerDialog.show(context,
      title: l10n.zestSnippetsRunOnTitle,
      needsTerminal: true,
      place: HostListPlace.runSnippet,
      includeLocalTerminal: true);
  if (!context.mounted) return;
  await runCommandOnPicked(context, ref, result,
      command: snippet.command,
      label: snippet.label,
      confirmFirst: snippet.confirmBeforeRun,
      snippetId: snippet.id);
}

/// "Run in the session you're in": the session open now; nothing when none.
Future<void> runSnippetInCurrentSession(BuildContext context, WidgetRef ref, Snippet snippet) async {
  final session = currentSessionOf(ref.read)?.session;
  if (session == null) return;
  await runCommandInSession(context, ref,
      sessionId: session.id,
      command: snippet.command,
      label: snippet.label,
      confirmFirst: snippet.confirmBeforeRun,
      snippetId: snippet.id);
}

/// When a snippet last ran on this device, in a few letters ("43d ago"), or
/// null when it never did.
String? snippetLastRunText(AppLocalizations l10n, SnippetUsage? usage) {
  if (usage == null || usage.runCount == 0) return null;
  // As the snippet cards say it (seconds from ten, just now before that).
  return snippetRelativeRun(usage.lastRunAt, l10n);
}

/// A snippet's details, read-only, in the right pane of the Snippets page.
class SnippetDetailView extends ConsumerWidget {
  const SnippetDetailView({
    super.key,
    required this.snippet,
    required this.categoryColor,
    required this.onEdit,
    required this.onClose,
  });

  final Snippet snippet;

  /// Its folder's colour (the list's section dot), or null outside a folder.
  final Color? categoryColor;
  final VoidCallback onEdit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final usage = ref.watch(snippetUsageProvider)[snippet.id];
    final lastRun = snippetLastRunText(l10n, usage);
    final folder = (snippet.category?.isNotEmpty ?? false) ? snippet.category! : null;
    final runWords = lastRun == null ? l10n.snippetPageNeverRun : l10n.snippetPageLastRun(lastRun);
    final target = snippetRunTarget(ref, snippet);
    final openCount = openSessionsByUse(ref.read).length;
    final hasDefaultHost = target?.host != null;
    final meta = parseSnippetMetadata(snippet.metadata);
    final vars = parseVariablesWithOptions(snippet.command);
    final workflows = [
      for (final w in ref.watch(workflowsProvider))
        if (snippet.label.isNotEmpty &&
            w.steps.any((s) => s.type == WorkflowStepType.snippet && s.snippetName == snippet.label))
          w.name,
    ];
    final mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, height: 1.6, color: ZestTokens.textPrimary);
    final accent = categoryColor ?? ZestTokens.textTertiary;

    return ColoredBox(
      color: ZestTokens.surfaceBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header: icon, name, folder and last run, Edit, close ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: ZestTokens.brand.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: ZestTokens.brand.withValues(alpha: 0.28)),
                  ),
                  child: Icon(LucideIcons.braces, size: 18, color: ZestTokens.brandInk),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        Redactable.freeText(snippet.label).displayIn(ref),
                        key: const ValueKey('snippet-detail-name'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (folder != null) ...[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              folder == null ? runWords : '$folder · $runWords',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ZestButton(
                  key: const ValueKey('snippet-detail-edit'),
                  label: l10n.zestSnippetsEdit,
                  icon: LucideIcons.pencil,
                  variant: ZestButtonVariant.ghost,
                  onPressed: onEdit,
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('snippet-detail-close'),
                  tooltip: l10n.close,
                  icon: Icon(LucideIcons.x, size: 16, color: ZestTokens.textTertiary),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: ZestScrollFade(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── The command, its variables as chips, with Copy ──
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                      decoration: BoxDecoration(
                        color: ZestTokens.surfaceRaisedAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ZestTokens.borderSubtle),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text.rich(
                                TextSpan(
                                  children: snippetCommandChipSpans(
                                      Redactable.freeText(snippet.command).displayIn(ref), mono),
                                ),
                                key: const ValueKey('snippet-detail-command'),
                              ),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('snippet-detail-copy'),
                            tooltip: l10n.zestSnippetsCopy,
                            icon: Icon(LucideIcons.copy, size: 15, color: ZestTokens.textTertiary),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: snippet.command));
                              if (context.mounted) {
                                showTopSnackBar(context, l10n.zestSnippetsCopied,
                                    duration: const Duration(seconds: 2));
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    if (vars.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      ZestSectionHeader(label: l10n.snippetPageVariables, count: vars.length),
                      const SizedBox(height: 10),
                      for (final v in vars) ...[
                        _VariableBox(
                          variable: v,
                          description: meta.variableDescriptions[v.key],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                    const SizedBox(height: 22),
                    ZestSectionHeader(label: l10n.snippetPageRunSection),
                    const SizedBox(height: 6),
                    _DetailRow(
                      label: l10n.zestSnippetsDefaultHostLabel,
                      // "The session you're in" only where the person is in
                      // one (this page is none).
                      value: hasDefaultHost
                          ? target!.name
                          : currentSessionOf(ref.read) != null
                              ? l10n.snippetPageSessionYoureIn
                              : (target?.name ?? l10n.snippetPageNone),
                    ),
                    _DetailRow(
                      label: l10n.snippetPageAskBefore,
                      value: snippet.confirmBeforeRun ? l10n.snippetPageYes : l10n.snippetPageNo,
                    ),
                    _DetailRow(
                      label: l10n.snippetPageUsedBy,
                      value: workflows.isEmpty ? l10n.snippetPageNone : workflows.join(', '),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ── Footer: Run on…, and Run on the default host or the session open now ──
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (target == null) ...[
                  Text(
                    // None open at all is another thing to say than several
                    // open while the person is on this page.
                    openCount == 0 ? l10n.snippetPageNoSession : l10n.snippetPageNotInSession(openCount),
                    key: const ValueKey('snippet-detail-no-session'),
                    style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    ZestButton(
                      key: const ValueKey('snippet-detail-run-on'),
                      label: l10n.zestSnippetsRunOn,
                      size: ZestButtonSize.large,
                      onPressed: () => runSnippetOnPickedHost(context, ref, snippet),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ZestButton(
                        key: const ValueKey('snippet-detail-run'),
                        label: target == null ? l10n.snippetPageRun : l10n.docCheckSnippetRunOnHost(target.name),
                        icon: LucideIcons.play,
                        size: ZestButtonSize.large,
                        variant: ZestButtonVariant.primary,
                        // Several open: it asks which, the open ones first.
                        onPressed: target == null && openCount == 0 ? null : () => runSnippetFromPage(context, ref, snippet),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VariableBox extends StatelessWidget {
  const _VariableBox({required this.variable, required this.description});

  final ParsedVariable variable;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final v = variable;
    final isList = v.type != VariableType.freeText;
    final what = (description?.trim().isNotEmpty ?? false) ? description!.trim() : v.name;
    final name = v.type == VariableType.dynamicList ? (v.dynamicSource ?? v.name) : v.key;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: ZestTokens.brand.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  name.length > 28 ? '${name.substring(0, 27)}…' : name,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestTokens.brandInk),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isList ? l10n.snippetPagePicksFrom(what) : l10n.snippetPageAsksFor(what),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                ),
              ),
            ],
          ),
          if (!isList) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(l10n.snippetPageDefault, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary)),
                const Spacer(),
                Text(
                  (v.defaultValue?.isNotEmpty ?? false) ? v.defaultValue! : l10n.snippetPageNone,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: ZestTokens.textSecondary,
                    fontFamily: (v.defaultValue?.isNotEmpty ?? false) ? 'JetBrainsMono' : null,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
