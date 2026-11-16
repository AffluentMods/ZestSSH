import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/automation/automation_switch.dart';
import 'package:zestssh/features/automation/automation_tab.dart';
import 'package:zestssh/features/automation/pages/automation_workflows_view.dart';
import 'package:zestssh/features/automation/widgets/runs_timeline.dart';
import 'package:zestssh/features/automation/widgets/triggers_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/ui/widgets/zest_page_header.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

// ══════════════════════════════════════════════════════════════════
// Automation View - desktop content view.
//
// 1.7 collapsed the old 5 tabs (Workflows / API Keys / Webhooks / Schedule /
// History) down to THREE:
//   * Workflows - the master/detail editor (unchanged, still tab index 0).
//   * Runs      - a day-grouped timeline merging Schedule + History.
//   * Triggers  - API keys (+ scope) + deep links + a webhooks placeholder.
// ══════════════════════════════════════════════════════════════════

/// Tab indices for the automation sub-navigation, in the order of
/// [AutomationTab] (which other parts of the app name a tab by). Labels here are English
/// fallbacks only - the tab bar renders the localized label (see [_TabBar]).
enum _AutoTab {
  workflows('Workflows'),
  runs('Runs'),
  triggers('Triggers');

  const _AutoTab(this.label);
  final String label;
}

/// The main automation panel shown when the sidebar "Automation" is selected.
class AutomationView extends ConsumerStatefulWidget {
  const AutomationView({super.key});

  @override
  ConsumerState<AutomationView> createState() => _AutomationViewState();
}

class _AutomationViewState extends ConsumerState<AutomationView> {
  _AutoTab _selectedTab = _AutoTab.workflows;

  @override
  Widget build(BuildContext context) {
    // A tab another part of the app sent the person to (a refused API key's
    // notice goes to Triggers, where the keys are): shown, then let go of.
    final wanted = ref.watch(automationTabWantedProvider);
    if (wanted != null) {
      _selectedTab = _AutoTab.values[wanted.index];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(automationTabWantedProvider.notifier).state = null;
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The head (as designed): the title, the
        // tabs beside it, New workflow, the switch of all automation and
        // the setup guide, on one band.
        _AutomationHeader(
          selectedTab: _selectedTab,
          onTabChanged: (tab) => setState(() => _selectedTab = tab),
        ),

        // Off-state banner: the master kill switch lives on this screen (the
        // header toggle), so when it is off, say plainly that deep links and
        // webhooks are ignored, with a one-tap turn-on (spec 4 migration).
        if (!ref.watch(automationEnabledProvider)) ...[
          const SizedBox(height: 12),
          const _AutomationOffBanner(),
        ],

        // An IndexedStack keeps every tab (in particular the Workflows
        // master/detail with its live edit controller + dirty state) mounted
        // across tab switches, so switching to Runs and back never silently
        // drops an in-progress edit. Order MUST match [_AutoTab].
        Expanded(
          child: IndexedStack(
            index: _selectedTab.index,
            children: const [
              AutomationWorkflowsView(),
              RunsTimeline(),
              TriggersView(),
            ],
          ),
        ),
      ],
    );
  }
}

/// A quiet warn banner shown under the header while the engine is off.
class _AutomationOffBanner extends ConsumerWidget {
  const _AutomationOffBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Squeezed's alone, as everywhere: without it the button upgrades.
    final isPro = ref.watch(isProProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.sftpWarn.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.sftpWarn.withValues(alpha: 0.28)),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.pauseCircle,
                size: 16, color: AppColors.sftpWarn),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.automationBannerOff,
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: AppColors.v3TextSecondary),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              key: const ValueKey('automation-turn-on'),
              onPressed: () => setAutomationOn(context, ref, true),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.v3AccentInk,
                textStyle:
                    const TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, fontWeight: FontWeight.w600),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                // A mouse's 32 high at least (it drew 30), a finger's 48.
                minimumSize: Size(0, minTapTarget(context)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(isPro ? l10n.automationTurnOn : l10n.settingsUpgradePro),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Header - title, engine toggle, one-line description + help
// ══════════════════════════════════════════════════════════════════

class _AutomationHeader extends ConsumerWidget {
  const _AutomationHeader({required this.selectedTab, required this.onTabChanged});

  final _AutoTab selectedTab;
  final ValueChanged<_AutoTab> onTabChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final engineEnabled = ref.watch(automationEnabledProvider);
    final isPro = ref.watch(isProProvider);

    final title = GuideTitle(
      feature: 'automation',
      title: Text(
        l10n.zestAutoTitle,
        style: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
          color: ZestTokens.textPrimary,
          height: 1.2,
        ),
      ),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
              if (selectedTab == _AutoTab.workflows) ...[
                ZestButton(
                  key: const ValueKey('automation-new-workflow'),
                  label: l10n.zestAutoNewLabel,
                  icon: LucideIcons.plus,
                  variant: ZestButtonVariant.primary,
                  onPressed: () => ref.read(automationNewWorkflowProvider.notifier).state++,
                ),
                const SizedBox(width: 16),
              ],
              // Runs: the scheduled tasks, which a computer runs itself from
              // 4.0 while ZestSSH is open or in the tray (a phone has them
              // under Settings, Automation). Their page says what Squeezed
              // gives before it is bought, as Android's does.
              if (selectedTab == _AutoTab.runs) ...[
                ZestButton(
                  key: const ValueKey('automation-scheduled-tasks'),
                  label: l10n.schedTaskTitle,
                  icon: LucideIcons.calendarClock,
                  onPressed: () => GoRouter.maybeOf(context)?.push(Routes.scheduledTasks),
                ),
                const SizedBox(width: 16),
              ],
              // The switch of all automation, with what it governs on hover
              // (without Squeezed it is shown and does nothing).
              Tooltip(
                message: isPro ? l10n.zestAutoEngineHelpBody : l10n.zestAutoEngineHelpBodyFree,
                waitDuration: const Duration(milliseconds: 500),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.autoAutomationsOn,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary),
                    ),
                    const SizedBox(width: 10),
                    // Said by the words beside it (a Semantics around it
                    // named no node: the switch is one of its own).
                    ZestSwitch(
                      key: const ValueKey('automation-engine-toggle'),
                      value: engineEnabled,
                      semanticLabel: l10n.autoAutomationsOn,
                      onChanged: isPro ? (value) => setAutomationOn(context, ref, value) : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const SetupGuideButton(SetupTopic.automation),
      ],
    );
    final tabs = _TabBar(selectedTab: selectedTab, onTabChanged: onTabChanged);
    return ZestPageBand(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 20, 0),
        // One line where the window is wide; the actions under the title and
        // the tabs where it is not. "Wide" grows with the system's text size:
        // at 1.5 times the one line ran over by a few words' width (Spanish,
        // Russian) in a window 1280 wide.
        child: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= MediaQuery.textScalerOf(context).scale(980)) {
            return SizedBox(
              height: 60,
              child: Row(
                children: [
                  title,
                  const SizedBox(width: 20),
                  Flexible(child: tabs),
                  const Spacer(),
                  actions,
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 52, child: Row(children: [title, const SizedBox(width: 20), Flexible(child: tabs)])),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FittedBox(fit: BoxFit.scaleDown, child: actions),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Tab bar - 3 text pills
// ══════════════════════════════════════════════════════════════════

class _TabBar extends StatelessWidget {
  final _AutoTab selectedTab;
  final ValueChanged<_AutoTab> onTabChanged;

  const _TabBar({
    required this.selectedTab,
    required this.onTabChanged,
  });

  String _labelFor(AppLocalizations l10n, _AutoTab tab) => switch (tab) {
        _AutoTab.workflows => l10n.zestAutoTabWorkflows,
        _AutoTab.runs => l10n.zestAutoTabRuns,
        _AutoTab.triggers => l10n.zestAutoTabTriggers,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Scrolls sideways where a language's names are longer than the room.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final tab in _AutoTab.values)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _TabPill(
              key: ValueKey('automation-tab-${tab.name}'),
              label: _labelFor(l10n, tab),
              isActive: tab == selectedTab,
              onTap: () => onTabChanged(tab),
            ),
          ),
      ],
      ),
    );
  }
}

class _TabPill extends StatefulWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabPill({
    super.key,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_TabPill> createState() => _TabPillState();
}

class _TabPillState extends State<_TabPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isActive;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          // A page's tabs: words with the accent's line under the one in
          // hand, as every page tab (it was a filled pill as well).
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isActive ? ZestTokens.brand : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              color: isActive || _hovered
                  ? ZestTokens.textPrimary
                  : ZestTokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
