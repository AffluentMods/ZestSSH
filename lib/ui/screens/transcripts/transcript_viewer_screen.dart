import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A saved transcript, read: decrypted with this device's key when the app
/// encrypted it (.zesttx), as it is when saved as plain text (3.0, 17 October
/// 2026: nothing in the app opened one). One that does not open says why, with
/// the details to copy.
class TranscriptViewerScreen extends ConsumerStatefulWidget {
  const TranscriptViewerScreen({super.key, required this.path});

  final String path;

  @override
  ConsumerState<TranscriptViewerScreen> createState() => _TranscriptViewerScreenState();
}

class _TranscriptViewerScreenState extends ConsumerState<TranscriptViewerScreen> {
  Object? _why;
  late final Future<String?> _text = SessionTranscriptService.readFromFile(widget.path).then((text) {
    _why = SessionTranscriptService.lastReadError;
    return text;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The name is masked by a plain function: rebuilt when recording mode
    // flips.
    ref.watch(recordingModeProvider);
    final name = Redactable.freeText(p.basename(widget.path)).display;
    return FutureBuilder<String?>(
      future: _text,
      builder: (context, snap) {
        final text = snap.data;
        return ResponsiveScaffold(
          title: name,
          actions: [
            if (text != null)
              IconButton(
                key: const ValueKey('transcript-copy-all'),
                tooltip: l10n.transcriptCopyAll,
                icon: const Icon(LucideIcons.copy),
                onPressed: () => _copyAll(text),
              ),
          ],
          body: switch (snap.connectionState) {
            ConnectionState.done when text != null => _lines(text),
            ConnectionState.done => LoadErrorState(
                icon: LucideIcons.lock,
                message: l10n.transcriptNotOpened,
                hint: l10n.transcriptNotOpenedHint,
                where: 'Opening a saved transcript',
                error: _why ?? snap.error ?? 'Not opened',
              ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        );
      },
    );
  }

  Widget _lines(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('transcript-lines'),
        padding: const EdgeInsets.all(12),
        itemCount: lines.length,
        itemBuilder: (context, i) => Text(
          lines[i],
          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.35, color: AppColors.onSurface),
        ),
      ),
    );
  }

  Future<void> _copyAll(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showTopSnackBar(context, AppLocalizations.of(context)!.transcriptCopied, isSuccess: true);
  }
}
