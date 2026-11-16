import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../core/theme/zest_colors.dart';
import '../../../models/redactable.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../ui/widgets/copy_details_button.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_a11y.dart';
import '../models/app_notification.dart';
import '../notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Slide-in toast overlay anchored to the top-right of the desktop
/// chrome, under the notifications bell. Stacks toasts vertically with a
/// small gap so multiple notifications don't fight for the same pixels.
///
/// Interaction:
/// * Slide-in animation when shown (right→left, with a slight
///   bounce thanks to easeOutBack).
/// * Slide-out + fade when dismissed (auto or manual).
/// * Click the X to dismiss; click the body to mark as read but
///   keep around in the bell history.
class NotificationToastOverlay extends ConsumerStatefulWidget {
  const NotificationToastOverlay({super.key, required this.child});

  /// The shell widget. We wrap it in a Stack so the toasts can
  /// float on top.
  final Widget child;

  @override
  ConsumerState<NotificationToastOverlay> createState() =>
      _NotificationToastOverlayState();
}

class _NotificationToastOverlayState
    extends ConsumerState<NotificationToastOverlay> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationCenterProvider);
    final toasts = state.visibleToasts;
    final screen = MediaQuery.sizeOf(context);
    // Never let the column run past the window edge on narrow desktops.
    // Top right, under the notifications bell, where each message is kept
    // afterwards (they stood at the
    // bottom right since a report of them covering the session's toolbar).
    const top = DesktopDimensions.pillBarHeight + 8;
    final width = math.min(360.0, screen.width - 32);
    final maxHeight = math.max(120.0, screen.height - top - 16);
    return Stack(
      children: [
        widget.child,
        // Toast column anchored at the top, on the side the bell is (the right,
        // the left in a language written right to left), the oldest on top:
        // a new one comes in under the others, so none moves while it is
        // being read. Position is fixed; the contents are an animated wrap
        // so toasts slide in / out smoothly.
        PositionedDirectional(
          top: top,
          end: 16,
          width: width,
          child: IgnorePointer(
            // Outer IgnorePointer: an empty toast column shouldn't
            // eat clicks from the underlying content. Inner toasts
            // re-enable pointer events.
            ignoring: toasts.isEmpty,
            child: ConstrainedBox(
              // A full queue of tall toasts can exceed the viewport - bound
              // it and scroll rather than overflow off-screen.
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final n in toasts)
                      Padding(
                        key: ValueKey(n.id),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _Toast(
                          notification: n,
                          onDismiss: () => ref
                              .read(notificationCenterProvider.notifier)
                              .dismissToast(n.id),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Single toast card. Renders with a slide-from-right animation on
/// first build and an opacity fade on dismiss.
class _Toast extends StatefulWidget {
  const _Toast({required this.notification, required this.onDismiss});

  final AppNotification notification;
  final VoidCallback onDismiss;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset> _slide;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _slide = Tween<Offset>(
      begin: const Offset(1.4, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
  }

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Less motion asked for: there at once, not slid in.
    if (zestReduceMotion(context)) {
      _ctrl.value = 1;
    } else {
      _ctrl.forward();
    }
    // Said to a screen reader as it comes (Narrator, VoiceOver, Orca): it was
    // drawn in a corner, and nobody heard it. Its words as shown, so
    // recording mode's redaction holds.
    final n = widget.notification;
    final body = n.summary?.join('. ') ?? n.body;
    zestAnnounce(context, [
      Redactable.freeText(n.title).display,
      if (body != null && body.isNotEmpty) Redactable.freeText(body).display,
    ].join('. '));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Play the slide/fade in REVERSE, then actually remove the toast - so
  /// a dismissed toast animates out instead of popping instantly (the
  /// class doc promised this; it never happened). The auto-dismiss timer
  /// path removes from the provider directly and just fades with the tree
  /// rebuild; this covers the manual X / action dismissals.
  void _animateOut() {
    if (zestReduceMotion(context)) {
      widget.onDismiss();
      return;
    }
    if (!_ctrl.isAnimating || _ctrl.status != AnimationStatus.reverse) {
      _ctrl.reverse().then((_) {
        if (mounted) widget.onDismiss();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      // In from the edge it stands at, on either side.
      textDirection: Directionality.of(context),
      position: _slide,
      child: FadeTransition(
        opacity: _opacity,
        child: _ToastBody(
          notification: widget.notification,
          onDismiss: _animateOut,
        ),
      ),
    );
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({required this.notification, required this.onDismiss});

  final AppNotification notification;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final accent = _accentForSeverity(notification.severity);
    final light = Theme.of(context).brightness == Brightness.light;

    // A card a step above the page with a hairline and a shadow: white on a
    // light page (it was the grey of a strong border there, darker than the
    // page). The severity is the icon's colour.
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: light ? ZestColors.chromeElevated : ZestColors.bgSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: light ? ZestColors.borderDefault : ZestColors.borderStrong,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: light ? 0.12 : 0.35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
        Padding(
          // Room at the end for the close button, which stands in the corner.
          padding: const EdgeInsetsDirectional.fromSTEB(12, 11, 34, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // What kind of notice it is, said in words to a screen reader
              // (the colour and the shape alone told it).
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  _iconForSeverity(notification.severity),
                  size: 16,
                  color: accent,
                  semanticLabel: _severityWords(AppLocalizations.of(context)!, notification.severity),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          // A title or body routinely names the host it is
                          // about: free-text redaction (recording mode).
                          child: RedactedText(
                            Redactable.freeText(notification.title),
                            style: TextStyle(
                              color: ZestColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                            // Bound the title like the body so a long /
                            // multi-line title can't inflate the overlay.
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Said again while it stood here: counted, not
                        // stood under itself a second time.
                        if (notification.repeats > 1) ...[
                          const SizedBox(width: 6),
                          NotificationCount(
                            key: const ValueKey('toast-count'),
                            count: notification.repeats,
                            accent: accent,
                          ),
                        ],
                      ],
                    ),
                    // Its summary where it has one, a line each (the whole
                    // is in the bell); else its words.
                    if (notification.summary case final lines? when lines.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Column(
                        key: const ValueKey('toast-summary'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in lines)
                            RedactedText(
                              Redactable.freeText(line),
                              style: _ToastText.style,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ] else if (notification.body != null) ...[
                      const SizedBox(height: 3),
                      _ToastText(text: notification.body!),
                    ],
                    if (notification.actionLabel != null) ...[
                      const SizedBox(height: 6),
                      _ToastAction(
                        label: notification.actionLabel!,
                        accent: ZestColors.accentInk,
                        onPressed: () {
                          // SECURITY: a notification can outlive the
                          // widget that registered its onAction (the
                          // user can leave the action pending in the
                          // bell history for hours). When that's the
                          // case the captured closure may touch a
                          // disposed State / Notifier, which throws
                          // a "setState on disposed widget" loud
                          // enough to crash the app. Catching here
                          // turns that into a no-op and cleanly
                          // dismisses the toast - at worst the user
                          // sees their click do nothing, which is
                          // strictly better than a crash.
                          try {
                            notification.onAction?.call();
                          } catch (_) {/* stale closure - ignore */}
                          onDismiss();
                        },
                      ),
                    ],
                    // What stands behind an error, to take along when asking
                    // for help. Copying leaves the toast where it is.
                    if (notification.details != null) ...[
                      const SizedBox(height: 4),
                      CopyDetailsButton(
                        key: const ValueKey('toast-copy-details'),
                        detail: notification.details!,
                        color: accent,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // Its 22 square cross at the corner, as before, in a 32 square target
        // that reaches into the card's padding.
        PositionedDirectional(top: 6, end: 3, child: _CloseButton(onTap: onDismiss)),
          ],
        ),
      ),
    );
  }
}

/// A notice's kind in words, for a screen reader.
String? _severityWords(AppLocalizations l10n, NotificationSeverity s) => switch (s) {
      NotificationSeverity.error => l10n.a11yNoticeError,
      NotificationSeverity.warning => l10n.a11yNoticeWarning,
      NotificationSeverity.success => l10n.a11yNoticeSuccess,
      NotificationSeverity.info => null,
    };

/// How many times a notice was said, beside its title: on its card while it
/// stands on screen, and on its row in the bell.
class NotificationCount extends StatelessWidget {
  const NotificationCount({super.key, required this.count, required this.accent});

  final int count;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '×$count',
        style: TextStyle(
          color: accent,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A notice's words: whole up to six lines; longer, six and Show more,
/// which shows them all (a sentence cut in the middle with nothing to read
/// the rest by told half of it).
class _ToastText extends StatefulWidget {
  const _ToastText({required this.text});

  final String text;

  static const _fewest = 6;

  /// A notice's words in a toast (its summary's too).
  static TextStyle get style => TextStyle(
        color: ZestColors.textSecondary,
        fontSize: 12,
        height: 1.4,
      );

  @override
  State<_ToastText> createState() => _ToastTextState();
}

class _ToastTextState extends State<_ToastText> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final style = _ToastText.style;
    return LayoutBuilder(
      builder: (context, box) {
        final shown = Redactable.freeText(widget.text).display;
        // Measured in the face it is drawn in (the app's, under it).
        final painter = TextPainter(
          text: TextSpan(text: shown, style: DefaultTextStyle.of(context).style.merge(style)),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: _ToastText._fewest,
        )..layout(maxWidth: box.maxWidth);
        final long = painter.didExceedMaxLines;
        painter.dispose();
        final l10n = AppLocalizations.of(context)!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RedactedText(
              Redactable.freeText(widget.text),
              style: style,
              maxLines: _all ? null : _ToastText._fewest,
              overflow: _all ? null : TextOverflow.ellipsis,
            ),
            if (long)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _ToastAction(
                  key: const ValueKey('toast-show-more'),
                  label: _all ? l10n.deskToastShowLess : l10n.deskToastShowMore,
                  accent: ZestColors.textSecondary,
                  onPressed: () => setState(() => _all = !_all),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ToastAction extends StatelessWidget {
  const _ToastAction({
    super.key,
    required this.label,
    required this.accent,
    required this.onPressed,
  });

  final String label;
  final Color accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // Give the action a real button affordance + tap target (was a bare
    // Text with no padding or hover), matching _CloseButton's hover fill.
    // Moved left by its own padding, so its words line up with the text
    // above them.
    return Transform.translate(
      offset: const Offset(-8, 0),
      child: Semantics(
      button: true,
      label: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            hoverColor: accent.withValues(alpha: 0.12),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;
  bool _focusRing = false;

  @override
  Widget build(BuildContext context) {
    final close = AppLocalizations.of(context)!.close;
    // A button by name to a screen reader and a stop for the keyboard, 32
    // square: it was a 22 square picture only a pointer could press.
    return Semantics(
      container: true,
      button: true,
      label: close,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Tooltip(
        message: close,
        excludeFromSemantics: true,
        child: ZestHover(onHover: (h) => setState(() => _hover = h), child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (f) => setState(() => _focusRing = f),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
              widget.onTap();
              return null;
            }),
          },
          child: GestureDetector(
            key: const ValueKey('toast-close'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: SizedBox.square(
              dimension: 32,
              child: Center(
                child: ZestFocusRing(
                  show: _focusRing,
                  radius: 4,
                  gap: 2,
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _hover ? ZestColors.bgSurface : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(LucideIcons.x, size: 13, color: ZestColors.textSecondary),
                  ),
                ),
              ),
            ),
          ),
        )),
      ),
    );
  }
}

Color _accentForSeverity(NotificationSeverity s) {
  switch (s) {
    case NotificationSeverity.info:
      return ZestColors.accentPrimary;
    case NotificationSeverity.success:
      return ZestColors.statusSuccess;
    case NotificationSeverity.warning:
      return ZestColors.statusWarning;
    case NotificationSeverity.error:
      return ZestColors.statusError;
  }
}

IconData _iconForSeverity(NotificationSeverity s) {
  switch (s) {
    case NotificationSeverity.info:
      return LucideIcons.info;
    case NotificationSeverity.success:
      return LucideIcons.checkCircle2;
    case NotificationSeverity.warning:
      return LucideIcons.alertTriangle;
    case NotificationSeverity.error:
      return LucideIcons.xCircle;
  }
}
