import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/ink_layer.dart';

/// Comprehensive help / FAQ / guide screen for the ZestSSH automation system.
///
/// Covers URL schemes, Tasker and MacroDroid setup, iOS Shortcuts, batch
/// execution, snippet variables, output filters, webhooks, history,
/// troubleshooting, and security. All content is baked in -- no network
/// requests needed.
class AutomationGuideScreen extends StatelessWidget {
  const AutomationGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.autoGuideTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──────────────────────────────────────
                _SectionTitle(label: l10n.autoGuideReferenceTitle),
                const SizedBox(height: 4),
                Text(
                  l10n.autoGuideIntro,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),

                // ── Guide sections ──────────────────────────────
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppColors.surface,
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: InkLayer(
                    child: Column(
                    children: [
                      // 1 ── What is Automation? ─────────────────
                      _GuideSection(
                        icon: LucideIcons.sparkles,
                        title: l10n.autoGuideSectionWhatIs,
                        children: const [_WhatIsAutomationBody()],
                      ),
                      const _TileDivider(),

                      // 2 ── MacroDroid Setup ────────────────────
                      _GuideSection(
                        icon: Icons.android_outlined,
                        title: l10n.autoGuideSectionMacroDroid,
                        children: const [_MacroDroidBody()],
                      ),
                      const _TileDivider(),

                      // 3 ── Tasker Setup ────────────────────────
                      _GuideSection(
                        icon: LucideIcons.settings2,
                        title: l10n.autoGuideSectionTasker,
                        children: const [_TaskerBody()],
                      ),
                      const _TileDivider(),

                      // 4 ── iOS Shortcuts & Siri ────────────────
                      _GuideSection(
                        icon: LucideIcons.smartphone,
                        title: l10n.autoGuideSectionIos,
                        children: const [_IOSShortcutsBody()],
                      ),
                      const _TileDivider(),

                      // 5 ── URL Scheme Reference ────────────────
                      _GuideSection(
                        icon: LucideIcons.link,
                        title: l10n.autoGuideSectionUrlScheme,
                        children: const [_UrlSchemeBody()],
                      ),
                      const _TileDivider(),

                      // 6 ── Batch Execution ─────────────────────
                      _GuideSection(
                        icon: LucideIcons.server,
                        title: l10n.autoGuideSectionBatch,
                        children: const [_BatchBody()],
                      ),
                      const _TileDivider(),

                      // 7 ── Snippet Variables ───────────────────
                      _GuideSection(
                        icon: LucideIcons.braces,
                        title: l10n.autoGuideSectionSnippetVars,
                        children: const [_SnippetVariablesBody()],
                      ),
                      const _TileDivider(),

                      // 8 ── Output Filters ──────────────────────
                      _GuideSection(
                        icon: LucideIcons.filter,
                        title: l10n.autoGuideSectionOutputFilters,
                        children: const [_OutputFiltersBody()],
                      ),
                      const _TileDivider(),

                      // 9 ── Webhook Callbacks ───────────────────
                      _GuideSection(
                        icon: LucideIcons.webhook,
                        title: l10n.autoGuideSectionWebhook,
                        children: const [_WebhookBody()],
                      ),
                      const _TileDivider(),

                      // 10 ── Automation History ─────────────────
                      _GuideSection(
                        icon: LucideIcons.history,
                        title: l10n.autoGuideSectionHistory,
                        children: const [_HistoryBody()],
                      ),
                      const _TileDivider(),

                      // 11 ── Troubleshooting ────────────────────
                      _GuideSection(
                        icon: LucideIcons.wrench,
                        title: l10n.autoGuideSectionTroubleshooting,
                        children: const [_TroubleshootingBody()],
                      ),
                      const _TileDivider(),

                      // 12 ── Security ───────────────────────────
                      _GuideSection(
                        icon: LucideIcons.shieldCheck,
                        title: l10n.autoGuideSectionSecurity,
                        children: const [_SecurityBody()],
                      ),
                    ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // ── Footer ──────────────────────────────────────
                Center(
                  child: Text(
                    l10n.autoGuideFooter,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceDim,
                    ),
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

// ═══════════════════════════════════════════════════════════════════
// Shared Widgets
// ═══════════════════════════════════════════════════════════════════

class _SectionTitle extends StatelessWidget {
  final String label;
  const _SectionTitle({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppColors.onSurface,
        ),
      ),
    );
  }
}

class _TileDivider extends StatelessWidget {
  const _TileDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, color: AppColors.divider);
  }
}

/// A single expandable guide section with an orange leading icon.
class _GuideSection extends StatefulWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _GuideSection({
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  State<_GuideSection> createState() => _GuideSectionState();
}

class _GuideSectionState extends State<_GuideSection>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: Icon(widget.icon, color: AppColors.accentInk, size: 22),
          title: Text(
            widget.title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          trailing: AnimatedRotation(
            turns: _expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 200),
            child: Icon(
              LucideIcons.chevronRight,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}

/// Dark monospace code block for examples and URL patterns.
class _CodeBlock extends StatelessWidget {
  final String code;
  const _CodeBlock(this.code);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: SelectableText(
        code,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          height: 1.5,
          color: AppColors.onSurface,
        ),
      ),
    );
  }
}

/// Standard paragraph text used inside guide sections.
class _BodyText extends StatelessWidget {
  final String text;
  const _BodyText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          height: 1.6,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// Inline label with monospace formatting for parameter names.
class _ParamLabel extends StatelessWidget {
  final String label;
  final String description;

  const _ParamLabel({required this.label, required this.description});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: label,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
                color: AppColors.accentInk,
              ),
            ),
            TextSpan(
              text: ': $description',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Numbered step inside a setup guide.
class _NumberedStep extends StatelessWidget {
  final int number;
  final String text;

  const _NumberedStep({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    // 22 across for a number 11 high, and as much wider as the number grows
    // with the text (a fixed 22 cut it from 1.5 times the text size).
    final side = MediaQuery.textScalerOf(context).scale(11) * 2;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: side,
            height: side,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.brandOrange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(side / 2),
            ),
            child: Text(
              '$number',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.accentInk,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Troubleshooting row: symptom on the left, fix on the right.
class _TroubleshootRow extends StatelessWidget {
  final String symptom;
  final String fix;

  const _TroubleshootRow({required this.symptom, required this.fix});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle,
              size: 16, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '"$symptom"\n',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurface,
                    ),
                  ),
                  TextSpan(
                    text: fix,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 1 -- What is Automation?
// ═══════════════════════════════════════════════════════════════════

class _WhatIsAutomationBody extends StatelessWidget {
  const _WhatIsAutomationBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideWhatIsP1),
        _BodyText(l10n.autoGuideWhatIsUseCasesLabel),
        _BodyText(l10n.autoGuideWhatIsUseCases),
        const SizedBox(height: 8),
        const _ProBadge(),
      ],
    );
  }
}

class _ProBadge extends StatelessWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.brandOrange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: AppColors.brandOrange.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.award,
              size: 14, color: AppColors.accentInk),
          const SizedBox(width: 6),
          Text(
            l10n.autoGuideProBadge,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.accentInk,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 2 -- MacroDroid Setup
// ═══════════════════════════════════════════════════════════════════

class _MacroDroidBody extends StatelessWidget {
  const _MacroDroidBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideMacroIntro),
        _NumberedStep(
          number: 1,
          text: l10n.autoGuideMacroStep1,
        ),
        _NumberedStep(
          number: 2,
          text: l10n.autoGuideMacroStep2,
        ),
        _NumberedStep(
          number: 3,
          text: l10n.autoGuideMacroStep3,
        ),
        _NumberedStep(
          number: 4,
          text: l10n.autoGuideMacroStep4,
        ),
        _NumberedStep(
          number: 5,
          text: l10n.autoGuideMacroStep5,
        ),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideMacroExampleLabel),
        const _CodeBlock(
          'zestssh://execute?\n'
          '  key=<API key>&\n'
          '  connection=MyServer&\n'
          '  command=df -h /&\n'
          '  timeout=15',
        ),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideMacroTip),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 3 -- Tasker Setup
// ═══════════════════════════════════════════════════════════════════

class _TaskerBody extends StatelessWidget {
  const _TaskerBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideTaskerIntro),
        _NumberedStep(
          number: 1,
          text: l10n.autoGuideTaskerStep1,
        ),
        _NumberedStep(
          number: 2,
          text: l10n.autoGuideTaskerStep2,
        ),
        _NumberedStep(
          number: 3,
          text: l10n.autoGuideTaskerStep3,
        ),
        _NumberedStep(
          number: 4,
          text: l10n.autoGuideTaskerStep4,
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideTaskerActionsLabel),
        const _CodeBlock(taskerGuideIntents),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideTaskerOpenVsConnect),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideTaskerResults),
      ],
    );
  }
}

/// The intents the guide shows for Tasker, each with its extras as Tasker
/// takes them (key:value, one to an Extra field) and as MainActivity reads
/// them: the key among them, without which a request is refused, and a
/// batch's hosts as "connections" (the guide showed key=value lines, no key,
/// and "connection_ids", found in the client's security
/// review).
@visibleForTesting
const taskerGuideIntents = '# Verify connectivity (ephemeral test)\n'
    'com.affluentlabs.zestssh.CONNECT\n'
    '  Extra: key:<API key>\n'
    '  Extra: connection_id:<label>\n\n'
    '# Open a persistent session - auto-starts tunnels\n'
    'com.affluentlabs.zestssh.OPEN\n'
    '  Extra: key:<API key>\n'
    '  Extra: connection_id:<label>\n'
    '  Extra: timeout:30   (optional, seconds to wait)\n\n'
    '# Execute a raw command\n'
    'com.affluentlabs.zestssh.EXECUTE\n'
    '  Extra: key:<API key>\n'
    '  Extra: connection_id:<label>\n'
    '  Extra: command:<cmd>\n'
    '  Extra: timeout:30\n\n'
    '# Run a saved snippet\n'
    'com.affluentlabs.zestssh.SNIPPET\n'
    '  Extra: key:<API key>\n'
    '  Extra: connection_id:<label>\n'
    '  Extra: snippet_name:<name>\n'
    '  Extra: var_branch:main\n\n'
    '# Batch execute across servers\n'
    'com.affluentlabs.zestssh.BATCH\n'
    '  Extra: key:<API key>\n'
    '  Extra: connections:Web1,Web2,DB1\n'
    '  Extra: command:<cmd>\n'
    '  Extra: parallel:true\n\n'
    '# Run a saved workflow\n'
    'com.affluentlabs.zestssh.WORKFLOW\n'
    '  Extra: key:<API key>\n'
    '  Extra: workflow_name:<name>';

// ═══════════════════════════════════════════════════════════════════
// Section 4 -- iOS Shortcuts & Siri
// ═══════════════════════════════════════════════════════════════════

class _IOSShortcutsBody extends StatelessWidget {
  const _IOSShortcutsBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideIosIntro),
        _NumberedStep(
          number: 1,
          text: l10n.autoGuideIosStep1,
        ),
        _NumberedStep(
          number: 2,
          text: l10n.autoGuideIosStep2,
        ),
        _NumberedStep(
          number: 3,
          text: l10n.autoGuideIosStep3,
        ),
        _NumberedStep(
          number: 4,
          text: l10n.autoGuideIosStep4,
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideIosExampleLabel),
        _BodyText(l10n.autoGuideIosExampleBody),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideIosTip),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideIosLimitation),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 5 -- URL Scheme Reference
// ═══════════════════════════════════════════════════════════════════

class _UrlSchemeBody extends StatelessWidget {
  const _UrlSchemeBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideUrlIntro),
        const SizedBox(height: 8),

        // ── Execute ──
        _BodyText(l10n.autoGuideUrlExecuteLabel),
        const _CodeBlock(
          'zestssh://execute?\n'
          '  key=<API key>&\n'
          '  connection=<label>&\n'
          '  command=<cmd>&\n'
          '  timeout=30&\n'
          '  grep=<pattern>&\n'
          '  head=<n>&\n'
          '  tail=<n>',
        ),
        _ParamLabel(
          label: 'key',
          description: l10n.autoGuideUrlKeyDesc,
        ),
        _ParamLabel(
          label: 'connection',
          description: l10n.autoGuideUrlConnectionDesc,
        ),
        _ParamLabel(
          label: 'command',
          description: l10n.autoGuideUrlCommandDesc,
        ),
        _ParamLabel(
          label: 'timeout',
          description: l10n.autoGuideUrlTimeoutDesc,
        ),

        const SizedBox(height: 16),

        // ── Snippet ──
        _BodyText(l10n.autoGuideUrlSnippetLabel),
        const _CodeBlock(
          'zestssh://snippet?\n'
          '  key=<API key>&\n'
          '  connection=<label>&\n'
          '  name=<snippet_name>&\n'
          '  var_branch=main&\n'
          '  var_env=production',
        ),
        _ParamLabel(
          label: 'name',
          description: l10n.autoGuideUrlNameDesc,
        ),
        _ParamLabel(
          label: 'var_<key>',
          description: l10n.autoGuideUrlVarKeyDesc,
        ),

        const SizedBox(height: 16),

        // ── Batch ──
        _BodyText(l10n.autoGuideUrlBatchLabel),
        const _CodeBlock(
          'zestssh://batch?\n'
          '  key=<API key>&\n'
          '  connections=Web1,Web2,DB1&\n'
          '  command=uptime&\n'
          '  timeout=30&\n'
          '  parallel=true',
        ),
        _ParamLabel(
          label: 'connections',
          description: l10n.autoGuideUrlConnectionsDesc,
        ),
        _ParamLabel(
          label: 'parallel',
          description: l10n.autoGuideUrlParallelDesc,
        ),

        const SizedBox(height: 16),

        // ── Connect ──
        _BodyText(l10n.autoGuideUrlConnectLabel),
        const _CodeBlock(
          'zestssh://connect?\n'
          '  host=192.168.1.10&\n'
          '  user=admin&\n'
          '  port=22',
        ),
        _ParamLabel(
          label: 'host',
          description: l10n.autoGuideUrlHostDesc,
        ),
        _ParamLabel(
          label: 'user',
          description: l10n.autoGuideUrlUserDesc,
        ),
        _ParamLabel(
          label: 'port',
          description: l10n.autoGuideUrlPortDesc,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 6 -- Batch Execution
// ═══════════════════════════════════════════════════════════════════

class _BatchBody extends StatelessWidget {
  const _BatchBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideBatchIntro),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideBatchCommaLabel),
        const _CodeBlock(
          'zestssh://batch?\n'
          '  key=<API key>&\n'
          '  connections=Web1,Web2,Web3,DB1&\n'
          '  command=free -m | head -2',
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideBatchParallelTitle),
        _BodyText(l10n.autoGuideBatchParallelBody),
        const _CodeBlock(
          '# Sequential execution\n'
          'zestssh://batch?\n'
          '  key=<API key>&\n'
          '  connections=Web1,Web2,Web3&\n'
          '  command=sudo systemctl restart nginx&\n'
          '  parallel=false&\n'
          '  timeout=60',
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideBatchOutputTitle),
        _BodyText(l10n.autoGuideBatchOutputBody),
        const _CodeBlock(
          '=== Web1 (exit=0) ===\n'
          '              total   used   free\n'
          'Mem:           7982   5123   2859\n\n'
          '=== Web2 (exit=0) ===\n'
          '              total   used   free\n'
          'Mem:           7982   3211   4771',
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 7 -- Snippet Variables
// ═══════════════════════════════════════════════════════════════════

class _SnippetVariablesBody extends StatelessWidget {
  const _SnippetVariablesBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideSnippetIntro("'{{variable}}'")),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideSnippetExampleLabel),
        const _CodeBlock(
          'cd /var/www/{{project}} &&\n'
          'git checkout {{branch}} &&\n'
          'git pull origin {{branch}} &&\n'
          'sudo systemctl restart {{service}}',
        ),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideSnippetTriggerUrlLabel),
        const _CodeBlock(
          'zestssh://snippet?\n'
          '  key=<API key>&\n'
          '  connection=ProdServer&\n'
          '  name=deploy&\n'
          '  var_project=myapp&\n'
          '  var_branch=main&\n'
          '  var_service=myapp.service',
        ),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideSnippetTaskerLabel),
        // As Tasker takes extras, the key among them (taskerGuideIntents).
        const _CodeBlock(
          'com.affluentlabs.zestssh.SNIPPET\n'
          '  Extra: key:<API key>\n'
          '  Extra: connection_id:ProdServer\n'
          '  Extra: snippet_name:deploy\n'
          '  Extra: var_project:myapp\n'
          '  Extra: var_branch:main\n'
          '  Extra: var_service:myapp.service',
        ),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideSnippetVarPrefix("'{{branch}}'")),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 8 -- Output Filters
// ═══════════════════════════════════════════════════════════════════

class _OutputFiltersBody extends StatelessWidget {
  const _OutputFiltersBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideFilterIntro),
        const SizedBox(height: 8),
        _ParamLabel(
          label: 'grep',
          description: l10n.autoGuideFilterGrepDesc,
        ),
        _ParamLabel(
          label: 'head',
          description: l10n.autoGuideFilterHeadDesc,
        ),
        _ParamLabel(
          label: 'tail',
          description: l10n.autoGuideFilterTailDesc,
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideFilterExamplesLabel),
        const _CodeBlock(
          '# Show only lines containing "error"\n'
          'zestssh://execute?\n'
          '  key=<API key>&\n'
          '  connection=ProdServer&\n'
          '  command=journalctl -u nginx --no-pager -n 200&\n'
          '  grep=error',
        ),
        const SizedBox(height: 8),
        const _CodeBlock(
          '# First 5 lines of output\n'
          'zestssh://execute?\n'
          '  key=<API key>&\n'
          '  connection=ProdServer&\n'
          '  command=ps aux --sort=-%mem&\n'
          '  head=5',
        ),
        const SizedBox(height: 8),
        const _CodeBlock(
          '# Last 10 lines of a log file\n'
          'zestssh://execute?\n'
          '  key=<API key>&\n'
          '  connection=ProdServer&\n'
          '  command=cat /var/log/syslog&\n'
          '  tail=10',
        ),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideFilterCombined),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 9 -- Webhook Callbacks
// ═══════════════════════════════════════════════════════════════════

class _WebhookBody extends StatelessWidget {
  const _WebhookBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideWebhookIntro),
        const SizedBox(height: 8),
        // An Android intent: a link's callback is not taken (a link can
        // come from anywhere, and its question does not show where the
        // output would go).
        const _CodeBlock(
          'com.affluentlabs.zestssh.EXECUTE\n'
          '  Extra: key:<API key>\n'
          '  Extra: connection_id:ProdServer\n'
          '  Extra: command:df -h /\n'
          '  Extra: callback:https://hooks.slack.com/services/T.../B.../xxx',
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideWebhookJsonLabel),
        const _CodeBlock(
          '{\n'
          '  "connection": "ProdServer",\n'
          '  "command": "df -h /",\n'
          '  "stdout": "Filesystem  Size  Used ...",\n'
          '  "stderr": "",\n'
          '  "exit_code": 0,\n'
          '  "elapsed_ms": 342,\n'
          '  "timestamp": "2025-01-15T08:30:00.000Z"\n'
          '}',
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideWebhookReqLabel),
        _BodyText(l10n.autoGuideWebhookReqs),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideWebhookUseCasesLabel),
        _BodyText(l10n.autoGuideWebhookUseCases),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 10 -- Automation History
// ═══════════════════════════════════════════════════════════════════

class _HistoryBody extends StatelessWidget {
  const _HistoryBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideHistoryIntro),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideHistoryWhereLabel),
        _BodyText(l10n.autoGuideHistoryWhere),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideHistoryViewLabel),
        _BodyText(l10n.autoGuideHistoryView),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideHistoryStorage),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 11 -- Troubleshooting
// ═══════════════════════════════════════════════════════════════════

class _TroubleshootingBody extends StatelessWidget {
  const _TroubleshootingBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TroubleshootRow(
          symptom: l10n.autoGuideTroubleDisabledSymptom,
          fix: l10n.autoGuideTroubleDisabledFix,
        ),
        _TroubleshootRow(
          symptom: l10n.autoGuideTroubleSqueezedSymptom,
          fix: l10n.autoGuideTroubleSqueezedFix,
        ),
        _TroubleshootRow(
          symptom: l10n.autoGuideTroubleNotFoundSymptom,
          fix: l10n.autoGuideTroubleNotFoundFix,
        ),
        _TroubleshootRow(
          symptom: l10n.autoGuideTroubleTimeoutSymptom,
          fix: l10n.autoGuideTroubleTimeoutFix,
        ),
        _TroubleshootRow(
          symptom: l10n.autoGuideTroubleHostKeySymptom,
          fix: l10n.autoGuideTroubleHostKeyFix,
        ),
        const SizedBox(height: 12),
        _BodyText(l10n.autoGuideTroubleFooter),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Section 12 -- Security
// ═══════════════════════════════════════════════════════════════════

class _SecurityBody extends StatelessWidget {
  const _SecurityBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BodyText(l10n.autoGuideSecurityIntro),
        const SizedBox(height: 8),
        _BodyText(l10n.autoGuideSecuritySqueezed),
        _BodyText(l10n.autoGuideSecurityKillSwitch),
        _BodyText(l10n.autoGuideSecurityHostKey),
        _BodyText(l10n.autoGuideSecurityNoInjection),
        _BodyText(l10n.autoGuideSecurityCredentials),
        _BodyText(l10n.autoGuideSecurityUriLimits),
        _BodyText(l10n.autoGuideSecurityHttps),
      ],
    );
  }
}
