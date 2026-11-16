// What a remote screen's tab shows (4.0) until the screen view (the
// screen pane on computers, PhoneScreenView on phones) takes its place:
// that the screen is connected, its desktop's name and size, or how far it
// got. The desktop tab shows its connecting and dropped states as a
// terminal's does; a phone's page shows them here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart' show RedactableDisplay;

class ScreenTabPlaceholder extends ConsumerWidget {
  const ScreenTabPlaceholder({super.key, required this.sessionId, this.asPage = false});

  final String sessionId;

  /// A phone's page of its own (with its bar and Back), rather than a pane.
  final bool asPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(sessionStateProvider(sessionId));
    final shell = state?.session?.shell;
    final info = shell is ScreenShellService ? shell.connectedInfo : null;
    final String text;
    if (state?.status == SessionStatus.connected && info != null) {
      // The desktop's name is the server's: masked while recording, as a host's is.
      text = l10n.screenPlaceholderConnected(Redactable.host(info.name).displayIn(ref), info.width, info.height);
    } else if (state?.status == SessionStatus.connecting) {
      text = l10n.terminalConnecting;
    } else {
      text = state?.errorMessage ?? state?.dropCause ?? '';
    }
    final body = Center(
      key: ValueKey('screen-placeholder-$sessionId'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.monitor, size: 40, color: ZestTokens.textMuted),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: ZestTokens.textMuted, fontSize: 13)),
          ],
        ),
      ),
    );
    if (!asPage) return body;
    final label = state?.connectionLabel ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(Redactable.host(label).displayIn(ref))),
      body: SafeArea(child: body),
    );
  }
}
