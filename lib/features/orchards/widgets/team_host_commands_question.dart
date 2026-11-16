import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/team_host_commands.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/utils/logger.dart';

/// Answers the sessions' questions about a team host's commands
/// ([teamCommandsRequestProvider]) on screen, in the context [navigator] gives
/// (the app's navigator). Call it from a build: the app's root does.
void answerTeamCommandRequests(WidgetRef ref, BuildContext? Function() navigator) {
  ref.listen<TeamCommandsRequest?>(teamCommandsRequestProvider, (_, request) {
    if (request == null || !request.isOpen) return;
    unawaited(_answer(navigator(), ref, request));
  });
}

Future<void> _answer(BuildContext? context, WidgetRef ref, TeamCommandsRequest request) async {
  try {
    if (context == null || !context.mounted || ref.read(isAppLockedProvider)) {
      request.reply(false);
      return;
    }
    // The question shows the commands as they are: while the screen is recorded,
    // which paints stand-ins for them, recording is turned off first, or they are
    // not run.
    if (!await confirmRevealWhileRecording(context, ref) || !context.mounted) {
      request.reply(false);
      return;
    }
    // (Its time may have run out while that was asked: the session has said so.)
    if (!request.isOpen) return;
    request.reply(await showTeamCommandsQuestion(context, request) ?? false);
  } catch (e) {
    AppLogger.warning('Team host commands: a question was not shown ($e)');
    request.reply(false);
  }
}

/// Whether what [request] shows is to be typed; null or false when not. Nothing
/// is chosen for the keyboard: it comes up over a terminal, and an Enter meant
/// for that answers nothing. It closes once [request] is answered some other
/// way: nobody answered in time, and the session says it was not run, so a Run
/// left on screen would do nothing.
Future<bool?> showTeamCommandsQuestion(BuildContext context, TeamCommandsRequest request) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.terminal,
    title: l10n.teamCommandsTitle,
    // A record brings the name too: what would hide or turn it round shows as
    // its code.
    subtitle: l10n.teamCommandsBody(
      Redactable.host(visibleCommand(request.hostLabel)).display,
      Redactable.address(visibleCommand(request.address)).display,
    ),
    body: _ClosesWhenAnswered(
      request: request,
      child: Container(
        key: const ValueKey('team-commands-box'),
        constraints: const BoxConstraints(maxHeight: 240),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.v3BorderSubtle.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            request.commands.shown.join('\n'),
            key: const ValueKey('team-commands-text'),
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.45),
          ),
        ),
      ),
    ),
    primaryAction: (
      label: l10n.teamCommandsRun,
      onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
      icon: LucideIcons.play,
    ),
    secondaryAction: (
      label: l10n.teamCommandsSkip,
      onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
    ),
  );
}

/// Takes the dialog it is in off the screen once [request] has its answer from
/// anywhere but the dialog's own buttons (they have closed it by then).
class _ClosesWhenAnswered extends StatefulWidget {
  const _ClosesWhenAnswered({required this.request, required this.child});

  final TeamCommandsRequest request;
  final Widget child;

  @override
  State<_ClosesWhenAnswered> createState() => _ClosesWhenAnsweredState();
}

class _ClosesWhenAnsweredState extends State<_ClosesWhenAnswered> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.request.answer.then((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = route.navigator!;
      // (Something else may have opened over it.)
      route.isCurrent ? navigator.pop() : navigator.removeRoute(route);
    }));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
