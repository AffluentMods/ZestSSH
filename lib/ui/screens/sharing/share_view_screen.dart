import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/tmux/tmux_cell_metrics.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// A live view of someone else's session (3.0, session sharing): their
/// terminal as they see it, at the size it has there, and who has the
/// keyboard. What is typed here goes to their session only while they have
/// handed this viewer the keyboard, and the screen says so the whole time.
class ShareViewScreen extends ConsumerStatefulWidget {
  const ShareViewScreen({super.key, required this.shareId, required this.onLeave});

  final String shareId;

  /// Leaves this screen (the view itself goes on unless it was left).
  final VoidCallback onLeave;

  @override
  ConsumerState<ShareViewScreen> createState() => _ShareViewScreenState();
}

class _ShareViewScreenState extends ConsumerState<ShareViewScreen> {
  final _terminalController = TerminalController();
  final _focus = FocusNode();
  (String, double, TextScaler)? _cellKey;
  Size _cell = const Size(8, 16);

  @override
  void dispose() {
    _terminalController.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    await ShareViews.close(widget.shareId);
    if (mounted) widget.onLeave();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<Map<String, ShareViewerController>>(
      valueListenable: ShareViews.active,
      builder: (context, views, _) {
        final view = views[widget.shareId];
        final share = ShareViews.shareOf(widget.shareId);
        if (view == null || share == null) {
          return Scaffold(
            backgroundColor: ZestColors.bgContent,
            body: SafeArea(
              child: _Centered(
                icon: LucideIcons.eyeOff,
                title: l10n.shareUiViewEndedTitle,
                body: l10n.shareEndEnded,
                action: l10n.close,
                onAction: widget.onLeave,
              ),
            ),
          );
        }
        final who = Redactable.account(share.fromEmail ?? l10n.shareSomeone).displayIn(ref);
        return ListenableBuilder(
          listenable: view,
          builder: (context, _) => Scaffold(
            backgroundColor: ZestColors.bgContent,
            body: SafeArea(
              child: Column(
                children: [
                  _header(l10n, view, share, who),
                  Expanded(child: _body(l10n, view, who)),
                  _footer(l10n, view, who),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The screen's header, the same in every state: 56 high, the title at
  /// 16 and where it is at 13, and Leave as a neutral button.
  Widget _header(AppLocalizations l10n, ShareViewerController view, IncomingShare share, String who) {
    final host = share.hostLabel == null ? null : Redactable.host(share.hostLabel!).displayIn(ref);
    final where = host == null ? l10n.shareInviteInCrate(share.crateName) : l10n.shareInviteOn(host, share.crateName);
    final title = l10n.shareViewTitle(who);
    final titleStyle = TextStyle(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600, color: ZestColors.textPrimary);
    final leaving = view.phase != ShareViewPhase.ended;
    return Container(
      height: 56,
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(bottom: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: LayoutBuilder(builder: (context, box) {
        // Leave with its word where the title keeps its room beside it,
        // otherwise its icon alone, the word its tooltip: on a phone the
        // title was cut ("Session of dana@example.…", found in a design
        // audit).
        var iconOnly = false;
        if (leaving) {
          final words = TextPainter(
            text: TextSpan(text: title, style: DefaultTextStyle.of(context).style.merge(titleStyle)),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final room = box.maxWidth - 44 - 4 - 8 - shareButtonWidth(context, l10n.shareViewLeave, dense: true);
          iconOnly = words.width > room;
          words.dispose();
        }
        return Row(
          children: [
            IconButton(
              key: const ValueKey('share-view-back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              icon: const Icon(LucideIcons.arrowLeft, size: 18),
              color: ZestColors.textSecondary,
              onPressed: widget.onLeave,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title,
                      key: const ValueKey('share-view-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle),
                  Text(where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, height: 1.3, color: ZestColors.textTertiary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (leaving)
              shareButton(
                key: const ValueKey('share-view-leave'),
                label: l10n.shareViewLeave,
                icon: LucideIcons.logOut,
                onPressed: () => unawaited(_leave()),
                dense: true,
                iconOnly: iconOnly,
              ),
          ],
        );
      }),
    );
  }

  Widget _body(AppLocalizations l10n, ShareViewerController view, String who) {
    switch (view.phase) {
      case ShareViewPhase.connecting:
        return _Centered(busy: true, title: l10n.shareViewConnecting);
      case ShareViewPhase.waitingForHost:
        return _Centered(busy: true, title: l10n.shareViewWaiting(who));
      case ShareViewPhase.joining:
        return _Centered(busy: true, title: l10n.shareViewJoining);
      case ShareViewPhase.ended:
        return _Centered(
          icon: LucideIcons.eyeOff,
          title: l10n.shareUiViewEndedTitle,
          body: _endText(l10n, view.end, who),
          action: l10n.close,
          onAction: () => unawaited(_leave()),
        );
      case ShareViewPhase.watching:
        return _terminal(view);
    }
  }

  String _endText(AppLocalizations l10n, ShareViewEnd? end, String who) => switch (end) {
        ShareViewEnd.stopped => l10n.shareEndStopped(who),
        ShareViewEnd.sessionClosed => l10n.shareEndSessionClosed,
        ShareViewEnd.removed => l10n.shareEndRemoved(who),
        ShareViewEnd.notFound => l10n.shareEndNotFound,
        ShareViewEnd.signedOut => l10n.shareEndSignedOut,
        ShareViewEnd.elsewhere => l10n.shareEndElsewhere,
        ShareViewEnd.full => l10n.shareEndFull,
        ShareViewEnd.refused => l10n.shareEndRefused(who),
        ShareViewEnd.failed => l10n.shareEndFailed,
        ShareViewEnd.ended || ShareViewEnd.left || null => l10n.shareEndEnded,
      };

  /// The least size a watched terminal's text is drawn at. Where their
  /// terminal would have to be shrunk below it to fit (a phone), it is drawn
  /// at this size and panned instead.
  static const double _readableFont = 11;

  Widget _terminal(ShareViewerController view) {
    final theme = ref.watch(terminalThemeProvider);
    final style = ref.watch(terminalStyleProvider);
    final keyboardLearns = !ref.watch(keyboardIncognitoProvider);
    final compactKeyboard = ref.watch(compactKeyboardProvider);
    // On a computer, copy and paste by the keys Settings binds them to.
    final bindings = isDesktopPlatform ? ref.watch(shortcutBindingsProvider) : null;
    final scaler = MediaQuery.textScalerOf(context);
    final key = (style.fontFamily, style.fontSize, scaler);
    if (_cellKey != key) {
      _cellKey = key;
      _cell = measureTerminalCell(style, scaler);
    }
    final terminal = view.terminal;
    final width = terminal.viewWidth * _cell.width;
    final height = terminal.viewHeight * _cell.height;
    final grid = SizedBox(
      width: width,
      height: height,
      child: TerminalView(
        terminal,
        key: ValueKey('share-view-terminal-${widget.shareId}'),
        controller: _terminalController,
        focusNode: _focus,
        theme: theme,
        textStyle: style,
        textScaler: scaler,
        padding: EdgeInsets.zero,
        // The size is the other terminal's, never this window's.
        autoResize: false,
        autofocus: true,
        // Nothing typed here goes anywhere unless the keyboard was
        // handed over (the controller drops it); read-only also keeps
        // a phone's keyboard down while only watching.
        readOnly: !view.isTyping,
        // A terminal's own keys, as every terminal has them
        // (terminalKeys); a paste only while the keyboard is this
        // one's.
        shortcuts: terminalKeys(
          paste: () {
            if (view.isTyping) pasteClipboardIntoTerminal(context, ref, terminal);
          },
          bindings: bindings,
          selected: () => _terminalController.selection != null,
        ),
        onKeyboardPaste: (text) {
          if (view.isTyping) pasteTextIntoTerminal(context, ref, terminal, text);
        },
        personalizedLearning: keyboardLearns,
        // The keyboard without suggestions where its person chose it
        // (Settings), else the widget's own, as it was.
        keyboardType: compactKeyboard ? TextInputType.visiblePassword : TextInputType.emailAddress,
        // Hidden where the program on the other side hid it (4.0).
        alwaysShowCursor: false,
      ),
    );
    return ColoredBox(
      color: theme.background,
      // The whole area is the terminal's ground, with their terminal in its
      // top left corner, as a terminal sits in its window.
      child: SizedBox.expand(
        child: LayoutBuilder(builder: (context, constraints) {
          final fit = width <= 0 || height <= 0
              ? 1.0
              : [(constraints.maxWidth - 16) / width, (constraints.maxHeight - 16) / height, 1.0]
                  .reduce((a, b) => a < b ? a : b);
          final least = style.fontSize <= _readableFont ? 1.0 : _readableFont / style.fontSize;
          if (fit >= least) {
            // Their terminal at its own size: shrunk to fit a smaller
            // window, never stretched in a larger one.
            return Padding(
              padding: const EdgeInsets.all(8),
              child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.topLeft, child: grid),
            );
          }
          // Shrunk to fit, it could not be read: drawn at the least size
          // that can, and moved sideways (and down) with a finger.
          return _PannedTerminal(
            terminal: terminal,
            scale: least,
            size: Size(width * least, height * least),
            child: FittedBox(fit: BoxFit.fill, alignment: Alignment.topLeft, child: grid),
          );
        }),
      ),
    );
  }

  /// The status bar under their terminal: who has the keyboard, in a few
  /// words (that the view is end-to-end encrypted, with the whole sentence
  /// behind the info mark), and the one thing to do about it as a button.
  /// Narrow (a phone), the button is on a row of its own.
  Widget _footer(AppLocalizations l10n, ShareViewerController view, String who) {
    if (view.phase != ShareViewPhase.watching) return const SizedBox.shrink();
    final typing = view.isTyping;
    final String state = switch (view.keyboard) {
      ShareKeyboard.you => l10n.shareViewTyping,
      ShareKeyboard.someoneElse => l10n.shareUiViewStatus(l10n.shareViewSomeoneTyping),
      ShareKeyboard.host => l10n.shareUiViewStatus(view.mayEnd ? l10n.shareUiViewCanEndShort : l10n.shareViewWatching),
    };
    final Widget? action = typing
        ? shareButton(
            key: const ValueKey('share-view-give-back'),
            label: l10n.shareViewGiveBack,
            onPressed: view.giveBack,
            dense: true,
          )
        : view.mayAsk
            ? shareButton(
                key: const ValueKey('share-view-ask'),
                label: view.isAsking ? l10n.shareViewAsked : l10n.shareViewAsk,
                kind: ShareButtonKind.primary,
                icon: LucideIcons.keyboard,
                onPressed: view.isAsking ? null : view.askKeyboard,
                dense: true,
              )
            : view.mayEnd
                ? shareButton(
                    key: const ValueKey('share-view-end'),
                    label: l10n.shareViewEnd,
                    kind: ShareButtonKind.danger,
                    onPressed: () => unawaited(_endSession(l10n, view, who)),
                    dense: true,
                  )
                : null;
    final status = Row(
      children: [
        Icon(typing ? LucideIcons.keyboard : LucideIcons.lock,
            size: 14, color: typing ? ZestTokens.brandInk : ZestTokens.textTertiary),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            state,
            key: const ValueKey('share-view-state'),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              fontWeight: typing ? FontWeight.w600 : FontWeight.w400,
              color: typing ? ZestTokens.textPrimary : ZestTokens.textSecondary,
            ),
          ),
        ),
        if (!typing) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: l10n.shareViewEncrypted,
            child: Icon(LucideIcons.info, size: 14, color: ZestTokens.textTertiary),
          ),
        ],
      ],
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        // The keyboard is this viewer's: a brand rule says so the whole time.
        border: Border(
          top: typing
              ? BorderSide(color: ZestTokens.brand, width: 2)
              : BorderSide(color: ZestColors.borderDefault),
        ),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth >= 560 || action == null) {
          return Row(children: [
            Expanded(child: status),
            if (action != null) ...[const SizedBox(width: 12), action],
          ]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: status),
            const SizedBox(height: 6),
            Align(alignment: AlignmentDirectional.centerEnd, child: action),
          ],
        );
      }),
    );
  }

  /// Ends the session being watched, after a yes that says what it does.
  Future<void> _endSession(AppLocalizations l10n, ShareViewerController view, String who) async {
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.shareViewEndTitle(who),
      body: l10n.shareViewEndBody,
      confirmLabel: l10n.shareViewEnd,
    );
    if (go == true) view.endSession();
  }
}

/// Their terminal, larger than the screen, moved with a finger: sideways, and
/// up and down. A drag goes to one thing only. Up and down, the terminal's
/// own history scrolls first while it can go that way; at its end (or with
/// no history at all) the same drag moves the view. In the alternate screen
/// (vim, less, top) the terminal has no history, and a drag there would only
/// send arrow keys to their program: it moves the view instead, and the
/// keyboard (where it is handed over) is what scrolls their program. Before,
/// the terminal kept every up-and-down drag it could take, so the view could
/// not be moved to its lower rows while there was history, nor at all in the
/// alternate screen.
class _PannedTerminal extends StatefulWidget {
  const _PannedTerminal({required this.terminal, required this.scale, required this.size, required this.child});

  final Terminal terminal;

  /// How much smaller [child] is drawn than its own size.
  final double scale;

  /// The size it is drawn at.
  final Size size;
  final Widget child;

  @override
  State<_PannedTerminal> createState() => _PannedTerminalState();
}

class _PannedTerminalState extends State<_PannedTerminal> {
  final _down = ScrollController();
  late bool _alt = widget.terminal.isUsingAltBuffer;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminal);
  }

  @override
  void didUpdateWidget(_PannedTerminal old) {
    super.didUpdateWidget(old);
    if (old.terminal != widget.terminal) {
      old.terminal.removeListener(_onTerminal);
      widget.terminal.addListener(_onTerminal);
      _alt = widget.terminal.isUsingAltBuffer;
    }
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminal);
    _down.dispose();
    super.dispose();
  }

  /// Built again only when the terminal goes into or out of the alternate
  /// screen, not at each line it is sent.
  void _onTerminal() {
    if (!mounted || widget.terminal.isUsingAltBuffer == _alt) return;
    setState(() => _alt = widget.terminal.isUsingAltBuffer);
  }

  /// The terminal's history at its end and the finger still going: the view
  /// moves by the rest (in the terminal's own pixels, drawn [scale] smaller).
  bool _handOver(OverscrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n.dragDetails == null || !_down.hasClients) return false;
    final p = _down.position;
    final to = (p.pixels + n.overscroll * widget.scale).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (to != p.pixels) _down.jumpTo(to);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final base = ScrollConfiguration.of(context);
    return SingleChildScrollView(
      key: const ValueKey('share-view-pan'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(8),
      child: SingleChildScrollView(
        controller: _down,
        child: SizedBox.fromSize(
          size: widget.size,
          child: NotificationListener<OverscrollNotification>(
            onNotification: _handOver,
            // Clamped everywhere, so that the end of the history is said
            // (a bounce, as on iOS, says nothing of it) and handed over.
            child: ScrollConfiguration(
              behavior: base.copyWith(
                physics: _alt ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A state of the view with nothing to watch: an icon tile (or a spinner in
/// it), what is going on, why where there is more to say, and one thing to
/// do, in a column no wider than 360.
class _Centered extends StatelessWidget {
  const _Centered({required this.title, this.body, this.busy = false, this.icon, this.action, this.onAction});

  final String title;
  final String? body;
  final bool busy;
  final IconData? icon;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: ZestTokens.surfaceChip,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: ZestTokens.borderSubtle),
                  ),
                  child: busy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.brand),
                        )
                      : Icon(icon ?? LucideIcons.users, size: 22, color: ZestTokens.textSecondary),
                ),
                const SizedBox(height: 16),
                Text(title,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, height: 1.35, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                if (body != null) ...[
                  const SizedBox(height: 8),
                  Text(body!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, height: 1.5, color: ZestTokens.textSecondary)),
                ],
                if (action != null) ...[
                  const SizedBox(height: 20),
                  shareButton(
                    key: const ValueKey('share-view-close'),
                    label: action!,
                    kind: ShareButtonKind.primary,
                    onPressed: onAction,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}
