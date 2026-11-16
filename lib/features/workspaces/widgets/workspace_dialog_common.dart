import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Shared pieces for the workspace save + edit dialogs so both render the
/// preview identically: the layout thumbnail, the `n tabs · n panes` count, a
/// per-pane row (identity colour as a LEFT RULE, host name, `user@address`
/// mono), the keyboard-hint chip, and the relative "opened …" text.

/// `1 tab · 3 panes` - the metadata line. The count words are localised /
/// pluralised; the middot separator is punctuation.
String workspaceCountLabel(AppLocalizations l10n, int tabs, int panes) =>
    '${l10n.workspaceTabCountLabel(tabs)} · '
    '${l10n.workspacePaneCountLabel(panes)}';

/// `opened 2h ago`, or `never opened` when [lastOpened] is null.
String workspaceOpenedLabel(AppLocalizations l10n, DateTime? lastOpened) {
  if (lastOpened == null) return l10n.workspaceNeverOpened;
  // The words that stand inside a sentence ("ouvert il y a 5 min").
  return l10n.workspaceOpenedRelative(timeAgoInSentence(l10n, lastOpened));
}

/// The display name for a member host, substituting a localised placeholder
/// when an unresolved (deleted) host left no stored label. A place that held
/// no host when it was saved (an empty "Connect…" pane) is an empty pane.
String workspaceMemberName(AppLocalizations l10n, WorkspaceMemberHost host) {
  if (host.name.isNotEmpty) return host.name;
  if (host.resolved) return '';
  return host.id.isEmpty ? l10n.desktopTerminalAreaEmptyPane : l10n.workspaceDeletedHost;
}

/// Whether [host] is a pane whose host was deleted since the workspace was
/// saved (it opens empty): not an empty place, which never had one.
bool workspaceMemberDeleted(WorkspaceMemberHost host) => !host.resolved && host.id.isNotEmpty;

/// [workspaceMemberName] as a [Redactable], for painting: a real name goes
/// through the host rule; the localised deleted-host placeholder is not an
/// identifier, so it takes the free-text rule (a pass-through for a plain
/// phrase) and reads the same in both modes.
Redactable workspaceMemberLabel(
    AppLocalizations l10n, WorkspaceMemberHost host) {
  if (host.name.isNotEmpty) return Redactable.host(host.name);
  return Redactable.freeText(workspaceMemberName(l10n, host));
}

/// Small monospace keyboard-hint chip (e.g. `Esc`, `Enter`).
class WorkspaceKbd extends StatelessWidget {
  const WorkspaceKbd(this.label, {super.key, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? AppColors.v3AccentInk : AppColors.v3TextTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent
            ? AppColors.v3AccentPrimary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: accent
              ? AppColors.v3AccentPrimary.withValues(alpha: 0.30)
              : AppColors.v3BorderSubtle,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10.5,
          height: 1.2,
          color: color,
        ),
      ),
    );
  }
}

/// The small pane-layout thumbnail: one thin bar per pane, each carrying its
/// pane's identity colour on the left edge.
class WorkspaceThumbnail extends StatelessWidget {
  const WorkspaceThumbnail({super.key, required this.paneColors});

  final List<Color> paneColors;

  @override
  Widget build(BuildContext context) {
    if (paneColors.isEmpty) {
      return const SizedBox(width: 0, height: 26);
    }
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < paneColors.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(
              width: 13,
              height: 26,
              decoration: BoxDecoration(
                color: AppColors.v3Surface,
                borderRadius: BorderRadius.circular(2),
                border: Border(
                  left: BorderSide(color: paneColors[i], width: 2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single pane row inside the preview box: identity colour LEFT RULE, host
/// name, `user@address` mono. Optional [leading] (a drag grip) and [trailing]
/// (a remove control) turn it into the editable variant used by the edit
/// dialog.
class WorkspacePaneRow extends StatelessWidget {
  const WorkspacePaneRow({
    super.key,
    required this.host,
    this.leading,
    this.trailing,
    this.showDivider = true,
  });

  final WorkspaceMemberHost host;
  final Widget? leading;
  final Widget? trailing;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = workspaceMemberLabel(l10n, host);
    return Container(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.04),
                ),
              )
            : null,
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            // Identity colour = left rule. Never status.
            Container(width: 2, color: host.resolvedColor),
            const SizedBox(width: 10),
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: RedactedText(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12.5,
                    color: host.resolved
                        ? AppColors.v3TextPrimary
                        : AppColors.v3TextTertiary,
                    fontStyle:
                        host.resolved ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ),
            ),
            // A host deleted since: said, so the row's remove control reads
            // as the way to tidy it (it opens as an empty pane meanwhile).
            if (workspaceMemberDeleted(host)) ...[
              const SizedBox(width: 10),
              Icon(LucideIcons.alertCircle, size: 12, color: AppColors.v3Warning),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  l10n.docCheckWorkspaceHostDeleted,
                  key: const ValueKey('workspace-pane-host-deleted'),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: AppColors.v3TextTertiary),
                ),
              ),
            ] else if (host.userAtAddress.isNotEmpty) ...[
              const SizedBox(width: 10),
              Flexible(
                child: RedactedText(
                  Redactable.freeText(host.userAtAddress),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10.5,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 6),
              trailing!,
            ],
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// Icon-tile header shared by both dialogs. The icon follows the same rule as
/// the workspace card: NEUTRAL by default, brand-toned only when [accent] is
/// set (the edit dialog passes "this workspace is open now"), so the card and
/// the editor read the same workspace identically.
class WorkspaceDialogHeader extends StatelessWidget {
  const WorkspaceDialogHeader({
    super.key,
    required this.title,
    this.subtitle,
    required this.onClose,
    this.accent = false,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onClose;

  /// Brand-tone the icon tile (the workspace is open right now). Neutral
  /// otherwise, matching the card.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final tileBg = accent
        ? AppColors.v3AccentPrimary.withValues(alpha: 0.14)
        : AppColors.v3Surface;
    final tileBorder = accent
        ? AppColors.v3AccentPrimary.withValues(alpha: 0.32)
        : AppColors.v3BorderSubtle;
    final glyph = accent ? AppColors.v3AccentInk : AppColors.v3TextTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tileBg,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: tileBorder),
            ),
            child: Icon(LucideIcons.layoutGrid, size: 17, color: glyph),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      height: 1.4,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _WorkspaceCloseButton(onPressed: onClose),
        ],
      ),
    );
  }
}

class _WorkspaceCloseButton extends StatefulWidget {
  const _WorkspaceCloseButton({required this.onPressed});
  final VoidCallback onPressed;
  @override
  State<_WorkspaceCloseButton> createState() => _WorkspaceCloseButtonState();
}

class _WorkspaceCloseButtonState extends State<_WorkspaceCloseButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(message: AppLocalizations.of(context)!.close, child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            LucideIcons.x,
            size: 14,
            color: _hover ? AppColors.v3TextPrimary : AppColors.v3TextSecondary,
          ),
        ),
      )),
    );
  }
}

/// Filled primary action. A null [onPressed] renders a flat neutral disabled
/// state (never a muddy dark-orange).
class WorkspacePrimaryButton extends StatelessWidget {
  const WorkspacePrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.v3AccentPrimary
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: enabled
                  ? Colors.white
                  : AppColors.v3TextTertiary.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outlined secondary action.
class WorkspaceOutlineButton extends StatelessWidget {
  const WorkspaceOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.shrink = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// A label that may be too long (one with a name in it) ends in an ellipsis
  /// at the width it is given. Only where it is given one: not as a plain
  /// child of a row.
  final bool shrink;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = enabled
        ? AppColors.v3TextSecondary
        : AppColors.v3TextTertiary.withValues(alpha: 0.6);
    return GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 7),
              ],
              if (shrink)
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                )
              else
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The combined-look name field used by both workspace dialogs: a left "NAME"
/// cell against the input, in the host-editor style.
/// Focus lifts the border to accent; [warn] lifts it to amber for an
/// unresolved name collision. This replaces the stacked-label ZestTextField so
/// both dialogs read identically.
class WorkspaceNameField extends StatefulWidget {
  const WorkspaceNameField({
    super.key,
    required this.controller,
    required this.label,
    this.hintText,
    this.autofocus = false,
    this.warn = false,
    this.onChanged,
    this.onSubmit,
  });

  final TextEditingController controller;
  final String label;
  final String? hintText;
  final bool autofocus;

  /// When true the field is drawn in the amber "collision" state, paired with
  /// a [WorkspaceCollisionCallout] below it.
  final bool warn;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmit;

  @override
  State<WorkspaceNameField> createState() => _WorkspaceNameFieldState();
}

class _WorkspaceNameFieldState extends State<WorkspaceNameField> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusNode.requestFocus();
        widget.controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.controller.text.length,
        );
      });
    }
  }

  void _onFocusChange() => setState(() {});

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focusNode.hasFocus;
    final Color border;
    final List<BoxShadow>? glow;
    if (widget.warn) {
      border = AppColors.v3Warning.withValues(alpha: 0.8);
      glow = [
        BoxShadow(
          color: AppColors.v3Warning.withValues(alpha: 0.12),
          blurRadius: 0,
          spreadRadius: 3,
        ),
      ];
    } else if (focused) {
      border = AppColors.v3AccentPrimary.withValues(alpha: 0.7);
      glow = [
        BoxShadow(
          color: AppColors.v3AccentPrimary.withValues(alpha: 0.14),
          blurRadius: 0,
          spreadRadius: 3,
        ),
      ];
    } else {
      border = AppColors.v3BorderSubtle;
      glow = null;
    }

    // ONE bordered container owns the whole field (the design-system field
    // spec): a label cell plus a flush value region. The focus / warn state
    // lives on THIS outer border and ring only. The inner TextField must draw
    // no border of its own: `border: InputBorder.none` is only the fallback
    // and the app theme's enabledBorder / focusedBorder (both outlines) were
    // still painting a second, heavier orange border around the input on
    // focus, so every variant is nulled explicitly below.
    return Container(
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: border,
          width: (focused || widget.warn) ? 1.2 : 1,
        ),
        boxShadow: glow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 70,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12,
                color: AppColors.v3TextTertiary,
              ),
            ),
          ),
          // The sunken value region: flush, no border of its own.
          Expanded(
            child: ColoredBox(
              color: AppColors.v3Background,
              child: Center(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmit == null
                      ? null
                      : (_) => widget.onSubmit!(),
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.v3TextPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    hintStyle: TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: AppColors.v3TextTertiary,
                    ),
                    isDense: true,
                    filled: false,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    counterText: '',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rich name-collision callout shared by BOTH workspace dialogs
/// ("Save, name already exists"). Spells out the diff instead of a thin
/// error line: a headline naming the existing workspace with its pane count and
/// last-opened time, a line listing its current panes plus the "keeps its
/// place" promise, and the two resolutions `Replace "<name>"` (amber filled)
/// and `Save as "<name> N"` (outline). The caller keeps Save disabled until one
/// is chosen or the name is edited to something free. In a dialog the two are
/// its footer's (the dialog rules of 3.4: no buttons in a dialog's body), and
/// this only says: [onReplace] and [onSaveAs] null.
class WorkspaceCollisionCallout extends ConsumerWidget {
  const WorkspaceCollisionCallout({
    super.key,
    required this.existing,
    this.saveAsName,
    this.onReplace,
    this.onSaveAs,
  });

  /// The already-saved workspace whose name was typed.
  final WorkspaceView existing;

  /// First free `"<name> N"` offered by the outline resolution.
  final String? saveAsName;
  final VoidCallback? onReplace;
  final VoidCallback? onSaveAs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final warn = AppColors.v3Warning;

    // Painted names go through the toolkit; the collision itself was
    // resolved on the raw names by the caller.
    final existingName = Redactable.workspace(existing.name).displayIn(ref);
    final buttons = onReplace != null && onSaveAs != null && saveAsName != null;
    final detail = '${l10n.workspacePaneCountLabel(existing.paneCount)}, '
        '${workspaceOpenedLabel(l10n, existing.lastOpened)}';
    final panes = existing.memberHosts
        .map((h) => workspaceMemberLabel(l10n, h).displayIn(ref))
        .where((n) => n.isNotEmpty)
        .join(', ');
    // Replacing keeps its name and its place in the list (no key launches a
    // workspace, so there is no shortcut to keep).
    final keepsLine = l10n.workspaceCollisionKeepsPosition;

    return Container(
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: warn.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.alertCircle, size: 14, color: warn),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.workspaceCollisionHeadline(existingName, detail),
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            panes.isEmpty
                ? keepsLine
                : '${l10n.workspaceCollisionPanesLine(panes)} $keepsLine',
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 11.5,
              height: 1.5,
              color: AppColors.v3TextTertiary,
            ),
          ),
          if (buttons) ...[
            const SizedBox(height: 10),
            // Under one another where a long name leaves no room side by side.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                WorkspaceWarnButton(
                  label: l10n.workspaceReplaceNamed(existingName),
                  onPressed: onReplace!,
                ),
                WorkspaceOutlineButton(
                  label: l10n.workspaceSaveAsNamed(Redactable.workspace(saveAsName!).displayIn(ref)),
                  shrink: true,
                  onPressed: onSaveAs,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The segmented identity bar: one stacked
/// color segment per member host, in pane order, so a workspace's member colors
/// read at a glance. Identity only, never status.
class WorkspaceSegmentBar extends StatelessWidget {
  const WorkspaceSegmentBar({
    super.key,
    required this.colors,
    this.width = 3,
    this.height = 34,
  });

  final List<Color> colors;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final segs = colors.isEmpty ? [AppColors.neutralLabelColor] : colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(width / 2),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            for (final c in segs)
              Expanded(child: Container(color: c)),
          ],
        ),
      ),
    );
  }
}

/// Amber "warn" action used for `Replace "<name>"`.
class WorkspaceWarnButton extends StatelessWidget {
  const WorkspaceWarnButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.v3Warning,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1B1202),
            ),
          ),
        ),
      ),
    );
  }
}
