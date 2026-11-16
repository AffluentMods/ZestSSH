// Remote screens (4.0): the questions a session asks when its
// person picks "Text size on the remote" (an RDP session) or "Frame rate
// limit" in the panel. The same choices as the host's editor; the editor
// keeps what a session starts with, these change the running one.
import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart' show ZestChoice, showZestChoice;

/// A text size's words: "Auto" for nothing said, else the percentage as the
/// language writes it.
String screenTextSizeLabel(AppLocalizations l10n, int percent) =>
    percent == 0 ? l10n.connectionEditRdpTextSizeOwn : l10n.connectionEditRdpTextSizePercent(percent);

/// Asks how large the remote draws its text, [current] picked. The size
/// chosen (0: nothing said, the remote's own), or null when it was closed.
Future<int?> showScreenTextSizeQuestion(BuildContext context, {required int current}) {
  final l10n = AppLocalizations.of(context)!;
  return showZestChoice<int>(
    context,
    key: const ValueKey('screen-text-size-question'),
    title: l10n.connectionEditRdpTextSize,
    subtitle: l10n.connectionEditRdpTextSizeNote,
    icon: LucideIcons.type,
    selected: ScreenOptions.textScales.contains(current) ? current : 0,
    choices: [
      for (final n in ScreenOptions.textScales)
        ZestChoice(
          key: ValueKey('screen-text-size-question-$n'),
          value: n,
          label: screenTextSizeLabel(l10n, n),
        ),
    ],
  );
}

/// A frame rate limit's words: "Off" for none, else so many a second as the
/// language abbreviates it.
String screenFrameLimitLabel(AppLocalizations l10n, int limit) =>
    limit == 0 ? l10n.connectionEditScreenFrameLimitOff : l10n.connectionEditScreenFrameLimitFps(limit);

/// Asks how many pictures a second the session draws at most, [current]
/// picked. The limit chosen (0: none), or null when it was closed.
Future<int?> showScreenFrameLimitQuestion(BuildContext context, {required int current}) {
  final l10n = AppLocalizations.of(context)!;
  return showZestChoice<int>(
    context,
    key: const ValueKey('screen-frame-limit-question'),
    title: l10n.connectionEditScreenFrameLimit,
    subtitle: l10n.connectionEditScreenFrameLimitNote,
    icon: LucideIcons.gauge,
    selected: ScreenOptions.frameLimits.contains(current) ? current : 0,
    choices: [
      for (final n in ScreenOptions.frameLimits)
        ZestChoice(
          key: ValueKey('screen-frame-limit-question-$n'),
          value: n,
          label: screenFrameLimitLabel(l10n, n),
        ),
    ],
  );
}
