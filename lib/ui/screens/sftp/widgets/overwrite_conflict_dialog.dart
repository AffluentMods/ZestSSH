import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/byte_size.dart';

/// What to do when a destination file already exists.
enum OverwriteAction {
  /// Replace the destination file ("Replace changed files": files that are
  /// already byte-identical were skipped before this prompt was ever shown).
  overwrite,

  /// Skip this file, leave destination unchanged ("Skip existing files").
  skip,

  /// Replace only if source is newer than destination by mtime ("Replace only
  /// when local is newer"). A file that differs but is not newer is never
  /// dropped silently: it is counted and offered for a one-tap resend. Offered
  /// only while more conflicts can follow: it is a rule for the rest of a
  /// batch, and on a single file Replace or Skip with both dates on screen
  /// already says the same.
  newer,

  /// Save under a new auto-generated name (e.g. "foo (1).txt").
  rename,

  /// User cancelled the whole batch.
  cancel,
}

/// Result of a conflict prompt - combines the chosen action with whether
/// to apply the same choice to every remaining file in the batch.
class OverwriteResolution {
  final OverwriteAction action;
  final bool applyToAll;

  const OverwriteResolution(this.action, {this.applyToAll = false});

  static const cancelled = OverwriteResolution(OverwriteAction.cancel);
}

/// Metadata about a file used to render the source / destination summary
/// rows. All fields are optional - null fields render as a dash.
class OverwriteFileInfo {
  final String path;
  final int? size;
  final DateTime? modified;

  const OverwriteFileInfo({required this.path, this.size, this.modified});
}

/// Modal dialog shown when a transfer would overwrite an existing file.
///
/// Pattern: caller checks for destination existence, calls `show()`, awaits
/// the resolution, then either skips or proceeds (and respects `applyToAll`
/// for the rest of the batch by short-circuiting subsequent prompts). The
/// "force re-upload everything" escape hatch deliberately does NOT live here:
/// it is an advanced option on the folder-sync preview.
class OverwriteConflictDialog extends StatefulWidget {
  final OverwriteFileInfo source;
  final OverwriteFileInfo destination;

  /// 1-based position of this conflict within the batch, and the batch size.
  /// One dialog serves both single (total == 1) and batch (total > 1): the
  /// counter renders only when total > 1, and the apply-to-all checkbox is
  /// always present but disabled once there are no further conflicts to apply
  /// it to (the last, or only, item).
  final int index;
  final int total;

  /// What the source is doing to the destination - "Uploading" / "Downloading"
  /// / "Copying", already localized by the caller. Labels the source row and
  /// has no other behaviour. Null reads as "Copying".
  final String? sourceVerb;

  /// Overrides whether the "apply to all remaining conflicts" control is
  /// enabled. When null (the default), it is derived from the counter
  /// (`index < total`), which is correct when the caller pre-counted every
  /// conflict up front. A recursive or streamed batch cannot cheaply know the
  /// total before it starts moving bytes, so it passes `true` to keep the
  /// control usable even while the running count is only a floor.
  final bool? applyToAllEnabled;

  /// Whether [total] is the exact conflict count. False for a recursive folder
  /// transfer, where only top-level conflicts are pre-counted, so nested
  /// conflicts push [index] past [total]; the counter then shows a running
  /// "Conflict N" instead of a wrong "N of M".
  final bool totalIsExact;

  /// How the two files' times show (the SFTP time format setting).
  final SftpTimeFormat timeFormat;

  const OverwriteConflictDialog({
    super.key,
    required this.source,
    required this.destination,
    this.index = 1,
    this.total = 1,
    this.sourceVerb,
    this.applyToAllEnabled,
    this.totalIsExact = true,
    this.timeFormat = SftpTimeFormat.h24,
  });

  /// Returns the user's chosen action. Returns
  /// `OverwriteResolution.cancelled` if the dialog is dismissed.
  static Future<OverwriteResolution> show(
    BuildContext context, {
    required OverwriteFileInfo source,
    required OverwriteFileInfo destination,
    int index = 1,
    int total = 1,
    String? sourceVerb,
    bool? applyToAllEnabled,
    bool totalIsExact = true,
    SftpTimeFormat timeFormat = SftpTimeFormat.h24,
  }) async {
    final result = await showZestModal<OverwriteResolution>(
      context: context,
      size: ZestModalSize.standard,
      barrierDismissible: false,
      child: OverwriteConflictDialog(
        source: source,
        destination: destination,
        index: index,
        total: total,
        sourceVerb: sourceVerb,
        applyToAllEnabled: applyToAllEnabled,
        totalIsExact: totalIsExact,
        timeFormat: timeFormat,
      ),
    );
    return result ?? OverwriteResolution.cancelled;
  }

  @override
  State<OverwriteConflictDialog> createState() =>
      _OverwriteConflictDialogState();
}

class _OverwriteConflictDialogState extends State<OverwriteConflictDialog> {
  bool _applyToAll = false;

  /// The resolution chosen in the list; null until one is, when the
  /// recommended one stands (see build).
  OverwriteAction? _chosen;

  String _fmtSize(int? bytes) =>
      bytes == null ? '-' : formatByteSize(bytes, digits: SizeDigits.oneThenTwo);

  String _fmtDate(DateTime? d) =>
      d == null ? '-' : widget.timeFormat.dateTime(d);

  /// Inserts zero-width break opportunities after path separators so a long
  /// path WRAPS at its own segments inside the fixed-width dialog rather than
  /// truncating. The tooltip still shows the clean path.
  String _wrappable(String path) => path
      .replaceAll('/', '/​')
      .replaceAll('\\', '\\​');

  /// One side of the compare grid: a fixed 96px label column (icon + caps
  /// label) sharing a left edge with every other side, then the path and
  /// metadata. [surface] sets this side apart from the other (local sits on a
  /// sunken surface, remote on a raised one) so the two halves read as a
  /// comparison, not two stacked rows.
  Widget _side(AppLocalizations l10n, String label, OverwriteFileInfo info,
      IconData icon, Color surface,
      {bool isNewer = false, bool unreadable = false}) {
    return Container(
      color: surface,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Row(
              children: [
                Icon(icon,
                    size: 13,
                    color: unreadable
                        ? AppColors.v3TextPrimary
                        : AppColors.onSurfaceDim),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 0.5,
                      color: AppColors.onSurfaceDim,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Long paths wrap at their separators (the tooltip holds the
                // clean copy) rather than truncating, so local and remote can
                // be read in full against each other.
                Tooltip(
                  message: info.path,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    _wrappable(info.path),
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                // Metadata line - a failed lookup renders "Not readable" in the
                // warn colour, never a placeholder or a 1970 date. The newer
                // side carries an inline "newer" tag so Replace is informed.
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _metaLine(l10n, info),
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: unreadable
                              ? AppColors.v3TextPrimary
                              : AppColors.onSurfaceDim,
                          fontFamily: 'JetBrainsMono',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isNewer) ...[
                      const SizedBox(width: 6),
                      Text(
                        l10n.sftpOverwriteNewerTag,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.onSurfaceVariant,
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Size + date as one line, or "Not readable" when the stat came back empty
  /// (both fields null) - a failed lookup is stated, not drawn as content.
  String _metaLine(AppLocalizations l10n, OverwriteFileInfo info) {
    if (info.size == null && info.modified == null) {
      return l10n.sftpOverwriteNotReadable;
    }
    return '${_fmtSize(info.size)}  •  ${_fmtDate(info.modified)}';
  }

  void _resolve(OverwriteAction action) {
    Navigator.of(context).pop(
      OverwriteResolution(action, applyToAll: _applyToAll),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final src = widget.source;
    final dst = widget.destination;
    final srcNewer = src.modified != null &&
        dst.modified != null &&
        src.modified!.isAfter(dst.modified!);
    final dstNewer = src.modified != null &&
        dst.modified != null &&
        dst.modified!.isAfter(src.modified!);
    final destName = _basename(dst.path);
    // The counter is exact only while the prompts stay within the pre-counted
    // total: a prompt past it (a file that appeared after the scan) falls back
    // to the running "Conflict N" rather than "5 of 4".
    final exact = widget.totalIsExact && widget.index <= widget.total;
    // Conflicts still to resolve after this one, when the total is known.
    final remaining = exact ? widget.total - widget.index : 0;
    // The apply-to-all box is shown always, but only does anything
    // while more conflicts can follow: a known remainder, or a batch whose total
    // could not be counted up front (applyToAllEnabled).
    final canApplyToAll =
        exact ? remaining > 0 : (widget.applyToAllEnabled ?? false);
    // "Replace if newer" is a rule for the conflicts still to come, so it is
    // offered only while "Do this for the rest" can carry it (user decision
    // 2026-09-22). On a single file, or the last conflict, Replace or Skip with
    // both dates on screen says the same thing.
    final showNewer = canApplyToAll;
    // A batch (a folder / multi-file push) versus a single deliberate drag onto
    // one file. `total > 1` means the conflicts were pre-counted; a streamed
    // recursive copy that cannot pre-count forces the batch signal on via
    // `applyToAllEnabled`. Drives both the Cancel-all label and, below, which
    // action is the recommended primary.
    final isBatch = widget.total > 1 || widget.applyToAllEnabled == true;
    // The remote (destination) could not be stat'd: both size and mtime are
    // null (the same test _metaLine uses to print "Not readable").
    final remoteUnreadable = dst.size == null && dst.modified == null;
    // "Replace if newer" compares the two mtimes; with either side missing it
    // cannot make the call, so it is shown disabled with the reason stated.
    final newerUnavailable = src.modified == null || dst.modified == null;

    // The recommended resolution is chosen as the dialog opens (one click,
    // or Enter, takes it): Replace, always. On a server you are almost always
    // updating the destination to match your source (the point of SFTP is
    // usually to update or replace); Keep both would
    // leave the stale file being served and litter "(1)" copies across the
    // tree. Where the server's file could not be read, its side says "Not
    // readable" right above the choice, so Replace is still made knowingly.
    // Every resolution stays a choice in the list; the main button in the
    // footer says the one chosen (the dialog rules of 3.4: the four were
    // buttons in the dialog's body).
    const recommended = OverwriteAction.overwrite;
    final chosen = _chosen ?? recommended;
    final choices = <(OverwriteAction, String, String?)>[
      (OverwriteAction.overwrite, l10n.sftpOverwriteReplaceShort, l10n.sftpOverwriteReplaceChangedDesc),
      (OverwriteAction.skip, l10n.sftpOverwriteSkipShort, null),
      (OverwriteAction.rename, l10n.sftpOverwriteKeepBoth, l10n.sftpOverwriteKeepBothDesc),
      if (showNewer) (OverwriteAction.newer, l10n.sftpOverwriteNewerShort, l10n.sftpOverwriteNewerOnlyDesc),
    ];
    final chosenLabel = choices.firstWhere((c) => c.$1 == chosen, orElse: () => choices.first).$2;
    final chosenUnavailable = chosen == OverwriteAction.newer && newerUnavailable;

    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.fileWarning,
      title: l10n.sftpOverwriteTitle(destName),
      // Exact when the scan could count every conflict up front ("1 of 4").
      // When it could not (a huge tree, or a same-size file that only a
      // content compare can settle), a running "Conflict N".
      subtitle: widget.total > 1 || !exact
          ? (exact
              ? l10n.sftpOverwriteCounter(widget.index, widget.total)
              : l10n.sftpOverwriteConflictN(widget.index))
          : null,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Bordered two-column compare: source on a sunken surface,
          // destination on a raised one, one shared left edge and a 1px
          // divider, so the paths line up for a direct read.
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.divider),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Column(
                children: [
                  _side(l10n, widget.sourceVerb ?? l10n.sftpVerbCopying, src,
                      LucideIcons.upload, AppColors.surfaceDark,
                      isNewer: srcNewer),
                  Container(height: 1, color: AppColors.divider),
                  _side(l10n, l10n.sftpOverwriteReplacingLabel, dst,
                      LucideIcons.fileWarning,
                      AppColors.surfaceContainerHighest,
                      isNewer: dstNewer, unreadable: remoteUnreadable),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Dot radios, as every one-of-a-few choice in the app
          // uses.
          RadioGroup<OverwriteAction>(
            groupValue: chosen,
            onChanged: (action) {
              if (action != null) setState(() => _chosen = action);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (action, label, detail) in choices)
                  _ChoiceTile(
                    key: ValueKey('overwrite-choice-${action.name}'),
                    label: label,
                    // "Replace if newer" compares the two ages: where it
                    // cannot, it is offered dim, and says why.
                    detail: action == OverwriteAction.newer && newerUnavailable
                        ? l10n.sftpOverwriteNewerUnavailable
                        : detail,
                    radio: Radio<OverwriteAction>(
                      value: action,
                      enabled: !(action == OverwriteAction.newer && newerUnavailable),
                    ),
                    selected: action == chosen,
                    onTap: action == OverwriteAction.newer && newerUnavailable
                        ? null
                        : () => setState(() => _chosen = action),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Opacity(
            opacity: canApplyToAll ? 1 : 0.4,
            child: InkWell(
              onTap: canApplyToAll
                  ? () => setState(() => _applyToAll = !_applyToAll)
                  : null,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: Checkbox(
                        value: _applyToAll && canApplyToAll,
                        onChanged: canApplyToAll
                            ? (v) => setState(() => _applyToAll = v ?? false)
                            : null,
                        checkColor: AppColors.background,
                        fillColor: WidgetStateProperty.resolveWith(
                          (s) => s.contains(WidgetState.selected)
                              ? AppColors.onSurfaceVariant
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        // Only name a number when the remaining count is
                        // real. A batch whose total is not exact shows the
                        // generic phrasing, never a number worked out from a
                        // partial count ("the remaining conflict" with more to
                        // come).
                        exact && remaining > 0
                            ? l10n.sftpOverwriteApplyRemaining(remaining)
                            : l10n.sftpOverwriteApplyRemainingGeneric,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      // Cancel (all) and the main button, which says the resolution chosen,
      // in the one footer.
      secondaryKey: const ValueKey('overwrite-cancel'),
      secondaryAction: (
        label: isBatch ? l10n.sftpOverwriteCancelAll : l10n.sftpOverwriteCancel,
        onPressed: () => _resolve(OverwriteAction.cancel),
      ),
      primaryKey: const ValueKey('overwrite-go'),
      primaryAction: (
        label: chosenLabel,
        icon: null,
        onPressed: chosenUnavailable ? null : () => _resolve(chosen),
      ),
      // Enter never replaces a file: the main button takes the keyboard
      // only while the choice keeps what is there (the 3.4 security review,
      // L9).
      autofocusPrimary: chosen != OverwriteAction.overwrite,
    );
  }

  String _basename(String p) {
    final norm = p.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i < 0 ? norm : norm.substring(i + 1);
  }
}

/// One resolution in the conflict dialog's list: a radio mark, its name and
/// what it does; the one chosen has a quiet fill (colour in a dialog is for
/// what it means). [onTap] null: offered but not possible here (shown dim,
/// with why in [detail]).
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    super.key,
    required this.label,
    required this.radio,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final Widget radio;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return Opacity(
      opacity: on ? 1 : 0.45,
      child: MergeSemantics(
        child: Semantics(
          enabled: on,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? AppColors.v3TextPrimary.withValues(alpha: 0.06) : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The dot radio (its own tap target off the keyboard's
                    // path: the row is the one to tab to).
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: ExcludeFocus(
                        child: Transform.scale(scale: 0.85, child: radio),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              fontFamily: 'GeistSans',
                              fontSize: 13.5,
                              height: 1.3,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                              color: AppColors.v3TextPrimary,
                            ),
                          ),
                          if (detail != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              detail!,
                              style: TextStyle(
                                fontFamily: 'GeistSans',
                                fontSize: 12,
                                height: 1.4,
                                color: AppColors.v3TextSecondary.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Generates a non-conflicting filename by appending " (n)" before the
/// extension. Returns the *new* filename (no path), starting from `base`
/// and incrementing `n` until `exists(candidate)` returns false.
///
/// Example: `uniqueRenameFor('report.pdf', exists: ...)` → `'report (1).pdf'`
/// the first time, `'report (2).pdf'` if `(1)` is already taken, etc.
Future<String> uniqueRenameFor(
  String base, {
  required Future<bool> Function(String candidate) exists,
}) async {
  final dot = base.lastIndexOf('.');
  // Treat dotfiles (".env", ".gitignore") as having no extension so the
  // suffix lands at the end, not before the dot.
  final hasExt = dot > 0 && dot < base.length - 1;
  final stem = hasExt ? base.substring(0, dot) : base;
  final ext = hasExt ? base.substring(dot) : '';

  for (var n = 1; n < 1000; n++) {
    final candidate = '$stem ($n)$ext';
    if (!await exists(candidate)) return candidate;
  }
  // Pathological - fall back to a timestamp suffix.
  final ts = DateTime.now().millisecondsSinceEpoch;
  return '$stem ($ts)$ext';
}
