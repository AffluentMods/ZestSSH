import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/hit_area.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/editor_find.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/editor_workspace.dart';

/// A host's colour in the editor: the stripe of its tabs, so two files of
/// the same name on two hosts never look alike. The same host has the same
/// colour each time; this computer's files are neutral.
Color editorHostColour(String? host) {
  if (host == null || host.isEmpty) return AppColors.v3TextTertiary;
  const palette = [
    Color(0xFF10B981),
    Color(0xFF3B82F6),
    Color(0xFFA855F7),
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
    Color(0xFF14B8A6),
    Color(0xFF6366F1),
    Color(0xFFEF4444),
  ];
  var h = 0;
  for (final u in host.codeUnits) {
    h = (h * 31 + u) & 0x7FFFFFFF;
  }
  return palette[h % palette.length];
}

/// What names [source]'s host in the editor's words (a notice, a question):
/// its label, masked while recording mode is on, else the file's name.
String editorHostShown(EditorSource source) {
  final label = source.hostLabel;
  return label == null ? source.fileName : Redactable.host(label).display;
}

/// A host's label as shown (masked in recording mode).
class EditorHostText extends ConsumerWidget {
  const EditorHostText(this.host, {super.key, this.style});

  final String host;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text(Redactable.host(host).displayIn(ref), maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
}

/// The strip of tabs: each file with its host chip and colour, a dot while
/// unsaved, close on hover (always on the current tab), and a tab whose host
/// dropped greyed with Reconnect. [trailing] sits at its right end.
///
/// On a computer (3.4.1) a tab has a menu ([onMenu], a right click: move it
/// to another editor window, close it), is dragged to another place in the
/// strip ([onReorder]), and dragged out of its window and let go goes to the
/// window it was let go on, else a new one ([onDraggedOut]).
class EditorTabStrip extends StatelessWidget {
  const EditorTabStrip({
    super.key,
    required this.workspace,
    required this.onClose,
    required this.onReconnect,
    this.onOpenFile,
    this.onMenu,
    this.onDraggedOut,
    this.onReorder,
    this.trailing = const [],
    this.compact = false,
  });

  final EditorWorkspace workspace;
  final void Function(EditorDocument doc) onClose;
  final void Function(EditorDocument doc) onReconnect;
  final VoidCallback? onOpenFile;
  final void Function(EditorDocument doc, Offset globalPosition)? onMenu;
  final void Function(EditorDocument doc)? onDraggedOut;
  final void Function(int from, int to)? onReorder;
  final List<Widget> trailing;

  /// A phone's: lower, and a strip to swipe.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final docs = workspace.docs;
    return Container(
      key: const ValueKey('editor-tabs'),
      // 48 to a finger: its tabs' targets fill it (4.0 accessibility pass).
      height: touchSizedAt(context) ? 48 : (compact ? 44 : 46),
      decoration: BoxDecoration(
        color: AppColors.v3ChromeBg,
        border: Border(bottom: BorderSide(color: AppColors.v3ChromeDivider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: touchSizedAt(context) ? 0 : 6),
              children: [
                for (var i = 0; i < docs.length; i++) ...[
                  _movable(
                    context,
                    i,
                    docs[i],
                    _EditorTab(
                      key: ObjectKey(docs[i]),
                      doc: docs[i],
                      active: i == workspace.activeIndex,
                      compact: compact,
                      onTap: () => workspace.activateIndex(i),
                      onClose: () => onClose(docs[i]),
                      onReconnect: () => onReconnect(docs[i]),
                      onMenu: onMenu == null ? null : (at) => onMenu!(docs[i], at),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (onOpenFile != null)
                  IconButton(
                    key: const ValueKey('editor-open-file'),
                    tooltip: l10n.editorOpenFile,
                    onPressed: onOpenFile,
                    icon: Icon(LucideIcons.plus, size: 16, color: AppColors.v3TextTertiary),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }

  /// [tab] dragged (a computer's strip): onto another tab, to its place;
  /// out of the window, to [onDraggedOut].
  Widget _movable(BuildContext context, int index, EditorDocument doc, Widget tab) {
    if (compact || (onDraggedOut == null && onReorder == null)) return tab;
    Offset? last;
    return DragTarget<EditorDocument>(
      onWillAcceptWithDetails: (d) => d.data != doc && workspace.docs.contains(d.data),
      onAcceptWithDetails: (d) {
        final from = workspace.docs.indexOf(d.data);
        if (from >= 0) onReorder?.call(from, index);
      },
      builder: (context, _, _) => Draggable<EditorDocument>(
        data: doc,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(opacity: 0.85, child: _DraggedTab(doc: doc)),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: tab),
        onDragUpdate: (d) => last = d.globalPosition,
        onDragEnd: (d) {
          final at = last;
          if (d.wasAccepted || at == null || onDraggedOut == null || !context.mounted) return;
          final size = MediaQuery.sizeOf(context);
          // Let go outside the window: to another window.
          if (at.dx < 0 || at.dy < 0 || at.dx > size.width || at.dy > size.height) onDraggedOut!(doc);
        },
        child: tab,
      ),
    );
  }
}

/// A tab as it is dragged.
class _DraggedTab extends StatelessWidget {
  const _DraggedTab({required this.doc});

  final EditorDocument doc;

  @override
  Widget build(BuildContext context) => Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.v3Surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.v3AccentPrimary.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.fileText, size: 13, color: AppColors.v3TextPrimary),
            const SizedBox(width: 7),
            Text(doc.source.fileName, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.v3TextPrimary)),
          ],
        ),
      );
}

/// The main window's editor minimized (3.4.1), in the status bar: how many
/// files it holds and whether any is unsaved; a click shows it again.
class EditorMinimizedChip extends ConsumerWidget {
  const EditorMinimizedChip({super.key, required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(editorWorkspaceProvider);
    if (!ws.minimized || ws.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final unsaved = ws.unsaved.length;
    final label = l10n.editorMinimizedFiles(ws.length);
    return Tooltip(
      message: unsaved > 0 ? '${l10n.editorShowEditor}\n${l10n.editorMinimizedUnsaved(unsaved)}' : l10n.editorShowEditor,
      child: Semantics(
        button: true,
        label: unsaved > 0 ? '$label, ${l10n.editorMinimizedUnsaved(unsaved)}' : label,
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('editor-minimized'),
          onTap: onShow,
          borderRadius: BorderRadius.circular(5),
          child: Container(
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.v3AccentPrimary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppColors.v3AccentPrimary.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.fileCode, size: 12, color: AppColors.v3AccentInk),
                const SizedBox(width: 5),
                Text(label, style: TextStyle(fontSize: 11.5, color: AppColors.v3AccentInk)),
                if (unsaved > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    key: const ValueKey('editor-minimized-unsaved'),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: AppColors.v3AccentPrimary, shape: BoxShape.circle),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorTab extends StatefulWidget {
  const _EditorTab({
    super.key,
    required this.doc,
    required this.active,
    required this.compact,
    required this.onTap,
    required this.onClose,
    required this.onReconnect,
    this.onMenu,
  });

  final EditorDocument doc;
  final bool active;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onReconnect;
  final void Function(Offset globalPosition)? onMenu;

  @override
  State<_EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<_EditorTab> {
  /// The keyboard's focus is on the tab, and shown.
  bool _focused = false;

  bool _hover = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _reveal();
  }

  @override
  void didUpdateWidget(_EditorTab old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _reveal();
  }

  /// The tab in front is slid into view in the strip (a phone's shows two
  /// or three at once).
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 160));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final doc = widget.doc;
    final host = doc.source.hostLabel;
    final off = !doc.source.isConnected;
    final colour = editorHostColour(host);
    final textColor = off
        ? AppColors.v3TextDisabled
        : widget.active
            ? AppColors.v3TextPrimary
            : AppColors.v3TextSecondary;
    final showClose = widget.active || _hover || _focused;
    final touch = touchSizedAt(context);
    void menuHere() {
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || widget.onMenu == null) return;
      widget.onMenu!(box.localToGlobal(box.size.center(Offset.zero)));
    }

    // To a screen reader the tab is one control: the file, its host, unsaved
    // or disconnected in words, selected while in front, its menu as an
    // action (4.0 accessibility pass: its words were read apart, with no
    // state). To a keyboard a stop of Tab, Enter bringing it to the front,
    // the accent ringing it with the focus. 48 high to a finger.
    Widget tab = Semantics(
      // (Where a finger taps it, its HitArea below is its node.)
      container: !touch,
      button: true,
      selected: widget.active,
      label: [
        doc.source.fileName,
        if (host != null) Redactable.host(host).display,
        if (doc.modified) l10n.editorUnsavedChanges,
        if (off) l10n.editorHostDisconnected(host ?? ''),
      ].join(', '),
      onTap: widget.onTap,
      onLongPress: widget.onMenu == null ? null : menuHere,
      customSemanticsActions:
          widget.onMenu == null ? null : {CustomSemanticsAction(label: l10n.a11yTabMenu): menuHere},
      child: FocusableActionDetector(
      onShowFocusHighlight: (on) => setState(() => _focused = on),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
      },
      child: MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        excludeFromSemantics: true,
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: widget.onMenu == null || !touchSizedAt(context)
            ? null
            : (d) => widget.onMenu!(d.globalPosition),
        child: Container(
          key: ValueKey('editor-tab-${doc.source.identity}'),
          height: widget.compact || touch ? 32 : 34,
          padding: const EdgeInsets.only(left: 12, right: 6),
          decoration: BoxDecoration(
            color: off
                ? Colors.transparent
                : widget.active || _hover
                    ? AppColors.v3Surface
                    : AppColors.v3Background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused
                  ? ZestTokens.brand
                  : widget.active && !off
                      ? AppColors.v3AccentPrimary.withValues(alpha: 0.45)
                      : AppColors.v3BorderSubtle,
              width: _focused ? 2 : 1,
            ),
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border(left: BorderSide(color: off ? colour.withValues(alpha: 0.4) : colour, width: 3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(off ? LucideIcons.unplug : LucideIcons.fileText, size: 13, color: textColor),
              const SizedBox(width: 7),
              ExcludeSemantics(
                child: Text(
                  doc.source.fileName,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: textColor),
                ),
              ),
              if (host != null) ...[
                const SizedBox(width: 7),
                ExcludeSemantics(
                  child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: off ? Colors.transparent : AppColors.v3Elevated,
                    borderRadius: BorderRadius.circular(5),
                    border: off ? Border.all(color: AppColors.v3BorderSubtle) : null,
                  ),
                  child: EditorHostText(
                    host,
                    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, color: off ? AppColors.v3TextDisabled : AppColors.v3TextTertiary),
                  ),
                ),
                ),
              ],
              if (off) ...[
                const SizedBox(width: 6),
                InkWell(
                  key: ValueKey('editor-reconnect-${doc.source.identity}'),
                  onTap: widget.onReconnect,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
                    decoration: BoxDecoration(color: AppColors.v3Elevated, borderRadius: BorderRadius.circular(6)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.refreshCw, size: 11, color: AppColors.v3TextSecondary),
                        const SizedBox(width: 5),
                        Text(l10n.editorReconnect, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              HitArea(
                // 40 by 48 to a finger (it was 22 square).
                grow: touch ? const EdgeInsets.symmetric(vertical: 13) : EdgeInsets.zero,
                child: SizedBox(
                width: touch ? 40 : 22,
                height: 22,
                child: showClose
                    ? Tooltip(
                        message: l10n.editorCloseTab,
                        excludeFromSemantics: true,
                        child: Semantics(
                          // Which file it closes ("Close config.yaml").
                          container: !touch,
                          button: true,
                          label: l10n.desktopTerminalAreaCloseNamedTab(doc.source.fileName),
                          excludeSemantics: true,
                          onTap: widget.onClose,
                          child: InkWell(
                            key: ValueKey('editor-tab-close-${doc.source.identity}'),
                            onTap: widget.onClose,
                            borderRadius: BorderRadius.circular(5),
                            child: Icon(LucideIcons.x, size: 13, color: AppColors.v3TextSecondary),
                          ),
                        ),
                      )
                    : doc.modified
                        ? Center(
                            child: Container(
                              key: ValueKey('editor-tab-unsaved-${doc.source.identity}'),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: AppColors.v3AccentPrimary, shape: BoxShape.circle),
                            ),
                          )
                        : null,
              ),
              ),
            ],
          ),
        ),
      ),
      ),
      ),
    );
    // A pill 32 high whose target is 48 where a finger taps it.
    if (touch) tab = Center(child: HitArea(grow: const EdgeInsets.symmetric(vertical: 8), child: tab));
    if (!off) return tab;
    return Tooltip(message: l10n.editorHostDisconnected(host ?? ''), child: tab);
  }
}

/// A small button of the toolbar: an icon and, on a computer, its word.
class EditorToolButton extends StatelessWidget {
  const EditorToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.on = false,
    this.showLabel = true,
    this.tooltip,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool on;
  final bool showLabel;
  final String? tooltip;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null
        ? AppColors.v3TextDisabled
        : on
            ? AppColors.v3TextPrimary
            : AppColors.v3TextSecondary;
    final button = InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        height: 30,
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 9 : 7),
        decoration: BoxDecoration(
          color: on ? AppColors.v3Elevated : null,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            if (showLabel) ...[
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12.5, color: color)),
            ],
            if (trailing != null) ...[const SizedBox(width: 4), trailing!],
          ],
        ),
      ),
    );
    return Tooltip(message: tooltip ?? label, waitDuration: const Duration(milliseconds: 400), child: button);
  }
}

/// Find and replace in one row (3.4): the pattern with match case, whole
/// word, regex and in the selection inside its field, the count, previous
/// and next, then the replacement with Replace and Replace all. Where the
/// window is narrow the replacement takes a second row.
class EditorFindBar extends StatelessWidget {
  const EditorFindBar({super.key, required this.find, required this.onClose});

  final EditorFindController find;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder(
      valueListenable: find,
      builder: (context, value, _) {
        final count = find.matchCount;
        final said = find.badPattern
            ? l10n.editorBadPattern
            : count == 0
                ? (find.findInputController.text.isEmpty ? '' : l10n.editorNoResults)
                : l10n.editorMatchCount(find.currentIndex + 1, count);
        Widget toggle(String key, Widget face, String tip, bool on, VoidCallback tap) => Tooltip(
              message: tip,
              child: InkWell(
                key: ValueKey(key),
                onTap: tap,
                borderRadius: BorderRadius.circular(5),
                child: Container(
                  width: 26,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? AppColors.v3AccentPrimary.withValues(alpha: 0.16) : null,
                    borderRadius: BorderRadius.circular(5),
                    border: on ? Border.all(color: AppColors.v3AccentPrimary.withValues(alpha: 0.5)) : null,
                  ),
                  child: face,
                ),
              ),
            );
        TextStyle faceStyle(bool on) => TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: on ? AppColors.v3AccentInk : AppColors.v3TextSecondary,
            );
        final findField = _field(
          key: const ValueKey('editor-find-field'),
          controller: find.findInputController,
          focusNode: find.findInputFocusNode,
          hint: l10n.editorFind,
          icon: LucideIcons.search,
          onSubmitted: (_) => find.nextMatch(),
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              toggle('editor-find-case', Text('Aa', style: faceStyle(find.caseSensitive)), l10n.editorMatchCase,
                  find.caseSensitive, find.toggleCaseSensitive),
              toggle(
                  'editor-find-word',
                  Text('ab', style: faceStyle(find.wholeWord).copyWith(decoration: TextDecoration.underline)),
                  l10n.editorWholeWord,
                  find.wholeWord,
                  find.toggleWholeWord),
              toggle('editor-find-regex', Text('.*', style: faceStyle(find.regex)), l10n.editorRegex, find.regex,
                  find.toggleRegex),
              toggle(
                  'editor-find-selection',
                  Icon(LucideIcons.textSelect, size: 13, color: find.inSelection ? AppColors.v3AccentInk : AppColors.v3TextSecondary),
                  l10n.editorInSelection,
                  find.inSelection,
                  find.toggleInSelection),
              const SizedBox(width: 3),
            ],
          ),
        );
        final counts = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 74,
              child: Text(
                said,
                key: const ValueKey('editor-find-count'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11.5,
                  color: find.badPattern ? AppColors.v3Error : AppColors.v3TextSecondary,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.editorPreviousMatch,
              onPressed: count == 0 ? null : find.previousMatch,
              icon: const Icon(LucideIcons.arrowUp, size: 15),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: l10n.editorNextMatch,
              onPressed: count == 0 ? null : find.nextMatch,
              icon: const Icon(LucideIcons.arrowDown, size: 15),
              visualDensity: VisualDensity.compact,
            ),
          ],
        );
        final replaceField = _field(
          key: const ValueKey('editor-replace-field'),
          controller: find.replaceInputController,
          focusNode: find.replaceInputFocusNode,
          hint: l10n.editorReplaceWith,
          onSubmitted: (_) => find.replaceMatch(),
        );
        final replaceButtons = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SmallButton(key: const ValueKey('editor-replace-one'), label: l10n.editorReplace, onPressed: count == 0 ? null : find.replaceMatch),
            const SizedBox(width: 6),
            _SmallButton(key: const ValueKey('editor-replace-all'), label: l10n.editorReplaceAll, onPressed: count == 0 ? null : find.replaceAllMatches),
          ],
        );
        final close = IconButton(
          key: const ValueKey('editor-find-close'),
          tooltip: l10n.textEditorCloseFindBar,
          onPressed: onClose,
          icon: const Icon(LucideIcons.x, size: 15),
          visualDensity: VisualDensity.compact,
        );
        final replacing = value?.replaceMode ?? false;
        return Container(
          key: const ValueKey('editor-find-bar'),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(
            color: AppColors.v3Surface,
            border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
          ),
          child: LayoutBuilder(builder: (context, c) {
            final oneRow = c.maxWidth >= 860;
            if (oneRow) {
              return Row(
                children: [
                  SizedBox(width: 360, child: findField),
                  counts,
                  if (replacing) ...[
                    Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: AppColors.v3BorderSubtle),
                    SizedBox(width: 240, child: replaceField),
                    const SizedBox(width: 8),
                    replaceButtons,
                  ] else
                    TextButton(
                      key: const ValueKey('editor-find-show-replace'),
                      onPressed: find.toggleMode,
                      child: Text(l10n.editorReplace, style: const TextStyle(fontSize: 12)),
                    ),
                  const Spacer(),
                  close,
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [Expanded(child: findField), counts, close]),
                if (replacing) ...[
                  const SizedBox(height: 6),
                  Row(children: [Expanded(child: replaceField), const SizedBox(width: 6), replaceButtons, const SizedBox(width: 6)]),
                ] else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('editor-find-show-replace'),
                      onPressed: find.toggleMode,
                      child: Text(l10n.editorReplace, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
              ],
            );
          }),
        );
      },
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required ValueChanged<String> onSubmitted,
    IconData? icon,
    Widget? suffix,
  }) {
    return SizedBox(
      height: 32,
      child: TextField(
        key: key,
        controller: controller,
        focusNode: focusNode,
        // Looked for as typed, as the file's text is.
        autocorrect: false,
        enableSuggestions: false,
        smartQuotesType: SmartQuotesType.disabled,
        smartDashesType: SmartDashesType.disabled,
        onSubmitted: onSubmitted,
        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: AppColors.v3TextPrimary),
        cursorColor: AppColors.v3AccentPrimary,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: AppColors.v3TextTertiary),
          isDense: true,
          filled: true,
          fillColor: AppColors.v3Background,
          prefixIcon: icon == null ? null : Icon(icon, size: 14, color: AppColors.v3TextTertiary),
          prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          suffixIcon: suffix,
          suffixIconConstraints: const BoxConstraints(minHeight: 26),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.v3BorderDefault)),
          enabledBorder:
              OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.v3BorderDefault)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.v3AccentPrimary, width: 1.3)),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: AppColors.v3BorderDefault),
        foregroundColor: AppColors.v3TextPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

/// One item of the status bar: its words, and a tap where it opens a choice.
class EditorStatusItem extends StatelessWidget {
  const EditorStatusItem({
    super.key,
    required this.label,
    this.onTap,
    this.tooltip,
    this.leading,
    this.color,
    this.shrinks = false,
  });

  final String label;
  final VoidCallback? onTap;
  final String? tooltip;
  final Widget? leading;
  final Color? color;

  /// Whether it gives way where the bar is narrow (its words end in an
  /// ellipsis): it stands in a row that shares out its width.
  final bool shrinks;

  @override
  Widget build(BuildContext context) {
    final words = Text(
      label,
      maxLines: 1,
      overflow: shrinks ? TextOverflow.ellipsis : null,
      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: color ?? AppColors.v3TextSecondary),
    );
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          if (shrinks) Flexible(child: words) else words,
        ],
      ),
    );
    final tappable = onTap == null
        ? child
        : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(5), child: child);
    final item = tooltip == null ? tappable : Tooltip(message: tooltip!, child: tappable);
    return shrinks ? Flexible(child: item) : item;
  }
}

/// A notice over the code: a file that opened in another encoding, a draft
/// put back. Its own close hides it; [actions] act on it.
class EditorNotice extends StatelessWidget {
  const EditorNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.secondLine,
    this.actions = const [],
    required this.onHide,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? secondLine;
  final List<Widget> actions;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: AppColors.v3Elevated, borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 15, color: AppColors.v3Info),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
                const SizedBox(height: 3),
                Text(body, style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary)),
                if (secondLine != null) ...[
                  const SizedBox(height: 3),
                  Text(secondLine!, style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary)),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 6, children: actions),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.editorHideNotice,
            onPressed: onHide,
            icon: Icon(LucideIcons.x, size: 14, color: AppColors.v3TextTertiary),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
