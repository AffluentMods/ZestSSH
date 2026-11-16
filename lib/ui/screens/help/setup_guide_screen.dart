import 'dart:io' show Platform;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../router/routes.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/zest_tokens.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../utils/platform_utils.dart';
import '../../widgets/dock_panel.dart';
import '../../widgets/responsive_scaffold.dart';

/// Which feature the setup guide is opened for.
enum SetupTopic { automation, snippets, serverMonitor }

/// Non-null while the desktop setup-guide side panel is open, holding the
/// topic it shows. Set by [showSetupGuide] on desktop, cleared by the panel's
/// close button. Null = closed. (Mobile uses the full-screen route instead.)
final setupGuideDockProvider = StateProvider<SetupTopic?>((_) => null);

/// The five platforms ZestSSH ships on. Names are brand nouns, not translated.
enum _Os { windows, macos, linux, android, ios }

extension _OsName on _Os {
  String get label => switch (this) {
        _Os.windows => 'Windows',
        _Os.macos => 'macOS',
        _Os.linux => 'Linux',
        _Os.android => 'Android',
        _Os.ios => 'iOS',
      };

  IconData get icon => switch (this) {
        _Os.windows => LucideIcons.appWindow,
        _Os.macos => LucideIcons.laptop,
        _Os.linux => LucideIcons.terminal,
        _Os.android => Icons.android,
        _Os.ios => LucideIcons.smartphone,
      };
}

_Os get _currentOs {
  if (Platform.isWindows) return _Os.windows;
  if (Platform.isMacOS) return _Os.macos;
  if (Platform.isLinux) return _Os.linux;
  if (Platform.isAndroid) return _Os.android;
  return _Os.ios;
}

/// Opens the setup guide for [topic]. On desktop it opens [SetupGuideDock], a
/// right-docked side panel that stays open while you work; on mobile (and
/// tablets, which use the mobile shell) it pushes the full-screen route.
void showSetupGuide(BuildContext context, SetupTopic topic) {
  if (desktopShellInUse) {
    ProviderScope.containerOf(context, listen: false)
        .read(setupGuideDockProvider.notifier)
        .state = topic;
  } else {
    context.push(Routes.setupGuide, extra: topic);
  }
}

/// A prominent, labelled "Setup guide" button for a screen header. Opens the
/// OS-aware setup guide for [topic]. Bigger and easier to spot than a bare "?"
/// icon (field feedback: the icon was too small and missed on most screens).
/// Drop it into a [ZestPageHeader]'s actions, an AppBar's actions, or a
/// [ResponsiveScaffold]'s actions.
class SetupGuideButton extends StatelessWidget {
  const SetupGuideButton(this.topic, {super.key});

  final SetupTopic topic;

  String _tooltip(AppLocalizations l10n) => switch (topic) {
        SetupTopic.automation => l10n.setupGuideAutomationTitle,
        SetupTopic.snippets => l10n.setupGuideSnippetsTitle,
        SetupTopic.serverMonitor => l10n.setupGuideMonitorTitle,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // A phone's app bar has room for the title or the word, not both: a
    // plain icon button there, in the bar's grey, with the bar's 48 target
    // (it was a box outlined in the accent, louder than the page's title).
    if (MediaQuery.sizeOf(context).width < 600) {
      return IconButton(
        key: const ValueKey('setup-guide-compact'),
        tooltip: _tooltip(l10n),
        onPressed: () => showSetupGuide(context, topic),
        color: ZestTokens.textSecondary,
        icon: const Icon(LucideIcons.bookOpen, size: 20),
      );
    }
    // A computer: the labelled secondary button, neutral beside the page's
    // own primary action.
    return Tooltip(
      message: _tooltip(l10n),
      child: OutlinedButton.icon(
        onPressed: () => showSetupGuide(context, topic),
        icon: const Icon(LucideIcons.bookOpen, size: 16),
        label: Text(l10n.setupGuideTitle),
      ),
    );
  }
}

/// Step-by-step setup help. The five operating systems are listed with the
/// user's current one first and expanded; tapping any OS reveals its steps for
/// the chosen [topic]. For automation, each OS also links to the full guide.
class SetupGuideScreen extends StatelessWidget {
  const SetupGuideScreen({super.key, required this.topic});

  final SetupTopic topic;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ResponsiveScaffold(
      title: _topicTitle(l10n, topic),
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: SetupGuideBody(topic: topic),
    );
  }
}

/// The desktop side panel: the setup guide docked to the right of the content
/// (the same chrome as the Help panel), shown while [setupGuideDockProvider]
/// holds a topic. It is a layout sibling of the content, so the content
/// shrinks instead of being covered and the guide stays open while you work.
class SetupGuideDock extends ConsumerWidget {
  const SetupGuideDock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topic = ref.watch(setupGuideDockProvider);
    if (topic == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return DockPanel(
      title: _topicTitle(l10n, topic),
      width: 420,
      onClose: () => ref.read(setupGuideDockProvider.notifier).state = null,
      child: SetupGuideBody(topic: topic),
    );
  }
}

/// The scrolling guide content: an intro line, then one expandable card per
/// operating system with the current device first and expanded. Shared by the
/// full-screen [SetupGuideScreen] (mobile) and the docked [SetupGuideDock]
/// (desktop). For automation, each OS card also links to the full guide.
class SetupGuideBody extends StatelessWidget {
  const SetupGuideBody({super.key, required this.topic});

  final SetupTopic topic;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final current = _currentOs;
    final oses = [current, ..._Os.values.where((o) => o != current)];
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        Text(
          _topicIntro(l10n, topic),
          style: TextStyle(
              color: AppColors.textSecondary, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < oses.length; i++)
          _OsCard(
            os: oses[i],
            isCurrent: oses[i] == current,
            initiallyExpanded: i == 0,
            steps: _steps(l10n, topic, oses[i]),
            footerAction: topic == SetupTopic.automation
                ? _AutomationGuideLink()
                : null,
          ),
      ],
    );
  }
}

String _topicTitle(AppLocalizations l10n, SetupTopic topic) => switch (topic) {
      SetupTopic.automation => l10n.setupGuideAutomationTitle,
      SetupTopic.snippets => l10n.setupGuideSnippetsTitle,
      SetupTopic.serverMonitor => l10n.setupGuideMonitorTitle,
    };

String _topicIntro(AppLocalizations l10n, SetupTopic topic) => switch (topic) {
      SetupTopic.automation => l10n.setupGuideAutomationIntro,
      SetupTopic.snippets => l10n.setupGuideSnippetsIntro,
      SetupTopic.serverMonitor => l10n.setupGuideMonitorIntro,
    };

List<String> _steps(AppLocalizations l10n, SetupTopic topic, _Os os) {
  switch (topic) {
    case SetupTopic.automation:
      switch (os) {
        case _Os.android:
          return [
            l10n.setupAutoAndroid1,
            l10n.setupAutoAndroid2,
            l10n.setupAutoAndroid3,
          ];
        case _Os.ios:
          return [
            l10n.setupAutoIos1,
            l10n.setupAutoIos2,
            l10n.setupAutoIos3,
          ];
        case _Os.windows:
        case _Os.macos:
        case _Os.linux:
          return [
            l10n.setupAutoDesktop1,
            l10n.setupAutoDesktop2,
            switch (os) {
              _Os.windows => l10n.setupAutoDesktopSchedWindows,
              _Os.macos => l10n.setupAutoDesktopSchedMacos,
              _ => l10n.setupAutoDesktopSchedLinux,
            },
          ];
      }
    case SetupTopic.snippets:
      final steps = [
        l10n.setupSnippets1,
        l10n.setupSnippets2,
        l10n.setupSnippets3,
      ];
      steps.add(switch (os) {
        _Os.android => l10n.setupSnippetsTriggerAndroid,
        _Os.ios => l10n.setupSnippetsTriggerIos,
        _ => l10n.setupSnippetsTriggerDesktop,
      });
      return steps;
    case SetupTopic.serverMonitor:
      final steps = [
        l10n.setupMonitor1,
        l10n.setupMonitor2,
        l10n.setupMonitor3,
        l10n.setupMonitor4,
      ];
      if (os == _Os.ios || os == _Os.android) {
        steps.add(l10n.setupMonitorMobileNote);
      }
      return steps;
  }
}

class _AutomationGuideLink extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        icon: const Icon(LucideIcons.bookOpen, size: 16),
        label: Text(l10n.setupGuideOpenFullAutomation),
        style: TextButton.styleFrom(foregroundColor: AppColors.accentInk),
        onPressed: () => context.push(Routes.automationGuide),
      ),
    );
  }
}

class _OsCard extends StatelessWidget {
  const _OsCard({
    required this.os,
    required this.isCurrent,
    required this.initiallyExpanded,
    required this.steps,
    this.footerAction,
  });

  final _Os os;
  final bool isCurrent;
  final bool initiallyExpanded;
  final List<String> steps;
  final Widget? footerAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Theme(
        // Drop the default ExpansionTile dividers for a cleaner card.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: Icon(os.icon,
              color: isCurrent ? AppColors.accentInk : AppColors.textSecondary),
          // The badge after the system's name, on the next line where the two
          // do not fit on one.
          title: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(os.label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15)),
              if (isCurrent) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.brandOrange.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l10n.setupGuideYourDevice,
                    style: TextStyle(
                        color: AppColors.accentInk,
                        fontSize: 10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 22 across for a number 11 high, and as much wider as
                    // the number grows with the text.
                    Container(
                      width: MediaQuery.textScalerOf(context).scale(11) * 2,
                      height: MediaQuery.textScalerOf(context).scale(11) * 2,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.brandOrange.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Text('${i + 1}',
                          style: TextStyle(
                              color: AppColors.accentInk,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(steps[i],
                          style: const TextStyle(fontSize: 13, height: 1.4)),
                    ),
                  ],
                ),
              ),
            ?footerAction,
          ],
        ),
      ),
    );
  }
}
