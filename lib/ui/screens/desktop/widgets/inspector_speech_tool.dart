import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/terminal/terminal_dictation.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';

/// Speech to text in the Inspector's Tools tab (4.0): start and stop it for
/// this session, what it is hearing and what it typed last, the language it
/// listens in, and that it is recognised on this computer. The same
/// listening as the session header's microphone and its key: one at a time,
/// for one session.
class InspectorSpeechTool extends ConsumerWidget {
  const InspectorSpeechTool({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final dictation = ref.watch(dictationProvider);
    final shortcut = ref.watch(shortcutBindingProvider(ShortcutAction.dictate));
    final here = dictation.listening && dictation.sessionId == sessionId;
    final elsewhere = dictation.listening && !here;
    final action = dictation.listening ? l10n.inspectorSpeechStop : l10n.inspectorSpeechStart;
    final language = dictation.language;
    final note = TextStyle(fontSize: 12, color: ZestColors.textTertiary);

    String? heard;
    var guess = false;
    if (here) {
      if (dictation.hearing.isNotEmpty) {
        heard = l10n.inspectorSpeechHearing(dictation.hearing);
        guess = true;
      } else if (dictation.lastTyped.isNotEmpty) {
        heard = l10n.inspectorSpeechTyped(dictation.lastTyped);
      } else {
        heard = l10n.inspectorSpeechWaiting;
        guess = true;
      }
    }

    return Container(
      key: const ValueKey('inspector-speech'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: dictation.listening ? ZestColors.accentPrimary : ZestColors.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              ZestStatusPill(
                key: const ValueKey('inspector-speech-state'),
                kind: dictation.listening ? ZestStatusKind.healthy : ZestStatusKind.neutral,
                icon: dictation.listening ? LucideIcons.mic : LucideIcons.micOff,
                label: dictation.listening ? l10n.inspectorSpeechListening : l10n.inspectorSpeechOff,
              ),
              Tooltip(
                message: shortcut == null ? action : '$action ($shortcut)',
                child: ZestButton(
                  key: const ValueKey('inspector-speech-toggle'),
                  label: action,
                  icon: dictation.listening ? LucideIcons.square : LucideIcons.mic,
                  variant: dictation.listening ? ZestButtonVariant.secondary : ZestButtonVariant.primary,
                  size: ZestButtonSize.medium,
                  onPressed: () => toggleDictation(context, ref, sessionId),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (heard != null)
            Container(
              key: const ValueKey('inspector-speech-heard'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: ZestColors.surfaceChip,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: ZestColors.borderSubtle),
              ),
              // Said as it changes, to a screen reader as well.
              child: Semantics(
                liveRegion: true,
                child: Text(
                  heard,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontStyle: guess ? FontStyle.italic : FontStyle.normal,
                    color: guess ? ZestColors.textSecondary : ZestColors.textPrimary,
                  ),
                ),
              ),
            )
          else
            Text(
              // Listening for another session's terminal: the button stops it.
              elsewhere ? l10n.inspectorSpeechListeningElsewhere : l10n.inspectorSpeechHint,
              style: TextStyle(fontSize: 12, color: ZestColors.textSecondary),
            ),
          const SizedBox(height: 8),
          Text(
            language == null ? l10n.inspectorSpeechLanguageSystem : l10n.inspectorSpeechLanguage(language),
            key: const ValueKey('inspector-speech-language'),
            style: note,
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.shieldCheck, size: 13, color: ZestColors.textTertiary),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(l10n.inspectorSpeechPrivacy, style: note)),
            ],
          ),
        ],
      ),
    );
  }
}
