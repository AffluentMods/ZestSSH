import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// What [DangerKind.explain] says: the part of the command it quotes in the
/// terminal's font, where the sentence has it between backticks.
class DangerExplanation extends StatelessWidget {
  const DangerExplanation(this.said, {super.key, required this.style});

  final String said;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final parts = said.split('`');
    return Text.rich(
      TextSpan(children: [
        for (var i = 0; i < parts.length; i++)
          if (parts[i].isNotEmpty)
            TextSpan(text: parts[i], style: i.isOdd ? const TextStyle(fontFamily: 'JetBrainsMono') : null),
      ]),
      style: style,
    );
  }
}

/// Result returned by [showDangerousCommandDialog].
///
/// Two-bit answer:
///   * [proceed] - did the user click "Run anyway" / "Paste anyway"?
///   * [dontAskAgain] - was the "Don't show this again" box ticked?
///
/// Callers are responsible for flipping the
/// `dangerousCommandProtectionProvider` off when [dontAskAgain] is true;
/// the dialog itself stays a pure UI primitive with no Riverpod
/// dependency.
class DangerousCommandDialogResult {
  const DangerousCommandDialogResult({
    required this.proceed,
    required this.dontAskAgain,
  });

  final bool proceed;
  final bool dontAskAgain;

  /// Convenience for "user dismissed via Esc / cancel".
  static const cancelled =
      DangerousCommandDialogResult(proceed: false, dontAskAgain: false);
}

/// [command] is what the question shows. Where that is not what runs ([runs]: a
/// masked value out of sight), [matches] are of what runs, and are said by what
/// is shown ([DangerousCommandService.asShown]).
Future<DangerousCommandDialogResult> showDangerousCommandDialog(
  BuildContext context, {
  required String command,
  required List<DangerousCommandMatch> matches,
  String? runs,
  bool isPaste = false,
}) async {
  // The checkbox's state, held outside the dialog so its answer outlives it.
  final dontAskAgain = ValueNotifier<bool>(false);
  final proceed = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    child: _DangerousCommandDialog(
      commands: [(command, runs == null ? matches : DangerousCommandService.asShown(runs, command, matches))],
      isPaste: isPaste,
      dontAskAgain: dontAskAgain,
    ),
  );
  final out = DangerousCommandDialogResult(
    proceed: proceed ?? false,
    dontAskAgain: dontAskAgain.value,
  );
  dontAskAgain.dispose();
  return out;
}

/// A command a question is about: what it runs, which is what is checked, and
/// what the question shows of it, with its masked values (`${VAR:secret}`) out of
/// sight.
typedef CommandAsked = ({String runs, String shown});

/// The question before a person's run of a workflow: every risky command it
/// will run, each shown whole, and how many hosts they run on ([hosts]).
Future<DangerousCommandDialogResult> showWorkflowDangerDialog(
  BuildContext context, {
  required List<CommandAsked> commands,
  required int hosts,
}) async {
  final dontAskAgain = ValueNotifier<bool>(false);
  final proceed = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    child: _DangerousCommandDialog(
      commands: [
        for (final c in commands)
          (c.shown, DangerousCommandService.asShown(c.runs, c.shown, DangerousCommandService.checkFilled(c.runs))),
      ],
      hosts: hosts,
      isPaste: false,
      dontAskAgain: dontAskAgain,
    ),
  );
  final out = DangerousCommandDialogResult(
    proceed: proceed ?? false,
    dontAskAgain: dontAskAgain.value,
  );
  dontAskAgain.dispose();
  return out;
}

/// The question itself, in the app's language and its own dialog (3.0, UI
/// step 12: a plain dialog that asked in English, "Dangerous Command
/// Detected", with what each risky part does in English as well). Its title
/// follows the worst of what was found: a warning that it could do lasting
/// harm, or only "Check this command" for what is worth a look.
/// Each part found has its sentence, and pointing at or tapping
/// a highlighted part lights the sentence that speaks of it.
class _DangerousCommandDialog extends StatefulWidget {
  const _DangerousCommandDialog({
    required this.commands,
    this.hosts,
    required this.isPaste,
    required this.dontAskAgain,
  });

  /// Each command it is about, and what was found in it.
  final List<(String, List<DangerousCommandMatch>)> commands;

  /// How many hosts they run on, where they run on hosts of a list.
  final int? hosts;
  final bool isPaste;
  final ValueNotifier<bool> dontAskAgain;

  @override
  State<_DangerousCommandDialog> createState() => _DangerousCommandDialogState();
}

class _DangerousCommandDialogState extends State<_DangerousCommandDialog> {
  /// The kind whose sentence is lit: of the highlighted part pointed at or
  /// tapped last.
  DangerKind? _lit;
  final _rows = <DangerKind, GlobalKey>{};
  final _taps = <DangerKind, TapGestureRecognizer>{};

  @override
  void dispose() {
    for (final t in _taps.values) {
      t.dispose();
    }
    super.dispose();
  }

  void _light(DangerKind? kind) {
    if (_lit != kind) setState(() => _lit = kind);
    if (kind == null) return;
    // On screen, in a long list of them.
    final row = _rows[kind]?.currentContext;
    if (row != null) {
      Scrollable.ensureVisible(row, duration: const Duration(milliseconds: 120), alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    }
  }

  TapGestureRecognizer _tapFor(DangerKind kind) =>
      _taps[kind] ??= (TapGestureRecognizer()..onTap = () => _light(kind));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final commands = widget.commands;
    final harm = worstDangerLevel([for (final (_, matches) in commands) ...matches]) == DangerLevel.harm;
    // The same kind found twice is said once, of the first place it was found.
    final kinds = <DangerKind, (String, DangerousCommandMatch)>{};
    for (final (command, matches) in commands) {
      for (final m in matches) {
        kinds.putIfAbsent(m.kind, () => (command, m));
      }
    }
    final on = widget.hosts;
    final many = commands.length > 1;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: harm ? ZestDialogTone.destructive : ZestDialogTone.neutral,
      icon: harm ? LucideIcons.alertTriangle : LucideIcons.eye,
      title: !harm
          ? (many ? l10n.dangerLookTitleMany : l10n.dangerLookTitle)
          : widget.isPaste
              ? l10n.dangerPasteTitle
              : many
                  ? l10n.wfDangerCommandsTitle
                  : l10n.dangerCommandTitle,
      subtitle: harm ? l10n.dangerSubtitle : l10n.dangerLookSubtitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            // Show the WHOLE command (scrollable) with the dangerous span
            // highlighted, so a benign prefix can't hide the harmful tail the
            // way a first-200-chars truncation did. Control characters are
            // rendered as visible glyphs so a smuggled newline can't execute
            // silently or fake the preview's length.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, (command, matches)) in commands.indexed) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _preview(command, matches),
                ],
              ],
            ),
          ),
          if (on != null) ...[
            const SizedBox(height: 10),
            Text(
              l10n.wfDangerOnHosts(on),
              key: const ValueKey('danger-on-hosts'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.onSurface),
            ),
          ],
          const SizedBox(height: 10),
          for (final e in kinds.entries) _row(l10n, e.key, e.value.$1, e.value.$2),
          const SizedBox(height: 4),
          // Don't ask again: the box in line with the warnings' icons above
          // it, the whole row a target, read as one checkbox with its label.
          // Only on the red question: the setting it turns off is the whole
          // guard, and a box on the quiet question turned the red one off too.
          if (harm)
            ValueListenableBuilder<bool>(
              valueListenable: widget.dontAskAgain,
              builder: (_, value, _) => MergeSemantics(
                child: InkWell(
                  key: const ValueKey('danger-dont-ask-again'),
                  onTap: () => widget.dontAskAgain.value = !value,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: Checkbox(
                            value: value,
                            onChanged: (v) => widget.dontAskAgain.value = v ?? false,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            activeColor: AppColors.brandOrange,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            l10n.dangerDontAskAgain,
                            style: TextStyle(fontSize: 13, color: AppColors.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      primaryAction: (
        label: !harm
            ? (widget.isPaste ? l10n.dangerLookPaste : l10n.dangerLookRun)
            : widget.isPaste
                ? l10n.dangerPasteAnyway
                : l10n.dangerRunAnyway,
        icon: null,
        onPressed: () => Navigator.of(context).pop(true),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
    );
  }

  /// A part found in [command]: what it does in a few words, and in a sentence
  /// that quotes it and says what to do.
  Widget _row(AppLocalizations l10n, DangerKind kind, String command, DangerousCommandMatch match) {
    final harm = kind.level == DangerLevel.harm;
    final tone = harm ? AppColors.error : AppColors.warning;
    final lit = _lit == kind;
    return AnimatedContainer(
      key: _rows[kind] ??= GlobalKey(),
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: lit ? tone.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(harm ? LucideIcons.alertCircle : LucideIcons.eye, size: 16, color: tone),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kind.describe(l10n),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.onSurface),
                ),
                const SizedBox(height: 2),
                DangerExplanation(
                  kind.explain(l10n, match.quotedIn(command)),
                  key: ValueKey('danger-explain-${kind.name}'),
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Renders [command] with the matched dangerous spans highlighted and every
  /// character that would not show as itself made visible
  /// ([visibleCharacter]). Scrolls vertically so long commands are fully
  /// inspectable rather than truncated, up to what can be laid out with the window
  /// still moving ([kMaxCommandShown]).
  Widget _preview(String command, List<DangerousCommandMatch> matches) {
    // Highlight ranges are offsets into the ORIGINAL command; escaping happens
    // per-character below so the highlight stays aligned even though escaped
    // glyphs change the displayed length.
    final ranges = matches
        .where((m) => m.start >= 0 && m.end > m.start && m.start < command.length)
        .map((m) => (start: m.start, end: m.end.clamp(0, command.length), kind: m.kind))
        .toList();

    DangerKind? kindAt(int i) {
      for (final r in ranges) {
        if (i >= r.start && i < r.end) return r.kind;
      }
      return null;
    }

    // The app's own code face, as the question before a broadcast shows it
    // ('monospace' named no font the app has, so each system chose its own).
    final base = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: 13,
      color: AppColors.onSurface,
    );

    final spans = <TextSpan>[];
    final buf = StringBuffer();
    DangerKind? current;
    void flush() {
      if (buf.isEmpty) return;
      final kind = current;
      if (kind == null) {
        spans.add(TextSpan(text: buf.toString(), style: base));
      } else {
        final tone = kind.level == DangerLevel.harm ? AppColors.error : AppColors.warning;
        spans.add(TextSpan(
          text: buf.toString(),
          style: base.copyWith(
            color: tone,
            fontWeight: FontWeight.w700,
            backgroundColor: tone.withValues(alpha: 0.15),
          ),
          // Its sentence: pointing at it on a computer, a tap on a phone.
          mouseCursor: SystemMouseCursors.help,
          onEnter: (_) => _light(kind),
          onExit: (_) => _light(null),
          recognizer: _tapFor(kind),
        ));
      }
      buf.clear();
    }

    var i = 0;
    for (final character in command.runes) {
      if (i >= kMaxCommandShown) {
        current = null;
        flush();
        buf.write('…');
        break;
      }
      final k = kindAt(i);
      if (k != current) flush();
      current = k;
      buf.write(visibleCharacter(character));
      i += character > 0xffff ? 2 : 1;
    }
    flush();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: SingleChildScrollView(
        child: Text.rich(key: const ValueKey('danger-preview'), TextSpan(children: spans)),
      ),
    );
  }
}
